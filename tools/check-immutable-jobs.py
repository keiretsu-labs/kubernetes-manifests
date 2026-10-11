#!/usr/bin/env python3
"""Catch rendered, same-name Job changes that Flux cannot apply in place."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import yaml


ROOT = Path(__file__).resolve().parent.parent
CLUSTERS = ("talos-ottawa", "talos-robbinsdale", "talos-stpetersburg")
FORCE = "kustomize.toolkit.fluxcd.io/force"
# These Job spec fields can be updated after creation. Treat every other spec
# change as unsafe, including template, selector and future immutable fields.
MUTABLE = frozenset(
    ("parallelism", "completions", "activeDeadlineSeconds", "backoffLimit",
     "ttlSecondsAfterFinished", "suspend")
)


def run(args, *, cwd=ROOT, env=None):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)


def jobs_by_key(documents):
    jobs = {}
    for obj in documents:
        if not isinstance(obj, dict) or obj.get("apiVersion") != "batch/v1" or obj.get("kind") != "Job":
            continue
        meta = obj.get("metadata") or {}
        key = (meta.get("namespace") or "default", meta.get("name"))
        if key[1]:
            jobs[key] = obj
    return jobs


def immutable_spec(job):
    return {key: value for key, value in (job.get("spec") or {}).items() if key not in MUTABLE}


def violations(before, after):
    old = jobs_by_key(before)
    new = jobs_by_key(after)
    findings = []
    for key in sorted(old.keys() & new.keys()):
        previous, current = old[key], new[key]
        if immutable_spec(previous) == immutable_spec(current):
            continue
        if (current.get("spec") or {}).get("ttlSecondsAfterFinished") is not None:
            continue
        annotations = (current.get("metadata") or {}).get("annotations") or {}
        if str(annotations.get(FORCE, "")).lower() in ("enabled", "true"):
            continue
        fields = sorted(
            field for field in immutable_spec(previous).keys() | immutable_spec(current).keys()
            if immutable_spec(previous).get(field) != immutable_spec(current).get(field)
        )
        findings.append((key, fields))
    return findings


def changed_files(base):
    result = run(["git", "diff", "--name-only", "--diff-filter=ACMRT", base, "--"])
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "git diff failed")
    return [Path(line) for line in result.stdout.splitlines()]


def source_file(files, name):
    # Flate's JSON build does not carry a source path. Match a raw Job source
    # first; for chart-generated Jobs, report the changed HelmRelease file.
    manifests = [path for path in files if path.suffix in (".yaml", ".yml") and
                 (str(path).startswith("kubernetes/") or str(path).startswith("clusters/"))]
    name_line = re.compile(r"^\s*name:\s*" + re.escape(name) + r"\s*(?:#.*)?$", re.M)
    for path in manifests:
        if path.is_file():
            data = path.read_text(errors="replace")
            if re.search(r"^kind:\s*Job\s*$", data, re.M) and name_line.search(data):
                return str(path)
    return ", ".join(map(str, manifests[:4])) or "rendered chart/resource"


def render(tree, other, cluster, env):
    result = run(
        [str(ROOT / "tools/flate.sh"), "build", "all", "--path", f"clusters/{cluster}",
         "--path-orig", str(other / "clusters" / cluster), "--output", "json",
         "--no-progress", "--allow-missing-secrets"],
        cwd=tree, env=env,
    )
    if result.returncode:
        detail = "\n".join(result.stderr.splitlines()[-15:])
        raise RuntimeError(f"Flate {cluster} render failed in {tree}:\n{detail}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"Flate {cluster} returned invalid JSON: {error}") from error


def raw_job_roots(files, baseline):
    roots = set()
    for path in files:
        parts = path.parts
        if len(parts) < 5 or parts[:3] != ("kubernetes", "apps", "base"):
            continue
        app = Path(*parts[:5])
        if not any((tree / app / "kustomization.yaml").is_file() for tree in (ROOT, baseline)):
            continue
        for tree in (ROOT, baseline):
            directory = tree / app
            if directory.is_dir() and any(
                re.search(r"^kind:\s*Job\s*$", item.read_text(errors="replace"), re.M)
                for item in directory.rglob("*.yaml")
            ):
                roots.add(app)
                break
    return sorted(roots)


def deployed_in(tree, cluster, app):
    location = cluster.removeprefix("talos-")
    pointers = tree / "kubernetes" / "apps" / location
    path = f"path: ./{app}"
    return pointers.is_dir() and any(
        path in pointer.read_text(errors="replace")
        for pointer in pointers.rglob("*.yaml")
    )


def render_raw(tree, app):
    directory = tree / app
    if not directory.is_dir():
        return []
    result = run(["kustomize", "build", "--enable-helm", str(directory)], cwd=tree)
    if result.returncode:
        raise RuntimeError(f"kustomize build {app} failed: {result.stderr.strip()[-1500:]}")
    try:
        return [doc for doc in yaml.safe_load_all(result.stdout) if isinstance(doc, dict)]
    except yaml.YAMLError as error:
        raise RuntimeError(f"kustomize build {app} returned invalid YAML: {error}") from error


def main():
    target = sys.argv[1:] or list(CLUSTERS)
    if any(cluster not in CLUSTERS for cluster in target):
        raise RuntimeError(f"unknown cluster: {target}")
    base_ref = os.environ.get("FLATE_BASE") or "origin/main"
    # GitHub's checkout has origin/main but no local main branch, while the
    # Flate action exports FLATE_BASE=main. Prefer that remote-tracking ref
    # locally too: a stale local main must not widen this comparison.
    candidates = [base_ref]
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9._-]*", base_ref) and not base_ref.startswith("origin/"):
        candidates.insert(0, f"origin/{base_ref}")
    for candidate in candidates:
        resolved = run(["git", "rev-parse", "--verify", f"{candidate}^{{commit}}"])
        if not resolved.returncode:
            break
    if resolved.returncode:
        raise RuntimeError(f"cannot resolve base {base_ref}: {resolved.stderr.strip()}")
    base = resolved.stdout.strip()
    files = changed_files(base)
    if not any(str(path).startswith(("clusters/", "kubernetes/")) for path in files):
        return 0

    # --path-orig selects changed resources. Render each side against the
    # other so removed/renamed Jobs are also visible in the baseline output.
    with tempfile.TemporaryDirectory(prefix="kman-immutable-job-") as tmp:
        baseline = Path(tmp) / "base"
        added = run(["git", "worktree", "add", "--detach", "--quiet", str(baseline), base])
        if added.returncode:
            raise RuntimeError(f"cannot create base worktree: {added.stderr.strip()}")
        try:
            env = os.environ.copy()
            env.pop("FLATE_BASE", None)  # Flate disallows --base with --path-orig.
            findings = []
            raw_roots = raw_job_roots(files, baseline)
            for cluster in target:
                current = render(ROOT, baseline, cluster, env)
                previous = render(baseline, ROOT, cluster, env)
                # Flate's changed-only build omits raw Jobs reached through a
                # Flux Kustomization pointer (including mimir-rules). Render
                # changed raw-Job apps with the same kustomize path Flux uses.
                for app in raw_roots:
                    if deployed_in(ROOT, cluster, app) or deployed_in(baseline, cluster, app):
                        current += render_raw(ROOT, app)
                        previous += render_raw(baseline, app)
                for (namespace, name), fields in violations(previous, current):
                    findings.append(
                        f"{cluster}: batch/v1 Job {namespace}/{name} in "
                        f"{source_file(files, name)} changes immutable spec.{', spec.'.join(fields)}"
                    )
            if findings:
                for finding in findings:
                    print(f"immutable Job: {finding}", file=sys.stderr)
                print("Remedies: rename the Job with a content hash suffix, set "
                      "spec.ttlSecondsAfterFinished, or annotate the Job "
                      "kustomize.toolkit.fluxcd.io/force: enabled.", file=sys.stderr)
                return 1
        finally:
            removed = run(["git", "worktree", "remove", "--force", str(baseline)])
            if removed.returncode:
                print(f"warning: cannot remove temporary worktree: {removed.stderr.strip()}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuntimeError as error:
        print(f"immutable Job check: {error}", file=sys.stderr)
        sys.exit(2)
