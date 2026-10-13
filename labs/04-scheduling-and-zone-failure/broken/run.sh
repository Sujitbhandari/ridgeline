#!/usr/bin/env bash
# Simulate losing zone lab-a: cordon and drain its node.
set -euo pipefail
node=$(kubectl get nodes -l topology.kubernetes.io/zone=lab-a -o jsonpath='{.items[0].metadata.name}')
echo "Waiting for pods to settle on $node, then draining it (zone lab-a goes away)..."
kubectl -n identity rollout status deploy/verify-api --timeout=120s
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=90s || \
  echo ">>> The drain is stuck. Find out why before you fix anything (see the lab README)."
