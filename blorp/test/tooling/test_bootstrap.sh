#!/usr/bin/env bash
# Exercise bootstrap transport and make recipes without a real compiler.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/blorp bootstrap.XXXXXX")
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
fixture="$scratch/repo with spaces"
tools="$scratch/fake tools"
mkdir -p "$fixture/scripts" "$fixture/blorp/src" "$tools"
fixture=$(cd "$fixture" && pwd -P)
cp "$repo_root/blorp/Makefile" "$fixture/blorp/Makefile"
if [ -f "$repo_root/scripts/blorp-compiler-bootstrap" ]; then
	cp "$repo_root/scripts/blorp-compiler-bootstrap" "$fixture/scripts/"
fi
resolver="$fixture/scripts/blorp-compiler-bootstrap"
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
export TEST_DRIVER_LOG="$scratch/driver.log" TEST_DRIVER_ARGS="$scratch/driver.args"
export TEST_CC_ARGS="$scratch/cc-args" TEST_COMPILER_ARGS="$scratch/compiler.args"
export TEST_DOWNLOAD_LOG="$scratch/download.log" TEST_BAD_EXEC_LOG="$scratch/bad-exec.log"
export TEST_SEED="$scratch/seed payload" TEST_DOWNLOAD_MODE=good
export TEST_OS=Linux TEST_ARCH=x86_64
export BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$scratch/cache with spaces"
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
	printf '#!/usr/bin/env bash\necho BAD_EXEC >>"$TEST_BAD_EXEC_LOG"\n' >"$4"
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
	*/self-hosted-tests/driver/driver.c)
		cat >"$output" <<'SEED'
#!/usr/bin/env bash
set -euo pipefail
printf 'driver:%s:%s:%s\n' "$1" "${BLORP_LEAK_CHECK:-unset}" "$PWD" >>"$TEST_DRIVER_LOG"
(IFS='|'; printf '%s\n' "$*") >>"$TEST_DRIVER_ARGS"
exit "${TEST_DRIVER_STATUS:-0}"
SEED
		;;
	*)
		cat >"$output" <<'SEED'
#!/usr/bin/env bash
set -euo pipefail
printf 'built\n' >>"$TEST_CC_LOG"
if [ "${1:-}" = --library-root ]; then
	printf 'compiler:%s\n' "${BLORP_LEAK_CHECK:-unset}" >>"$TEST_COMPILER_ARGS"
	printf '%s\n' "$*" >>"$TEST_COMPILER_ARGS"
	if [ "${TEST_DRIVER_COMPILE_STATUS:-0}" -ne 0 ]; then exit "$TEST_DRIVER_COMPILE_STATUS"; fi
	printf '/* fake fixture C */\n' >"$4"
fi
SEED
		;;
