.PHONY: help test diff

CLUSTERS := talos-ottawa talos-robbinsdale talos-stpetersburg
FLATE_FLAGS := --no-progress --allow-missing-secrets

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_%.-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-25s\033[0m %s\n", $$1, $$2}'

test: ## Render-test all clusters with flate
	@for c in $(CLUSTERS); do \
		echo "=== $$c ==="; \
		flate test all --path clusters/$$c/flux/config $(FLATE_FLAGS) || exit 1; \
	done

test-%: ## Render-test one cluster, e.g. make test-talos-ottawa
	@flate test all --path clusters/$*/flux/config $(FLATE_FLAGS)

diff: ## Show rendered diff vs origin/main for all clusters
	@for c in $(CLUSTERS); do \
		echo "=== $$c ==="; \
		flate diff all --path clusters/$$c/flux/config --base origin/main $(FLATE_FLAGS) || exit 1; \
	done

default: help
