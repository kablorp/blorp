# Blorp Compiler Makefile

.PHONY: all build isolated-build isolated-test clean test smoke test-asan unit-test coverage ocaml-check fmt-check c-static-analysis hygiene-check quality quality-full docker-build docker-test docker-test-clean docker-shell

STD_SOURCES := $(shell find std -name '*.brp' 2>/dev/null)
RUNTIME_TEST_ROOTS := $(wildcard tests/test_blorp tests/test_std tests/test_pkg)
DUNE_BUILD_DIR ?= _build
DUNE_BUILD_FLAG := --build-dir=$(DUNE_BUILD_DIR)
DUNE_BUILD_ROOT := $(if $(filter /%,$(DUNE_BUILD_DIR)),$(DUNE_BUILD_DIR),compiler/$(DUNE_BUILD_DIR))
BLORP_BUILD_EXE := $(DUNE_BUILD_ROOT)/default/bin/blorp.exe
COVERAGE_ROOT ?= $(CURDIR)/compiler/_coverage

# Default target: build and install blorp to project root
# Only copy if binary actually changed (preserves mtime for test cache)
all: build
	@if ! cmp -s "$(BLORP_BUILD_EXE)" ./blorp 2>/dev/null; then \
		tmp=$$(mktemp "./.blorp.XXXXXX") || exit 1; \
		rm -f "$$tmp"; \
		cp "$(BLORP_BUILD_EXE)" "$$tmp"; \
		chmod +x "$$tmp"; \
		codesign -s - "$$tmp" 2>/dev/null || true; \
		mv -f "$$tmp" ./blorp; \
	fi

# Generate embedded std library from std/**/*.brp
compiler/lib/embedded_std.ml: compiler/tools/gen_embed_std.ml $(STD_SOURCES)
	@tmp=$$(mktemp "$@.XXXXXX") || exit 1; \
	trap 'rm -f "$$tmp"' EXIT; \
	ocaml compiler/tools/gen_embed_std.ml std > "$$tmp" && mv "$$tmp" "$@"

# Build the OCaml compiler
build: compiler/lib/embedded_std.ml
	cd compiler && dune build $(DUNE_BUILD_FLAG)

# Run all runtime tests (language features + standard library)
test: all
	./blorp test $(RUNTIME_TEST_ROOTS)

# Fast local validation path for compiler work
smoke: all
	scripts/run_tests.sh unit compiler

# Compile in a disposable Dune build directory without publishing ./blorp.
isolated-build:
	@mkdir -p "$(CURDIR)/compiler/_build"; \
	tmp=$$(mktemp -d "$(CURDIR)/compiler/_build/isolated.XXXXXX") || exit 1; \
	trap 'rm -rf "$$tmp"' EXIT; \
	$(MAKE) DUNE_BUILD_DIR="$$tmp" build

# Run suites with scripts/run_tests.sh's per-run Dune build directory.
# Pass SUITES="unit compiler" to narrow the default full run.
isolated-test:
	scripts/run_tests.sh $(SUITES)

# Run OCaml unit tests
unit-test:
	cd compiler && dune runtest $(DUNE_BUILD_FLAG)

ocaml-check:
	cd compiler && dune build @check $(DUNE_BUILD_FLAG)

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
	cd compiler && dune fmt $(DUNE_BUILD_FLAG) --preview --display=quiet

# Run unit tests with coverage report
coverage:
	@set -e; \
	mkdir -p "$(COVERAGE_ROOT)"; \
	coverage_dir=$$(mktemp -d "$(COVERAGE_ROOT)/run.XXXXXX") || exit 1; \
	report_dir="$$coverage_dir/html"; \
	mkdir -p "$$report_dir"; \
	cd compiler && dune build $(DUNE_BUILD_FLAG) --instrument-with bisect_ppx --force test/run_tests.exe; \
	cd compiler && BISECT_FILE="$$coverage_dir/bisect" "$(DUNE_BUILD_DIR)/default/test/run_tests.exe"; \
	cd compiler && bisect-ppx-report summary --coverage-path "$$coverage_dir"; \
	cd compiler && bisect-ppx-report html -o "$$report_dir" --coverage-path "$$coverage_dir"; \
	echo "Coverage report: $$report_dir/index.html"

c-static-analysis:
	@command -v clang >/dev/null 2>&1 || { \
		echo "clang is required for c-static-analysis."; \
		exit 127; \
	}
	@tmp_plist=$$(mktemp "$${TMPDIR:-/tmp}/blorp-clang-analyze.XXXXXX"); \
	trap 'rm -f "$$tmp_plist"' EXIT; \
	clang --analyze -Wno-nullability-completeness -Wno-unused-command-line-argument -o "$$tmp_plist" -x c compiler/lib/runtime_decl.c

# Run all tests with AddressSanitizer + UBSan
test-asan: all
	./blorp test --sanitize $(RUNTIME_TEST_ROOTS)

# Docker targets
docker-build:
	scripts/docker-test --build-only

docker-test:
	scripts/docker-test

docker-test-clean:
	scripts/docker-test --clean

docker-shell:
	scripts/docker-test --shell

# Clean build artifacts
clean:
	cd compiler && dune clean $(DUNE_BUILD_FLAG)
	rm -f ./blorp compiler/lib/embedded_std.ml
