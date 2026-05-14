# Blorp Compiler Makefile

.PHONY: all build clean test smoke test-asan unit-test coverage ocaml-check fmt-check c-static-analysis hygiene-check quality quality-full docker-build docker-test docker-test-clean docker-shell

STD_SOURCES := $(shell find std -name '*.brp' 2>/dev/null)
RUNTIME_TEST_ROOTS := $(wildcard tests/test_blorp tests/test_std tests/test_pkg)

# Default target: build and install blorp to project root
# Only copy if binary actually changed (preserves mtime for test cache)
all: build
	@if ! cmp -s compiler/_build/default/bin/blorp.exe ./blorp 2>/dev/null; then \
		rm -f ./blorp; \
		cp compiler/_build/default/bin/blorp.exe ./blorp; \
		codesign -s - ./blorp 2>/dev/null || true; \
	fi

# Generate embedded std library from std/**/*.brp
compiler/lib/embedded_std.ml: compiler/tools/gen_embed_std.ml $(STD_SOURCES)
	ocaml compiler/tools/gen_embed_std.ml std > $@.tmp && mv $@.tmp $@

# Build the OCaml compiler
build: compiler/lib/embedded_std.ml
	cd compiler && dune build

# Run all runtime tests (language features + standard library)
test: all
	./blorp test $(RUNTIME_TEST_ROOTS)

# Fast local validation path for compiler work
smoke: all
	scripts/run_tests.sh unit compiler

# Run OCaml unit tests
unit-test:
	cd compiler && dune runtest

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

# Run unit tests with coverage report
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
	cd compiler && dune clean
	rm -f ./blorp compiler/lib/embedded_std.ml