esac
chmod +x "$output"
SH
chmod +x "$tools/"*
export PATH="$tools:$PATH"
commit=0123456789abcdef0123456789abcdef01234567
# The release family the resolver accepts, its seed_release_family. The next seed
# rotation switches this one line, together with the resolver and the pin, to blorp.
family=blorp2
tag=$family-seed-0123456789ab
digest=$(sha256_file "$TEST_SEED")
manifest="$fixture/blorp/bootstrap.env"
write_manifest() {
	cat >"$manifest" <<EOF
BLORP_BOOTSTRAP_FORMAT=1
BLORP_BOOTSTRAP_REPO=kablorp/blorp
BLORP_BOOTSTRAP_TAG=$tag
BLORP_BOOTSTRAP_SOURCE_COMMIT=$commit
BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=$digest
BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=$digest
BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=$digest
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
grep -Fxq "https://github.com/kablorp/blorp/releases/download/$tag/$family-x86_64-unknown-linux-gnu" "$TEST_DOWNLOAD_LOG" || fail 'asset URL'
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
[ ! -e "$resolved" ] && [ ! -e "$TEST_SEED_LOG" ] && [ ! -e "$TEST_BAD_EXEC_LOG" ] || fail 'unverified execution or install'
pass 'bad downloaded bytes never install or execute'
"$resolver" --print-path >"$scratch/path"

chmod -R a-w "$BLORP_COMPILER_BOOTSTRAP_CACHE_DIR"
TEST_DOWNLOAD_MODE=offline "$resolver" --print-path >"$scratch/path"
chmod -R u+w "$BLORP_COMPILER_BOOTSTRAP_CACHE_DIR"
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
	grep -Fq "/$family-$triple" "$TEST_DOWNLOAD_LOG" || fail 'platform asset'
done
export TEST_OS=Darwin TEST_ARCH=x86_64
expect_failure 'Unsupported Blorp bootstrap target' "$resolver" --print-path
export TEST_OS=Linux TEST_ARCH=x86_64
pass 'three supported platform assets and unsupported platform rejection'

# Manifest values are authoritative even when similarly named env vars exist.
BLORP_BOOTSTRAP_TAG=latest BLORP_BOOTSTRAP_REPO=hostile/repo \
	BLORP_COMPILER_BOOTSTRAP_REPO=hostile/repo "$resolver" --print-id >"$scratch/id"
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
# The resolver accepts one release family, never both: the other spelling rejects.
other_family=blorp
[ "$family" != blorp ] || other_family=blorp2
sed "s/$tag/$other_family-seed-0123456789ab/" "$manifest" >"$scratch/invalid"
cp "$scratch/invalid" "$manifest"
expect_failure "tag must be immutable $family-seed-<12hex>" "$resolver" --print-id
pass 'only the resolver release family is accepted'
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
expect_failure 'missing BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU' "$resolver" --print-id
pass 'every platform digest is required'
write_manifest
printf 'UNKNOWN_FIELD=1\n' >>"$manifest"
expect_failure 'unknown field' "$resolver" --print-id
pass 'unknown manifest field rejects'
write_manifest
printf 'BLORP_BOOTSTRAP_FORMAT=1\n' >>"$manifest"
expect_failure 'duplicate field' "$resolver" --print-id
pass 'duplicate manifest field rejects'
write_manifest
printf 'BLORP_BOOTSTRAP_FORMAT =1\n' >>"$manifest"
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
make -s -C "$fixture/blorp" -j compiler test-compiler BLORP_CC="$tools/fake cc" >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'parallel requested build targets'; }
printf 'seed\nlink:0\nlink:1\n' >"$scratch/expected"
cmp -s "$TEST_CC_LOG" "$scratch/expected" || fail 'generation/link ordering or diagnostic modes'
printf 'cwd:%s\0arg:%s\0arg:%s\0arg:%s\0arg:%s\0' "$fixture" \
	--library-root blorp/standard_library blorp/src/main.brp blorp/build/compiler.c >"$scratch/expected"
cmp -s "$TEST_SEED_LOG" "$scratch/expected" || fail 'make seed CLI or generation count'
printf '%s\0' -O0 -DBLORP_MEMORY_DIAGNOSTICS=0 blorp/build/compiler.c -o blorp/build/compiler -lm -lpthread \
	-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 blorp/build/compiler.c -o blorp/build/compiler -lm -lpthread >"$scratch/expected"
cmp -s "$TEST_CC_ARGS" "$scratch/expected" || fail 'link flags or operand argv'
pass 'parallel requested normal/diagnostic builds generate once and link serially'

: >"$TEST_CC_LOG"
make -s -C "$fixture/blorp" BLORP_CC="$tools/fake cc" \
	BLORP_COMPILER='blorp/build/output compiler' \
	BLORP_COMPILER_C='blorp/build/output compiler.c' >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'default compiler with quoted outputs'; }
printf 'seed\nlink:0\n' >"$scratch/expected"
cmp -s "$TEST_CC_LOG" "$scratch/expected" || fail 'default target normal mode'
[ -x "$fixture/blorp/build/output compiler" ] || fail 'explicit binary override'
pass 'default target and explicit output paths with spaces work'

: >"$TEST_CC_LOG"
make -s -C "$fixture/blorp" link-test-compiler BLORP_CC="$tools/fake cc" >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'standalone diagnostic link'; }
printf 'link:1\n' >"$scratch/expected"
cmp -s "$TEST_CC_LOG" "$scratch/expected" || fail 'fixpoint link regenerated or wrong mode'
pass 'standalone link-test-compiler preserves fixpoint boundary'

