BLORP_CC ?= clang

.PHONY: example test host-check

example: host-check
	@mkdir -p build
	@cd .. && bin/blorp run --no-format blorp_2/src/main.brp -- \
		blorp_2/test/e2e/fixtures/return_zero.brp blorp_2/build/return_zero.c
	@$(BLORP_CC) -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
		build/return_zero.c -o build/return_zero
	@build/return_zero

test: host-check
	@cd .. && bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/e2e

host-check:
	@cd .. && scripts/compiler-build-status --quiet
