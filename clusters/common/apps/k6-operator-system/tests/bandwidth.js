import http from 'k6/http';
import { commonTags, targetURL } from './tags.js';
import { bandwidthThresholds } from './thresholds.js';
import { makeCustomMetrics, recordResponse } from './helpers.js';

const URL = targetURL('http://hello-world.tailscale-examples') + (__ENV.PATH_SUFFIX || '/10mb');
const m = makeCustomMetrics('k6_bandwidth');

export const options = {
  scenarios: {
    download: {
      executor: 'constant-vus',
      vus: parseInt(__ENV.VUS || '4'),
      duration: __ENV.DURATION || '2m',
    },
  },
  thresholds: bandwidthThresholds,
  tags: commonTags(),
  noConnectionReuse: __ENV.NO_REUSE === 'true',
};

export default function () {
  const res = http.get(URL, { timeout: '60s', responseType: 'binary' });
  recordResponse(m, res);
}