: >"$TEST_CC_LOG"
make -s -C "$fixture/blorp" example BLORP_CC="$tools/fake cc" >"$scratch/make.stdout" 2>"$scratch/make.stderr" || { cat "$scratch/make.stderr" >&2; fail 'seed-built example'; }
[ "$(grep -c '^built$' "$TEST_CC_LOG")" = 2 ] || fail 'example did not use new compiler and real main'
pass 'example uses newly built executable'
# The test targets build one Blorp driver with the compiler under test and run
# it once per mode. Only the fake driver executes here: what each mode does is
# proven by the driver's unit suite and by running `make test` itself.
real_parent="$scratch/real parent"
link_parent="$scratch/link parent"
mkdir "$real_parent"
ln -s "$real_parent" "$link_parent"
real_parent=$(cd "$real_parent" && pwd -P)
expected_compiler="$fixture/blorp/build/output compiler"
expected_cc="$tools/fake cc"
reset_driver_logs() {
	: >"$TEST_DRIVER_LOG"
	: >"$TEST_DRIVER_ARGS"
	: >"$TEST_COMPILER_ARGS"
	: >"$TEST_CC_ARGS"
}
run_test_target() {
	local target
	target="$1"
	shift
	TMPDIR="$link_parent" make -s -C "$fixture/blorp" "$target" BLORP_CC="$tools/fake cc" \
		BLORP_COMPILER='blorp/build/output compiler' \
		BLORP_COMPILER_C='blorp/build/output compiler.c' "$@" >"$scratch/make.stdout" 2>"$scratch/make.stderr"
}

reset_driver_logs
if ! run_test_target test-e2e; then cat "$scratch/make.stderr" >&2; fail 'test-e2e must run the driver'; fi
printf 'driver:e2e:strict:%s\n' "$fixture" >"$scratch/expected"
cmp -s "$TEST_DRIVER_LOG" "$scratch/expected" || fail 'test-e2e did not run exactly the e2e mode strictly from the repository root'
printf 'e2e|%s|%s|%s\n' "$expected_compiler" "$expected_cc" "$real_parent" >"$scratch/expected"
cmp -s "$TEST_DRIVER_ARGS" "$scratch/expected" || fail 'e2e arguments are not the absolute tools and the physical temporary parent'
pass 'test-e2e runs the e2e mode with absolute tools and the symlink-resolved temporary parent'

reset_driver_logs
if ! run_test_target test-e2e INSTRUCTION_CHECK=on; then cat "$scratch/make.stderr" >&2; fail 'test-e2e with INSTRUCTION_CHECK must run the driver'; fi
printf 'e2e|%s|%s|%s|--check-instructions\n' "$expected_compiler" "$expected_cc" "$real_parent" >"$scratch/expected"
cmp -s "$TEST_DRIVER_ARGS" "$scratch/expected" || fail 'INSTRUCTION_CHECK did not pass --check-instructions to the e2e mode'
reset_driver_logs
if run_test_target test-e2e INSTRUCTION_CHECK=off; then fail 'INSTRUCTION_CHECK=off must not run e2e'; fi
grep -Fq 'INSTRUCTION_CHECK must be empty or on, not off' "$scratch/make.stderr" || fail 'INSTRUCTION_CHECK=off was not rejected with its reason'
[ ! -s "$TEST_DRIVER_ARGS" ] || fail 'INSTRUCTION_CHECK=off still ran the driver'
pass 'INSTRUCTION_CHECK passes the instruction flag only for on, and rejects other values'

printf 'compiler:strict\n--library-root blorp/standard_library blorp/test/e2e/self_hosted.brp blorp/build/self-hosted-tests/driver/driver.c\n' >"$scratch/expected"
cmp -s "$TEST_COMPILER_ARGS" "$scratch/expected" || fail 'the driver was not compiled strictly from the driver entry'
printf '%s\0' -std=c11 -Wall -Wextra -Werror -pedantic -O0 -fsanitize=undefined -fno-sanitize-recover=all \
	-DBLORP_MEMORY_DIAGNOSTICS=1 blorp/build/self-hosted-tests/driver/driver.c -o blorp/build/self-hosted-tests/driver/driver \
	-lm -lpthread >"$scratch/expected"
cmp -s "$TEST_CC_ARGS" "$scratch/expected" || fail 'driver link flags or operand argv'
pass 'the driver is built by the compiler under test, strictly, with sanitizers'

reset_driver_logs
if ! run_test_target test-target-components TARGET_COMPONENT_SOURCES='a b/test_one.brp c.brp'; then cat "$scratch/make.stderr" >&2; fail 'test-target-components must run the driver'; fi
printf 'components|%s|%s|-lm|-lpthread|--|a|b/test_one.brp|c.brp\n' "$expected_compiler" "$expected_cc" >"$scratch/expected"
cmp -s "$TEST_DRIVER_ARGS" "$scratch/expected" || fail 'the narrow selection is not passed to the components mode'
pass 'test-target-components passes TARGET_COMPONENT_SOURCES to the driver, and only that'

