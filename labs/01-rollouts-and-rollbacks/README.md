# Lab 01: Rollouts and rollbacks

**Goal:** see two layers of "safe change". A rolling update that can't make
things worse (Part A), and a canary that measures the new version against
the SLO and rolls itself back (Part B).

## Part A: a bad image on a rolling Deployment (verify-api)

```bash
make load RPS=100 DURATION=10m
scripts/lab.sh apply labs/01-rollouts-and-rollbacks broken
kubectl -n identity get pods -w
```

**Observe**
- New pods sit in `ErrImagePull` / `ImagePullBackOff`.
- Old pods keep serving. k6 shows no errors. Why? The chart sets
  `maxUnavailable: 0`, so an old pod is only removed after a new one is Ready.
- `kubectl -n identity rollout status deploy/verify-api` hangs, then fails
  after `progressDeadlineSeconds` (300s) and the Deployment condition becomes
  `Progressing=False, reason=ProgressDeadlineExceeded`.

**Fix**
```bash
kubectl -n identity rollout history deploy/verify-api
kubectl -n identity rollout undo deploy/verify-api
```
Then think about which one is the real fix in a GitOps world: `rollout undo`
stops the bleeding, but git still says `0.1.1-never-pushed`, and Argo CD would
re-apply it. The durable fix is reverting the commit. (Here, `scripts/lab.sh reset`.)

## Part B: a release that fails 5% of requests (risk-scorer, canary)

risk-scorer deploys with `rollout.strategy: canary`. The chart renders an
Argo Rollout plus an AnalysisTemplate that queries the error ratio of **canary
pods only** (via the `rollouts-pod-template-hash` label) and compares it to
the SLO budget (99.9% → 0.1%).

```bash
scripts/lab.sh apply labs/01-rollouts-and-rollbacks broken
kubectl argo rollouts get rollout risk-scorer -n risk --watch
```

**Observe**
- The rollout shifts 10% of traffic to the new ReplicaSet and starts an AnalysisRun.
- `kubectl -n risk get analysisrun` → the run turns `Failed` after `failureLimit` measurements.
- The Rollout goes `Degraded`, traffic returns 100% to stable, canary pods scale down.
- Grafana: the error ratio blips, stays far below the burn-rate alert threshold.
  That's the point: the canary consumed a sliver of error budget instead of 5% of all traffic.

**Questions to answer**
1. How many requests failed in total? (`sum(increase(http_requests_total{service="risk-scorer",code=~"5.."}[15m]))`)
2. What would that number have been with a plain rolling update?
3. Why does the analysis treat "no data yet" as inconclusive rather than success?
   (Look at `successCondition` in `charts/platform-service/templates/observability.yaml`.)

## Results (fill in from your run)

| | Value |
|---|---|
| Part A: errors seen by k6 during the bad rollout | |
| Part A: time until `ProgressDeadlineExceeded` | |
| Part B: canary weight when the analysis aborted | |
| Part B: failed requests during the canary | |
| Part B: estimated failed requests without a canary | |
