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
# Explicitly ported suites: every active B2 test runs through Blorp 2.
TARGET_COMPONENT_SOURCES := \
	blorp_2/test/unit/test_utils/test_boolean.brp \
	blorp_2/test/unit/test_utils/test_constant_ids.brp \
	blorp_2/test/unit/test_utils/test_ids.brp \
	blorp_2/test/unit/test_utils/test_int_map.brp \
	blorp_2/test/unit/test_utils/test_names.brp \
	blorp_2/test/unit/test_utils/test_source.brp \
	blorp_2/test/unit/test_utils/test_syntax.brp \
	blorp_2/test/unit/test_utils/test_text.brp \
	blorp_2/test/unit/test_lex/test_char_literals.brp \
	blorp_2/test/unit/test_lex/test_continuation.brp \
	blorp_2/test/unit/test_lex/test_doc_blocks.brp \
	blorp_2/test/unit/test_lex/test_float.brp \
	blorp_2/test/unit/test_lex/test_keywords.brp \
	blorp_2/test/unit/test_lex/test_lex.brp \
	blorp_2/test/unit/test_lex/test_ordering_operators.brp \
	blorp_2/test/unit/test_lex/test_pipe_strings.brp \
	blorp_2/test/unit/test_lex/test_provenance.brp \
	blorp_2/test/unit/test_lex/test_ranges.brp \
	blorp_2/test/unit/test_lex/test_runtime_text.brp \
	blorp_2/test/unit/test_lex/test_trivia.brp \
	blorp_2/test/unit/test_parse/test_constant_inventory.brp \
	blorp_2/test/unit/test_parse/test_file_read.brp \
	blorp_2/test/unit/test_parse/test_float_builtin_labels.brp \
	blorp_2/test/unit/test_parse/test_int_comparisons.brp \
	blorp_2/test/unit/test_parse/test_ordering_operators.brp \
	blorp_2/test/unit/test_parse/test_provenance.brp \
	blorp_2/test/unit/test_parse/test_string_concat.brp \
	blorp_2/test/unit/test_parse/test_string_slice.brp \
	blorp_2/test/unit/test_parse/test_write_file.brp \
	blorp_2/test/unit/test_harness/test_self_hosted_reports.brp \
	blorp_2/test/unit/test_parse/test_discard_propagation.brp \
	blorp_2/test/unit/test_parse/test_methods_selection.brp \
	blorp_2/test/unit/test_check/test_discard_propagation.brp \
	blorp_2/test/unit/test_check/test_direct_list_updates.brp \
	blorp_2/test/unit/test_check/test_nominal_types.brp \
	blorp_2/test/unit/test_check/test_ordering_operators.brp \
	blorp_2/test/unit/test_own/test_list_updates.brp \
	blorp_2/test/unit/test_verify/test_list_updates.brp \
	blorp_2/test/unit/test_emit/test_list_updates.brp \
	blorp_2/test/unit/test_lower/test_loop_reads.brp \
	blorp_2/test/unit/test_own/test_ownership_transfer.brp \
	blorp_2/test/unit/test_verify/test_ownership_transfer.brp \
	blorp_2/test/unit/test_parse/test_run_to_files.brp \
	blorp_2/test/unit/test_parse/test_module_stems.brp \
	blorp_2/test/unit/test_check/test_run_to_files.brp \
	blorp_2/test/unit/test_specialize/test_indexed_list.brp \
	blorp_2/test/unit/test_specialize/test_run_to_files.brp \
	blorp_2/test/unit/test_lower/test_run_to_files.brp \
	blorp_2/test/unit/test_own/test_run_to_files.brp \
	blorp_2/test/unit/test_verify/test_run_to_files.brp \
	blorp_2/test/unit/test_emit/test_run_to_files.brp \
	blorp_2/test/unit/test_emit/test_function_labels.brp

.PHONY: compiler generate-compiler link-compiler example test test-components test-target-components test-compiler link-test-compiler test-e2e

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

