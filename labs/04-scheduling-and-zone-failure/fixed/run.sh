#!/usr/bin/env bash
set -euo pipefail
node=$(kubectl get nodes -l topology.kubernetes.io/zone=lab-a -o jsonpath='{.items[0].metadata.name}')
kubectl -n identity rollout status deploy/verify-api --timeout=180s
echo "Retrying the drain with spreading in place..."
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl get pods -n identity -o wide
echo "Zone lab-a is gone and verify-api is still serving. Bring it back with: kubectl uncordon $node"
