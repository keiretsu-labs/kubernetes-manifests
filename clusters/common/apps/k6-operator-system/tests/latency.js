import http from 'k6/http';
import { sleep } from 'k6';
import { targetURL } from './tags.js';
import { latencyThresholds } from './thresholds.js';
import { makeCustomMetrics, recordResponse } from './helpers.js';

const URL = targetURL('http://hello-world.tailscale-examples');
const m = makeCustomMetrics('k6_latency');

// HOSTS_OVERRIDE format: "host1=ip1,host2=ip2"
// Used to bypass cluster DNS for paths like Tailscale Funnel where the
// runner pod cannot resolve the hostname through CoreDNS.
const hosts = __ENV.HOSTS_OVERRIDE
  ? Object.fromEntries(__ENV.HOSTS_OVERRIDE.split(',').map((s) => s.split('=')))
  : undefined;

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS || '5'),
      duration: __ENV.DURATION || '2m',
    },
  },
  thresholds: latencyThresholds,
  hosts,
};

export default function () {
  const res = http.get(URL, { timeout: '5s' });
  recordResponse(m, res);
  sleep(0.1);
}
