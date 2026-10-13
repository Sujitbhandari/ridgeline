# Labs: break it, watch it, explain it, fix it

Deploying 30 pods is easy. Knowing what to do when 30 pods are running and the
service is still slow is the job. Each lab reproduces a real production
failure mode on the local cluster, on purpose, with the platform's telemetry
watching.

Every lab follows the same loop:

1. **Baseline**: run load, note the golden signals (Grafana → *Ridgeline / Service golden signals*).
2. **Break**: `scripts/lab.sh apply labs/<lab> broken`
3. **Observe**: which alert fires, which panel moves, what `kubectl` says.
4. **Diagnose**: prove the cause with data before touching anything.
5. **Fix**: `scripts/lab.sh apply labs/<lab> fixed`, confirm the signals recover.
6. **Reset**: `scripts/lab.sh reset` (Argo CD converges back to git).
7. **Write it down** in the lab's *Results* table, with your real numbers.

| # | Lab | What it teaches |
|---|-----|-----------------|
| 01 | [Rollouts and rollbacks](01-rollouts-and-rollbacks/) | `maxUnavailable: 0`, progress deadlines, `rollout undo`, SLO-gated canaries that abort themselves |
| 02 | [CPU throttling](02-cpu-throttling/) | CFS quota, why average CPU lies, why the golden path sets no CPU limit |
| 03 | [Scaling makes it worse](03-scaling-makes-it-worse/) | Connection budgets, Little's Law, why more pods can mean more errors |
| 04 | [Scheduling and zone failure](04-scheduling-and-zone-failure/) | Topology spread, node selectors, PDBs blocking drains, reading scheduler events |
| 05 | [Probes and graceful shutdown](05-probes-and-graceful-shutdown/) | Startup vs liveness vs readiness, the endpoint-removal race, preStop |
| 06 | [Memory and admission](06-memory-and-admission/) | OOMKilled, QoS classes, limits as blast radius, admission control as a guardrail |
| 07 | [Default deny and access](07-default-deny-access/) | Debugging NetworkPolicy, self-service access, expiring grants |

## Start load before every lab

```bash
make load RPS=150 DURATION=10m        # in-cluster k6 against verify-api
make ui                               # Grafana :3000, Prometheus :9090, Jaeger :16686, Argo CD :8081
```

## Commands you'll use in every lab

```bash
kubectl get pods -n identity -o wide                 # where did pods land, are they Ready, restarts?
kubectl describe pod -n identity <pod>               # Events: scheduling, probe failures, OOM, pulls
kubectl get events -n identity --sort-by=.lastTimestamp | tail -20
kubectl top pods -n identity                         # metrics-server (current usage, not limits)
kubectl -n identity rollout status deploy/verify-api
kubectl argo rollouts get rollout risk-scorer -n risk --watch
```
