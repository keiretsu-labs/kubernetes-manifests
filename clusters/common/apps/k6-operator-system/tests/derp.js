import { check, sleep } from 'k6';
import { WebSocket } from 'k6/experimental/websockets';
import { setTimeout, clearTimeout } from 'k6/timers';
import { commonTags, targetURL } from './tags.js';
import { makeCustomMetrics } from './helpers.js';

// Opens many concurrent WebSocket sessions and holds them open. Useful for
// exercising long-lived connection handling and DERP relay path stability.

const WS_URL = targetURL('wss://derp.${CLUSTER_DOMAIN}/derp');
const m = makeCustomMetrics('k6_ws');

export const options = {
  scenarios: {
    hold: {
      executor: 'per-vu-iterations',
      vus: parseInt(__ENV.VUS || '20'),
      iterations: 1,
      maxDuration: __ENV.DURATION || '3m',
    },
  },
  thresholds: {
    checks: ['rate>0.95'],
  },
  tags: commonTags(),
};

export default function () {
  const ws = new WebSocket(WS_URL);
  let opened = false;
  ws.addEventListener('open', () => {
    opened = true;
    m.successRate.add(true);
  });
  ws.addEventListener('error', (e) => {
    m.errors.add(1);
    m.successRate.add(false);
  });
  ws.addEventListener('message', (msg) => {
    m.bytes.add(msg.data ? msg.data.length : 0);
  });

  const closeAt = setTimeout(() => {
    check(opened, { 'ws connected': (v) => v === true });
    ws.close();
  }, parseInt(__ENV.HOLD_MS || '60000'));
}
