import http from 'k6/http';
import { targetURL } from './tags.js';
import { bandwidthThresholds } from './thresholds.js';
import { makeCustomMetrics, recordResponse } from './helpers.js';

const URL = targetURL('http://hello-world.tailscale-examples') + (__ENV.PATH_SUFFIX || '/10mb');
const m = makeCustomMetrics('k6_bandwidth');

const hosts = __ENV.HOSTS_OVERRIDE
  ? Object.fromEntries(__ENV.HOSTS_OVERRIDE.split(',').map((s) => s.split('=')))
  : undefined;

export const options = {
  scenarios: {
    download: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS || '4'),
      duration: __ENV.DURATION || '2m',
    },
  },
  thresholds: bandwidthThresholds,
  noConnectionReuse: __ENV.NO_REUSE === 'true',
  hosts,
};

export default function () {
  const res = http.get(URL, { timeout: '60s', responseType: 'binary' });
  recordResponse(m, res);
}
