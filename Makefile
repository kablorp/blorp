# Blorp Compiler Makefile

.PHONY: all build install warm-formatter clean test smoke runtime-test test-asan compiler-unit-test unit-test coverage ocaml-check fmt-check c-static-analysis security-check hygiene-check quality quality-full docker-build docker-gate docker-gate-clean docker-shell docker-premerge-gate docker-premerge-gate-all

STD_SOURCES := $(shell find std -name '*.brp' 2>/dev/null)
FORMATTER_SOURCES := $(shell find tools/formatter -name '*.brp' 2>/dev/null)
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

# Default target: build and install blorp to project root, then warm the
# self-hosted formatter binary cache so the first interactive format is fast.
all: install warm-formatter

# Only copy when Dune produced a newer binary. The installed root binary may be
# ad-hoc signed on macOS, so byte-for-byte comparison against the unsigned Dune
# output would recopy on every make and invalidate mtime-based caches.
install: build
	@if [ ! -f ./blorp ] || [ compiler/_build/default/bin/blorp.exe -nt ./blorp ]; then \
		rm -f ./blorp; \
		cp compiler/_build/default/bin/blorp.exe ./blorp; \
		codesign -s - ./blorp 2>/dev/null || true; \
	fi

warm-formatter: install
	@tmp_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/blorp-format-warm.XXXXXX"); \
	trap 'rm -rf "$$tmp_dir"' EXIT; \
	tmp="$$tmp_dir/warm.brp"; \
	printf 'func main(args: List[String]) -> Int:\n\t0\n' > "$$tmp"; \
	./blorp format --check "$$tmp" >/dev/null

# Generate embedded std library from std/**/*.brp
compiler/lib/embedded_std.ml: compiler/tools/gen_embed_std.ml $(STD_SOURCES)
	ocaml compiler/tools/gen_embed_std.ml std > $@.tmp && mv $@.tmp $@

# Generate embedded formatter source from tools/formatter/**/*.brp
compiler/lib/embedded_formatter.ml: compiler/tools/gen_embed_formatter.ml $(FORMATTER_SOURCES)
	ocaml compiler/tools/gen_embed_formatter.ml tools/formatter > $@.tmp && mv $@.tmp $@

# Build the OCaml compiler
build: compiler/lib/embedded_std.ml compiler/lib/embedded_formatter.ml
	cd compiler && dune build

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
compiler-unit-test: compiler/lib/embedded_std.ml compiler/lib/embedded_formatter.ml
	cd compiler && dune runtest

# Legacy alias for compiler-unit-test
unit-test: compiler-unit-test

ocaml-check:
	cd compiler && dune build @check

quality:
	$(MAKE) ocaml-check
	$(MAKE) hygiene-check
	$(MAKE) c-static-analysis

quality-full:
	$(MAKE) quality
	$(MAKE) fmt-check

hygiene-check:
	@if [ -d ocaml ]; then \
		echo "Retired compiler source directory './ocaml' found."; \
		echo "Compiler sources live in './compiler'; remove stale generated or copied files."; \
		exit 1; \
	fi
	@scripts/check-editor-drift
	@scripts/check-std-builtins
	@if [ -e compiler/_build/default/lib/parser.conflicts ] && [ -s compiler/_build/default/lib/parser.conflicts ]; then \
		echo "Menhir conflicts found in compiler/_build/default/lib/parser.conflicts."; \
		echo "Run 'cd compiler && dune build @check' and inspect the conflict report."; \
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

fmt-check:
	@command -v ocamlformat >/dev/null 2>&1 || { \
		echo "ocamlformat is required for fmt-check. Install it with opam for the project's OCaml switch before enabling dune fmt in CI."; \
		exit 127; \
	}
	cd compiler && dune fmt --preview --display=quiet

# Run compiler-unit tests with coverage report
coverage:
	rm -rf compiler/_coverage
	mkdir -p compiler/_coverage
	cd compiler && dune build --instrument-with bisect_ppx --force test/run_tests.exe
	cd compiler && BISECT_FILE=$(CURDIR)/compiler/_coverage/bisect ./_build/default/test/run_tests.exe
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
	BLORP_COMPILER_TEST_TIMEOUT=60 scripts/test compiler
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
	rm -f ./blorp compiler/lib/embedded_std.ml compiler/lib/embedded_formatter.ml
