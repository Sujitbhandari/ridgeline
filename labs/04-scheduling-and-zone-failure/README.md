# Lab 04: Scheduling and zone failure

**Goal:** understand where the scheduler puts pods and why, what a PodDisruptionBudget
actually protects, and what losing an availability zone does to a service
that isn't spread.

The kind cluster has three workers labeled `topology.kubernetes.io/zone`
`lab-a`, `lab-b`, `lab-c`, standing in for three AZs.

## Run it

```bash
make load RPS=100 DURATION=10m
scripts/lab.sh apply labs/04-scheduling-and-zone-failure broken
```

The overlay pins verify-api to zone `lab-a` (a `nodeSelector` someone added
"because that's where the node pool was") and turns spreading off. Then
`run.sh` drains the lab-a node, which is what an AZ outage, a node upgrade,
or a Karpenter consolidation looks like to your pods.

## Observe

```bash
kubectl get pods -n identity -o wide                 # all 4 replicas on one node
kubectl get pdb -n identity                          # ALLOWED DISRUPTIONS
kubectl describe pod -n identity <a Pending pod>     # read the Events
```

- The drain evicts one pod, then **stops**: `Cannot evict pod as it would violate the pod's disruption budget.`
- The replacement pod is `Pending`. Its event reads roughly:
  `0/4 nodes are available: 1 node(s) were unschedulable, 1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane}, 2 node(s) didn't match Pod's node affinity/selector.`

Read that message slowly. It's the scheduler telling you every filter that
rejected every node. That one line is most of scheduling debugging.

## Diagnose

- The PDB did its job: it refused to let the drain take out more replicas than
  the service can tolerate. But it can't create capacity: the only zone the
  pods may run in is the one being drained.
- In a real AZ outage there is no drain to block. All four replicas go at once.
  Grafana **Pods per zone** shows 100% of the service in one zone.

## Fix

```bash
scripts/lab.sh apply labs/04-scheduling-and-zone-failure fixed
```

The golden-path defaults come back: a **hard** zone spread
(`maxSkew: 1, whenUnsatisfiable: DoNotSchedule`) and a **soft** node spread.
Pods land in lab-b and lab-c, the PDB allows the drain to finish, and the
service keeps serving with zone lab-a gone.

## Questions to answer

1. Why is the zone constraint hard and the node constraint soft? What would
   happen with a hard node constraint and 10 replicas on 3 nodes?
2. With a hard zone spread, what happens when one zone has no capacity left?
   (Pending pods. Why might that be the right trade-off for a 99.99% service?)
3. Why does the chart set `unhealthyPodEvictionPolicy: AlwaysAllow` on the PDB?
4. What does `matchLabelKeys: [pod-template-hash]` change during a rollout?

## Results (fill in from your run)

| | Broken | Fixed |
|---|---|---|
| Replicas per zone before drain | | |
| Did the drain complete? | | |
| Errors seen by k6 during the drain | | |
