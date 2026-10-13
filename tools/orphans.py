#!/usr/bin/env python3
"""Find listed-but-missing and unlisted YAML files in kustomization trees.

Keep the shallow, fixed-string checks from orphans.sh: this is a drift hint,
not a full Kustomize parser. A single process avoids thousands of grep/awk
invocations on large app trees.
"""

import os
import re
import stat
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RESOURCE_KEYS = {"resources", "components", "crds", "bases"}
GENERATED = (".dec", ".dec.yaml", ".bak", ".tmp")


def progress(message: str) -> None:
    if os.environ.get("KMAN_ORPHANS_PROGRESS") != "1":
        return
    line = f"orphans: {message}\n"
    if os.environ.get("KMAN_ORPHANS_PROGRESS_FD") == "3":
        os.write(3, line.encode())
    else:
        print(line, end="", file=sys.stderr)


def entries(content: str):
    mode = ""
    for line in content.splitlines():
        if re.match(r"^[A-Za-z].*:", line):
            key = line.split(":", 1)[0]
            mode = "r" if key in RESOURCE_KEYS else "p" if key == "patches" else ""
            continue
        value = ""
        kind = ""
        if mode == "r" and re.match(r"^\s+-\s", line):
            value = re.sub(r"^\s*-\s*", "", line)
            kind = "r"
        elif mode == "p" and re.search(r"path:\s", line):
            value = re.sub(r"^.*path:\s*", "", line)
            kind = "p"
        if value:
            value = re.sub(r"\s*#.*", "", value).rstrip().replace('"', "")
            if value and (kind == "r" or re.search(r"\.ya?ml$", value)):
                yield value


def remote(entry: str) -> bool:
    return (
        "://" in entry
        or entry.startswith(("github.com/", "gitlab.com/", "git@"))
        or "?ref=" in entry
    )


def display(path: Path) -> str:
    # Match the shell's ${path#"$ROOT"/}; arbitrary fixture trees remain absolute.
    name = str(path)
    prefix = str(ROOT) + "/"
    return name[len(prefix) :] if name.startswith(prefix) else name


def main() -> int:
    scan = Path(sys.argv[1])
    if not scan.is_dir():
        print(f"orphans.sh: not a directory: {scan}", file=sys.stderr)
        return 2

    report = []
    count = 0
    progress(f"scanning {scan}")
    # find does not descend a symlink passed as its starting path.
    walk = () if scan.is_symlink() else os.walk(scan)
    for directory, _, filenames in walk:
        if "kustomization.yaml" not in filenames:
            continue
        kfile = Path(directory) / "kustomization.yaml"
        if not stat.S_ISREG(kfile.lstat().st_mode):
            continue
        count += 1
        if count % 100 == 0:
            progress(f"checked {count} kustomizations")
        content = kfile.read_text()
        parent = kfile.parent.parent / "kustomization.yaml"
        parent_content = parent.read_text() if parent.is_file() else ""

        for entry in entries(content):
            # Preserve the shell's "$kdir/$entry" behavior even for an entry
            # beginning with / (Path / absolute would discard kdir).
            if not remote(entry) and not os.path.exists(f"{kfile.parent}/{entry}"):
                report.append(f"MISSING   {display(kfile)}  ->  {entry}")

        for filename in filenames:
            # Bash's *.yaml / *.yml globs skip dotfiles by default.
            if filename.startswith("."):
                continue
            if not filename.endswith((".yaml", ".yml")):
                continue
            if filename == "kustomization.yaml" or filename.endswith(GENERATED):
                continue
            sibling = kfile.parent / filename
            if not sibling.exists():
                continue
            relative = f"{kfile.parent.name}/{filename}"
            if filename in content or (parent.is_file() and relative in parent_content):
                continue
            report.append(f"UNLISTED  {display(sibling)}")

    progress(f"checked {count} kustomizations")
    if report:
        print("\n".join(sorted(report)))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
