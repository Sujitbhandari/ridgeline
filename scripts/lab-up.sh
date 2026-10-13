#!/usr/bin/env bash
# Builds the whole platform on a laptop: kind + Calico + Argo CD, then hands
# off to GitOps. After this script, every change goes through git.
#
# Requirements: docker, kind, kubectl, helm (and a fork/push of this repo if
# you want Argo CD to track your own changes; see REPO_URL below).
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=ridgeline
CALICO_VERSION=${CALICO_VERSION:-v3.29.2}
ARGOCD_CHART_VERSION=${ARGOCD_CHART_VERSION:-7.8.2}
TAG=${TAG:-0.1.0}

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "Creating kind cluster (3 zones)"
  kind create cluster --config infra/kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

log "Installing Calico (NetworkPolicy enforcement)"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "Building service images and loading them into the cluster"
for app in verify_api risk_scorer; do
  img="ridgeline/${app//_/-}:${TAG}"
  docker build -q --build-arg APP="$app" -t "$img" services >/dev/null
  kind load docker-image "$img" --name "$CLUSTER" >/dev/null
  echo "  $img"
done

log "Installing Argo CD ${ARGOCD_CHART_VERSION}"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_CHART_VERSION" \
  -n argocd --create-namespace --wait \
  --set 'configs.params.server\.insecure=true' \
  --set dex.enabled=false --set notifications.enabled=false >/dev/null

log "Bootstrapping GitOps (app-of-apps)"
kubectl apply -f gitops/argocd/projects.yaml
kubectl apply -f gitops/bootstrap/root-app.yaml

log "Preparing the in-cluster load generator"
kubectl create namespace loadtest --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n loadtest create configmap k6-scripts --from-file=loadtest/verify.js \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Waiting for Argo CD to converge (first sync pulls ~10 charts; give it a few minutes)"
for _ in $(seq 1 90); do
  total=$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')
  healthy=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null | grep -c '^Synced/Healthy$' || true)
  printf '\r  %s/%s applications Synced+Healthy ' "$healthy" "$total"
  if [ "$total" -gt 10 ] && [ "$healthy" -eq "$total" ]; then echo; break; fi
  sleep 10
done
echo
kubectl -n argocd get applications

cat <<MSG

Done. Useful next steps:
  make ui        # port-forward Argo CD, Grafana, Prometheus, Jaeger
  make load      # in-cluster k6 load against verify-api
  labs/README.md # start with Lab 01
MSG
