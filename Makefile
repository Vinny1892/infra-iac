.PHONY: lint lint-fmt lint-tflint test test-unit test-integration

lint: lint-fmt lint-tflint

lint-fmt:
	terraform fmt -check -recursive atoms/ molecules/

lint-tflint:
	@echo "==> Running tflint on atoms/aws..."
	@for dir in $$(find atoms/aws -mindepth 1 -maxdepth 3 -type d); do \
		if ls "$$dir"/*.tf >/dev/null 2>&1; then \
			echo "  tflint: $$dir"; \
			tflint --config="$(CURDIR)/.tflint.hcl" --chdir="$$dir" || exit 1; \
		fi; \
	done
	@echo "==> Running tflint on molecules/aws..."
	@for dir in $$(find molecules/aws -mindepth 1 -maxdepth 3 -type d); do \
		if ls "$$dir"/*.tf >/dev/null 2>&1; then \
			echo "  tflint: $$dir"; \
			tflint --config="$(CURDIR)/.tflint.hcl" --chdir="$$dir" || exit 1; \
		fi; \
	done

test: test-unit

test-unit:
	cd tests && go test -tags=unit -v -timeout 30m ./unit/...
