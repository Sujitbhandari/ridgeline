# Design decisions

Short records of the choices that shape the platform, and what was traded away.

## 1. One golden-path chart instead of per-team manifests

**Decision:** every HTTP service deploys with `charts/platform-service`. Teams
set a handful of values (team, image, size, SLO, who may call them).

**Why:** the failure modes in the labs (throttling, missing probes, no
spreading, no drain) come from defaults nobody chose on purpose. Encoding
them once means every service inherits fixes. The values schema rejects
`latest` tags and missing owners before anything reaches the cluster.

**Trade-off:** less flexibility. Escape hatches exist (`size: custom`,
`cpuLimit`) and are visible in review.

## 2. Argo CD, app-of-apps, and ApplicationSets

**Decision:** Argo CD reconciles the platform and tenants from git. A
directory under `gitops/tenants/<env>/<namespace>/<service>/` is a service.

**Why:** deploy = merge, rollback = revert, drift is corrected. The audit trail
for a high-compliance environment is the git log. Sync waves give a
deterministic install order (CRDs → operators → telemetry → tenants).

The lab cluster only syncs `gitops/tenants/lab`. Staging lives in
`gitops/staging/tenants.yaml` and is applied on the staging cluster, so a
promotion PR does not also roll the laptop lab onto registry images.

**Trade-off:** emergency changes still go through git. `rollout undo` /
`argo rollouts abort` are the break-glass, and the revert PR follows.

## 3. Two AppProjects

**Decision:** `platform` may create anything; `tenants` may create only a
whitelist of namespaced kinds in tenant namespaces.

**Why:** a values file in a team's directory must never be able to create a
ClusterRole, a webhook, or delete a policy.

## 4. Kyverno for admission, conftest for plans

**Decision:** Kyverno (YAML policies, generate rules, image verification)
in-cluster; OPA/conftest on Terraform plan JSON in CI.

**Why:** Kyverno policies are readable by the developers they block, and its
generate rules give every tenant namespace default-deny and a LimitRange
automatically. Plan-time checks catch IAM wildcards before `apply`.

## 5. No CPU limits by default

**Decision:** presets set CPU requests and memory requests/limits, no CPU limit.

**Why:** CFS quota throttles in 100ms periods and turns bursts into tail
latency while average CPU looks fine (lab 02). Requests still give fair share
under contention. Memory can't be throttled, only killed, so the limit bounds
the blast radius of a leak (lab 06).

## 6. KEDA on in-flight requests

**Decision:** default autoscaling signal is average in-flight requests per pod
from Prometheus, with a CPU trigger as a floor.

**Why:** these services are I/O-bound; CPU barely moves while queues grow.
Concurrency tracks load directly. Lab 03 shows the limit of any autoscaler:
it can't create downstream capacity, so `maxReplicas` has to respect the
downstream's connection budget.

## 7. Canary releases gated on the SLO

**Decision:** `rollout.strategy: canary` renders an Argo Rollout and an
AnalysisTemplate that compares canary-only error ratio against the SLO budget.

**Why:** the canary spends a sliver of error budget instead of all of it.
"No data" is inconclusive, not success, so a canary that gets no traffic
can't pass by accident.

## 8. Multi-window, multi-burn-rate SLO alerts

**Decision:** page on 14.4x (1h & 5m) or 6x (6h & 30m) burn; ticket on 1x (3d & 6h).

**Why:** pages only when the budget is actually in danger, resets quickly
when the burn stops, and still catches slow leaks. Thresholds are derived
from each service's own SLO, so teams change one number.

## 9. Access as code, with expiry

**Decision:** cross-boundary access is an `AccessRequest` file.
`accessctl` validates it against a catalog and renders least-privilege IAM
(Terraform) and NetworkPolicies (Argo CD).

**Why:** the dominant platform interrupt becomes a reviewable PR that routes to
the owners of the resource, not to whoever is on call. Expiry is mandatory;
a nightly job opens PRs removing expired grants. Every rendered object carries
the ticket, requester, expiry and a hash of the request.

**Guardrails:** no wildcards; only catalog actions; per-environment maximum
duration; PII outside production requires a risk-exception ID, security
review, and ≤14 days. IRSA roles have a permissions boundary whose Allow
list is those same catalog actions, plus an explicit Deny for IAM,
Organizations, and CloudTrail.

## 10. PII never leaves the process unredacted

**Decision:** pseudonymize at the edge with a per-environment salt, redact in
the log formatter, and redact again in the OpenTelemetry Collector.

**Why:** defense in depth. Non-production environments work from synthetic
data (NANP 555-01xx numbers in load tests), matching how real data is
excluded outside production except under an approved risk exception.

## 11. Collector egress stays on private ranges

**Decision:** the golden-path NetworkPolicy allows OTLP (port 4317) only to
`10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`.

**Why:** the collector is a hostNetwork DaemonSet, so a pod selector cannot
name it. `0.0.0.0/0` on that port would let every tenant pod reach any
public address that happens to listen there. Private ranges cover kind
nodes and EKS node CIDRs.

**Trade-off:** a collector on a public IP would be unreachable. That is the
intended outcome.

## 12. Python services

**Decision:** the demo services are FastAPI.

**Why:** small, readable, and the official OpenTelemetry instrumentation is
mature. The platform tooling (`accessctl`) is Go, which fits a single static
binary in CI.
