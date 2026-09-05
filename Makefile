# Blorp Compiler Makefile

.PHONY: all build build-blorp-cli generate-blorp-cli-c prepare-blorp-cli-c compile-prepared-blorp-cli compile-blorp-cli install-prepared-blorp-cli compiler-build-source-generator install warm warm-formatter clean test smoke runtime-test test-asan compiler-blorp-test compiler-tools-test compiler-core-sanitize-test compiler-blorp-sanitize-test lsp-test package-test c-static-analysis security-check hygiene-check quality quality-full docker-build docker-gate docker-gate-clean docker-shell docker-premerge-gate docker-premerge-gate-all force-generated-sources

STANDARD_LIBRARY_SOURCE_ROOT := standard_library/src
STANDARD_LIBRARY_TEST_ROOT := standard_library/test
STANDARD_LIBRARY_SOURCES := $(shell find $(STANDARD_LIBRARY_SOURCE_ROOT) -name '*.brp' 2>/dev/null)
BLORP_CLI_SOURCE := blorp/src/main.brp
BLORP_CLI_BUILD_DIR := blorp/build/_build/blorp-cli
BLORP_CLI_C := $(BLORP_CLI_BUILD_DIR)/blorp_cli_main.c
BLORP_CLI_BIN := $(BLORP_CLI_BUILD_DIR)/blorp
BLORP_INSTALLED_BIN := bin/blorp
BLORP_CLI_INPUT_HASH := $(BLORP_CLI_BUILD_DIR)/inputs.sha256
BLORP_CLI_C_INPUT_HASH := $(BLORP_CLI_BUILD_DIR)/generated-c-inputs.sha256
BLORP_CLI_C_HASH := $(BLORP_CLI_BUILD_DIR)/blorp_cli_main.c.sha256
BLORP_CLI_C_BUILD_INPUT_MANIFEST := $(BLORP_CLI_BUILD_DIR)/generated-c-build-inputs.sha256
BLORP_CLI_C_OPTIMIZATION ?= -O0
BLORP_CLI_RUNTIME_CONFIG_HASH := $(shell { printf '%s\n' '$(BLORP_CLI_C_OPTIMIZATION)' '-fwrapv -pipe -w -DMINICORO_IMPL -DBLORP_COMPILER_RUNTIME_SOURCES=1'; command -v cc; cc --version 2>/dev/null | head -n 1; } | shasum -a 256 | awk '{print $$1}')
BLORP_CLI_BUILD_INPUT_MANIFEST := $(BLORP_CLI_BUILD_DIR)/build-inputs.sha256
BLORP_CLI_INSTALL_INPUT_MANIFEST := $(BLORP_CLI_BUILD_DIR)/install-inputs.sha256
BLORP_CLI_BIN_HASH := $(BLORP_CLI_BUILD_DIR)/blorp.sha256
BLORP_CLI_EMBEDDED_INPUT_MANIFEST := $(BLORP_CLI_BUILD_DIR)/embedded-inputs.sha256
BLORP_CLI_MANIFEST_TOOL := scripts/blorp-cli-embedded-manifest
BLORP_CLI_RUNTIME_SOURCES_C := $(BLORP_CLI_BUILD_DIR)/runtime_sources.c
BLORP_CLI_RUNTIME_OBJECT := $(BLORP_CLI_BUILD_DIR)/runtime-$(BLORP_CLI_RUNTIME_CONFIG_HASH).o
BLORP_LSP_NATIVE_RUNTIME_C := blorp/src/lsp/server/native_runtime.c
BLORP_EMBEDDED_STD_SOURCE := blorp/src/compiler/stage_01_generated_inputs/embedded_std.brp
BLORP_BUILD_INFO_SOURCE := blorp/src/compiler/stage_01_generated_inputs/compiler_build_info.brp
BLORP_COMPILER_BOOTSTRAP := scripts/blorp-compiler-bootstrap
BLORP_BUILD_TOOLS_DIR := blorp/build/_build/build-tools
BLORP_BUILD_SOURCE_GENERATOR_SOURCE := blorp/tool/generate_build_sources.brp
BLORP_BUILD_SOURCE_GENERATOR_C := $(BLORP_BUILD_TOOLS_DIR)/generate_build_sources.c
BLORP_BUILD_SOURCE_GENERATOR := $(BLORP_BUILD_TOOLS_DIR)/generate-build-sources
RUNTIME_TEST_ROOTS := $(wildcard blorp/test/runtime $(STANDARD_LIBRARY_TEST_ROOT) pkg/test)
SECURITY_RUNTIME_TESTS := \
	blorp/test/runtime/sys/test_process.brp \
	blorp/test/runtime/sys/test_file_io.brp \
	blorp/test/runtime/sys/test_system_fs.brp \
	blorp/test/runtime/sys/test_system_interface.brp \
	blorp/test/runtime/sys/test_env.brp \
	blorp/test/runtime/sys/test_time.brp \
	blorp/test/runtime/sys/test_runtime_safety.brp \
	blorp/test/runtime/sys/test_streaming_io.brp \
	blorp/test/runtime/sys/test_for_each_line.brp \
	blorp/test/runtime/text/test_regex.brp \
	blorp/test/runtime/text/test_string_capacity.brp \
	blorp/test/runtime/text/test_bytes.brp \
	blorp/test/runtime/numeric/test_crypto_random.brp \
	blorp/test/runtime/memory/test_builtin_borrowed_arg_ownership.brp \
	$(STANDARD_LIBRARY_TEST_ROOT)/stream/test_stream.brp
