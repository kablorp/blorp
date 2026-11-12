BLORP_CC ?= clang
.DEFAULT_GOAL := compiler
# compiler and test-compiler both link the test compiler, and every test target
# runs compiled programs. Serialize this small Makefile so that `make -j` can
# neither race two links of one file nor run two test targets at once.
.NOTPARALLEL:
# A generator that fails halfway must not leave a module that looks up to date.
.DELETE_ON_ERROR:
# Paths are relative to the repository root, where every recipe runs.
# BLORP_COMPILER_C is linked at two paths, so that neither link replaces the
# other: BLORP_COMPILER, the blorp command, without memory diagnostics, and
# BLORP_TEST_COMPILER with them. Every test target runs BLORP_TEST_COMPILER,
# because e2e checks the strict allocation report only a diagnostic link prints.
# scripts/blorp-fixpoint sets BLORP_COMPILER_C and BLORP_TEST_COMPILER per
# stage and links at -O0. A command-line VAR=value overrides these; the
# environment does not (hence := and not ?=).
BLORP_COMPILER := blorp/build/blorp
BLORP_TEST_COMPILER := blorp/build/blorp-test
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

# The standard library embedded in the compiler: a generator the pinned seed
# builds, and the module it writes, which src/common/analysis/load/load.brp imports.
# Both are file targets, so they are rebuilt only when the library or the
# generator changes. These are targets, so relative to blorp/ where make runs;
# the recipes run in the repository root and prefix them with blorp/.
EMBED_LIBRARY := build/generated/embed_library
EMBEDDED_LIBRARY := build/generated/embedded_library.brp

.PHONY: compiler generate-compiler link-compiler example test format-check test-target-components test-compiler link-test-compiler test-e2e build-test-driver

# Links the test compiler too, so that a test target run after `make compiler`
# tests this C, not whatever test compiler an earlier build left.
compiler: generate-compiler
	@$(MAKE) --no-print-directory link-compiler link-test-compiler

# A pinned-seed change (bootstrap.env) or a change to the shared text helper it
# imports rebuilds the generator too. -O1: the generator loops over every
# library byte, which -O0 makes needlessly slow.
$(EMBED_LIBRARY): scripts/embed_library.brp src/common/utils/text.brp bootstrap.env
	@echo 'Build blorp/$(EMBED_LIBRARY)'
	@cd .. && mkdir -p "$$(dirname "blorp/$(EMBED_LIBRARY)")" \
		&& scripts/blorp-compiler-bootstrap compile blorp/scripts/embed_library.brp \
			--library-root blorp/standard_library -o "blorp/$(EMBED_LIBRARY).c" \
		&& "$(BLORP_CC)" -O1 "blorp/$(EMBED_LIBRARY).c" -o "blorp/$(EMBED_LIBRARY)" $(TEST_COMPILER_LIBRARIES)

# Every folder under the library is a prerequisite so that a deleted or renamed
# library file, which no match can name, regenerates the module; the files are
# found at any depth so that an edit inside a subfolder does too.
$(EMBEDDED_LIBRARY): $(EMBED_LIBRARY) $(shell find standard_library \( -type d -o -name '*.brp' \))
	@echo 'Generate blorp/$(EMBEDDED_LIBRARY)'
	@cd .. && "blorp/$(EMBED_LIBRARY)" blorp/standard_library "blorp/$(EMBEDDED_LIBRARY)"

generate-compiler: $(EMBEDDED_LIBRARY)
	@echo 'Generate $(BLORP_COMPILER_C)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP_COMPILER_C)")" \
		&& scripts/blorp-compiler-bootstrap compile blorp/src/main.brp \
			--library-root blorp/standard_library -o "$(BLORP_COMPILER_C)"

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
	compiler_path="$(BLORP_TEST_COMPILER)"; \
	case "$$compiler_path" in /*) ;; *) compiler_path="$$PWD/$$compiler_path";; esac; \
	if [ ! -x "$$compiler_path" ]; then \
		printf '%s\n' 'missing Blorp test compiler; run make -C blorp test-compiler first' >&2; exit 1; \
	fi; \
	cc_path=$$(command -v "$(BLORP_CC)") || { printf '%s\n' 'C compiler executable not found' >&2; exit 1; }; \
	case "$$cc_path" in /*) ;; *) cc_path="$$PWD/$$cc_path";; esac; \
	if [ ! -x "$$cc_path" ]; then printf '%s\n' 'C compiler must resolve to an executable file' >&2; exit 1; fi
endef

# One make invocation builds the driver once: test-target-components and test-e2e name
# it as a prerequisite, so they share one build when given together.
test:
	@$(MAKE) --no-print-directory test-compiler
	@$(MAKE) --no-print-directory format-check test-target-components test-e2e

# The formatting gate. The roots are named so the walk never reaches build
# output. FORMAT_EXCLUDED holds the sources that are unformatted on purpose:
# the formatter's own layout inputs, and must-fail fixtures that the parser
# rejects (so the formatter cannot read them), whose rejections the e2e driver
# checks. It uses the test compiler already built; `make test` builds it first, and
# run alone it needs `make -C blorp test-compiler` (or `compiler`) beforehand.
FORMAT_ROOTS := blorp/scripts blorp/src blorp/standard_library blorp/test
FORMAT_EXCLUDED := \
	blorp/test/unit/test_format/fixtures \
	blorp/test/e2e/fixtures/opaque/generic/explicit_arguments.brp \
	blorp/test/e2e/fixtures/unsupported/propagation_if.brp \
	blorp/test/e2e/fixtures/unsupported/propagation_match.brp \
	blorp/test/e2e/fixtures/variants/alias_union_variant.brp \
	blorp/test/e2e/trait_inputs/operators/reject_chain.brp

format-check:
	@$(RESOLVE_TEST_TOOLS); \
	"$$compiler_path" format --check \
		$(addprefix --exclude ,$(FORMAT_EXCLUDED)) $(FORMAT_ROOTS)

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
# blorp/build/self-hosted-tests/, where a failure can be inspected. With no
# TARGET_COMPONENT_SOURCES the driver runs its whole selection, and first fails
# on any test_*.brp that selection leaves out.
test-target-components: build-test-driver
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" components "$$compiler_path" "$$cc_path" \
			$(TEST_COMPILER_LIBRARIES) -- $(TARGET_COMPONENT_SOURCES)

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: generate-compiler
	@$(MAKE) --no-print-directory link-test-compiler

link-test-compiler:
	@echo 'Link $(BLORP_TEST_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP_TEST_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			"$(BLORP_COMPILER_C)" -o "$(BLORP_TEST_COMPILER)" $(TEST_COMPILER_LIBRARIES)

test-e2e: build-test-driver
	@set -eu; $(RESOLVE_TEST_TOOLS); \
		temporary_parent=$$(cd "$${TMPDIR:-/tmp}" && pwd -P); \
		BLORP_LEAK_CHECK=strict "$(TEST_DRIVER)" e2e "$$compiler_path" "$$cc_path" "$$temporary_parent" \
			$(if $(INSTRUCTION_CHECK),$(if $(filter on,$(INSTRUCTION_CHECK)),--check-instructions,$(error INSTRUCTION_CHECK must be empty or on, not $(INSTRUCTION_CHECK))))
