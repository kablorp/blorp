#!/usr/bin/env bash
# Exercise bootstrap transport and make recipes without a real compiler.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/blorp2 bootstrap.XXXXXX")
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
fixture="$scratch/repo with spaces"
tools="$scratch/fake tools"
mkdir -p "$fixture/scripts" "$fixture/blorp_2/src" "$fixture/bin" "$tools"
fixture=$(cd "$fixture" && pwd -P)
cp "$repo_root/blorp_2/Makefile" "$fixture/blorp_2/Makefile"
if [ -f "$repo_root/scripts/blorp2-compiler-bootstrap" ]; then
	cp "$repo_root/scripts/blorp2-compiler-bootstrap" "$fixture/scripts/"
fi
resolver="$fixture/scripts/blorp2-compiler-bootstrap"
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
sha256_file() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}

export TEST_SEED_LOG="$scratch/seed.log" TEST_CC_LOG="$scratch/cc.log"
export TEST_E2E_LOG="$scratch/e2e.log" TEST_E2E_ARGS="$scratch/e2e.args"
export TEST_CC_ARGS="$scratch/cc-args" TEST_COMPONENT_LOG="$scratch/components.log"
export TEST_DOWNLOAD_LOG="$scratch/download.log" TEST_LEGACY_LOG="$scratch/legacy.log"
export TEST_SEED="$scratch/seed payload" TEST_DOWNLOAD_MODE=good
export TEST_OS=Linux TEST_ARCH=x86_64
export BLORP2_COMPILER_BOOTSTRAP_CACHE_DIR="$scratch/cache with spaces"
cat >"$TEST_SEED" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd:%s\0' "$PWD" >>"$TEST_SEED_LOG"
for argument in "$@"; do printf 'arg:%s\0' "$argument" >>"$TEST_SEED_LOG"; done
printf 'seed\n' >>"$TEST_CC_LOG"
if [ "${1:-}" = --library-root ]; then
	printf '/* fake generated C */\n' >"$4"
fi
SH
chmod +x "$TEST_SEED"
cat >"$tools/uname" <<'SH'
#!/usr/bin/env bash
case "$1" in -s) echo "$TEST_OS";; -m) echo "$TEST_ARCH";; *) exit 2;; esac
SH
cat >"$tools/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$2" >>"$TEST_DOWNLOAD_LOG"
[ "$TEST_DOWNLOAD_MODE" != offline ] || exit 22
[ "$1" = -fsSL ] && [ "$3" = -o ] || exit 23
if [ "$TEST_DOWNLOAD_MODE" = bad ]; then
	printf '#!/usr/bin/env bash\necho BAD_EXEC >>"$TEST_LEGACY_LOG"\n' >"$4"
else
	cp "$TEST_SEED" "$4"
fi
SH
cat >"$tools/fake cc" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >>"$TEST_CC_ARGS"
mode=example
output=
input=
while [ $# -gt 0 ]; do
	case "$1" in
		-DBLORP_MEMORY_DIAGNOSTICS=*) mode="${1#*=}";;
		-o) output="$2"; shift;;
		*.c) input="$1";;
	esac
	shift
done
[ -n "$input" ] && [ -s "$input" ] || exit 24
printf 'link:%s\n' "$mode" >>"$TEST_CC_LOG"
if [ "${TEST_CC_STATUS:-0}" -ne 0 ]; then exit "$TEST_CC_STATUS"; fi
case "$input" in
	*/runner.c)
		cat >"$output" <<'SEED'
#!/usr/bin/env bash
set -euo pipefail
printf 'e2e:%s\n' "${BLORP_LEAK_CHECK:-unset}" >>"$TEST_E2E_LOG"
printf '%s\0' "$@" >>"$TEST_E2E_ARGS"
[ "$#" = 3 ] && [ -x "$1" ] && [ -x "$2" ] && [ -d "$3" ] || exit 94
exit "${TEST_E2E_STATUS:-0}"
SEED
		;;
	*/self-hosted-tests/*)
		cat >"$output" <<'SEED'
#!/usr/bin/env bash
set -euo pipefail
printf 'native:%s\n' "${BLORP_LEAK_CHECK:-unset}" >>"$TEST_COMPONENT_LOG"
exit "${TEST_COMPONENT_NATIVE_STATUS:-0}"
SEED
		;;
	*)
		cat >"$output" <<'SEED'
#!/usr/bin/env bash
set -euo pipefail
printf 'built\n' >>"$TEST_CC_LOG"
if [ "${1:-}" = --library-root ]; then
	if [ "${3:-}" = --test-suite ]; then
		shift 3
		while [ "$#" -gt 1 ]; do printf 'compile:%s\n' "$1" >>"$TEST_COMPONENT_LOG"; shift; done
		if [ "${TEST_COMPONENT_COMPILE_STATUS:-0}" -ne 0 ]; then exit "$TEST_COMPONENT_COMPILE_STATUS"; fi
		printf '/* fake component C */\n' >"$1"
	else
		if [ "${TEST_E2E_COMPILE_STATUS:-0}" -ne 0 ]; then exit "$TEST_E2E_COMPILE_STATUS"; fi
		printf '/* fake fixture C */\n' >"$4"
	fi
