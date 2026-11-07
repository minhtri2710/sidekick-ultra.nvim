.PHONY: fmt lint test test-floor check

fmt:
	stylua --check lua tests

lint:
	selene lua tests

# The acceptance lanes ignore SKU_SPEC (the dev filter in tests/minit.lua).
test:
	env -u SKU_SPEC scripts/test

test-floor:
	env -u SKU_SPEC NVIM=$(CURDIR)/.tests/nvim-0.11/nvim-macos-arm64/bin/nvim scripts/test

check: fmt lint test
