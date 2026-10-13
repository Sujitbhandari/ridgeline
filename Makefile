# Ridgeline: everything you'd run, in one place.  `make help`
SHELL := bash
RPS ?= 100
DURATION ?= 5m
CRDS := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## --- Checks (the same ones CI runs) ---------------------------------------
.PHONY: test lint chart-check policy-test access-check check
test: ## Unit tests: services (pytest) and accessctl (go test)
	cd services && python -m pytest -q
	go test ./tools/accessctl/...

lint: ## ruff, go vet, terraform fmt
	cd services && ruff check . && ruff format --check .
	go vet ./tools/accessctl/...
	terraform fmt -check -recursive infra/terraform

chart-check: ## helm lint + render every values file + kubeconform
	@for f in charts/platform-service/ci/*.yaml gitops/tenants/*/*/*/values.yaml; do \
	  echo "== $$f"; \
	  helm lint charts/platform-service -f $$f --strict --quiet && \
	  helm template svc charts/platform-service -n ns -f $$f | \
	    kubeconform -strict -summary -kubernetes-version 1.32.0 -schema-location default -schema-location '$(CRDS)' || exit 1; \
	done

policy-test: ## Kyverno policy tests + Terraform plan policy tests
	kyverno test policies/kyverno/tests
	conftest verify --policy policies/terraform

access-check: ## Validate all AccessRequests and re-render grants
	go run ./tools/accessctl validate access-requests

access-render: ## Re-render IAM/NetworkPolicy from AccessRequests (commit the result)
	rm -rf access-requests/rendered && go run ./tools/accessctl render access-requests

check: test lint chart-check policy-test access-check ## Everything

## --- Local lab ---------------------------------------------------------------
.PHONY: lab-up lab-down images load ui
lab-up: ## Create the kind cluster and bootstrap the platform via Argo CD
	scripts/lab-up.sh

lab-down: ## Delete the kind cluster
	kind delete cluster --name ridgeline

images: ## Rebuild service images and load them into kind (TAG=0.1.0)
	@for app in verify_api risk_scorer; do \
	  img="ridgeline/$${app//_/-}:$${TAG:-0.1.0}"; \
	  docker build --build-arg APP=$$app -t $$img services && kind load docker-image $$img --name ridgeline; \
	done

load: ## In-cluster k6 load test (RPS=100 DURATION=5m)
	kubectl -n loadtest create configmap k6-scripts --from-file=loadtest/verify.js --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n loadtest delete job k6 --ignore-not-found
	sed -e 's/value: "100"/value: "$(RPS)"/' -e 's/value: "5m"/value: "$(DURATION)"/' loadtest/k6-job.yaml | kubectl apply -f -
	@echo "Follow with: kubectl -n loadtest logs -f job/k6"

ui: ## Port-forward Grafana :3000, Prometheus :9090, Jaeger :16686, Argo CD :8081
	@echo "Grafana admin / ridgeline-lab | Argo CD admin / $$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
	@trap 'kill 0' EXIT; \
	kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null & \
	kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null & \
	kubectl -n observability port-forward svc/jaeger 16686:16686 >/dev/null & \
	kubectl -n argocd port-forward svc/argocd-server 8081:80 >/dev/null & \
	wait
