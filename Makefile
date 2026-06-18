# Convenience wrappers around the ops script and Compose.
# `make help` lists targets.
.DEFAULT_GOAL := help
.PHONY: help up down status logs smoke build scan

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

up: ## Build and start the stack
	./scripts/ops.sh up

down: ## Stop the stack
	./scripts/ops.sh down

status: ## Show service health
	./scripts/ops.sh status

logs: ## Tail API logs
	./scripts/ops.sh logs

smoke: ## Run API smoke tests
	./scripts/ops.sh smoke

build: ## Build the Docker image only
	docker compose build

scan: ## Scan the built image for CRITICAL CVEs (requires trivy)
	docker compose build
	trivy image --severity CRITICAL --ignore-unfixed notifications-api:local
