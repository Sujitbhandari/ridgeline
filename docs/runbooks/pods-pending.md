# Runbook: PodsPendingTooLong

```bash
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <pod> -n <ns> | sed -n '/Events/,$p'
```

Read the scheduler's message; it lists why each node was rejected:

| Message fragment | Meaning | Usual fix |
|---|---|---|
| `Insufficient cpu` / `memory` | requests don't fit anywhere | right-size requests; add capacity |
| `didn't match pod topology spread constraints` | a zone is full or missing | add capacity in that zone; check `maxSkew` |
| `didn't match Pod's node affinity/selector` | pinned to labels no schedulable node has | remove/fix the nodeSelector |
| `had untolerated taint` | node reserved for something else | expected for control-plane/dedicated pools |
| `node(s) were unschedulable` | cordoned (drain/upgrade) | wait, or uncordon if the drain is done |

Reproduction: labs/04-scheduling-and-zone-failure.
