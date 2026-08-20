# Blorp Compiler Makefile

.PHONY: all build build-blorp-cli compiler-build-source-generator install warm warm-formatter clean test smoke runtime-test test-asan compiler-blorp-test compiler-tools-test compiler-core-sanitize-test compiler-blorp-sanitize-test lsp-test package-test c-static-analysis security-check hygiene-check quality quality-full docker-build docker-gate docker-gate-clean docker-shell docker-premerge-gate docker-premerge-gate-all force-generated-sources

STD_SOURCES := $(shell find std -name '*.brp' 2>/dev/null)
BLORP_CLI_SOURCE := compiler/blorp/src/stage_12_cli/main.brp
BLORP_CLI_BUILD_DIR := compiler/_build/blorp-cli
BLORP_CLI_C := $(BLORP_CLI_BUILD_DIR)/blorp_cli_main.c
BLORP_CLI_BIN := $(BLORP_CLI_BUILD_DIR)/blorp
BLORP_CLI_INPUT_HASH := $(BLORP_CLI_BUILD_DIR)/inputs.sha256
BLORP_CLI_C_OPTIMIZATION ?= -O0
BLORP_CLI_RUNTIME_CONFIG_HASH := $(shell { printf '%s\n' '$(BLORP_CLI_C_OPTIMIZATION)' '-fwrapv -pipe -w -DMINICORO_IMPL -DBLORP_COMPILER_RUNTIME_SOURCES=1'; command -v cc; cc --version 2>/dev/null | head -n 1; } | shasum -a 256 | awk '{print $$1}')
BLORP_CLI_BUILD_INPUT_MANIFEST := $(BLORP_CLI_BUILD_DIR)/build-inputs.sha256
BLORP_CLI_BIN_HASH := $(BLORP_CLI_BUILD_DIR)/blorp.sha256
BLORP_CLI_EMBEDDED_INPUT_MANIFEST := $(BLORP_CLI_BUILD_DIR)/embedded-inputs.sha256
BLORP_CLI_MANIFEST_TOOL := scripts/blorp-cli-embedded-manifest
BLORP_CLI_RUNTIME_SOURCES_C := $(BLORP_CLI_BUILD_DIR)/compiler_runtime_sources.c
BLORP_CLI_RUNTIME_OBJECT := $(BLORP_CLI_BUILD_DIR)/runtime-$(BLORP_CLI_RUNTIME_CONFIG_HASH).o
BLORP_LSP_NATIVE_RUNTIME_C := compiler/blorp/src/stage_12_lsp/native_runtime.c
BLORP_EMBEDDED_STD_SOURCE := compiler/blorp/src/stage_01_file_io/embedded_std.brp
BLORP_BUILD_INFO_SOURCE := compiler/blorp/src/stage_01_file_io/compiler_build_info.brp
BLORP_COMPILER_BOOTSTRAP := scripts/blorp-compiler-bootstrap
BLORP_BUILD_TOOLS_DIR := compiler/_build/build-tools
BLORP_BUILD_SOURCE_GENERATOR_SOURCE := compiler/tools/generate_build_sources.brp
BLORP_BUILD_SOURCE_GENERATOR_C := $(BLORP_BUILD_TOOLS_DIR)/generate_build_sources.c
BLORP_BUILD_SOURCE_GENERATOR := $(BLORP_BUILD_TOOLS_DIR)/generate-build-sources
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
	@if ! "$(BLORP_CLI_MANIFEST_TOOL)" verify-installed \
		--compiler ./blorp \
		--inputs "$(BLORP_CLI_BUILD_INPUT_MANIFEST)" \
		--output "$(BLORP_CLI_EMBEDDED_INPUT_MANIFEST)"; then \
		rm -f ./blorp; \
		cp "$(BLORP_CLI_BIN)" ./blorp; \
		codesign -s - ./blorp 2>/dev/null || true; \
		"$(BLORP_CLI_MANIFEST_TOOL)" write-installed \
			--compiler ./blorp \
			--inputs "$(BLORP_CLI_BUILD_INPUT_MANIFEST)" \
			--output "$(BLORP_CLI_EMBEDDED_INPUT_MANIFEST)"; \
	fi

warm: warm-formatter

