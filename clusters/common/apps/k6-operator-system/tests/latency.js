import http from 'k6/http';
import { sleep } from 'k6';
import { commonTags, targetURL } from './tags.js';
import { latencyThresholds } from './thresholds.js';
import { makeCustomMetrics, recordResponse } from './helpers.js';

const URL = targetURL('http://hello-world.tailscale-examples');
const m = makeCustomMetrics('k6_latency');

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS || '5'),
      duration: __ENV.DURATION || '2m',
    },
  },
  thresholds: latencyThresholds,
  tags: commonTags(),
};

export default function () {
  const res = http.get(URL, { timeout: '5s' });
  recordResponse(m, res);
  sleep(0.1);
}
