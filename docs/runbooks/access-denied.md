# Runbook: "my service can't reach X"

The most common platform request. Before anyone opens anything by hand:

1. **Is it the network?** In Jaeger, a client span that times out with no
   matching server span means the request never arrived. From the pod:
   `kubectl exec -n <ns> deploy/<svc> -- python -c "import socket; socket.create_connection(('<host>', <port>), 3)"`
   Timeout → dropped by policy. Refused → nothing listening.
2. **Is there a grant?** `kubectl get networkpolicy -A -l app.kubernetes.io/managed-by=accessctl`
   and look for an AccessRequest in `access-requests/<env>/`. Check its `expires`.
3. **Is it AWS?** `AccessDenied` in the app logs names the action and ARN.
   Compare with the rendered policy in `access-requests/rendered/<env>/iam/`.
4. **Fix:** open (or renew) an AccessRequest PR. `accessctl explain` shows
   reviewers exactly what changes; CODEOWNERS routes it to the owning team.

Never apply a NetworkPolicy or IAM change by hand: it will be reverted by
GitOps, and it leaves no audit trail.
