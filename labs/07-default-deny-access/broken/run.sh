#!/usr/bin/env bash
# The verify-api -> risk-scorer grant "expires": stop syncing it and remove it.
set -euo pipefail
kubectl -n argocd patch application access-grants-lab --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null
kubectl delete networkpolicy -A -l app.kubernetes.io/managed-by=accessctl
echo "Grant removed. Run load and watch verify-api."