SECURITY_LEAK_TESTS := \
	blorp/test/runtime/sys/test_process.brp \
	blorp/test/runtime/sys/test_file_io.brp \
	blorp/test/runtime/sys/test_streaming_io.brp \
	blorp/test/runtime/sys/test_for_each_line.brp \
	blorp/test/runtime/text/test_regex.brp \
	blorp/test/runtime/sys/test_runtime_safety.brp \
	blorp/test/runtime/memory/test_builtin_borrowed_arg_ownership.brp

# Default target: build and install blorp under bin/.
all: install

# Only copy when build outputs are newer. Installed root binaries may be
# ad-hoc signed on macOS, so byte-for-byte comparison against unsigned outputs
# would recopy on every make and invalidate mtime-based caches.
install: build-blorp-cli
	@$(MAKE) --no-print-directory install-prepared-blorp-cli

install-prepared-blorp-cli:
	@test -x "$(BLORP_CLI_BIN)"
	@printf '%s\n' "$(BLORP_CLI_INPUT_HASH)" "$(BLORP_CLI_BIN_HASH)" | \
		"$(BLORP_CLI_MANIFEST_TOOL)" write-inputs \
			--root . \
			--output "$(BLORP_CLI_INSTALL_INPUT_MANIFEST)"
	@mkdir -p "$(dir $(BLORP_INSTALLED_BIN))"
	@if ! "$(BLORP_CLI_MANIFEST_TOOL)" verify-installed \
		--compiler "$(BLORP_INSTALLED_BIN)" \
		--inputs "$(BLORP_CLI_INSTALL_INPUT_MANIFEST)" \
		--output "$(BLORP_CLI_EMBEDDED_INPUT_MANIFEST)"; then \
		rm -f "$(BLORP_INSTALLED_BIN)"; \
		cp "$(BLORP_CLI_BIN)" "$(BLORP_INSTALLED_BIN)"; \
		codesign -s - "$(BLORP_INSTALLED_BIN)" 2>/dev/null || true; \
		"$(BLORP_CLI_MANIFEST_TOOL)" write-installed \
			--compiler "$(BLORP_INSTALLED_BIN)" \
			--inputs "$(BLORP_CLI_INSTALL_INPUT_MANIFEST)" \
			--output "$(BLORP_CLI_EMBEDDED_INPUT_MANIFEST)"; \
	fi

