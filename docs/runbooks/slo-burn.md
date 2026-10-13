# Runbook: SLO error budget burn

**Alerts:** `<Service>AvailabilityBudgetFastBurn`, `<Service>LatencyBudgetFastBurn` (page),
`...SlowBurn` (ticket). Generated per service by the platform-service chart.

## What it means

- **Fast burn (page):** at the current rate, 2% of the 30-day error budget is
  gone within an hour (14.4x burn), or 5% within 6 hours (6x). Users are hurting now.
- **Slow burn (ticket):** the service will run out of budget before the window
  ends if nothing changes. Fix it this week, not tonight.

## First five minutes

1. **Is it us or a dependency?** Grafana → *Ridgeline / Service golden signals*,
   pick the service. Errors by status: 503s with `risk scoring saturated` /
   `unavailable` point downstream; 500s point at this service.
2. **Did something change?** Argo CD → the app's history. `kubectl argo rollouts get rollout <svc> -n <ns>`.
   A deploy in the last hour is the prime suspect. **Roll back first, debug second.**
3. **Is it everywhere or one place?** Split errors by pod and zone:
   `sum by (pod) (rate(http_requests_total{service="<svc>",code=~"5.."}[5m]))`.
   One bad pod or one zone → cordon/delete, don't redeploy everything.
4. **Pick a trace.** Jaeger → service `<svc>`, tag `error=true`. Which span
   fails or is slow? Click through to the logs (trace_id is on every log line).

## Mitigations, in order of preference

| Situation | Action |
|---|---|
| Recent deploy | Revert the commit (Argo CD syncs it); for a canary, `kubectl argo rollouts abort` |
| Downstream saturated | Shed load or raise the downstream ceiling; **don't scale the caller** (labs/03) |
| CPU throttling | Raise/remove the CPU limit (labs/02) |
| Single bad node/zone | `kubectl cordon` + delete pods there; the spread constraint reschedules elsewhere |
| Crash loops / OOM | Check `Last State` in `kubectl describe pod`; roll back (labs/05, 06) |

## Afterwards

Every page gets a postmortem if it burned >5% of the monthly budget:
[docs/postmortems/TEMPLATE.md](../postmortems/TEMPLATE.md).