warm-formatter: install
	@tmp_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/blorp-format-warm.XXXXXX"); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	tmp="$$tmp_dir/warm.brp"; \
	printf 'func main(args: List[String]) -> Int:\n\t0\n' > "$$tmp"; \
	./blorp format --check "$$tmp" >/dev/null

# Generate the embedded std library consumed by the Blorp compiler.
force-generated-sources:

$(BLORP_BUILD_SOURCE_GENERATOR_C): $(BLORP_BUILD_SOURCE_GENERATOR_SOURCE) $(BLORP_COMPILER_BOOTSTRAP) compiler/bootstrap.env
	@mkdir -p "$(BLORP_BUILD_TOOLS_DIR)"
	@set -e; \
	bootstrap_compiler="$${BLORP_BOOTSTRAP_COMPILER_BIN:-}"; \
	if [ -z "$$bootstrap_compiler" ]; then \
		bootstrap_compiler=$$("$(BLORP_COMPILER_BOOTSTRAP)" --print-path); \
	fi; \
	tmp="$@.tmp"; \
	trap 'rm -f "$$tmp"' EXIT; \
	"$$bootstrap_compiler" compile --no-format -o "$$tmp" "$(BLORP_BUILD_SOURCE_GENERATOR_SOURCE)"; \
	mv "$$tmp" "$@"; \
	trap - EXIT

$(BLORP_BUILD_SOURCE_GENERATOR): $(BLORP_BUILD_SOURCE_GENERATOR_C)
	@set -e; \
	tmp="$@.tmp"; \
	trap 'rm -f "$$tmp"' EXIT; \
	cc -O2 -fwrapv -pipe -w "$<" -lm -lpthread -o "$$tmp"; \
	mv "$$tmp" "$@"; \
	trap - EXIT

compiler-build-source-generator: $(BLORP_BUILD_SOURCE_GENERATOR)

$(BLORP_EMBEDDED_STD_SOURCE): force-generated-sources $(BLORP_BUILD_SOURCE_GENERATOR) $(STD_SOURCES)
	$(BLORP_BUILD_SOURCE_GENERATOR) embedded-std std > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

$(BLORP_BUILD_INFO_SOURCE): force-generated-sources $(BLORP_BUILD_SOURCE_GENERATOR) compiler/VERSION
	$(BLORP_BUILD_SOURCE_GENERATOR) build-info compiler/VERSION > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

# Keep `build` as the established alias for the self-hosted compiler.
build: build-blorp-cli

# Build the public Blorp executable through the immutable pinned compiler.
$(BLORP_CLI_RUNTIME_SOURCES_C): force-generated-sources $(BLORP_BUILD_SOURCE_GENERATOR) compiler/lib/minicoro.h compiler/lib/runtime.c compiler/lib/runtime_decl.c
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	$(BLORP_BUILD_SOURCE_GENERATOR) embedded-runtime-c compiler/lib/minicoro.h compiler/lib/runtime.c compiler/lib/runtime_decl.c > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

$(BLORP_CLI_RUNTIME_OBJECT): compiler/lib/minicoro.h compiler/lib/runtime.c compiler/lib/runtime_decl.c
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	tmp="$@.tmp"; \
	trap 'rm -f "$$tmp"' EXIT; \
	cc "$(BLORP_CLI_C_OPTIMIZATION)" -fwrapv -pipe -w -DMINICORO_IMPL \
		-DBLORP_COMPILER_RUNTIME_SOURCES=1 \
		-include compiler/lib/minicoro.h -c compiler/lib/runtime.c -o "$$tmp"; \
	mv "$$tmp" "$@"; \
	trap - EXIT

