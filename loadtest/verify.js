// k6 load profile for verify-api.
//   k6 run -e BASE_URL=http://localhost:8080 -e RPS=200 loadtest/verify.js
//
// Uses only phone numbers in the NANP fictional range 555-0100..0199,
// so no load test can ever touch a real person's number.

import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const RPS = parseInt(__ENV.RPS || '100', 10);
const DURATION = __ENV.DURATION || '5m';

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RPS,
      timeUnit: '1s',
      duration: DURATION,
      preAllocatedVUs: Math.max(50, RPS),
      maxVUs: RPS * 4,
    },
  },
  // Same numbers as the SLOs in observability/slo-rules.yaml.
  thresholds: {
    http_req_failed: ['rate<0.001'],
    'http_req_duration{expected_response:true}': ['p(99)<300'],
  },
};

const areaCodes = ['214', '469', '972', '817', '682'];

function syntheticPhone() {
  const area = areaCodes[Math.floor(Math.random() * areaCodes.length)];
  const line = 100 + Math.floor(Math.random() * 100); // 0100-0199
  return `+1${area}5550${line}`;
}

export default function () {
  const res = http.post(
    `${BASE_URL}/v1/verify`,
    JSON.stringify({ phone_number: syntheticPhone(), consent: true, channel: 'mobile' }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  check(res, { 'status is 200': (r) => r.status === 200 });
}
