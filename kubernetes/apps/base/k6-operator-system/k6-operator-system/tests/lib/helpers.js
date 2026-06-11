import { Trend, Counter, Rate } from 'k6/metrics';

export function makeCustomMetrics(prefix) {
  return {
    rtt: new Trend(`${prefix}_rtt_ms`, true),
    bytes: new Counter(`${prefix}_bytes_total`),
    errors: new Counter(`${prefix}_errors_total`),
    successRate: new Rate(`${prefix}_success_rate`),
  };
}

export function recordResponse(metrics, res) {
  metrics.rtt.add(res.timings.duration);
  metrics.bytes.add(res.body ? res.body.length : 0);
  const ok = res.status >= 200 && res.status < 400;
  metrics.successRate.add(ok);
  if (!ok) metrics.errors.add(1);
  return ok;
}