fi
SEED
		;;
esac
chmod +x "$output"
SH
chmod +x "$tools/"*
for path in bin/blorp scripts/blorp-compiler-bootstrap scripts/compiler-build-status; do
	cat >"$fixture/$path" <<'SH'
#!/usr/bin/env bash
echo legacy >>"$TEST_LEGACY_LOG"
exit 97
SH
	chmod +x "$fixture/$path"
done
export PATH="$tools:$PATH"
commit=0123456789abcdef0123456789abcdef01234567
tag=blorp2-seed-0123456789ab
digest=$(sha256_file "$TEST_SEED")
manifest="$fixture/blorp_2/bootstrap.env"
write_manifest() {
	cat >"$manifest" <<EOF
BLORP2_BOOTSTRAP_FORMAT=1
BLORP2_BOOTSTRAP_REPO=kablorp/blorp
BLORP2_BOOTSTRAP_TAG=$tag
BLORP2_BOOTSTRAP_SOURCE_COMMIT=$commit
BLORP2_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=$digest
BLORP2_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=$digest
BLORP2_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=$digest
EOF
}
write_manifest

expect_failure() {
	local message="$1"
	shift
	if "$@" >"$scratch/stdout" 2>"$scratch/stderr"; then
		fail "expected rejection: $message"
	fi
	grep -Fq "$message" "$scratch/stderr" || fail "missing diagnostic: $message"
}
downloads() { wc -l <"$TEST_DOWNLOAD_LOG" | tr -d ' '; }

if ! "$resolver" --print-path >"$scratch/path" 2>"$scratch/stderr"; then
	cat "$scratch/stderr" >&2
	fail 'cold verified seed resolves'
fi
resolved=$(cat "$scratch/path")
[ -x "$resolved" ] && cmp -s "$resolved" "$TEST_SEED" || fail 'resolved seed bytes'
[ "$(downloads)" = 1 ] || fail 'one cold download'
grep -Fxq "https://github.com/kablorp/blorp/releases/download/$tag/blorp2-x86_64-unknown-linux-gnu" "$TEST_DOWNLOAD_LOG" || fail 'asset URL'
[ ! -e "$TEST_SEED_LOG" ] || fail 'print-path ran seed'
pass 'cold verified seed resolves without execution'

"$resolver" --print-path >"$scratch/path"
[ "$(downloads)" = 1 ] || fail 'warm cache downloaded'
pass 'warm verified cache avoids transport'

printf corrupt >"$resolved"
"$resolver" --print-path >"$scratch/path"
cmp -s "$resolved" "$TEST_SEED" || fail 'corrupt cache survived'
[ "$(downloads)" = 2 ] || fail 'corrupt cache was not rehashed'
pass 'corrupt cached bytes are replaced by verified download'

rm "$resolved"
TEST_DOWNLOAD_MODE=bad expect_failure 'checksum' "$resolver" argument
[ ! -e "$resolved" ] && [ ! -e "$TEST_SEED_LOG" ] && [ ! -e "$TEST_LEGACY_LOG" ] || fail 'unverified execution or install'
pass 'bad downloaded bytes never install or execute'
"$resolver" --print-path >"$scratch/path"

chmod -R a-w "$BLORP2_COMPILER_BOOTSTRAP_CACHE_DIR"
TEST_DOWNLOAD_MODE=offline "$resolver" --print-path >"$scratch/path"
chmod -R u+w "$BLORP2_COMPILER_BOOTSTRAP_CACHE_DIR"
cmp -s "$scratch/path" <(printf '%s\n' "$resolved") || fail 'readonly cache path changed'
pass 'read-only offline valid cache remains usable'

mkdir -p "$scratch/elsewhere"
(
	cd "$scratch/elsewhere"
	"$resolver" -- 'two words' '' '*literal*' $'line\nbreak'
)
printf 'cwd:%s\0arg:%s\0arg:%s\0arg:%s\0arg:%s\0' "$fixture" 'two words' '' '*literal*' $'line\nbreak' >"$scratch/expected"
cmp -s "$TEST_SEED_LOG" "$scratch/expected" || fail 'argv or repository cwd changed'
pass 'argv including empty and newline values survives from another cwd'

