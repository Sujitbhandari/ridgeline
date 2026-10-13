#!/usr/bin/env bash
# Apply a lab's "broken" or "fixed" state, or reset everything back to git.
#
#   scripts/lab.sh apply labs/02-cpu-throttling broken
#   scripts/lab.sh apply labs/02-cpu-throttling fixed
#   scripts/lab.sh reset
#
# Overlay files are named <namespace>.<app>.yaml (in <lab>/<state>/) and are layered on top of the
# app's GitOps values. Auto-sync is paused for touched apps so Argo CD doesn't
# immediately undo the experiment; `reset` turns it back on and Argo CD
# restores whatever git says. (In real life, the overlay would be a PR.)
set -euo pipefail
cd "$(dirname "$0")/.."

pause_sync()  { kubectl -n argocd patch application "$1" --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null; }
resume_sync() { kubectl -n argocd patch application "$1" --type merge \
                  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null; }

case "${1:-}" in
  apply)
    lab=${2:?lab directory}; state=${3:?broken|fixed}
    shopt -s nullglob
    for overlay in "$lab/$state"/*.*.yaml; do
      base=$(basename "$overlay" .yaml); ns=${base%%.*}; app=${base#*.}
      echo "-> $ns/$app ($state)"
      pause_sync "$ns-$app-lab"
      helm template "$app" charts/platform-service -n "$ns" \
        -f "gitops/tenants/lab/$ns/$app/values.yaml" -f "$overlay" \
        | kubectl apply -n "$ns" -f -
    done
    # Plain manifests (load generators, noisy neighbors...) carry the
    # ridgeline.dev/lab label so `reset` can find and remove them.
    [ -d "$lab/$state/manifests" ] && kubectl apply -f "$lab/$state/manifests"
    [ -x "$lab/$state/run.sh" ] && "$lab/$state/run.sh"
    ;;
  reset)
    for app in $(kubectl -n argocd get applications -l ridgeline.dev/appset=tenants -o name); do
      resume_sync "${app#*/}"
    done
    kubectl delete deploy,job,pod,configmap -A -l ridgeline.dev/lab --ignore-not-found
    for node in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name); do
      kubectl uncordon "$node" >/dev/null
      kubectl taint "$node" ridgeline.dev/lab- >/dev/null 2>&1 || true
    done
    echo "Auto-sync restored; Argo CD will converge back to git."
    ;;
  *) echo "usage: $0 apply <lab-dir> <broken|fixed> | reset" >&2; exit 2 ;;
esac
