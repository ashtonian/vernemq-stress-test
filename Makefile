.PHONY: help bootstrap destroy deps up down down-all \
       bench compare matrix report \
       local-bench local-compare local-down \
       grafana-url grafana-pass ssh-check clean

SHELL := /bin/bash

# Configurable defaults (override on CLI: make bench REPO=... REF=...)
PROFILE       ?= default
REGION        ?= us-east-1
REPO          ?= https://github.com/vernemq/vernemq.git
REF           ?= main
TAG           ?= $(REF)-$(shell date +%Y%m%d-%H%M%S)
SCENARIOS     ?= standard
CATEGORY      ?= all
DURATION      ?=
# Used by compare and matrix targets only; bench uses LOAD_MULTIPLIER env var
LOAD_MULT     ?= 3
CLUSTER_SIZE  ?=
EXPORT_PROM   ?=
BENCH_PROFILE ?=

# A/B comparison
BASELINE_REPO ?= $(REPO)
BASELINE_REF  ?=
CAND_REPO     ?= $(REPO)
CAND_REF      ?=

# Matrix (space-separated list of REPO@REF specs)
VERSIONS      ?=

# Local (Docker)
NODES         ?= 3
SCALE         ?= 0.4
MONITORING    ?=
LB            ?=
NO_AUTH       ?=
AUTH_USER     ?=
AUTH_PASS     ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

bootstrap: ## First-time AWS setup (IAM user + profile + bench.env)
	./scripts/bootstrap.sh --profile $(PROFILE) --region $(REGION)

destroy: ## Tear down bootstrap artifacts (IAM user + bench.env + shared.tfvars)
	./scripts/bootstrap.sh --destroy --profile $(PROFILE) --region $(REGION)

deps: ## Install optional Python dependencies (matplotlib for charts)
	pip install -r requirements.txt

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

up: ## Provision all AWS infrastructure (network → monitoring → compute)
	./scripts/infra_up.sh

down: ## Destroy compute only (monitoring stays for data review)
	./scripts/infra_down.sh

down-all: ## Destroy all AWS infrastructure
	./scripts/infra_down.sh --all

# ---------------------------------------------------------------------------
# Benchmarks (AWS)
# ---------------------------------------------------------------------------

bench: ## Run benchmark (REPO=, REF=, TAG=, SCENARIOS=, CATEGORY=, LB=1)
	LOAD_MULTIPLIER=$(LOAD_MULT) ./scripts/run_benchmark.sh \
		--repo $(REPO) --ref $(REF) --tag $(TAG) \
		--scenarios $(SCENARIOS) --category $(CATEGORY) \
		$(if $(CLUSTER_SIZE),--cluster-size $(CLUSTER_SIZE)) \
		$(if $(DURATION),--duration $(DURATION)) \
		$(if $(EXPORT_PROM),--export-prom) \
		$(if $(BENCH_PROFILE),--profile $(BENCH_PROFILE)) \
		$(if $(LB),--lb)

compare: ## A/B comparison (BASELINE_REF=, CAND_REF=, BASELINE_REPO=, CAND_REPO=)
	@if [ -z "$(BASELINE_REF)" ] || [ -z "$(CAND_REF)" ]; then \
		echo "ERROR: BASELINE_REF and CAND_REF are required"; \
		echo "  make compare BASELINE_REF=v2.1.2 CAND_REF=main"; \
		exit 1; \
	fi
	./scripts/run_comparison.sh \
		--baseline-repo $(BASELINE_REPO) --baseline-ref $(BASELINE_REF) \
		--candidate-repo $(CAND_REPO) --candidate-ref $(CAND_REF) \
		--scenarios $(SCENARIOS) --load-multiplier $(LOAD_MULT) \
		$(if $(DURATION),--duration $(DURATION)) \
		$(if $(LB),--lb)

matrix: ## N-version matrix (VERSIONS="repo@ref repo@ref ...")
	@if [ -z "$(VERSIONS)" ]; then \
		echo "ERROR: VERSIONS is required (space-separated REPO@REF specs)"; \
		echo '  make matrix VERSIONS="https://github.com/vernemq/vernemq.git@v2.1.2 https://github.com/vernemq/vernemq.git@main"'; \
		exit 1; \
	fi
	./scripts/run_matrix.sh \
		$(foreach v,$(VERSIONS),--version $(v)) \
		--scenarios $(SCENARIOS) --load-multiplier $(LOAD_MULT) \
		$(if $(DURATION),--duration $(DURATION)) \
		$(if $(LB),--lb)

