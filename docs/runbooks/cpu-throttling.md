# Runbook: ContainerCPUThrottlingHigh

The container spent >25% of CFS periods throttled for 15 minutes. Latency is
being added by the CPU *limit*, not by a lack of node capacity.

1. Confirm: Grafana panel *CPU throttling by pod*, and p99 vs p50 latency.
2. `kubectl get deploy <svc> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].resources}'`
3. If a `cpuLimit` is set in the service's values, remove it (or raise it well
   above p99 usage) and set the request from observed usage instead.
4. If no limit is set and the node is saturated, it's real contention:
   check `kubectl top nodes` and whether requests reflect actual usage.

Background and a reproduction: labs/02-cpu-throttling.
