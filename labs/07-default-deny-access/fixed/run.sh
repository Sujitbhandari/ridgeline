#!/usr/bin/env bash
# Restore the grant from git (the merged AccessRequest), the GitOps way.
set -euo pipefail
kubectl -n argocd patch application access-grants-lab --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null
echo "Argo CD is re-applying access-requests/rendered/lab/network/ ..."
sleep 15
kubectl get networkpolicy -A -l app.kubernetes.io/managed-by=accessctl
