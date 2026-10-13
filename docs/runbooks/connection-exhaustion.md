# Runbook: connection pool / datastore ceiling

**Alerts:** `UpstreamConnectionsSaturated`, `DatastoreConnectionCeilingNear`.

## Check the arithmetic first

```promql
sum(upstream_pool_size{service="verify-api"})          # what callers *could* open
max(datastore_max_connections)                          # what the datastore allows
sum(datastore_active_connections)                       # what is open now
sum(rate(http_requests_total{service="risk-scorer"}[1m]))   # arrival rate
```

Little's Law: connections needed ≈ request rate × query latency. If that is
under the ceiling but `active` is pinned at the ceiling, the fleet is
over-provisioned with connections, not under-provisioned with capacity.

## Do

- Reduce per-pod pool size (`UPSTREAM_POOL_SIZE`) so `maxReplicas × pool ≤ 0.8 × ceiling`.
- Cap the caller's `autoscaling.maxReplicas` to what the downstream can serve.
- Longer term: a pooler in front of the datastore (PgBouncer / RDS Proxy).

## Don't

- Scale the caller up. Every new pod brings a full pool with it (labs/03).
- Raise the database's max_connections without checking its memory: each
  connection costs RAM on the database side.
