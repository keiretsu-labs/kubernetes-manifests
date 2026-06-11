import http from 'k6/http';
import { sleep } from 'k6';
import { targetURL } from './tags.js';
import { soakThresholds } from './thresholds.js';
import { makeCustomMetrics, recordResponse } from './helpers.js';

// Long-running stability test - reveals leaks, slow degradation, eventual
// reconnect storms. Default 1 hour. Run before/after a ts upgrade for
// regression comparison.

const URL = targetURL('http://hello-world.tailscale-examples');
const m = makeCustomMetrics('k6_soak');

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS || '10'),
      duration: __ENV.DURATION || '1h',
    },
  },
  thresholds: soakThresholds,
};

export default function () {
  const res = http.get(URL, { timeout: '5s' });
  recordResponse(m, res);
  sleep(parseFloat(__ENV.SLEEP || '1'));
}
