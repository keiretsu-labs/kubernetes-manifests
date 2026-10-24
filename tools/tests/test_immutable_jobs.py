#!/usr/bin/env python3
"""Offline regression for the mimir-rules immutable Job incident."""

from copy import deepcopy
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory

import yaml


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("immutable_jobs", ROOT / "tools/check-immutable-jobs.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
fixture = ROOT / "tools/tests/fixtures/immutable-jobs"
before = [yaml.safe_load((fixture / "base.yaml").read_text())]
after = [yaml.safe_load((fixture / "changed.yaml").read_text())]

def rendered_fixture(name):
    with TemporaryDirectory(prefix="immutable-job-fixture-") as directory:
        tree = Path(directory)
        (tree / "job.yaml").write_text((fixture / name).read_text())
        (tree / "kustomization.yaml").write_text(
            "apiVersion: kustomize.config.k8s.io/v1beta1\n"
            "kind: Kustomization\nresources:\n  - job.yaml\n"
        )
        return guard.render_raw(tree, Path("."))


assert guard.violations(rendered_fixture("base.yaml"), rendered_fixture("changed.yaml")) == [
    (('mimir', 'mimir-rules'), ['template'])
]

found = guard.violations(before, after)
assert found == [(('mimir', 'mimir-rules'), ['template'])], found

renamed = deepcopy(after)
renamed[0]['metadata']['name'] = 'mimir-rules-3b6a24dd'
assert not guard.violations(before, renamed)

ttl = deepcopy(after)
ttl[0]['spec']['ttlSecondsAfterFinished'] = 0
assert not guard.violations(before, ttl)

forced = deepcopy(after)
forced[0]['metadata']['annotations'] = {'kustomize.toolkit.fluxcd.io/force': 'enabled'}
assert not guard.violations(before, forced)

mutable = deepcopy(before)
mutable[0]['spec']['backoffLimit'] = 5
assert not guard.violations(before, mutable)

selector = deepcopy(before)
selector[0]['spec']['selector'] = {'matchLabels': {'job': 'changed'}}
assert guard.violations(before, selector) == [(('mimir', 'mimir-rules'), ['selector'])]

unrelated = deepcopy(after)
unrelated[0]['kind'] = 'CronJob'
assert not guard.violations(before, unrelated)
# --- CLI exit-path coverage: exercise main()'s 0/1 branches offline. -------
# main() normally needs a git worktree and flate renders. Stub only the
# boundary functions (production code untouched) and feed synthetic Jobs.

def _main_with_jobs(jobs_a, jobs_b):
    from types import SimpleNamespace as _NS
    import unittest.mock as mock

    def fake_run(args, **_):
        return _NS(returncode=0, stdout="abc123\n", stderr="")

    renders = iter([jobs_b, jobs_a])  # current, previous — per render() call pair

    def render(tree, other, cluster, env):
        return next(renders)

    with mock.patch("sys.argv", ["check-immutable-jobs.py", "talos-ottawa"]), \
         mock.patch.object(guard, "run", fake_run), \
         mock.patch.object(guard, "changed_files",
                           return_value=[Path("kubernetes/apps/base/mimir/x.yaml")]), \
         mock.patch.object(guard, "raw_job_roots", return_value=[]), \
         mock.patch.object(guard, "render", side_effect=render):
        return guard.main()


def _job(spec_overrides=None, annotations=None):
    job = deepcopy(before[0])
    job["kind"] = "Job"
    if spec_overrides:
        job["spec"].update(spec_overrides)
    if annotations:
        job["metadata"]["annotations"] = annotations
    return [job]


# Mutable-only delta -> no findings -> exit 0
assert _main_with_jobs(_job({"backoffLimit": 3}), _job({"backoffLimit": 9})) == 0

# Immutable-field patch (template) with no remedy -> findings -> exit 1
old = _job()
new = deepcopy(old)
new[0]["spec"]["template"]["spec"]["restartPolicy"] = "Never"
assert _main_with_jobs(old, new) == 1

# Same immutable patch but ttlSecondsAfterFinished set -> remedy -> exit 0
remedied = deepcopy(new)
remedied[0]["spec"]["ttlSecondsAfterFinished"] = 0
assert _main_with_jobs(new, remedied) == 0

# Same immutable patch but force annotation -> remedy -> exit 0
forced = deepcopy(new)
forced[0]["metadata"]["annotations"] = {guard.FORCE: "enabled"}
assert _main_with_jobs(new, forced) == 0

# Render failure inside main -> RuntimeError -> CLI contract exit 2 (main raises)
def boom(*_a, **_k):
    raise RuntimeError("synthetic render failure")

from types import SimpleNamespace as _NS
import unittest.mock as mock

def fake_run(args, **_):
    return _NS(returncode=0, stdout="abc123\n", stderr="")

with mock.patch("sys.argv", ["check-immutable-jobs.py", "talos-ottawa"]), \
     mock.patch.object(guard, "run", fake_run), \
     mock.patch.object(guard, "changed_files",
                       return_value=[Path("kubernetes/apps/base/mimir/x.yaml")]), \
     mock.patch.object(guard, "raw_job_roots", return_value=[]), \
     mock.patch.object(guard, "render", side_effect=boom):
    try:
        guard.main()
        raised = False
    except RuntimeError:
        raised = True
assert raised
