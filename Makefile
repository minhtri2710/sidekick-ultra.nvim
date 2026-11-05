.PHONY: fmt lint test test-floor check

fmt:
	stylua --check lua tests

lint:
	selene lua tests

test:
	scripts/test

test-floor:
	NVIM=/tmp/sku-nvim-0.11/nvim-macos-arm64/bin/nvim scripts/test

check: fmt lint test