test:
	@$(MAKE) --no-print-directory test-compiler
	@$(MAKE) --no-print-directory test-components
	@$(MAKE) --no-print-directory test-e2e

# Other suites remain in source for incremental self-hosted migration.
# Callers build once or supply the exact B2 compiler under test.
test-components:
	@$(MAKE) --no-print-directory test-target-components
	@printf '%s\n' 'DEFERRED: remaining unit/runtime/grammar/tooling and broader native e2e suites; only explicit self-hosted selections run.'

# Each selected source keeps its own normal test entry and strict native run.
# Mirror source paths so equally named suites never overwrite each other's C.
test-target-components:
	@set -eu; cd ..; \
		if [ -z "$(strip $(TARGET_COMPONENT_SOURCES))" ]; then \
			printf '%s\n' 'no target component sources selected' >&2; exit 1; \
		fi; \
		for source in $(TARGET_COMPONENT_SOURCES); do \
			program="blorp_2/build/self-hosted-tests/$${source#blorp_2/test/}"; \
			program="$${program%.brp}"; \
			mkdir -p "$$(dirname "$$program")"; \
			"$(BLORP2_COMPILER)" --library-root blorp_2/standard_library --test-suite "$$source" "$$program.c"; \
			"$(BLORP_CC)" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
				-DBLORP_MEMORY_DIAGNOSTICS=1 "$$program.c" -o "$$program" $(TEST_COMPILER_LIBRARIES); \
			BLORP_LEAK_CHECK=strict "$$program"; \
		done

# Each e2e run builds once and passes its binary to its fixture groups.
test-compiler: generate-compiler
	@$(MAKE) --no-print-directory link-test-compiler

link-test-compiler:
	@echo 'Link $(BLORP2_COMPILER)'
	@cd .. && mkdir -p "$$(dirname "$(BLORP2_COMPILER)")" \
		&& "$(BLORP_CC)" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			"$(BLORP2_COMPILER_C)" -o "$(BLORP2_COMPILER)" $(TEST_COMPILER_LIBRARIES)

# The driver is an ordinary B2 main(args) running TestSuites; fixtures retain
# their own real mains. It receives all configuration explicitly from Make.
test-e2e:
	@set -eu; cd ..; \
		compiler_path="$(BLORP2_COMPILER)"; \
		case "$$compiler_path" in /*) ;; *) compiler_path="$$PWD/$$compiler_path";; esac; \
		if [ ! -x "$$compiler_path" ]; then \
			printf '%s\n' 'missing Blorp 2 test compiler; run make -C blorp_2 test-compiler first' >&2; exit 1; \
		fi; \
		cc_path=$$(command -v "$(BLORP_CC)") || { printf '%s\n' 'C compiler executable not found' >&2; exit 1; }; \
		case "$$cc_path" in /*) ;; *) cc_path="$$PWD/$$cc_path";; esac; \
		if [ ! -x "$$cc_path" ]; then printf '%s\n' 'C compiler must resolve to an executable file' >&2; exit 1; fi; \
		runner_directory=$$(mktemp -d "$${TMPDIR:-/tmp}/blorp2-e2e.XXXXXX"); \
		runner_directory=$$(cd "$$runner_directory" && pwd -P); \
		trap 'rm -rf "$$runner_directory"' EXIT; \
		trap 'exit 1' HUP INT TERM; \
		BLORP_LEAK_CHECK=strict "$$compiler_path" --library-root blorp_2/standard_library \
			blorp_2/test/e2e/self_hosted.brp "$$runner_directory/runner.c"; \
		"$$cc_path" -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
			-fsanitize=address,undefined -fno-sanitize-recover=all \
			-DBLORP_MEMORY_DIAGNOSTICS=1 "$$runner_directory/runner.c" \
			-o "$$runner_directory/runner" $(TEST_COMPILER_LIBRARIES); \
		BLORP_LEAK_CHECK=strict "$$runner_directory/runner" "$$compiler_path" "$$cc_path" "$$runner_directory"
