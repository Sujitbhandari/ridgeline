# Lab 05: Probes and graceful shutdown

Two failure modes that show up as "random errors during deploys".

## Part A: a slow start becomes a crash loop

```bash
scripts/lab.sh apply labs/05-probes-and-graceful-shutdown broken
kubectl get pods -n identity -w
```

The new release needs 45 seconds to warm up. The startup probe allows 10.

**Observe:** `RESTARTS` climbs, then `CrashLoopBackOff`. `kubectl describe pod`
shows `Startup probe failed: ... connection refused` followed by
`Container app failed startup probe, will be restarted`. The app never got
the chance to finish starting, and the restarts make sure it never will.

Note what **didn't** happen: the old pods kept serving (maxUnavailable 0).
The bad config is stuck in rollout, not in production.

**Know the three probes cold:**

| Probe | Question it answers | On failure | Must not depend on |
|---|---|---|---|
| startup | Has the process finished starting? | restart (after the budget) | anything slow you can't bound |
| liveness | Is the process wedged? | restart | downstream services (a DB blip would restart your whole fleet) |
| readiness | Should I get traffic *right now*? | removed from Service endpoints | nothing: it's allowed to reflect dependencies and draining |

## Part B: dropped requests on every deploy

The same overlay sets `preStopSleepSeconds: 0`. Run load and restart:

```bash
make load RPS=200 DURATION=5m
kubectl -n identity rollout restart deploy/verify-api
```

**Why requests fail:** when a pod is deleted, two things start *in parallel*:
the kubelet sends SIGTERM, and the endpoints controller removes the pod from the
Service. kube-proxy on every node then updates its rules a moment later. For
that moment, traffic is still routed to a process that already stopped
accepting connections.

The fix is boring and effective: a `preStop` sleep of a few seconds runs
*before* SIGTERM, so routing converges first. Then uvicorn drains in-flight
requests within `--timeout-graceful-shutdown`, comfortably inside
`terminationGracePeriodSeconds`. See `services/ridgeline_common/lifecycle.py`.

## Fix

```bash
scripts/lab.sh apply labs/05-probes-and-graceful-shutdown fixed
kubectl -n identity rollout restart deploy/verify-api     # with load running
```

## Results (fill in from your run)

| | Broken | Fixed |
|---|---|---|
| Part A: restarts before you stopped it | | |
| Part B: k6 errors during `rollout restart` at 200 rps | | |