before=$(downloads)
identity=$(TEST_DOWNLOAD_MODE=offline "$resolver" --print-id)
[ "$identity" = "kablorp/blorp $tag $commit" ] || fail 'manifest identity'
[ "$(downloads)" = "$before" ] || fail 'print-id downloaded'
pass 'print-id reports validated immutable identity without transport'

for target in 'Darwin arm64 aarch64-apple-darwin' 'Linux aarch64 aarch64-unknown-linux-gnu' 'Linux arm64 aarch64-unknown-linux-gnu'; do
	read -r TEST_OS TEST_ARCH triple <<<"$target"
	export TEST_OS TEST_ARCH
	"$resolver" --print-path >"$scratch/path"
	case "$(cat "$scratch/path")" in *"/$triple/"*) ;; *) fail 'target-specific cache';; esac
	grep -Fq "/blorp2-$triple" "$TEST_DOWNLOAD_LOG" || fail 'platform asset'
done
export TEST_OS=Darwin TEST_ARCH=x86_64
expect_failure 'Unsupported Blorp 2 bootstrap target' "$resolver" --print-path
export TEST_OS=Linux TEST_ARCH=x86_64
pass 'three supported platform assets and unsupported platform rejection'

# Manifest values are authoritative even when similarly named env vars exist.
BLORP2_BOOTSTRAP_TAG=latest BLORP2_BOOTSTRAP_REPO=hostile/repo \
	BLORP2_COMPILER_BOOTSTRAP_REPO=hostile/repo "$resolver" --print-id >"$scratch/id"
[ "$(cat "$scratch/id")" = "kablorp/blorp $tag $commit" ] || fail 'ambient release override'
pass 'ambient release variables cannot override the manifest'

sed 's/FORMAT=1/FORMAT=2/' "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'unsupported format' "$resolver" --print-id
pass 'unsupported manifest format rejects'
write_manifest
sed "s/$tag/latest/" "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'immutable' "$resolver" --print-id
pass 'mutable release tag rejects'
write_manifest
sed "s/$commit/ffffffffffffffffffffffffffffffffffffffff/" "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'does not match' "$resolver" --print-id
pass 'tag and full source commit must agree'
write_manifest
sed "s/$commit/0123456789ab/" "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'full source commit' "$resolver" --print-id
pass 'short source commit rejects'
write_manifest
sed 's|REPO=kablorp/blorp|REPO=../bad/repo|' "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'repository' "$resolver" --print-id
pass 'invalid release repository rejects'
write_manifest
sed "s/$digest/not-a-digest/g" "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'SHA-256' "$resolver" --print-id
pass 'malformed digests reject before any transport'
write_manifest
grep -v 'AARCH64_UNKNOWN_LINUX_GNU' "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure 'missing BLORP2_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU' "$resolver" --print-id
pass 'every platform digest is required'
write_manifest
printf 'UNKNOWN_FIELD=1\n' >>"$manifest"
expect_failure 'unknown field' "$resolver" --print-id
pass 'unknown manifest field rejects'
write_manifest
printf 'BLORP2_BOOTSTRAP_FORMAT=1\n' >>"$manifest"
expect_failure 'duplicate field' "$resolver" --print-id
pass 'duplicate manifest field rejects'
write_manifest
printf 'BLORP2_BOOTSTRAP_FORMAT =1\n' >>"$manifest"
expect_failure 'invalid field' "$resolver" --print-id
pass 'malformed assignment rejects'
write_manifest
mv "$manifest" "$scratch/manifest"
"$resolver" --help >"$scratch/help"
grep -Fq -- '--print-path' "$scratch/help" || fail 'help unavailable without pin'
expect_failure 'manifest is missing' "$resolver" --print-path
mv "$scratch/manifest" "$manifest"
pass 'help works before publication and missing manifest has useful error'

# Only fake seed/CC execute in these Makefile behavior checks.
: >"$TEST_CC_LOG"
: >"$TEST_CC_ARGS"
: >"$TEST_SEED_LOG"
make -s -C "$fixture/blorp_2" -j compiler test-compiler BLORP_CC="$tools/fake cc" >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'parallel requested build targets'; }
printf 'seed\nlink:0\nlink:1\n' >"$scratch/expected"
cmp -s "$TEST_CC_LOG" "$scratch/expected" || fail 'generation/link ordering or diagnostic modes'
printf 'cwd:%s\0arg:%s\0arg:%s\0arg:%s\0arg:%s\0' "$fixture" \
	--library-root blorp_2/standard_library blorp_2/src/main.brp blorp_2/build/compiler.c >"$scratch/expected"