warm: warm-formatter

warm-formatter: install
	@tmp_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/blorp-format-warm.XXXXXX"); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	tmp="$$tmp_dir/warm.brp"; \
	printf 'func main(args: List[String]) -> Int:\n\t0\n' > "$$tmp"; \
	$(BLORP_INSTALLED_BIN) format --check "$$tmp" >/dev/null

# Generate the embedded std library consumed by the Blorp compiler.
force-generated-sources:

$(BLORP_BUILD_SOURCE_GENERATOR_C): $(BLORP_BUILD_SOURCE_GENERATOR_SOURCE) $(BLORP_COMPILER_BOOTSTRAP) blorp/build/bootstrap.env
	@mkdir -p "$(BLORP_BUILD_TOOLS_DIR)"
	@set -e; \
	bootstrap_compiler="$${BLORP_BOOTSTRAP_COMPILER_BIN:-}"; \
	if [ -z "$$bootstrap_compiler" ]; then \
		bootstrap_compiler=$$("$(BLORP_COMPILER_BOOTSTRAP)" --print-path); \
	fi; \
	tmp="$@.tmp"; \
	trap 'rm -f "$$tmp"' EXIT; \
	"$$bootstrap_compiler" compile --std-dir "$(STANDARD_LIBRARY_SOURCE_ROOT)" \
		--no-format -o "$$tmp" "$(BLORP_BUILD_SOURCE_GENERATOR_SOURCE)"; \
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

$(BLORP_EMBEDDED_STD_SOURCE): force-generated-sources $(BLORP_BUILD_SOURCE_GENERATOR) $(STANDARD_LIBRARY_SOURCES)
	$(BLORP_BUILD_SOURCE_GENERATOR) embedded-std $(STANDARD_LIBRARY_SOURCE_ROOT) > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

$(BLORP_BUILD_INFO_SOURCE): force-generated-sources $(BLORP_BUILD_SOURCE_GENERATOR) blorp/build/VERSION
	$(BLORP_BUILD_SOURCE_GENERATOR) build-info blorp/build/VERSION > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

# Keep `build` as the established alias for the self-hosted compiler.
build: build-blorp-cli

# Build the public Blorp executable through the immutable pinned compiler.
$(BLORP_CLI_RUNTIME_SOURCES_C): force-generated-sources $(BLORP_BUILD_SOURCE_GENERATOR) blorp/src/lib/runtime/native/minicoro.h blorp/src/lib/runtime/native/runtime.c blorp/src/lib/runtime/native/runtime_decl.c
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	$(BLORP_BUILD_SOURCE_GENERATOR) embedded-runtime-c blorp/src/lib/runtime/native/minicoro.h blorp/src/lib/runtime/native/runtime.c blorp/src/lib/runtime/native/runtime_decl.c > $@.tmp
	@cmp -s $@.tmp $@ && rm -f $@.tmp || mv $@.tmp $@

$(BLORP_CLI_RUNTIME_OBJECT): blorp/src/lib/runtime/native/minicoro.h blorp/src/lib/runtime/native/runtime.c blorp/src/lib/runtime/native/runtime_decl.c
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	tmp="$@.tmp"; \
	trap 'rm -f "$$tmp"' EXIT; \
	cc "$(BLORP_CLI_C_OPTIMIZATION)" -fwrapv -pipe -w -DMINICORO_IMPL \
		-DBLORP_COMPILER_RUNTIME_SOURCES=1 \
		-include blorp/src/lib/runtime/native/minicoro.h -c blorp/src/lib/runtime/native/runtime.c -o "$$tmp"; \
	mv "$$tmp" "$@"; \
	trap - EXIT

