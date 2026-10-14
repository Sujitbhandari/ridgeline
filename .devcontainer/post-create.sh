#!/usr/bin/env bash
# Tools the devcontainer features don't provide. kind matches the node image
# in infra/kind/cluster.yaml; k6 matches the image in loadtest/k6-job.yaml.
set -euo pipefail

KIND_VERSION=${KIND_VERSION:-v0.27.0}
K6_VERSION=${K6_VERSION:-v0.57.0}
arch=$(dpkg --print-architecture)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsSLo "$tmp/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}"
sudo install -m 0755 "$tmp/kind" /usr/local/bin/kind

curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-${arch}.tar.gz" \
  | tar -xz -C "$tmp"
sudo install -m 0755 "$tmp/k6-${K6_VERSION}-linux-${arch}/k6" /usr/local/bin/k6

kind version
k6 version
