BLORP_CC ?= clang
.DEFAULT_GOAL := compiler
# Normal and diagnostic targets share output overrides. Serialize this small
# Makefile so `make -j compiler test-compiler` cannot race competing links.
.NOTPARALLEL:
# Paths are relative to the repository root, where every recipe runs. The e2e
# suite tests BLORP2_COMPILER, which test-compiler links from BLORP2_COMPILER_C;
# scripts/blorp2-fixpoint sets both per stage and links at -O0. A command-line
# VAR=value overrides these; the environment does not (hence := and not ?=).
BLORP2_COMPILER := blorp_2/build/compiler
BLORP2_COMPILER_C := blorp_2/build/compiler.c
TEST_COMPILER_FLAGS := -O0
TEST_COMPILER_LIBRARIES := -lm -lpthread

.PHONY: compiler generate-compiler link-compiler example test test-components test-compiler link-test-compiler test-e2e host-check

compiler: generate-compiler
	@$(MAKE) --no-print-directory link-compiler

generate-compiler:
	@echo 'Generate $(BLORP2_COMPILER_C)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP2_COMPILER_C)")" \
		&& scripts/blorp2-compiler-bootstrap --library-root blorp_2/standard_library \
			blorp_2/src/main.brp "$(BLORP2_COMPILER_C)"

link-compiler:
	@echo 'Link $(BLORP2_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP2_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=0 \
			"$(BLORP2_COMPILER_C)" -o "$(BLORP2_COMPILER)" $(TEST_COMPILER_LIBRARIES)

example: compiler
	@mkdir -p build
	@cd .. && "$(BLORP2_COMPILER)" \
		--library-root blorp_2/standard_library blorp_2/test/e2e/fixtures/return/zero.brp blorp_2/build/return_zero.c
	@"$(BLORP_CC)" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
		build/return_zero.c -o build/return_zero
	@build/return_zero

test: host-check
	@$(MAKE) --no-print-directory test-compiler
	@$(MAKE) --no-print-directory test-components
	@$(MAKE) --no-print-directory test-e2e

# The text factory is target-owned; host discovery retains all other suites.
# Callers build once or supply the exact compiler under test, as with test-e2e.
test-components: host-check
	@cd .. && bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
	@mkdir -p build/self-hosted-tests
	@cd .. && "$(BLORP2_COMPILER)" --library-root blorp_2/standard_library --test-suite \
		blorp_2/test/unit/test_utils/test_text.brp blorp_2/build/self-hosted-tests/text.c
	@"$(BLORP_CC)" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
		-DBLORP_MEMORY_DIAGNOSTICS=1 build/self-hosted-tests/text.c \
		-o build/self-hosted-tests/text $(TEST_COMPILER_LIBRARIES)
	@BLORP_LEAK_CHECK=strict build/self-hosted-tests/text

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: generate-compiler
	@$(MAKE) --no-print-directory link-test-compiler

link-test-compiler:
	@echo 'Link $(BLORP2_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP2_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			"$(BLORP2_COMPILER_C)" -o "$(BLORP2_COMPILER)" $(TEST_COMPILER_LIBRARIES)

# The harness receives the compiler under test here, never from a default.
test-e2e: host-check
	@cd .. && BLORP2_COMPILER="$(BLORP2_COMPILER)" bin/blorp test --suite --timeout 0 blorp_2/test/e2e

host-check:
	@cd .. && scripts/compiler-build-status --quiet
