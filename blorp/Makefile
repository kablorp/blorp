BLORP_CC ?= clang
.DEFAULT_GOAL := compiler
# Normal and diagnostic targets share output overrides. Serialize this small
# Makefile so `make -j compiler test-compiler` cannot race competing links.
.NOTPARALLEL:
# Paths are relative to the repository root, where every recipe runs.
# test-compiler links BLORP_COMPILER from BLORP_COMPILER_C;
# scripts/blorp-fixpoint sets both per stage and links at -O0. A command-line
# VAR=value overrides these; the environment does not (hence := and not ?=).
BLORP_COMPILER := blorp/build/blorp
BLORP_COMPILER_C := blorp/build/blorp.c
TEST_COMPILER_FLAGS := -O0
TEST_COMPILER_LIBRARIES := -lm -lpthread
# The component programs are listed in test/e2e/self_hosted.brp. Setting this
# to source paths runs exactly those instead, for the narrow loop.
TARGET_COMPONENT_SOURCES :=
# Set to `on` on macOS (`make test INSTRUCTION_CHECK=on`) to also hold each
# ported e2e compile to its retired-instruction ceiling, measured with
# /usr/bin/time -l. Empty by default: only the allocation ceilings are held.
# Any other value is an error, so `INSTRUCTION_CHECK=off` cannot enable it.
INSTRUCTION_CHECK :=
# Beside the component programs, whose root is BUILD_ROOT in
# test/e2e/self_hosted_selection.brp. No test directory is named `driver`, so
# no component program overwrites it.
TEST_DRIVER_DIRECTORY := blorp/build/self-hosted-tests/driver
TEST_DRIVER := $(TEST_DRIVER_DIRECTORY)/driver

.PHONY: compiler generate-compiler link-compiler example test test-components test-target-components test-compiler link-test-compiler test-e2e build-test-driver

compiler: generate-compiler
	@$(MAKE) --no-print-directory link-compiler

generate-compiler:
	@echo 'Generate $(BLORP_COMPILER_C)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP_COMPILER_C)")" \
		&& scripts/blorp-compiler-bootstrap --library-root blorp/standard_library \
			blorp/src/main.brp "$(BLORP_COMPILER_C)"

link-compiler:
	@echo 'Link $(BLORP_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=0 \
			"$(BLORP_COMPILER_C)" -o "$(BLORP_COMPILER)" $(TEST_COMPILER_LIBRARIES)

example: compiler
	@mkdir -p build
	@cd .. && "$(BLORP_COMPILER)" compile blorp/test/e2e/fixtures/return/zero.brp \
		--library-root blorp/standard_library -o blorp/build/return_zero.c
	@"$(BLORP_CC)" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
		build/return_zero.c -o build/return_zero
	@build/return_zero

# Straight-line shell that gives the test recipes absolute tool paths.
define RESOLVE_TEST_TOOLS
cd ..; \
	compiler_path="$(BLORP_COMPILER)"; \
	case "$$compiler_path" in /*) ;; *) compiler_path="$$PWD/$$compiler_path";; esac; \
	if [ ! -x "$$compiler_path" ]; then \
		printf '%s\n' 'missing Blorp test compiler; run make -C blorp test-compiler first' >&2; exit 1; \
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

# The driver is an ordinary Blorp main(args) running TestSuites; fixtures retain
# their own real mains. It receives all configuration explicitly from Make, and
# is built by the compiler under test, so a compiler defect cannot hide behind
# a driver built by another one.
# It is built without AddressSanitizer, on every platform, for now; a follow-up
# will try starting children with posix_spawn, which may let ASan return.
# Observed on macOS: in any long e2e run with an ASan driver, one forked child
# was killed by SIGKILL before exec ("child terminated by signal") at an
# arbitrary case; `log show` named it "[driver: killed] exiting with signal 9"
# (system log, not retained).
# The same runs pass without ASan. UBSan and the strict leak check still apply.
build-test-driver:
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		mkdir -p "$(TEST_DRIVER_DIRECTORY)"; rm -f "$(TEST_DRIVER)"; \
		BLORP_LEAK_CHECK=strict "$$compiler_path" compile blorp/test/e2e/self_hosted.brp \
			--library-root blorp/standard_library -o "$(TEST_DRIVER).c"; \
		"$$cc_path" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
			-fsanitize=undefined -fno-sanitize-recover=all \
			-DBLORP_MEMORY_DIAGNOSTICS=1 "$(TEST_DRIVER).c" -o "$(TEST_DRIVER)" $(TEST_COMPILER_LIBRARIES)

# One program per phase directory, built and run under strict leak checking in
# blorp/build/self-hosted-tests/, where a failure can be inspected.
test-target-components: build-test-driver
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" components "$$compiler_path" "$$cc_path" \
			$(TEST_COMPILER_LIBRARIES) -- $(TARGET_COMPONENT_SOURCES)

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: generate-compiler
	@$(MAKE) --no-print-directory link-test-compiler

link-test-compiler:
	@echo 'Link $(BLORP_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			"$(BLORP_COMPILER_C)" -o "$(BLORP_COMPILER)" $(TEST_COMPILER_LIBRARIES)

test-e2e: build-test-driver
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		temporary_parent=$$(cd "$${TMPDIR:-/tmp}" && pwd -P); \
		BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" e2e "$$compiler_path" "$$cc_path" "$$temporary_parent" \
			$(if $(INSTRUCTION_CHECK),$(if $(filter on,$(INSTRUCTION_CHECK)),--check-instructions,$(error INSTRUCTION_CHECK must be empty or on, not $(INSTRUCTION_CHECK))))
