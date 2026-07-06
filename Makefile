# ===========================================================================
# gpu-inference — the platform's single control surface.
#
# Design rule: the Makefile dispatches, it does not decide. All behaviour lives
# in scripts/ and infra/pools/. A new pool never edits this file.
#
#   make up            bring the platform up on POOL (default: local-kind, $0)
#   make demo          up -> contract test -> chat round-trip -> proof
#   make down          destroy everything, then prove zero orphans
#   make verify        prove zero orphaned resources for POOL (no teardown)
#   make chat          port-forward the chat UI and print its URL
#   make status        show what is currently running
#
# Knobs (all optional; sane defaults):
#   POOL=local-kind|aws        provider seam (ADR-0002)
#   GPU=t4|l4|h100             hardware profile -> platform/serving/gpus/<GPU>/
#   OBS=0|1                    Prometheus+Grafana (default: on for GPU pools)
#
# Examples:
#   make demo                              # $0 local chat demo
#   make up POOL=aws GPU=l4 CONFIRM_SPEND=1   # Phase 1: L4 GPU on EKS
#   make down POOL=aws                     # tear the expensive thing down
# ===========================================================================

POOL ?= local-kind
GPU  ?= l4
export POOL GPU

SHELL := /bin/bash
S     := scripts

.DEFAULT_GOAL := help

.PHONY: help up down demo verify chat status orphans preflight lint bootstrap env \
        contract cache-weights grafana

help: ## Show this help
	@awk 'BEGIN{FS":.*##"} /^[a-zA-Z0-9_-]+:.*##/{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  POOL=$(POOL)  GPU=$(GPU)"

preflight: ## Check required tooling for POOL
	@$(S)/preflight.sh

up: ## Bring the platform up on POOL
	@$(S)/up.sh

down: ## Destroy everything on POOL, then verify zero orphans
	@$(S)/down.sh

demo: ## up -> contract test -> chat round-trip (TEARDOWN=1 to auto-destroy)
	@$(S)/demo.sh

contract: ## Run the OpenAI-contract test against the running platform
	@$(S)/contract.sh

verify: ## Prove zero orphaned resources for POOL (no teardown)
	@$(S)/verify-zero-orphans.sh

chat: ## Port-forward the chat UI and print its URL
	@$(S)/chat.sh

status: ## Show what is currently running on POOL
	@$(S)/status.sh

cache-weights: ## Push freshly-downloaded model weights to the S3 cache
	@$(S)/cache-weights.sh

grafana: ## Port-forward Grafana (requires OBS=1 install)
	@$(S)/grafana.sh

orphans: verify ## Alias for verify

lint: ## Static checks: shellcheck + kustomize build + terraform fmt
	@$(S)/lint.sh

bootstrap: ## One-time: create TF state backend + weights bucket (AWS)
	@$(S)/bootstrap.sh

env: ## Print eval-able exports for a new terminal: eval "$$(make env)"
	@$(S)/env.sh