report: ## Generate comparison report from existing results (BASELINE=dir CANDIDATE=dir)
	@if [ -z "$(BASELINE)" ] || [ -z "$(CANDIDATE)" ]; then \
		echo "ERROR: BASELINE and CANDIDATE result dirs are required"; \
		echo "  make report BASELINE=results/baseline-v2.1.2-... CANDIDATE=results/candidate-main-..."; \
		exit 1; \
	fi
	python3 scripts/report.py --baseline $(BASELINE) --candidate $(CANDIDATE) \
		--output results/comparison-$(shell date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------
# Local (Docker)
# ---------------------------------------------------------------------------

local-bench: ## Run local Docker bench (NODES=, REF=, SCENARIOS=, MONITORING=1, LB=1)
	cd local && ./run_local_bench.sh \
		--nodes $(NODES) --scenarios $(SCENARIOS) --category $(CATEGORY) \
		--scale $(SCALE) \
		$(if $(REF),--ref $(REF)) \
		$(if $(DURATION),--duration $(DURATION)) \
		$(if $(TAG),--tag $(TAG)) \
		$(if $(MONITORING),--monitoring) \
		$(if $(SKIP_BUILD),--skip-build) \
		$(if $(KEEP),--keep) \
		$(if $(EXPORT_PROM),--export-prom) \
		$(if $(LB),--lb) \
		$(if $(NO_AUTH),--no-auth) \
		$(if $(AUTH_USER),--auth-user $(AUTH_USER)) \
		$(if $(AUTH_PASS),--auth-pass $(AUTH_PASS))

local-compare: ## Local A/B comparison (BASELINE_REF=, CAND_REF=, NODES=)
	@if [ -z "$(BASELINE_REF)" ] || [ -z "$(CAND_REF)" ]; then \
		echo "ERROR: BASELINE_REF and CAND_REF are required"; \
		echo "  make local-compare BASELINE_REF=v2.1.2 CAND_REF=main"; \
		exit 1; \
	fi
	cd local && ./run_ab_comparison.sh \
		--baseline-ref $(BASELINE_REF) --candidate-ref $(CAND_REF) \
		--nodes $(NODES) --scenarios $(SCENARIOS) --category $(CATEGORY) \
		--scale $(SCALE) \
		$(if $(BASELINE_REPO),--baseline-repo $(BASELINE_REPO)) \
		$(if $(CAND_REPO),--candidate-repo $(CAND_REPO)) \
		$(if $(DURATION),--duration $(DURATION)) \
		$(if $(MONITORING),--monitoring) \
		$(if $(LB),--lb) \
		$(if $(NO_AUTH),--no-auth) \
		$(if $(AUTH_USER),--auth-user $(AUTH_USER)) \
		$(if $(AUTH_PASS),--auth-pass $(AUTH_PASS))

local-down: ## Stop and remove local Docker cluster
	cd local && docker compose down -v

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

grafana-url: ## Print Grafana URL
	@terraform -chdir=terraform/monitoring output grafana_url 2>/dev/null || echo "Monitoring not provisioned"

grafana-pass: ## Print Grafana admin password
	@terraform -chdir=terraform/monitoring output -raw grafana_admin_password 2>/dev/null || echo "Monitoring not provisioned"

ssh-check: ## Test SSH connectivity to monitor node
	@source bench.env 2>/dev/null || true; \
	MONITOR_IP=$$(terraform -chdir=terraform/monitoring output -raw monitor_public_ip 2>/dev/null); \
	if [ -z "$$MONITOR_IP" ] || [ "$$MONITOR_IP" = "unknown" ]; then \
		echo "Monitoring not provisioned"; exit 1; \
	fi; \
	ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes \
		$${SSH_KEY:+-i $$SSH_KEY} ec2-user@$$MONITOR_IP echo "Monitor: OK"

clean: ## Remove results directories (AWS + local)
	rm -rf results/*
	rm -rf local/results/*
	@echo "Results cleaned. Infrastructure untouched."
