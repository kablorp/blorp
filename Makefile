# Blorp Compiler Makefile

.PHONY: all build build-blorp-cli install warm warm-formatter clean test smoke runtime-test test-asan compiler-core-sanitize-test compiler-blorp-sanitize-test compiler-unit-test compiler-unit-deep-test unit-test coverage c-static-analysis security-check hygiene-check quality quality-full docker-build docker-gate docker-gate-clean docker-shell docker-premerge-gate docker-premerge-gate-all

STD_SOURCES := $(shell find std -name '*.brp' 2>/dev/null)
OCAML_HOST := compiler/_build/default/bin/blorp_ocaml_host.exe
ROOT_OCAML_HOST := ./blorp-ocaml-host
BLORP_CLI_SOURCE := compiler/blorp/src/stage_12_cli/compiler_cli_main.brp
BLORP_CLI_BUILD_DIR := compiler/_build/blorp-cli
BLORP_CLI_C := $(BLORP_CLI_BUILD_DIR)/blorp_cli_main.c
BLORP_CLI_BIN := $(BLORP_CLI_BUILD_DIR)/blorp
BLORP_CLI_INPUT_HASH := $(BLORP_CLI_BUILD_DIR)/inputs.sha256
BLORP_COMPILER_BOOTSTRAP := scripts/blorp-compiler-bootstrap
RUNTIME_TEST_ROOTS := $(wildcard tests/test_blorp tests/test_std tests/test_pkg)
SECURITY_RUNTIME_TESTS := \
	tests/test_blorp/sys/test_process.brp \
	tests/test_blorp/sys/test_file_io.brp \
	tests/test_blorp/sys/test_system_fs.brp \
	tests/test_blorp/sys/test_system_interface.brp \
	tests/test_blorp/sys/test_env.brp \
	tests/test_blorp/sys/test_time.brp \
	tests/test_blorp/sys/test_runtime_safety.brp \
	tests/test_blorp/sys/test_streaming_io.brp \
	tests/test_blorp/sys/test_for_each_line.brp \
	tests/test_blorp/text/test_regex.brp \
	tests/test_blorp/text/test_string_capacity.brp \
	tests/test_blorp/text/test_bytes.brp \
	tests/test_blorp/numeric/test_crypto_random.brp \
	tests/test_blorp/memory/test_builtin_borrowed_arg_ownership.brp \
	tests/test_std/stream/test_stream.brp
SECURITY_LEAK_TESTS := \
	tests/test_blorp/sys/test_process.brp \
	tests/test_blorp/sys/test_file_io.brp \
	tests/test_blorp/sys/test_streaming_io.brp \
	tests/test_blorp/sys/test_for_each_line.brp \
	tests/test_blorp/text/test_regex.brp \
	tests/test_blorp/sys/test_runtime_safety.brp \
	tests/test_blorp/memory/test_builtin_borrowed_arg_ownership.brp

# Default target: build and install blorp to the project root.
all: install

# Only copy when build outputs are newer. Installed root binaries may be
# ad-hoc signed on macOS, so byte-for-byte comparison against unsigned outputs
# would recopy on every make and invalidate mtime-based caches.
install: build-blorp-cli
	@if [ ! -f "$(ROOT_OCAML_HOST)" ] || [ "$(OCAML_HOST)" -nt "$(ROOT_OCAML_HOST)" ]; then \
		rm -f "$(ROOT_OCAML_HOST)"; \
		cp "$(OCAML_HOST)" "$(ROOT_OCAML_HOST)"; \
		codesign -s - "$(ROOT_OCAML_HOST)" 2>/dev/null || true; \
	fi
	@if [ ! -f ./blorp ] || [ "$(BLORP_CLI_BIN)" -nt ./blorp ]; then \
		rm -f ./blorp; \
		cp "$(BLORP_CLI_BIN)" ./blorp; \
		codesign -s - ./blorp 2>/dev/null || true; \
	fi

warm: warm-formatter

warm-formatter: install
	@tmp_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/blorp-format-warm.XXXXXX"); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	tmp="$$tmp_dir/warm.brp"; \
	printf 'func main(args: List[String]) -> Int:\n\t0\n' > "$$tmp"; \
	./blorp format --check "$$tmp" >/dev/null

