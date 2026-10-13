# Lab 03: Thirty pods, still broken (scaling makes it worse)

**Symptom:** verify-api latency and 503s rise. Someone scales verify-api from
4 to 12 pods. Errors go *up*.

## The setup

- risk-scorer fronts a datastore with a hard ceiling of 60 connections in
  total (2 pods × `MAX_ACTIVE_CONNECTIONS=30`, the same shape as Postgres
  `max_connections`). Each query takes ~100ms.
- Every verify-api pod keeps its own pool of `UPSTREAM_POOL_SIZE` connections
  to risk-scorer.
- Potential concurrent connections = **replicas × pool size**. Nobody owns that number.

## Run it

```bash
scripts/lab.sh apply labs/03-scaling-makes-it-worse broken    # 12+ pods x 20 = 240 potential vs 60
# risk-scorer is a canary Rollout; skip the canary steps for this lab:
kubectl argo rollouts promote risk-scorer -n risk --full
make load RPS=400 DURATION=10m     # lower RPS if your laptop can't generate it; keep RPS x 0.1 under 60
```

## Observe

- k6: rising `http_req_failed`. verify-api returns `503 risk scoring saturated`.
- Grafana **Upstream pool and datastore connections**: `datastore active`
  is pinned at the ceiling while `pool capacity (all pods)` is 4x larger.
- `DatastoreConnectionCeilingNear` pages.
- verify-api's in-flight requests rise, so KEDA adds *more* verify-api pods,
  which adds *more* potential connections. A feedback loop.
- Logs (Grafana → Loki): `{service_name="risk-scorer"} |= "connection refused"`

## Diagnose with Little's Law

Concurrency needed = arrival rate × time in system.

```
400 req/s × 0.1 s per query  ≈ 40 concurrent datastore connections needed
```

40 fits under the ceiling of 60. The capacity was there; the fleet was
configured to *demand* 240 at once, so the datastore spent its time refusing
connections instead of serving queries.

## Fix

```bash
scripts/lab.sh apply labs/03-scaling-makes-it-worse fixed
```

- Pool budget: `maxReplicas × pool ≤ 0.8 × ceiling` → `12 × 4 = 48 ≤ 48`.
- Excess load now **queues** in verify-api (bounded by the upstream timeout)
  instead of being **refused** by the datastore. Latency rises gracefully under
  overload; errors don't.
- In production the structural fix is a connection pooler (PgBouncer / RDS
  Proxy) so pod count and connection count are decoupled.

## Questions to answer

1. Why didn't the HPA help, and what signal *should* have triggered a human?
2. How would you encode the pool budget so the next team can't break it?
   (Ideas: a chart value validated against a catalog-declared ceiling; a
   Kyverno policy; an alert on `sum(upstream_pool_size)` vs the ceiling.)
3. Write the postmortem for this one using [docs/postmortems/TEMPLATE.md](../../docs/postmortems/TEMPLATE.md).

## Results (fill in from your run)

| | Broken | Fixed |
|---|---|---|
| verify-api replicas | | |
| Potential connections (replicas × pool) | | |
| Datastore active connections (peak) | | |
| Error rate | | |
| p99 latency | | |
