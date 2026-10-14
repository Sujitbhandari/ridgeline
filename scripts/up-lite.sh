#!/usr/bin/env bash
# A smaller lab for low-resource machines: kind + Calico, Prometheus and
# Grafana, and both services on the golden-path chart. No Argo CD, Kyverno,
# KEDA, Argo Rollouts, Loki, Jaeger or OpenTelemetry Collector, so the chart
# runs with autoscaling off and rolling updates, and spans are not exported.
#
# Requirements: docker, kind, kubectl, helm.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=ridgeline
CALICO_VERSION=${CALICO_VERSION:-v3.29.2}
PROM_CHART_VERSION=${PROM_CHART_VERSION:-69.8.2}
TAG=${TAG:-0.1.0}

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "Creating kind cluster (3 zones)"
  kind create cluster --config infra/kind/cluster.yaml
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# The kind config disables the default CNI, so nodes stay NotReady without this.
log "Installing Calico (CNI and NetworkPolicy enforcement)"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" >/dev/null
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=300s

log "Applying namespaces and priority classes"
kubectl apply -f gitops/platform/baseline/early/ >/dev/null
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace loadtest --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Installing Prometheus and Grafana (kube-prometheus-stack ${PROM_CHART_VERSION})"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$PROM_CHART_VERSION" -n observability --wait --timeout 10m \
  -f gitops/platform/kube-prometheus-stack/values.yaml \
  --set alertmanager.enabled=false \
  --set prometheus.prometheusSpec.resources.requests.memory=512Mi \
  --set-json 'grafana.additionalDataSources=[]' >/dev/null
kubectl apply -f gitops/platform/baseline/observability/dashboard-golden-signals.yaml \
  -f gitops/platform/baseline/observability/platform-alerts.yaml >/dev/null

log "Building service images and loading them into the cluster"
for app in verify_api risk_scorer; do
  img="ridgeline/${app//_/-}:${TAG}"
  docker build -q --build-arg APP="$app" -t "$img" services >/dev/null
  kind load docker-image "$img" --name "$CLUSTER" >/dev/null
  echo "  $img"
done

log "Deploying both services with the platform-service chart"
for svc in risk/risk-scorer identity/verify-api; do
  ns=${svc%/*}; app=${svc#*/}
  helm upgrade --install "$app" charts/platform-service -n "$ns" \
    -f "gitops/tenants/lab/$ns/$app/values.yaml" \
    --set image.tag="$TAG" \
    --set autoscaling.enabled=false \
    --set rollout.strategy=rolling >/dev/null
done
# The chart's baseline NetworkPolicy blocks verify-api -> risk-scorer until
# the access grant is applied.
kubectl apply -f access-requests/rendered/lab/network/ >/dev/null
kubectl -n loadtest create configmap k6-scripts --from-file=loadtest/verify.js \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n risk rollout status deploy/risk-scorer --timeout=180s
kubectl -n identity rollout status deploy/verify-api --timeout=180s

cat <<MSG

Done. Useful next steps:
  make ui-lite         # port-forward Grafana :3000 and Prometheus :9090
  make load RPS=50     # in-cluster k6 against verify-api
  make lab-down        # delete the cluster
MSG