# Generate embedded std library from std/**/*.brp
compiler/lib/embedded_std.ml: compiler/tools/gen_embed_std.ml $(STD_SOURCES)
	ocaml compiler/tools/gen_embed_std.ml std > $@.tmp && mv $@.tmp $@

# Build the OCaml compiler
build: compiler/lib/embedded_std.ml
	cd compiler && dune build bin/blorp_ocaml_host.exe bin/blorp_ocaml_middle.exe

# Build the public Blorp executable. The OCaml binary remains as a private host
# for compiler stages that have not yet moved across the boundary.
build-blorp-cli: build $(BLORP_CLI_SOURCE)
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	bridge_compiler="$${BLORP_COMPILER_BRIDGE_BIN:-}"; \
	if [ -z "$$bridge_compiler" ]; then \
		bridge_compiler=$$("$(BLORP_COMPILER_BOOTSTRAP)" --print-path); \
	fi; \
	new_hash=$$( { \
		find compiler/blorp/src -name '*.brp' -type f -print; \
		find std -name '*.brp' -type f -print; \
		printf '%s\n' "$(OCAML_HOST)" "$$bridge_compiler" compiler/lib/runtime.c compiler/lib/runtime_decl.c compiler/lib/minicoro.h; \
	} | LC_ALL=C sort | while IFS= read -r path; do shasum -a 256 "$$path"; done | shasum -a 256 | awk '{print $$1}' ); \
	old_hash=$$(cat "$(BLORP_CLI_INPUT_HASH)" 2>/dev/null || true); \
	if [ "$$new_hash" != "$$old_hash" ] || [ ! -x "$(BLORP_CLI_BIN)" ]; then \
		echo "Building Blorp CLI"; \
		tmp_bin="$(BLORP_CLI_BIN).tmp"; \
		tmp_hash="$(BLORP_CLI_INPUT_HASH).tmp"; \
		trap 'rm -f "$$tmp_bin" "$$tmp_hash"' EXIT; \
		rm -f "$(BLORP_CLI_C)" "$$tmp_bin" "$$tmp_hash"; \
		BLORP_COMPILER_BRIDGE_BIN="$$bridge_compiler" "$(OCAML_HOST)" __compiler-host-compile-wrapper -o "$(BLORP_CLI_C)" "$(BLORP_CLI_SOURCE)"; \
		test -s "$(BLORP_CLI_C)"; \
		cc -O0 -fwrapv -pipe -w "$(BLORP_CLI_C)" -lm -lpthread -o "$$tmp_bin"; \
		mv "$$tmp_bin" "$(BLORP_CLI_BIN)"; \
		printf '%s\n' "$$new_hash" > "$$tmp_hash"; \
		mv "$$tmp_hash" "$(BLORP_CLI_INPUT_HASH)"; \
		trap - EXIT; \
	else \
		echo "Blorp CLI up to date"; \
	fi

# Run the top-level local test gate
test:
	scripts/test

# Run runtime tests only (language features + standard library)
runtime-test: all
	./blorp test $(RUNTIME_TEST_ROOTS)

# Fast local validation path for compiler work
smoke: all
	scripts/test compiler-unit compiler

# Run compiler-internal OCaml/Alcotest tests
compiler-unit-test: compiler/lib/embedded_std.ml
	cd compiler && dune exec test/run_tests.exe -- --scope=default

# Run integration-shaped compiler-internal OCaml/Alcotest tests
compiler-unit-deep-test: compiler/lib/embedded_std.ml
	cd compiler && dune exec test/run_tests.exe -- --scope=deep

# Legacy alias for compiler-unit-test
unit-test: compiler-unit-test

quality:
	$(MAKE) hygiene-check
	$(MAKE) c-static-analysis

quality-full: quality

hygiene-check:
	@if [ -d ocaml ]; then \
		echo "Retired compiler source directory './ocaml' found."; \
		echo "Compiler sources live in './compiler'; remove stale generated or copied files."; \
		exit 1; \
	fi
	@scripts/check-editor-drift
	@scripts/check-std-builtins
	@scripts/check-compiler-port-inventory
	@scripts/check-compiler-bridge-stack-usage
	@tests/test_build_configuration.sh
	@tests/test_scripts_test_harness.sh
	@if [ -e compiler/_build/default/lib/parser.conflicts ] && [ -s compiler/_build/default/lib/parser.conflicts ]; then \
		echo "Menhir conflicts found in compiler/_build/default/lib/parser.conflicts."; \
		echo "Inspect the conflict report before continuing."; \
		exit 1; \
	fi
	@artifacts=$$( \
		find . \
			\( -path './.git' -o -path './compiler/_build' -o -path './_build' -o -path './cmake-build-debug' \) -prune -o \
			\( -name 'runtime_decl.plist' -o -name '*.generated.c' -o -name '.blorp_doctest_*' \) -print; \
		find tests std -name '*.c' -print 2>/dev/null; \
	); \
	if [ -n "$$artifacts" ]; then \
		echo "Generated artifacts should not be left in the repo:"; \
		echo "$$artifacts"; \
		exit 1; \
	fi

