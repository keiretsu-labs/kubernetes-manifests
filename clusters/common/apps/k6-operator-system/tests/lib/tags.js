// Helper: read TARGET_URL from env with a default fallback.
//
// Tags themselves (cluster_src, cluster_dst, transport, payload, k6_version)
// are NOT set from JS — the k6 prometheus-rw output ignores `options.tags`,
// so they're passed via --tag CLI flags from the TestRun's `arguments` field.
// See runs/intra-cluster/lan-latency.yaml for the canonical pattern.

export function targetURL(defaultURL) {
  return __ENV.TARGET_URL || defaultURL;
}
