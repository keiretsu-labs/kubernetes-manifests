// SLO definitions reused across tests. Override per-test if needed by
// merging with Object.assign before passing to options.thresholds.

export const latencyThresholds = {
  http_req_duration: ['p(95)<500', 'p(99)<1000'],
  http_req_failed: ['rate<0.01'],
};

export const bandwidthThresholds = {
  http_req_duration: ['p(95)<30000'],
  http_req_failed: ['rate<0.01'],
  data_received: ['count>10485760'],
};

export const dialerThresholds = {
  http_req_connecting: ['p(95)<200', 'p(99)<500'],
  http_req_tls_handshaking: ['p(95)<300'],
  http_req_failed: ['rate<0.05'],
};

export const soakThresholds = {
  http_req_duration: ['p(95)<1000'],
  http_req_failed: ['rate<0.005'],
};