# Generate the compiler C separately so CI reports self-hosting time independently.
generate-blorp-cli-c: $(BLORP_EMBEDDED_STD_SOURCE) $(BLORP_BUILD_INFO_SOURCE) $(BLORP_CLI_SOURCE)
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	bootstrap_compiler="$${BLORP_BOOTSTRAP_COMPILER_BIN:-}"; \
	if [ -z "$$bootstrap_compiler" ]; then \
		bootstrap_compiler=$$("$(BLORP_COMPILER_BOOTSTRAP)" --print-path); \
	fi; \
	case "$$bootstrap_compiler" in \
		*/*) ;; \
		*) bootstrap_compiler=$$(command -v "$$bootstrap_compiler") || { echo "Bootstrap compiler not found on PATH: $$bootstrap_compiler" >&2; exit 1; } ;; \
	esac; \
	bootstrap_compiler=$$(cd "$$(dirname "$$bootstrap_compiler")" && pwd -P)/$$(basename "$$bootstrap_compiler"); \
	input_manifest_tmp="$(BLORP_CLI_C_BUILD_INPUT_MANIFEST).tmp"; \
	tmp_c="$(BLORP_CLI_C).tmp"; \
	tmp_input_hash="$(BLORP_CLI_C_INPUT_HASH).tmp"; \
	tmp_c_hash="$(BLORP_CLI_C_HASH).tmp"; \
	trap 'rm -f "$$input_manifest_tmp" "$$tmp_c" "$$tmp_input_hash" "$$tmp_c_hash"' EXIT; \
	rm -f "$$input_manifest_tmp" "$$tmp_c" "$$tmp_input_hash" "$$tmp_c_hash"; \
	{ \
		find blorp/src -name '*.brp' -type f -print; \
		find $(STANDARD_LIBRARY_SOURCE_ROOT) -name '*.brp' -type f -print; \
		printf '%s\n' "$$bootstrap_compiler" "$(BLORP_COMPILER_BOOTSTRAP)" "$(BLORP_CLI_MANIFEST_TOOL)"; \
	} | LC_ALL=C sort -u | "$(BLORP_CLI_MANIFEST_TOOL)" write-inputs \
		--root . \
		--output "$$input_manifest_tmp"; \
	source_hash=$$(shasum -a 256 "$$input_manifest_tmp" | awk '{print $$1}'); \
	recipe_hash=$$(sed -n '/^# Generate the compiler C separately/,/^# Prepare every generated C input/p' Makefile | shasum -a 256 | awk '{print $$1}'); \
	new_input_hash=$$(printf '%s\n%s\n' "$$source_hash" "$$recipe_hash" | shasum -a 256 | awk '{print $$1}'); \
	old_input_hash=$$(cat "$(BLORP_CLI_C_INPUT_HASH)" 2>/dev/null || true); \
	recorded_c_hash=$$(cat "$(BLORP_CLI_C_HASH)" 2>/dev/null || true); \
	actual_c_hash=$$(shasum -a 256 "$(BLORP_CLI_C)" 2>/dev/null | awk '{print $$1}'); \
	if [ "$$new_input_hash" != "$$old_input_hash" ] || [ ! -s "$(BLORP_CLI_C)" ] || [ -z "$$actual_c_hash" ] || [ "$$actual_c_hash" != "$$recorded_c_hash" ]; then \
		echo "Generating Blorp CLI C"; \
		"$$bootstrap_compiler" compile --std-dir "$(STANDARD_LIBRARY_SOURCE_ROOT)" \
			--no-format --no-embed-runtime -o "$$tmp_c" "$(BLORP_CLI_SOURCE)"; \
		test -s "$$tmp_c"; \
		shasum -a 256 "$$tmp_c" | awk '{print $$1}' > "$$tmp_c_hash"; \
		printf '%s\n' "$$new_input_hash" > "$$tmp_input_hash"; \
		mv "$$tmp_c" "$(BLORP_CLI_C)"; \
		mv "$$tmp_input_hash" "$(BLORP_CLI_C_INPUT_HASH)"; \
		mv "$$tmp_c_hash" "$(BLORP_CLI_C_HASH)"; \
	else \
		echo "Blorp CLI C up to date"; \
	fi; \
	mv "$$input_manifest_tmp" "$(BLORP_CLI_C_BUILD_INPUT_MANIFEST)"; \
	trap - EXIT

# Prepare every generated C input and the complete native build manifest.
prepare-blorp-cli-c: generate-blorp-cli-c $(BLORP_CLI_RUNTIME_SOURCES_C)
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	bootstrap_compiler="$${BLORP_BOOTSTRAP_COMPILER_BIN:-}"; \
	if [ -z "$$bootstrap_compiler" ]; then \
		bootstrap_compiler=$$("$(BLORP_COMPILER_BOOTSTRAP)" --print-path); \
	fi; \
	case "$$bootstrap_compiler" in \
		*/*) ;; \
		*) bootstrap_compiler=$$(command -v "$$bootstrap_compiler") || { echo "Bootstrap compiler not found on PATH: $$bootstrap_compiler" >&2; exit 1; } ;; \
	esac; \
	bootstrap_compiler=$$(cd "$$(dirname "$$bootstrap_compiler")" && pwd -P)/$$(basename "$$bootstrap_compiler"); \
	input_manifest_tmp="$(BLORP_CLI_BUILD_INPUT_MANIFEST).tmp"; \
	trap 'rm -f "$$input_manifest_tmp"' EXIT; \
	rm -f "$$input_manifest_tmp"; \
	{ \
		find blorp/src -name '*.brp' -type f -print; \
		find blorp/src -name '*.h' -type f -print; \
		find $(STANDARD_LIBRARY_SOURCE_ROOT) -name '*.brp' -type f -print; \
		printf '%s\n' "$$bootstrap_compiler" "$(BLORP_COMPILER_BOOTSTRAP)" "$(BLORP_CLI_MANIFEST_TOOL)" "$(BLORP_CLI_RUNTIME_SOURCES_C)" "$(BLORP_LSP_NATIVE_RUNTIME_C)" "$(BLORP_BUILD_SOURCE_GENERATOR_SOURCE)" blorp/src/lib/runtime/native/runtime.c blorp/src/lib/runtime/native/runtime_decl.c blorp/src/lib/runtime/native/minicoro.h; \
	} | LC_ALL=C sort -u | "$(BLORP_CLI_MANIFEST_TOOL)" write-inputs \
		--root . \
		--output "$$input_manifest_tmp"; \
	mv "$$input_manifest_tmp" "$(BLORP_CLI_BUILD_INPUT_MANIFEST)"; \
	trap - EXIT

