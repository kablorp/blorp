BLORP_CC ?= clang
.DEFAULT_GOAL := compiler
# Normal and diagnostic targets share output overrides. Serialize this small
# Makefile so `make -j compiler test-compiler` cannot race competing links.
.NOTPARALLEL:
# Paths are relative to the repository root, where every recipe runs.
# test-compiler links BLORP2_COMPILER from BLORP2_COMPILER_C;
# scripts/blorp2-fixpoint sets both per stage and links at -O0. A command-line
# VAR=value overrides these; the environment does not (hence := and not ?=).
BLORP2_COMPILER := blorp_2/build/compiler
BLORP2_COMPILER_C := blorp_2/build/compiler.c
TEST_COMPILER_FLAGS := -O0
TEST_COMPILER_LIBRARIES := -lm -lpthread
# The component programs are listed in test/e2e/self_hosted.brp. Setting this
# to source paths runs exactly those instead, for the narrow loop.
TARGET_COMPONENT_SOURCES :=
# Beside the component programs, whose root is BUILD_ROOT in
# test/e2e/self_hosted_selection.brp. No test directory is named `driver`, so
# no component program overwrites it.
TEST_DRIVER_DIRECTORY := blorp_2/build/self-hosted-tests/driver
TEST_DRIVER := $(TEST_DRIVER_DIRECTORY)/driver

.PHONY: compiler generate-compiler link-compiler example test test-components test-target-components test-compiler link-test-compiler test-e2e build-test-driver

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

# Straight-line shell that gives the test recipes absolute tool paths.
define RESOLVE_TEST_TOOLS
cd ..; \
	compiler_path="$(BLORP2_COMPILER)"; \
	case "$$compiler_path" in /*) ;; *) compiler_path="$$PWD/$$compiler_path";; esac; \
	if [ ! -x "$$compiler_path" ]; then \
		printf '%s\n' 'missing Blorp 2 test compiler; run make -C blorp_2 test-compiler first' >&2; exit 1; \
	fi; \
	cc_path=$$(command -v "$(BLORP_CC)") || { printf '%s\n' 'C compiler executable not found' >&2; exit 1; }; \
	case "$$cc_path" in /*) ;; *) cc_path="$$PWD/$$cc_path";; esac; \
	if [ ! -x "$$cc_path" ]; then printf '%s\n' 'C compiler must resolve to an executable file' >&2; exit 1; fi
endef

# One make invocation builds the driver once: test-components and test-e2e name
# it as a prerequisite, so they share one build when given together.
test:
	@$(MAKE) --no-print-directory test-compiler
	@$(MAKE) --no-print-directory test-components test-e2e

# Other suites remain in source for incremental self-hosted migration; the
# driver prints how many it leaves out, per top directory. That report is its own
# invocation so test-target-components, the narrow loop, prints only its suites.
test-components: test-target-components
	@set -eu; cd ..; BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" deferred $(TARGET_COMPONENT_SOURCES)

# The driver is an ordinary B2 main(args) running TestSuites; fixtures retain
# their own real mains. It receives all configuration explicitly from Make, and
# is built by the compiler under test, so a compiler defect cannot hide behind
# a driver built by another one.
build-test-driver:
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		mkdir -p "$(TEST_DRIVER_DIRECTORY)"; rm -f "$(TEST_DRIVER)"; \
		BLORP_LEAK_CHECK=strict "$$compiler_path" --library-root blorp_2/standard_library \
			blorp_2/test/e2e/self_hosted.brp "$(TEST_DRIVER).c"; \
		"$$cc_path" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
			-fsanitize=address,undefined -fno-sanitize-recover=all \
			-DBLORP_MEMORY_DIAGNOSTICS=1 "$(TEST_DRIVER).c" -o "$(TEST_DRIVER)" $(TEST_COMPILER_LIBRARIES)

# One program per phase directory, built and run under strict leak checking in
# blorp_2/build/self-hosted-tests/, where a failure can be inspected.
test-target-components: build-test-driver
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" components "$$compiler_path" "$$cc_path" \
			$(TEST_COMPILER_LIBRARIES) -- $(TARGET_COMPONENT_SOURCES)

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: generate-compiler
	@$(MAKE) --no-print-directory link-test-compiler

link-test-compiler:
	@echo 'Link $(BLORP2_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP2_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			"$(BLORP2_COMPILER_C)" -o "$(BLORP2_COMPILER)" $(TEST_COMPILER_LIBRARIES)

test-e2e: build-test-driver
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		temporary_parent=$$(cd "$${TMPDIR:-/tmp}" && pwd -P); \
		BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" e2e "$$compiler_path" "$$cc_path" "$$temporary_parent"
