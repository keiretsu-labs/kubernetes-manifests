"""Graph vocabulary + service-status logic. Small on purpose.

Nodes are services; edges are DEPENDS_ON (src relies on dst). Container-level
state is folded into the service it runs (one logical health per service).

Service status (worst-wins):
  down > hung > unhealthy > restarting > erroring > starting > healthy

"starting" is transitional (a container coming up during a rolling deploy) and
is NOT a bad status - a service with one ready replica and one starting replica
must not page. A service where NOTHING is ready escalates to unhealthy in
build._collapse.
"""
# status precedence (index 0 = worst); "unknown" sorts last
STATUS_ORDER = ["down", "hung", "unhealthy", "restarting", "erroring", "starting",
                "healthy", "unknown"]
BAD_STATUSES = ["down", "hung", "unhealthy", "restarting", "erroring"]


def derive_container_status(state, health):
    """Map a container's docker/k8s state+health to a service status (pre-metrics)."""
    if state in (None, "", "missing"):
        return "down"
    if state in ("exited", "dead"):
        return "down"
    if state == "created":
        return "starting"  # not yet running: transitional, escalated if nothing is ready
    if state == "paused":
        return "hung"
    if state == "restarting":
        return "restarting"
    if health == "unhealthy":
        return "unhealthy"
    if state == "running":
        return "healthy"
    return "unknown"


def worse(a, b):
    """Return the worse of two statuses per STATUS_ORDER."""
    ia = STATUS_ORDER.index(a) if a in STATUS_ORDER else len(STATUS_ORDER)
    ib = STATUS_ORDER.index(b) if b in STATUS_ORDER else len(STATUS_ORDER)
    return a if ia <= ib else b