# Compile prepared C inputs with the host C toolchain only.
compile-prepared-blorp-cli: $(BLORP_CLI_RUNTIME_OBJECT)
	@mkdir -p "$(BLORP_CLI_BUILD_DIR)"
	@set -e; \
	for input in "$(BLORP_CLI_C)" "$(BLORP_CLI_RUNTIME_SOURCES_C)" "$(BLORP_CLI_BUILD_INPUT_MANIFEST)"; do \
		test -s "$$input" || { echo "Prepared compiler input is missing: $$input" >&2; echo "Run make prepare-blorp-cli-c first." >&2; exit 1; }; \
	done; \
	tmp_bin="$(BLORP_CLI_BIN).tmp"; \
	tmp_hash="$(BLORP_CLI_INPUT_HASH).tmp"; \
	tmp_bin_hash="$(BLORP_CLI_BIN_HASH).tmp"; \
	trap 'rm -f "$$tmp_bin" "$$tmp_hash" "$$tmp_bin_hash"' EXIT; \
	rm -f "$$tmp_bin" "$$tmp_hash" "$$tmp_bin_hash"; \
	source_hash=$$(shasum -a 256 "$(BLORP_CLI_BUILD_INPUT_MANIFEST)" | awk '{print $$1}'); \
	generated_c_hash=$$(shasum -a 256 "$(BLORP_CLI_C)" | awk '{print $$1}'); \
	recipe_hash=$$(sed -n '/^# Compile prepared C inputs/,/^# Preserve the safe all-in-one build path/p' Makefile | shasum -a 256 | awk '{print $$1}'); \
	new_hash=$$(printf '%s\n%s\n%s\n%s\n%s\n' "$$source_hash" "$$generated_c_hash" "$$recipe_hash" "$(BLORP_CLI_C_OPTIMIZATION)" "$(BLORP_CLI_RUNTIME_CONFIG_HASH)" | shasum -a 256 | awk '{print $$1}'); \
	old_hash=$$(cat "$(BLORP_CLI_INPUT_HASH)" 2>/dev/null || true); \
	recorded_bin_hash=$$(cat "$(BLORP_CLI_BIN_HASH)" 2>/dev/null || true); \
	actual_bin_hash=$$(shasum -a 256 "$(BLORP_CLI_BIN)" 2>/dev/null | awk '{print $$1}'); \
	if [ "$$new_hash" != "$$old_hash" ] || [ ! -x "$(BLORP_CLI_BIN)" ] || [ -z "$$actual_bin_hash" ] || [ "$$actual_bin_hash" != "$$recorded_bin_hash" ]; then \
		echo "Compiling Blorp CLI"; \
		cc "$(BLORP_CLI_C_OPTIMIZATION)" -fwrapv -pipe -w -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
			-include blorp/src/lib/runtime/native/runtime_decl.c \
			-Iblorp/src/compiler/stage_01_generated_inputs \
			-Iblorp/src/compiler/stage_06_typecheck/graph \
			-Iblorp/src \
			-Iblorp/src/lib \
			-Iblorp/src/lsp/server \
			-Iblorp/src/test \
			"$(BLORP_CLI_C)" "$(BLORP_CLI_RUNTIME_OBJECT)" "$(BLORP_CLI_RUNTIME_SOURCES_C)" "$(BLORP_LSP_NATIVE_RUNTIME_C)" -lm -lpthread -o "$$tmp_bin"; \
		shasum -a 256 "$$tmp_bin" | awk '{print $$1}' > "$$tmp_bin_hash"; \
		mv "$$tmp_bin" "$(BLORP_CLI_BIN)"; \
		printf '%s\n' "$$new_hash" > "$$tmp_hash"; \
		mv "$$tmp_hash" "$(BLORP_CLI_INPUT_HASH)"; \
		mv "$$tmp_bin_hash" "$(BLORP_CLI_BIN_HASH)"; \
	else \
		echo "Blorp CLI up to date"; \
	fi; \
	trap - EXIT