# Run compiler-unit tests with coverage report
coverage:
	rm -rf compiler/_coverage
	mkdir -p compiler/_coverage
	cd compiler && dune build --instrument-with bisect_ppx --force test/run_tests.exe
	cd compiler && BISECT_FILE=$(CURDIR)/compiler/_coverage/bisect ./_build/default/test/run_tests.exe --scope=default $(RUN_TESTS_ARGS)
	cd compiler && bisect-ppx-report summary --coverage-path $(CURDIR)/compiler/_coverage
	cd compiler && bisect-ppx-report html --coverage-path $(CURDIR)/compiler/_coverage
	@echo "Coverage report: compiler/_coverage/index.html"

c-static-analysis:
	@command -v clang >/dev/null 2>&1 || { \
		echo "clang is required for c-static-analysis."; \
		exit 127; \
	}
	@tmp_plist=$$(mktemp "$${TMPDIR:-/tmp}/blorp-clang-analyze.XXXXXX"); \
	block_checker_args=$$(clang -cc1 -analyzer-checker-help 2>/dev/null | grep -Fq 'unix.BlockInCriticalSection' && printf '%s' '-Xclang -analyzer-disable-checker=unix.BlockInCriticalSection'); \
	trap 'rm -f "$$tmp_plist"' EXIT; \
	clang --analyze -D_GNU_SOURCE -Wno-nullability-completeness -Wno-unused-command-line-argument -o "$$tmp_plist" -x c compiler/lib/runtime_decl.c; \
	clang --analyze -Wno-nullability-completeness -Wno-unused-command-line-argument \
		-D_GNU_SOURCE $$block_checker_args \
		-DMINICORO_IMPL -include compiler/lib/minicoro.h \
		-o "$$tmp_plist" -x c compiler/lib/runtime.c

security-check: all c-static-analysis
	BLORP_COMPILER_TEST_TIMEOUT=60 scripts/test compiler compiler-deep
	./blorp test --no-cache --timeout 20 $(SECURITY_RUNTIME_TESTS)
	./blorp test --no-cache --leak-check --timeout 20 $(SECURITY_LEAK_TESTS)

# Run runtime tests with sanitizer instrumentation. On Darwin, Apple
# AddressSanitizer does not reliably compose with user-land fiber stack
# switching, so the runtime-wide gate uses UBSan there. Linux keeps the
# stronger ASan + UBSan combination.
test-asan: all
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		./blorp test --no-format --sanitize=undefined $(RUNTIME_TEST_ROOTS); \
	else \
		./blorp test --no-format --sanitize $(RUNTIME_TEST_ROOTS); \
	fi

# Run the self-hosted compiler TestSuites without result caching under ASan.
# Keep this separate from test-asan: compiler-owned sources do not exercise
# fiber stack switching and therefore support AddressSanitizer on Darwin too.
compiler-core-sanitize-test: all
	scripts/test compiler-core-sanitize --serial

compiler-blorp-sanitize-test: all
	scripts/test compiler-blorp-sanitize --serial

# Docker targets
docker-build:
	scripts/docker-gate --build-only

docker-gate:
	scripts/docker-gate

docker-gate-clean:
	scripts/docker-gate --clean

docker-shell:
	scripts/docker-gate --shell

docker-premerge-gate:
	scripts/docker-gate --premerge-gate

docker-premerge-gate-all:
	scripts/docker-gate --premerge-gate --all-platforms

# Clean build artifacts
clean:
	cd compiler && dune clean
	rm -rf "$(BLORP_CLI_BUILD_DIR)"
	rm -f ./blorp "$(ROOT_OCAML_HOST)" compiler/lib/embedded_std.ml