# Hash the complete public compiler build section, including runtime compilation.
build-blorp-cli: $(BLORP_EMBEDDED_STD_SOURCE) $(BLORP_BUILD_INFO_SOURCE) $(BLORP_CLI_SOURCE) $(BLORP_CLI_RUNTIME_SOURCES_C) $(BLORP_CLI_RUNTIME_OBJECT)
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	bootstrap_compiler="$${BLORP_BOOTSTRAP_COMPILER_BIN:-}"; \
	if [ -z "$$bootstrap_compiler" ]; then \
		bootstrap_compiler=$$("$(BLORP_COMPILER_BOOTSTRAP)" --print-path); \
	fi; \
	input_manifest_tmp="$(BLORP_CLI_BUILD_INPUT_MANIFEST).tmp"; \
	tmp_bin="$(BLORP_CLI_BIN).tmp"; \
	tmp_hash="$(BLORP_CLI_INPUT_HASH).tmp"; \
	tmp_bin_hash="$(BLORP_CLI_BIN_HASH).tmp"; \
	trap 'rm -f "$$input_manifest_tmp" "$$tmp_bin" "$$tmp_hash" "$$tmp_bin_hash"' EXIT; \
	rm -f "$$input_manifest_tmp" "$$tmp_bin" "$$tmp_hash" "$$tmp_bin_hash"; \
	{ \
		find compiler/blorp/src \( -name '*.brp' -o -name '*.h' \) -type f -print; \
		find std -name '*.brp' -type f -print; \
		find tools/formatter -name '*.brp' -type f -print; \
		printf '%s\n' "$$bootstrap_compiler" "$(BLORP_COMPILER_BOOTSTRAP)" "$(BLORP_CLI_MANIFEST_TOOL)" "$(BLORP_CLI_RUNTIME_SOURCES_C)" "$(BLORP_LSP_NATIVE_RUNTIME_C)" "$(BLORP_BUILD_SOURCE_GENERATOR_SOURCE)" compiler/lib/runtime.c compiler/lib/runtime_decl.c compiler/lib/minicoro.h; \
	} | LC_ALL=C sort -u | "$(BLORP_CLI_MANIFEST_TOOL)" write-inputs \
		--root . \
		--output "$$input_manifest_tmp"; \
	source_hash=$$(shasum -a 256 "$$input_manifest_tmp" | awk '{print $$1}'); \
	recipe_hash=$$(sed -n '/^# Build the public Blorp executable/,/^# Run the top-level local test gate/p' Makefile | shasum -a 256 | awk '{print $$1}'); \
	new_hash=$$(printf '%s\n%s\n%s\n' "$$source_hash" "$$recipe_hash" "$(BLORP_CLI_C_OPTIMIZATION)" | shasum -a 256 | awk '{print $$1}'); \
	old_hash=$$(cat "$(BLORP_CLI_INPUT_HASH)" 2>/dev/null || true); \
	recorded_bin_hash=$$(cat "$(BLORP_CLI_BIN_HASH)" 2>/dev/null || true); \
	actual_bin_hash=$$(shasum -a 256 "$(BLORP_CLI_BIN)" 2>/dev/null | awk '{print $$1}'); \
	if [ "$$new_hash" != "$$old_hash" ] || [ ! -x "$(BLORP_CLI_BIN)" ] || [ ! -s "$(BLORP_CLI_C)" ] || [ -z "$$actual_bin_hash" ] || [ "$$actual_bin_hash" != "$$recorded_bin_hash" ]; then \
		echo "Building Blorp CLI"; \
		rm -f "$(BLORP_CLI_C)"; \
		"$$bootstrap_compiler" compile --no-format --no-embed-runtime -o "$(BLORP_CLI_C)" "$(BLORP_CLI_SOURCE)"; \
		test -s "$(BLORP_CLI_C)"; \
		cc "$(BLORP_CLI_C_OPTIMIZATION)" -fwrapv -pipe -w -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
			-include compiler/lib/runtime_decl.c \
			-Icompiler/blorp/src/stage_01_file_io \
			-Icompiler/blorp/src/stage_06_typecheck/graph \
			-Icompiler/blorp/src/stage_12_cli \
			-Icompiler/blorp/src/stage_12_lsp \
			"$(BLORP_CLI_C)" "$(BLORP_CLI_RUNTIME_OBJECT)" "$(BLORP_CLI_RUNTIME_SOURCES_C)" "$(BLORP_LSP_NATIVE_RUNTIME_C)" -lm -lpthread -o "$$tmp_bin"; \
		shasum -a 256 "$$tmp_bin" | awk '{print $$1}' > "$$tmp_bin_hash"; \
		mv "$$tmp_bin" "$(BLORP_CLI_BIN)"; \
		printf '%s\n' "$$new_hash" > "$$tmp_hash"; \
		mv "$$tmp_hash" "$(BLORP_CLI_INPUT_HASH)"; \
		mv "$$tmp_bin_hash" "$(BLORP_CLI_BIN_HASH)"; \
	else \
		echo "Blorp CLI up to date"; \
	fi; \
	mv "$$input_manifest_tmp" "$(BLORP_CLI_BUILD_INPUT_MANIFEST)"; \
	trap - EXIT