# Preserve the safe all-in-one build path for local callers.
compile-blorp-cli: prepare-blorp-cli-c $(BLORP_CLI_RUNTIME_OBJECT)
	@$(MAKE) --no-print-directory compile-prepared-blorp-cli

build-blorp-cli: compile-blorp-cli

# Run the top-level local test gate
test:
	scripts/test

# Run runtime tests only (language features + standard library)
runtime-test: all
	$(BLORP_INSTALLED_BIN) test $(RUNTIME_TEST_ROOTS)

# Fast local validation path for compiler work
smoke: all
	$(BLORP_INSTALLED_BIN) check --no-format blorp/src/main.brp

quality:
	$(MAKE) hygiene-check
	$(MAKE) c-static-analysis

quality-full: quality

hygiene-check: build-blorp-cli
	@scripts/check-blorp-layout
	@scripts/check-editor-drift
	@scripts/check-c-symbol-projection-boundary
	@scripts/compiler-check --validate-manifest
	@scripts/check-std-builtins
	@$(BLORP_CLI_BIN) check --no-format blorp/benchmark/compiler/compiler_typecheck_worker.brp
	@$(BLORP_CLI_BIN) check --no-format blorp/benchmark/compiler/compiler_backend_worker.brp
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/benchmark/test_backend_memory.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/benchmark/test_perceus_memory.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/stage_09_core/support/test_ownership_node_inventory.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/stage_09_core/support/test_borrowed_boundary_child_modes.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/stage_09_core/support/test_cleanup_coverage_ledger.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/test/test_session_benchmark.py
	@PYTHONDWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/stage_06_typecheck/support/test_worker.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/benchmark/test_typecheck_memory.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/stage_06_typecheck/support/test_replay.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/fixture_support/test_check_fixtures.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/tool/test_tool_fixture_runner.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest $(STANDARD_LIBRARY_TEST_ROOT)/test_check_std_builtins.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/architecture/test_dead_code_audit.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/compiler/build/test_compiler_check.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/runtime/test_runtime_allocator_stats.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/build/test_blorp_cli_embedded_manifest.py
	@PYTHONDONTWRITEBYTECODE=1 python3 -m unittest blorp/test/build/test_blorp_source_layout.py
	@blorp/test/compiler/benchmark/test_record_layout.sh
	@BLORP_RECORD_UPDATE_SKIP_BUILD=1 benchmarks/compiler_record_update_match_allocations
	@BLORP_RECORD_UPDATE_SKIP_BUILD=1 benchmarks/compiler_record_update_nested_match_allocations
	@blorp/test/build/test_build_configuration.sh
	@blorp/test/build/test_build_source_generator.sh
	@blorp/test/build/test_release_toolchain.sh
	@blorp/test/build/test_scripts_test_harness.sh
	@artifacts=$$( \
		find . \
			\( -path './.git' -o -path './blorp/build/_build' -o -path './_build' -o -path './cmake-build-debug' \) -prune -o \
			\( -name 'runtime_decl.plist' -o -name '*.generated.c' -o -name '.blorp_doctest_*' \) -print; \
		find blorp/test $(STANDARD_LIBRARY_TEST_ROOT) pkg/test -name '*.c' -print 2>/dev/null; \
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
	clang --analyze -D_GNU_SOURCE -Wno-nullability-completeness -Wno-unused-command-line-argument -o "$$tmp_plist" -x c blorp/src/lib/runtime/native/runtime_decl.c; \
	clang --analyze -Wno-nullability-completeness -Wno-unused-command-line-argument \
		-D_GNU_SOURCE $$block_checker_args \
		-DMINICORO_IMPL -include blorp/src/lib/runtime/native/minicoro.h \
		-o "$$tmp_plist" -x c blorp/src/lib/runtime/native/runtime.c; \
	clang --analyze -D_GNU_SOURCE -Wno-unused-command-line-argument \
		-Iblorp/src/lsp/server \
		-o "$$tmp_plist" -x c "$(BLORP_LSP_NATIVE_RUNTIME_C)"

security-check: all c-static-analysis
	blorp/test/compiler/pipeline/codegen_audit/run_codegen_audit.sh $(BLORP_INSTALLED_BIN)
	BLORP_COMPILER_TEST_TIMEOUT=360 scripts/test compiler-blorp
	$(BLORP_INSTALLED_BIN) test --timeout 20 $(SECURITY_RUNTIME_TESTS)
	$(BLORP_INSTALLED_BIN) test --leak-check --timeout 20 $(SECURITY_LEAK_TESTS)

# Run runtime tests with sanitizer instrumentation. On Darwin, Apple
# AddressSanitizer does not reliably compose with user-land fiber stack
# switching, so the runtime-wide gate uses UBSan there. Linux keeps the
# stronger ASan + UBSan combination.
test-asan: all
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		$(BLORP_INSTALLED_BIN) test --sanitize=undefined $(RUNTIME_TEST_ROOTS); \
	else \
		$(BLORP_INSTALLED_BIN) test --sanitize $(RUNTIME_TEST_ROOTS); \
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
	scripts/clean-retired-layout
	rm -f "$(BLORP_INSTALLED_BIN)" \
		"$(BLORP_EMBEDDED_STD_SOURCE)" "$(BLORP_BUILD_INFO_SOURCE)"
