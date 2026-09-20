SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

REGION      ?= eu-central-1
CLUSTER     ?= hivemind-greeter
NAMESPACE   ?= hivemind-greeter
K8S_VERSION ?= 1.36.0
IMAGE       ?= greeter:local

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---- application ---------------------------------------------------------------

.PHONY: test
test: ## Run Go tests with the race detector and coverage
	cd app && go test -race -covermode=atomic -coverprofile=coverage.out ./...
	cd app && go tool cover -func=coverage.out | tail -1

.PHONY: lint
lint: ## Run gofmt, go vet and golangci-lint
	cd app && test -z "$$(gofmt -l .)" || { echo "not gofmt-clean:"; gofmt -l app; exit 1; }
	cd app && go vet ./...
	cd app && golangci-lint run ./...

.PHONY: build
build: ## Build the container image locally
	docker build -t $(IMAGE) ./app

.PHONY: run
run: build ## Run the service locally on :8080
	docker run --rm -p 8080:8080 -e HELLO_TAG=local --hostname local-pod $(IMAGE)

# ---- static analysis -------------------------------------------------------------

.PHONY: validate
validate: ## Validate Terraform and Kubernetes manifests
	cd terraform && terraform fmt -check -recursive -diff
	cd terraform && terraform init -backend=false -input=false >/dev/null
	cd terraform && terraform validate
	cd terraform && tflint --init --config=$(CURDIR)/.tflint.hcl >/dev/null
	cd terraform && tflint --config=$(CURDIR)/.tflint.hcl --format compact
	kubectl kustomize k8s/base | kubeconform -strict -summary -kubernetes-version $(K8S_VERSION)

.PHONY: scan
scan: ## Run all Trivy scans
	trivy config --config trivy.yaml --ignorefile .trivyignore.yaml terraform/
	@# trivy config cannot read from stdin, so the manifests are rendered to a file first.
	@tmp=$$(mktemp -d) && trap 'rm -rf "$$tmp"' EXIT && \
	  kubectl kustomize k8s/base > "$$tmp/rendered.yaml" && \
	  trivy config --config trivy.yaml "$$tmp/rendered.yaml"
	trivy config --config trivy.yaml app/Dockerfile
	trivy image --severity HIGH,CRITICAL --exit-code 1 --no-progress $(IMAGE)

.PHONY: lint-actions
lint-actions: ## Lint the GitHub Actions workflows
	actionlint

.PHONY: check
check: lint test validate lint-actions ## Everything CI runs, except image scanning

# ---- infrastructure ---------------------------------------------------------------

.PHONY: plan
plan: ## terraform plan
	cd terraform && terraform init -input=false && terraform plan

.PHONY: apply
apply: ## terraform apply (~20 minutes)
	cd terraform && terraform init -input=false && terraform apply

.PHONY: kubeconfig
kubeconfig: ## Point kubectl at the cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER)

.PHONY: deploy
deploy: ## Apply the workload manifests and wait for the rollout
	kubectl apply -k k8s/base
	kubectl -n $(NAMESPACE) rollout status deployment/hivemind-greeter --timeout=5m

.PHONY: url
url: ## Print the public URL
	@printf 'http://%s\n' "$$(kubectl -n $(NAMESPACE) get ingress hivemind-greeter \
	  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

.PHONY: smoke
smoke: ## Curl the deployed service through the ALB
	@host="$$(kubectl -n $(NAMESPACE) get ingress hivemind-greeter -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"; \
	 echo "GET /        -> $$(curl -sf --max-time 10 "http://$$host/")"; \
	 echo "GET /?name=  -> $$(curl -sf --max-time 10 "http://$$host/?name=Ada")"

# ---- packaging ------------------------------------------------------------------

.PHONY: package
package: ## Build the submission zip from tracked files only
	@# git archive emits exactly what is committed. Zipping the working
	@# directory instead would ship terraform.tfstate — which carries the AWS
	@# account id, VPC and subnet ids, security groups, IAM role ARNs and the
	@# cluster CA — plus ~970MB of .terraform provider binaries. .gitignore
	@# does not apply inside a zip, so this must not be done by hand.
	@test -z "$$(git status --porcelain)" || { echo "refusing: working tree is dirty"; git status --short; exit 1; }
	@rm -f hivemind-greeter.zip
	@git archive --format=zip --prefix=hivemind-greeter/ -o hivemind-greeter.zip HEAD
	@echo "wrote hivemind-greeter.zip ($$(du -h hivemind-greeter.zip | cut -f1), $$(unzip -l hivemind-greeter.zip | tail -1 | awk '{print $$2}') files)"
	@echo "verifying no state, provider cache or credentials leaked:"
	@! unzip -l hivemind-greeter.zip | grep -qE 'tfstate|\.terraform/|coverage\.out|\.env$$|credentials' \
	  && echo "  clean" || { echo "  LEAK DETECTED"; exit 1; }

.PHONY: destroy
destroy: ## Tear down in the correct order (workload first, then infrastructure)
	@echo "==> Deleting the workload so the controller releases the ALB."
	@echo "    Destroying Terraform first would strand the ALB's ENIs in the"
	@echo "    subnets and hang VPC deletion."
	-kubectl delete -k k8s/base --ignore-not-found
	-kubectl -n $(NAMESPACE) wait --for=delete ingress/hivemind-greeter --timeout=5m
	@echo "==> Waiting for the load balancer to disappear"
	@sleep 30
	cd terraform && terraform destroy