# Run the top-level local test gate
test:
	scripts/test

# Run runtime tests only (language features + standard library)
runtime-test: all
	./blorp test $(RUNTIME_TEST_ROOTS)

# Fast local validation path for compiler work
smoke: all
	./blorp check --no-format compiler/blorp/src/stage_12_cli/main.brp

quality:
	$(MAKE) hygiene-check
	$(MAKE) c-static-analysis

quality-full: quality

hygiene-check: build-blorp-cli
	@scripts/check-editor-drift
	@scripts/compiler-check --validate-manifest
	@scripts/check-std-builtins
	@scripts/check-compiler-bridge-stack-usage
	@$(BLORP_CLI_BIN) check --no-format compiler/blorp/benchmarks/compiler_typecheck_worker.brp
	@$(BLORP_CLI_BIN) check --no-format compiler/blorp/benchmarks/compiler_backend_worker.brp
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_backend_memory_benchmark.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_perceus_memory_benchmark.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_perceus_ownership_node_inventory.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_perceus_cleanup_coverage_ledger.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_blorp_test_session_benchmark.py
	@PYTHONDWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_typecheck_worker.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_typecheck_memory_benchmark.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_typecheck_replay.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_blorp_check_fixtures.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_tool_fixtures.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_check_std_builtins.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_audit_compiler_blorp_dead_code.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_compiler_check.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_runtime_allocator_stats.py
	@tests/test_compiler_record_layout_benchmark.sh
	@BLORP_RECORD_UPDATE_SKIP_BUILD=1 benchmarks/compiler_record_update_match_allocations
	@BLORP_RECORD_UPDATE_SKIP_BUILD=1 benchmarks/compiler_record_update_nested_match_allocations
	@tests/test_build_configuration.sh
	@tests/test_build_source_generator.sh
	@tests/test_release_toolchain.sh
	@tests/test_scripts_test_harness.sh
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
		-o "$$tmp_plist" -x c compiler/lib/runtime.c; \
	clang --analyze -D_GNU_SOURCE -Wno-unused-command-line-argument \
		-Icompiler/blorp/src/stage_12_lsp \
		-o "$$tmp_plist" -x c "$(BLORP_LSP_NATIVE_RUNTIME_C)"

security-check: all c-static-analysis
	tests/test_compiler/codegen_audit/run_codegen_audit.sh ./blorp
	BLORP_COMPILER_TEST_TIMEOUT=180 scripts/test compiler-blorp
	./blorp test --timeout 20 $(SECURITY_RUNTIME_TESTS)
	./blorp test --leak-check --timeout 20 $(SECURITY_LEAK_TESTS)

# Run runtime tests with sanitizer instrumentation. On Darwin, Apple
# AddressSanitizer does not reliably compose with user-land fiber stack
# switching, so the runtime-wide gate uses UBSan there. Linux keeps the
# stronger ASan + UBSan combination.
test-asan: all
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		./blorp test --sanitize=undefined $(RUNTIME_TEST_ROOTS); \
	else \
		./blorp test --sanitize $(RUNTIME_TEST_ROOTS); \
	fi

# Run the self-hosted compiler TestSuites under ASan.
# Keep this separate from test-asan: compiler-owned sources do not exercise
# fiber stack switching and therefore support AddressSanitizer on Darwin too.
compiler-core-sanitize-test: all
	scripts/test compiler-core-sanitize --serial

compiler-blorp-sanitize-test: all
	scripts/test compiler-blorp-sanitize --serial

compiler-blorp-test: all
	scripts/test compiler-blorp --serial

compiler-tools-test: all
	scripts/test compiler-tools --serial

lsp-test: all
	scripts/test lsp --serial

package-test: all
	scripts/test package --serial

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
	rm -rf "$(BLORP_CLI_BUILD_DIR)"
	rm -rf "$(BLORP_BUILD_TOOLS_DIR)"
	rm -f ./blorp \
		"$(BLORP_EMBEDDED_STD_SOURCE)" "$(BLORP_BUILD_INFO_SOURCE)"
