# Lab 06: Memory, OOMKilled, and admission control

## Part A: a leak meets a memory limit

```bash
make load RPS=150 DURATION=10m
scripts/lab.sh apply labs/06-memory-and-admission broken    # 64KB leaked per request
```

**Observe**

```bash
kubectl get pods -n identity -w            # RESTARTS climbing
kubectl describe pod -n identity <pod>     # Last State: Terminated, Reason: OOMKilled, Exit Code: 137
```

```promql
container_memory_working_set_bytes{namespace="identity", container="app"}
kube_pod_container_status_last_terminated_reason{namespace="identity", reason="OOMKilled"}
```

The sawtooth in working-set memory, climbing to the 256Mi limit and dropping
to zero, is the signature of a leak. Each restart drops in-flight requests,
and readiness hides the pod for a few seconds each time.

**Why a memory limit at all?** Memory isn't compressible. Without a limit the
leak grows until the *node* runs out and the kernel kills whatever it picks,
possibly a neighbor. The limit turns "random node-wide damage" into "this
container restarts". The limit is a blast-radius control, not a fix.

**QoS classes** (check with `kubectl get pod <pod> -o jsonpath='{.status.qosClass}'`):
- `Guaranteed`: requests == limits for every resource.
- `Burstable`: requests set, limits higher or missing. The golden path is here.
- `BestEffort`: nothing set. First to be evicted under node pressure.

Fix: `scripts/lab.sh apply labs/06-memory-and-admission fixed`. The real fix
is in the code; the platform's job was to contain it and make it obvious.

## Part B: the noisy neighbor that never gets in

```bash
kubectl apply -f labs/06-memory-and-admission/noisy-neighbor.yaml
```

Kyverno rejects it at admission, listing every violated policy: no requests or
limits, `:latest`-style untrusted image, no probes, runs as root. Read the
message as a developer would. Is it clear what to change?

Then run the same CPU-hungry work the platform way:

```bash
kubectl apply -f labs/06-memory-and-admission/fixed/manifests/batch-job.yaml
```

It has requests (so the scheduler accounts for it), a memory limit, and
`priorityClassName: batch-low` with `preemptionPolicy: Never`. Under
contention, the CPU scheduler shares cycles by *request*, so verify-api's
latency should barely move. Check that with the latency panel instead of
taking it on faith.

## Results (fill in from your run)

| | Value |
|---|---|
| Time from start of load to first OOMKill | |
| Working-set memory slope (MiB/min) | |
| Policies listed in the admission rejection | |
| verify-api p99 with batch-burn running vs without | |
