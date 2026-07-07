"""Connector factories - pick the implementation from config (the seam)."""
from .. import config
from .prometheus import PrometheusSource


def topology_source():
    if config.TOPOLOGY == "k8s":
        from .kubernetes import KubernetesTopology
        namespaces = config.K8S_NAMESPACES or [config.K8S_NAMESPACE]
        return KubernetesTopology(namespaces, config.K8S_CONTEXT,
                                  exclude=config.K8S_EXCLUDE_NAMESPACES)
    if config.TOPOLOGY == "traces":
        from .traces import JaegerTopology
        return JaegerTopology(config.JAEGER_URL, config.TRACES_LOOKBACK)
    from .docker_compose import DockerComposeTopology
    return DockerComposeTopology(config.COMPOSE_PROJECT)


def metrics_source():
    if config.METRICS_BACKEND == "datadog":
        from .datadog import DatadogMetricsSource
        return DatadogMetricsSource()
    return PrometheusSource(
        config.PROM_URL,
        error_rate_query=config.ERROR_RATE_QUERY,
        error_rate_label=config.ERROR_RATE_LABEL,
        db_up_query=config.DB_UP_QUERY,
    )