cmp -s "$TEST_SEED_LOG" "$scratch/expected" || fail 'make seed CLI or generation count'
printf '%s\0' -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 blorp_2/build/compiler.c -o blorp_2/build/compiler -lm -lpthread \
	-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 blorp_2/build/compiler.c -o blorp_2/build/compiler -lm -lpthread >"$scratch/expected"
cmp -s "$TEST_CC_ARGS" "$scratch/expected" || fail 'link flags or operand argv'
[ ! -e "$TEST_LEGACY_LOG" ] || fail 'build touched legacy'
pass 'parallel requested normal/diagnostic builds generate once and link serially'

: >"$TEST_CC_LOG"
make -s -C "$fixture/blorp_2" BLORP_CC="$tools/fake cc" \
	BLORP2_COMPILER='blorp_2/build/output compiler' \
	BLORP2_COMPILER_C='blorp_2/build/output compiler.c' >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'default compiler with quoted outputs'; }
printf 'seed\nlink:0\n' >"$scratch/expected"
cmp -s "$TEST_CC_LOG" "$scratch/expected" || fail 'default target normal mode'
[ -x "$fixture/blorp_2/build/output compiler" ] || fail 'explicit binary override'
pass 'default target and explicit output paths with spaces work'

: >"$TEST_CC_LOG"
make -s -C "$fixture/blorp_2" link-test-compiler BLORP_CC="$tools/fake cc" >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'standalone diagnostic link'; }
printf 'link:1\n' >"$scratch/expected"
cmp -s "$TEST_CC_LOG" "$scratch/expected" || fail 'fixpoint link regenerated or wrong mode'
pass 'standalone link-test-compiler preserves fixpoint boundary'

: >"$TEST_CC_LOG"
make -s -C "$fixture/blorp_2" example BLORP_CC="$tools/fake cc" >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'seed-built example'; }
[ "$(grep -c '^built$' "$TEST_CC_LOG")" = 2 ] || fail 'example did not use new compiler and real main'
[ ! -e "$TEST_LEGACY_LOG" ] || fail 'example touched legacy'
pass 'example uses newly built B2 executable'
# Every public B2 test route must avoid the legacy tripwires above.
# Two test_utils sources around a test_lex source: groups follow first appearance.
component_sources='blorp_2/test/unit/test_utils/test_boolean.brp blorp_2/test/unit/test_lex/test_lex.brp blorp_2/test/unit/test_utils/test_text.brp'
for target in test test-components; do
	: >"$TEST_COMPONENT_LOG"
	: >"$TEST_E2E_LOG"
	: >"$TEST_E2E_ARGS"
	: >"$TEST_CC_ARGS"
	if ! make -s -C "$fixture/blorp_2" "$target" BLORP_CC="$tools/fake cc" \
		BLORP2_COMPILER='blorp_2/build/output compiler' \
		BLORP2_COMPILER_C='blorp_2/build/output compiler.c' \
		TARGET_COMPONENT_SOURCES="$component_sources" >"$scratch/make.stdout" 2>"$scratch/make.stderr"; then
		cat "$scratch/make.stderr" >&2
		fail "$target must run the self-hosted selection"
	fi
	printf 'compile:%s\ncompile:%s\nnative:strict\ncompile:%s\nnative:strict\n' \
		blorp_2/test/unit/test_utils/test_boolean.brp blorp_2/test/unit/test_utils/test_text.brp \
		blorp_2/test/unit/test_lex/test_lex.brp >"$scratch/expected"
	cmp -s "$TEST_COMPONENT_LOG" "$scratch/expected" || fail "$target selected sources, grouping, order or strict native entrypoint"
	if [ "$target" = test ]; then
		grep -Fxq 'e2e:strict' "$TEST_E2E_LOG" || fail 'default test did not run self-hosted e2e';
	else
		[ ! -s "$TEST_E2E_LOG" ] || fail 'component target ran e2e';
	fi
	if [ "$target" = test-components ]; then
		: >"$scratch/expected"
		for group in unit/test_utils unit/test_lex; do
			program="blorp_2/build/self-hosted-tests/$group/all_suites"
			printf '%s\0' -std=c11 -Wall -Wextra -Werror -pedantic -O0 \
				-DBLORP_MEMORY_DIAGNOSTICS=1 "$program.c" -o "$program" -lm -lpthread >>"$scratch/expected"
		done
		if ! cmp -s "$TEST_CC_ARGS" "$scratch/expected"; then fail 'selected C compiler flags or mirrored group output paths'; fi
	fi
	if ! grep -Fq 'DEFERRED:' "$scratch/make.stdout"; then fail "$target omitted unported coverage status"; fi
	if [ -e "$TEST_LEGACY_LOG" ]; then fail "$target invoked a legacy host/build-status/bootstrap"; fi
	pass "$target runs the selected B2 suites as one strict program per directory"
