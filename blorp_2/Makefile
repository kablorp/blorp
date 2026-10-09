BLORP_CC ?= clang
TEST_COMPILER_FLAGS := -O0
TEST_COMPILER_LIBRARIES := -lm -lpthread

.PHONY: example test test-compiler host-check

example: host-check
	@mkdir -p build
	@cd .. && bin/blorp run --no-format blorp_2/src/main.brp -- \
		blorp_2/src/prelude_temp.brp blorp_2/test/e2e/fixtures/return_zero.brp blorp_2/build/return_zero.c
	@$(BLORP_CC) -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
		build/return_zero.c -o build/return_zero
	@build/return_zero

test: host-check
	@cd .. && bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: host-check
	@mkdir -p build
	@echo 'Generate build/compiler.c'
	@cd .. && bin/blorp compile --no-format blorp_2/src/main.brp -o blorp_2/build/compiler.c
	@echo 'Link build/compiler'
	@$(BLORP_CC) $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
		build/compiler.c -o build/compiler $(TEST_COMPILER_LIBRARIES)

host-check:
	@cd .. && scripts/compiler-build-status --quiet
