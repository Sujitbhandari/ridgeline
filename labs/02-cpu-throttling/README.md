# Lab 02: CPU throttling (the limit is the bottleneck, not the node)

**Symptom you'll be paged with:** p99 latency is several times p50, but CPU
dashboards say the pods use well under their limit and nodes are mostly idle.

## The mechanism

A CPU *limit* is enforced by the kernel's CFS bandwidth controller in
**100ms periods**. `cpu: 200m` means "20ms of CPU per 100ms period". A
request that needs 15ms of CPU, arriving while other requests already spent
this period's 20ms, is frozen until the next period begins: up to ~80ms of
added latency that shows up nowhere in "average CPU usage", because the
average over a minute is low. Bursty request handlers hit this constantly.

The golden-path chart therefore sets CPU **requests** (for scheduling and fair
share under contention) but **no CPU limit** by default. Memory still gets a
limit, because memory can't be throttled, only killed.

## Run it

```bash
make load RPS=25 DURATION=10m     # low on purpose: 3 throttled pods can only do ~40 rps
scripts/lab.sh apply labs/02-cpu-throttling broken   # cpuLimit 200m, 15ms CPU per request
```

## Observe

- Grafana: **Latency percentiles** p99 climbs; **CPU throttling by pod** goes high.
- After 15 minutes the `ContainerCPUThrottlingHigh` alert fires.
- `kubectl top pods -n identity` shows usage *at or below* the limit. This is the trap.

## Diagnose with data

```promql
# Fraction of CFS periods in which the container was throttled
sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="identity"}[1m]))
/
sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="identity"}[1m]))

# Total time spent throttled, per pod (seconds per second)
sum by (pod) (rate(container_cpu_cfs_throttled_seconds_total{namespace="identity"}[1m]))
```

Open a slow trace in Jaeger. The `risk-scorer.score` span is fast; the gap is
inside verify-api *before* the downstream call, where the CPU work happens.

## Fix

```bash
scripts/lab.sh apply labs/02-cpu-throttling fixed    # no CPU limit, medium size (250m request)
```

Same work per request. Watch throttling drop to ~0 and p99 converge toward p50.

## Questions to answer

1. With a 200m limit and 15ms per request, what is the theoretical max
   throughput of one pod before throttling is guaranteed? (Hint: 20ms / 100ms.)
2. When *would* you set a CPU limit? (Think: multi-tenant noisy batch work,
   or a JVM that sizes thread pools from the cgroup CPU quota.)
3. What does the CPU request still do for you without a limit?

## Results (fill in from your run)

| | Broken (limit 200m) | Fixed (no limit) |
|---|---|---|
| p50 latency | | |
| p99 latency | | |
| Throttled periods % | | |
| CPU usage per pod (`kubectl top`) | | |