done

: >"$TEST_E2E_LOG"
: >"$TEST_E2E_ARGS"
make -s -C "$fixture/blorp_2" test-e2e BLORP_CC="$tools/fake cc" \
	BLORP2_COMPILER='blorp_2/build/output compiler' >"$scratch/e2e.stdout" 2>"$scratch/e2e.stderr" || { cat "$scratch/e2e.stderr" >&2; fail 'self-hosted e2e route'; }
grep -Fxq 'e2e:strict' "$TEST_E2E_LOG" || fail 'e2e did not run the strict ordinary driver main'
[ ! -e "$TEST_LEGACY_LOG" ] || fail 'e2e invoked legacy'
pass 'test-e2e runs its new B2 driver with explicit executable and temporary paths'

for failure_kind in compile link native; do
	: >"$TEST_E2E_LOG"
	export TEST_E2E_COMPILE_STATUS=0 TEST_CC_STATUS=0 TEST_E2E_STATUS=0
	case "$failure_kind" in
		compile) TEST_E2E_COMPILE_STATUS=41 ;;
		link) TEST_CC_STATUS=42 ;;
		native) TEST_E2E_STATUS=43 ;;
	esac
	if make -s -C "$fixture/blorp_2" test-e2e BLORP_CC="$tools/fake cc" \
		BLORP2_COMPILER='blorp_2/build/output compiler' >"$scratch/e2e.stdout" 2>"$scratch/e2e.stderr"; then
		fail "e2e $failure_kind failure was ignored"
	fi
	if [ "$failure_kind" != native ] && [ -s "$TEST_E2E_LOG" ]; then fail 'failed compile/link ran a stale e2e driver'; fi
	pass "self-hosted e2e $failure_kind failure stops and fails the target"
done
unset TEST_E2E_COMPILE_STATUS TEST_CC_STATUS TEST_E2E_STATUS

expect_failure 'missing Blorp 2 test compiler' make -s -C "$fixture/blorp_2" test-e2e BLORP2_COMPILER=missing-compiler
pass 'e2e missing compiler fails with actionable build help'

: >"$TEST_COMPONENT_LOG"
expect_failure 'no target component sources selected' make -s -C "$fixture/blorp_2" test-components TARGET_COMPONENT_SOURCES=
if [ -s "$TEST_COMPONENT_LOG" ]; then fail 'empty selection executed components'; fi
pass 'empty self-hosted selection fails closed'

for failure_kind in compile link native; do
	: >"$TEST_COMPONENT_LOG"
	export TEST_COMPONENT_COMPILE_STATUS=0 TEST_CC_STATUS=0 TEST_COMPONENT_NATIVE_STATUS=0
	case "$failure_kind" in
		compile) TEST_COMPONENT_COMPILE_STATUS=31 ;;
		link) TEST_CC_STATUS=32 ;;
		native) TEST_COMPONENT_NATIVE_STATUS=33 ;;
	esac
	if make -s -C "$fixture/blorp_2" test-components BLORP_CC="$tools/fake cc" \
		BLORP2_COMPILER='blorp_2/build/output compiler' TARGET_COMPONENT_SOURCES="$component_sources" \
		>"$scratch/make.stdout" 2>"$scratch/make.stderr"; then
		fail "$failure_kind failure was ignored"
	fi
	if grep -Fq 'compile:blorp_2/test/unit/test_lex/test_lex.brp' "$TEST_COMPONENT_LOG"; then fail "$failure_kind failure continued to the next group"; fi
	if [ "$failure_kind" != native ] && grep -Fq 'native:' "$TEST_COMPONENT_LOG"; then fail "$failure_kind failure executed stale native output"; fi
	if [ -e "$TEST_LEGACY_LOG" ]; then fail "$failure_kind failure invoked legacy"; fi
	pass "self-hosted $failure_kind failure blocks and stops the selection"
done
unset TEST_COMPONENT_COMPILE_STATUS TEST_CC_STATUS TEST_COMPONENT_NATIVE_STATUS
printf '%s tests passed\n' "$passed"
