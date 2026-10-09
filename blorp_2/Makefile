BLORP_CC ?= clang
TEST_COMPILER_FLAGS := -O2
TEST_COMPILER_LIBRARIES := -lm -lpthread

.PHONY: example test test-compiler host-check

example: host-check
	@mkdir -p build
	@cd .. && bin/blorp run --no-format blorp_2/src/main.brp -- \
		blorp_2/test/e2e/fixtures/return_zero.brp blorp_2/build/return_zero.c
	@$(BLORP_CC) -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
		build/return_zero.c -o build/return_zero
	@build/return_zero

test: test-compiler
	@cd .. && bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/e2e blorp_2/test/test_grammar

# Compare content/configuration, so warm direct TestSuite runs do not rebuild.
# Publish the input identity only after both compiler modes link successfully.
test-compiler: host-check
	@mkdir -p build
	@set -e; \
	cc_path=$$(command -v "$(BLORP_CC)"); \
	cc_path=$$(realpath "$$cc_path"); \
	cc_version=$$("$$cc_path" --version); \
	inputs=$$(mktemp build/compiler-inputs.XXXXXX); \
	trap 'rm -f "$$inputs" build/compiler.c.tmp build/compiler.tmp build/compiler-diagnostic.tmp' EXIT; \
	{ printf '%s\n' "$$cc_path" "$$cc_version" \
		'compile --no-format blorp_2/src/main.brp' \
		'$(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=0 $(TEST_COMPILER_LIBRARIES)' \
		'$(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 $(TEST_COMPILER_LIBRARIES)'; \
		shasum -a 256 ../bin/blorp src/*.brp Makefile; \
	} > "$$inputs"; \
	refresh=false; \
	if ! cmp -s "$$inputs" build/compiler.inputs || [ ! -s build/compiler.c ]; then \
		refresh=true; \
		rm -f build/compiler.inputs; \
		echo 'Generate build/compiler.c'; \
		(cd .. && bin/blorp compile --no-format blorp_2/src/main.brp -o blorp_2/build/compiler.c.tmp); \
		mv build/compiler.c.tmp build/compiler.c; \
	fi; \
	if $$refresh || [ ! -x build/compiler ]; then \
		echo 'Link build/compiler'; \
		"$$cc_path" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=0 \
			build/compiler.c -o build/compiler.tmp $(TEST_COMPILER_LIBRARIES); \
		mv build/compiler.tmp build/compiler; \
	fi; \
	if $$refresh || [ ! -x build/compiler-diagnostic ]; then \
		echo 'Link build/compiler-diagnostic'; \
		"$$cc_path" $(TEST_COMPILER_FLAGS) -DBLORP_MEMORY_DIAGNOSTICS=1 \
			build/compiler.c -o build/compiler-diagnostic.tmp $(TEST_COMPILER_LIBRARIES); \
		mv build/compiler-diagnostic.tmp build/compiler-diagnostic; \
	fi; \
	if ! cmp -s "$$inputs" build/compiler.inputs; then mv "$$inputs" build/compiler.inputs; fi

host-check:
	@cd .. && scripts/compiler-build-status --quiet
