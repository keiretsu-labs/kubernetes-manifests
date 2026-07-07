"""Timestamped diagnose snapshots - the postmortem/audit trail.

With auto-refresh the graph is a cache of NOW: once the incident heals, the
state that justified the page is overwritten. When WP_SNAPSHOT_DIR is set,
every diagnose persists {diagnosis + full topology} as JSON, so the verdict
stays reproducible and defensible after the fact. Rotation keeps the newest
WP_SNAPSHOT_KEEP files.
"""
import json
import os
import re
import time

# diagnose-<UTCstamp>[-<n>].json; suffix n orders same-second snapshots.
_SNAP_RE = re.compile(r"^diagnose-(\d{8}T\d{6}Z)(?:-(\d+))?\.json$")


def _snap_key(name):
    """Chronological sort key: (timestamp, collision suffix). Lexicographic
    sorting is WRONG here: '-1.json' < '.json' ('-' < '.') and '-10' < '-2',
    which made rotation delete the newest same-second snapshots."""
    m = _SNAP_RE.match(name)
    return (m.group(1), int(m.group(2) or 0)) if m else ("", 0)


def save(result, topology, directory, keep=100):
    """Write one snapshot; returns its path. Filenames are UTC-timestamped and
    collision-suffixed, written atomically (tmp + rename)."""
    directory = os.path.expanduser(directory)
    os.makedirs(directory, exist_ok=True)
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    # Monotonic collision suffix (max existing + 1), NOT first-free-name: after
    # rotation deletes old files, a freed name must never be reused or the
    # newest snapshot would sort as the oldest and be pruned next.
    same_second = [_snap_key(f)[1] for f in os.listdir(directory)
                   if _SNAP_RE.match(f) and _snap_key(f)[0] == ts]
    n = max(same_second) + 1 if same_second else 0
    path = os.path.join(directory,
                        f"diagnose-{ts}.json" if n == 0 else f"diagnose-{ts}-{n}.json")
    doc = {
        "saved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "diagnosis": result,
        "topology": topology,
    }
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, indent=2)
    os.replace(tmp, path)
    _prune(directory, keep)
    return path


def _prune(directory, keep):
    if keep <= 0:
        return
    snaps = sorted((f for f in os.listdir(directory) if _SNAP_RE.match(f)),
                   key=_snap_key)
    for name in snaps[:-keep]:
        try:
            os.remove(os.path.join(directory, name))
        except OSError:
            pass


def maybe_save(result, store):
    """Snapshot the diagnosis if WP_SNAPSHOT_DIR is configured. Adds the file
    path to the result; a snapshot failure degrades to a warning, never breaks
    the diagnosis itself."""
    from . import config
    if not config.SNAPSHOT_DIR:
        return result
    try:
        result["snapshot"] = save(result, store.topology(),
                                  config.SNAPSHOT_DIR, config.SNAPSHOT_KEEP)
    except Exception as e:
        result.setdefault("warnings", []).append(f"snapshot failed ({e})")
    return result