for target in test-target-components test-components; do
	reset_driver_logs
	if ! run_test_target "$target"; then cat "$scratch/make.stderr" >&2; fail "$target must run the driver"; fi
	printf 'components|%s|%s|-lm|-lpthread|--\n' "$expected_compiler" "$expected_cc" >"$scratch/expected"
	[ "$target" = test-target-components ] || printf 'deferred\n' >>"$scratch/expected"
	cmp -s "$TEST_DRIVER_ARGS" "$scratch/expected" || fail "$target did not leave the selection to the driver or report deferrals only for test-components"
	if grep -Fq 'driver:e2e' "$TEST_DRIVER_LOG"; then fail "$target ran e2e"; fi
	grep -Fxq "driver:components:strict:$fixture" "$TEST_DRIVER_LOG" || fail "$target did not run the components mode strictly from the repository root"
	pass "$target leaves an empty selection to the driver's built-in list"
done

reset_driver_logs
if ! run_test_target test-components TARGET_COMPONENT_SOURCES='a.brp'; then cat "$scratch/make.stderr" >&2; fail 'test-components with a selection'; fi
printf 'components|%s|%s|-lm|-lpthread|--|a.brp\ndeferred|a.brp\n' "$expected_compiler" "$expected_cc" >"$scratch/expected"
cmp -s "$TEST_DRIVER_ARGS" "$scratch/expected" || fail 'the deferral report does not use the same selection'
pass 'test-components reports deferrals against the selection it ran'

# `test` builds the driver once, then runs components, the deferral report and e2e.
reset_driver_logs
if ! TMPDIR="$link_parent" make -s -C "$fixture/blorp" test BLORP_CC="$tools/fake cc" \
	BLORP_COMPILER='blorp/build/output compiler' \
	BLORP_COMPILER_C='blorp/build/output compiler.c' >"$scratch/make.stdout" 2>"$scratch/make.stderr"; then
	cat "$scratch/make.stderr" >&2
	fail 'test must run the self-hosted driver'
fi
[ "$(grep -c '^compiler:strict$' "$TEST_COMPILER_ARGS")" = 1 ] || fail 'test did not build the driver exactly once'
printf 'driver:components:strict:%s\ndriver:deferred:strict:%s\ndriver:e2e:strict:%s\n' "$fixture" "$fixture" "$fixture" >"$scratch/expected"
cmp -s "$TEST_DRIVER_LOG" "$scratch/expected" || fail 'test did not run components, deferrals and e2e in that order'
pass 'test builds the driver once and runs components, deferrals and e2e in order'

for failure_kind in driver-compile driver-link driver-run; do
	reset_driver_logs
	export TEST_DRIVER_COMPILE_STATUS=0 TEST_CC_STATUS=0 TEST_DRIVER_STATUS=0
	case "$failure_kind" in
		driver-compile) TEST_DRIVER_COMPILE_STATUS=41 ;;
		driver-link) TEST_CC_STATUS=42 ;;
		driver-run) TEST_DRIVER_STATUS=43 ;;
	esac
	for target in test-target-components test-components test-e2e; do
		: >"$TEST_DRIVER_LOG"
		if run_test_target "$target"; then fail "$target ignored a $failure_kind failure"; fi
		if [ "$failure_kind" != driver-run ] && [ -s "$TEST_DRIVER_LOG" ]; then fail "$target ran a driver after a $failure_kind failure"; fi
		if [ "$failure_kind" = driver-run ] && [ "$target" = test-components ] && [ "$(wc -l <"$TEST_DRIVER_LOG" | tr -d ' ')" != 1 ]; then fail 'a failed component run still reported deferrals'; fi
	done
	pass "a $failure_kind failure stops every test target and fails it"
done
unset TEST_DRIVER_COMPILE_STATUS TEST_CC_STATUS TEST_DRIVER_STATUS

for target in test-target-components test-components test-e2e; do
	expect_failure 'missing Blorp test compiler' make -s -C "$fixture/blorp" "$target" BLORP_COMPILER=missing-compiler
done
pass 'every test target fails with actionable build help when the compiler is missing'
printf '%s tests passed\n' "$passed"
