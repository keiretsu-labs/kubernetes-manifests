// Tag conventions for k6 metrics so dashboards can slice by path.
// All tags here flow through to Prometheus as label dimensions.
//
// Required env vars on the runner pod (set in TestRun.spec.runner.env):
//   CLUSTER_SRC      - source cluster name (e.g. "talos-ottawa")
//   CLUSTER_DST      - destination identifier (e.g. "lan", "robbinsdale", "public")
//   TRANSPORT        - one of: lan, ts-egress, ts-derp, funnel, tsnet-sidecar
//   PAYLOAD          - "small" | "10mb" | "100mb"
//   TESTID           - unique per run, defaults to TestRun name + timestamp

export function commonTags() {
  return {
    cluster_src: __ENV.CLUSTER_SRC || 'unknown',
    cluster_dst: __ENV.CLUSTER_DST || 'unknown',
    transport: __ENV.TRANSPORT || 'unknown',
    payload: __ENV.PAYLOAD || 'small',
    testid: __ENV.TESTID || `local-${Date.now()}`,
    k6_version: __ENV.K6_VERSION || 'default',
    tailscale_operator_version: __ENV.TS_OPERATOR_VERSION || 'unset',
  };
}

export function targetURL(defaultURL) {
  return __ENV.TARGET_URL || defaultURL;
}
