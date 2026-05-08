import http from 'k6/http';
import { commonTags, targetURL } from './tags.js';
import { dialerThresholds } from './thresholds.js';
import { makeCustomMetrics, recordResponse } from './helpers.js';

// Forces a fresh TCP+TLS handshake every iteration by disabling connection reuse.
// This isolates dialer setup cost - critical for tsnet stress tests.

const URL = targetURL('http://hello-world.tailscale-examples');
const m = makeCustomMetrics('k6_dialer');

export const options = {
  scenarios: {
    burst: {
      executor: 'ramping-arrival-rate',
      startRate: parseInt(__ENV.START_RATE || '5'),
      timeUnit: '1s',
      preAllocatedVUs: parseInt(__ENV.PRE_VUS || '50'),
      maxVUs: parseInt(__ENV.MAX_VUS || '500'),
      stages: [
        { target: parseInt(__ENV.PEAK_RATE || '200'), duration: __ENV.RAMP || '1m' },
        { target: parseInt(__ENV.PEAK_RATE || '200'), duration: __ENV.HOLD || '2m' },
        { target: 0, duration: '30s' },
      ],
    },
  },
  thresholds: dialerThresholds,
  tags: commonTags(),
  noConnectionReuse: true,
};

export default function () {
  const res = http.get(URL, { timeout: '10s' });
  recordResponse(m, res);
}
