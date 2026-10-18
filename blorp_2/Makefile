BLORP_CC ?= clang
# Paths are relative to the repository root, where every recipe runs. The e2e
# suite tests BLORP2_COMPILER, which test-compiler links from BLORP2_COMPILER_C;
# scripts/blorp2-fixpoint sets both per stage and links at -O0. A command-line
# VAR=value overrides these; the environment does not (hence := and not ?=).
BLORP2_COMPILER := blorp_2/build/compiler
BLORP2_COMPILER_C := blorp_2/build/compiler.c
TEST_COMPILER_FLAGS := -O0
TEST_COMPILER_LIBRARIES := -lm -lpthread

.PHONY: example test test-compiler link-test-compiler test-e2e host-check

example: host-check
	@mkdir -p build
	@cd .. && bin/blorp run --no-format blorp_2/src/main.brp -- \
		--library-root blorp_2/standard_library blorp_2/test/e2e/fixtures/return/zero.brp blorp_2/build/return_zero.c
	@$(BLORP_CC) -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
		build/return_zero.c -o build/return_zero
	@build/return_zero

test: host-check
	@cd .. && bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
	@$(MAKE) --no-print-directory test-compiler
	@$(MAKE) --no-print-directory test-e2e

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: host-check
	@echo 'Generate $(BLORP2_COMPILER_C)'
	@cd .. && mkdir -p $(dir $(BLORP2_COMPILER_C)) \
		&& bin/blorp compile --no-format blorp_2/src/main.brp -o $(BLORP2_COMPILER_C)
	@$(MAKE) --no-print-directory link-test-compiler

link-test-compiler:
	@echo 'Link $(BLORP2_COMPILER)'
	@cd .. && mkdir -p $(dir $(BLORP2_COMPILER)) \
		&& $(BLORP_CC) $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			$(BLORP2_COMPILER_C) -o $(BLORP2_COMPILER) $(TEST_COMPILER_LIBRARIES)

# The harness receives the compiler under test here, never from a default.
test-e2e: host-check
	@cd .. && BLORP2_COMPILER=$(BLORP2_COMPILER) bin/blorp test --suite --timeout 0 blorp_2/test/e2e

host-check:
	@cd .. && scripts/compiler-build-status --quiet
