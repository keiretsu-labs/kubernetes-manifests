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
