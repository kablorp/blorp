#!/usr/bin/env bash
# Regression tests for release archives and compiler-bootstrap installation.

set -euo pipefail

cd "$(dirname "$0")/.."

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-release-toolchain.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

sha256_file() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		sha256sum "$1" | awk '{print $1}'
	fi
}

write_checksum() {
	local archive="$1"
	printf '%s  %s\n' "$(sha256_file "$archive")" "$(basename "$archive")" \
		>"$archive.sha256"
}

fake_bin="$tmp_dir/release-bin"
mkdir -p "$fake_bin"
bootstrap_layout_name="blorp-bootstrap-layout"
bootstrap_layout_version="isolated-v1"
current_toolchain_executables=(
	blorp
	blorp-ocaml-host
	blorp-ocaml-middle
	blorp-compiler-renderer
	blorp-compiler-parser
	blorp-compiler-typecheck
)
bootstrap_bundle_executables=(
	blorp-bootstrap-compiler
	blorp-bootstrap-host
	blorp-bootstrap-renderer
	blorp-bootstrap-parser
	blorp-bootstrap-typecheck
)
toolchain_executables=(
	"${current_toolchain_executables[@]}"
	"${bootstrap_bundle_executables[@]}"
)
for executable in "${toolchain_executables[@]}"; do
	cp /bin/sh "$fake_bin/$executable"
done
printf '%s\n' "$bootstrap_layout_version" \
	>"$fake_bin/$bootstrap_layout_name"
cat >"$fake_bin/blorp-bootstrap-compiler" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

toolchain_dir=$(cd "$(dirname "$0")" && pwd -P)
export BLORP_COMPILER_RENDERER_BRIDGE_BIN="$toolchain_dir/blorp-bootstrap-renderer"
export BLORP_COMPILER_PARSER_BRIDGE_BIN="$toolchain_dir/blorp-bootstrap-parser"
export BLORP_COMPILER_TYPECHECK_BRIDGE_BIN="$toolchain_dir/blorp-bootstrap-typecheck"
export BLORP_COMPILER_REQUIRE_PREPARED_BRIDGE=1
exec "$toolchain_dir/blorp-bootstrap-host" "$@"
SH
chmod +x "$fake_bin/blorp-bootstrap-compiler"
cat >"$fake_bin/blorp-bootstrap-host" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != "__compiler-host-compile-wrapper" ]; then
	echo "unexpected bootstrap compiler command: ${1:-<missing>}" >&2
	exit 1
fi
shift

for helper in \
	"${BLORP_COMPILER_RENDERER_BRIDGE_BIN:-}" \
	"${BLORP_COMPILER_PARSER_BRIDGE_BIN:-}" \
	"${BLORP_COMPILER_TYPECHECK_BRIDGE_BIN:-}"
do
	if [ ! -x "$helper" ]; then
		echo "bootstrap compiler did not receive its immutable helper generation" >&2
		exit 1
	fi
	if ! grep -Fq '# bootstrap-generation' "$helper"; then
		echo "bootstrap compiler received a helper from another generation" >&2
		exit 1
	fi
done

output=""
source_file=""
while [ $# -gt 0 ]; do
	case "$1" in
		--profile)
			shift
			;;
		-o)
			output="${2:?missing output path}"
			shift 2
			;;
		-*)
			echo "unexpected bootstrap compiler option: $1" >&2
			exit 1
			;;
		*)
			source_file="$1"
			shift
			;;
	esac
done

if [ -z "$output" ] || [ ! -f "$source_file" ]; then
	echo "bootstrap compiler requires an output and an existing source file" >&2
	exit 1
fi
printf 'int main(void) { return 0; }\n' >"$output"
SH
chmod +x "$fake_bin/blorp-bootstrap-host"
for bootstrap_helper in \
	blorp-bootstrap-renderer \
	blorp-bootstrap-parser \
	blorp-bootstrap-typecheck
do
	cat >"$fake_bin/$bootstrap_helper" <<'SH'
#!/bin/sh
# bootstrap-generation
exit 0
SH
	chmod +x "$fake_bin/$bootstrap_helper"
done
cat >"$fake_bin/blorp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "__compiler-bridge-prepare" ]; then
	if [ "${BLORP_OCAML_HOST_BIN:-}" != "${BLORP_TEST_EXPECTED_OCAML_HOST:?}" ]; then
		echo "prepare did not receive the selected OCaml host" >&2
		exit 1
	fi
	if [ "${BLORP_OCAML_MIDDLE_BIN:-}" != "${BLORP_TEST_EXPECTED_OCAML_MIDDLE:?}" ]; then
		echo "prepare did not receive the selected OCaml middle worker" >&2
		exit 1
	fi
	mkdir -p "$2"
	cp /bin/sh "$2/compiler_renderer_bridge.bin"
	cp /bin/sh "$2/compiler_parser_bridge.bin"
	cp /bin/sh "$2/compiler_typecheck_bridge.bin"
	: >"${BLORP_TEST_PREPARE_MARKER:?}"
	exit 0
fi

exec /bin/sh "$@"
SH
chmod +x "$fake_bin/blorp"

release_version=0.0.1-dev.aaaaaaaaaaaa
release_target=x86_64-unknown-linux-gnu
release_dir="$tmp_dir/dist"
prepare_marker="$tmp_dir/prepare-called"
selected_workers="$tmp_dir/selected-workers"
mkdir -p "$selected_workers"
cp /bin/sh "$selected_workers/blorp-ocaml-host"
cp /bin/sh "$selected_workers/blorp-ocaml-middle"
BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_BOOTSTRAP_COMPILER="$fake_bin/blorp-bootstrap-compiler" \
	BLORP_RELEASE_OCAML_HOST="$selected_workers/blorp-ocaml-host" \
	BLORP_RELEASE_OCAML_MIDDLE="$selected_workers/blorp-ocaml-middle" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	BLORP_TEST_PREPARE_MARKER="$prepare_marker" \
	BLORP_TEST_EXPECTED_OCAML_HOST="$selected_workers/blorp-ocaml-host" \
	BLORP_TEST_EXPECTED_OCAML_MIDDLE="$selected_workers/blorp-ocaml-middle" \
	scripts/package-release "$release_dir" >/dev/null
if [ ! -e "$prepare_marker" ]; then
	fail "release packaging without bridge overrides must prepare one coherent bridge set"
fi

archive_base="blorp-${release_version}-${release_target}"
archive="$release_dir/$archive_base.tar.gz"
extract_dir="$tmp_dir/extracted-release"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"
for executable in "${toolchain_executables[@]}"; do
	packaged="$extract_dir/$archive_base/$executable"
	if [ ! -x "$packaged" ]; then
		fail "release archive must contain executable $executable"
	fi
	if ! cmp "$fake_bin/$executable" "$packaged"; then
		fail "packaged $executable must match its release input"
	fi
done
if ! cmp "$fake_bin/$bootstrap_layout_name" \
	"$extract_dir/$archive_base/$bootstrap_layout_name"
then
	fail "release archive must preserve the immutable bootstrap layout manifest"
fi

bootstrap_smoke_output="$tmp_dir/bootstrap-smoke.c"
"$extract_dir/$archive_base/blorp-bootstrap-compiler" \
	__compiler-host-compile-wrapper \
	-o "$bootstrap_smoke_output" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$bootstrap_smoke_output" ]; then
	fail "the packaged bootstrap compiler must compile a source file"
fi

legacy_bootstrap_source="$tmp_dir/legacy-bootstrap-source"
mkdir -p "$legacy_bootstrap_source"
cp "$fake_bin/blorp-bootstrap-host" \
	"$legacy_bootstrap_source/blorp-ocaml-host"
cp "$fake_bin/blorp-bootstrap-renderer" \
	"$legacy_bootstrap_source/blorp-compiler-renderer"
cp "$fake_bin/blorp-bootstrap-parser" \
	"$legacy_bootstrap_source/blorp-compiler-parser"
cp "$fake_bin/blorp-bootstrap-typecheck" \
	"$legacy_bootstrap_source/blorp-compiler-typecheck"
for legacy_helper in \
	blorp-compiler-renderer \
	blorp-compiler-parser \
	blorp-compiler-typecheck
do
	printf '%s\n' '# legacy-generation' \
		>>"$legacy_bootstrap_source/$legacy_helper"
done
legacy_bundle_release_dir="$tmp_dir/legacy-bundle-dist"
BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_BOOTSTRAP_COMPILER="$legacy_bootstrap_source/blorp-ocaml-host" \
	BLORP_RELEASE_BOOTSTRAP_TOOLCHAIN_DIR="$legacy_bootstrap_source" \
	BLORP_RELEASE_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_RELEASE_OCAML_MIDDLE="$fake_bin/blorp-ocaml-middle" \
	BLORP_RELEASE_RENDERER_BRIDGE="$fake_bin/blorp-compiler-renderer" \
	BLORP_RELEASE_PARSER_BRIDGE="$fake_bin/blorp-compiler-parser" \
	BLORP_RELEASE_TYPECHECK_BRIDGE="$fake_bin/blorp-compiler-typecheck" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$legacy_bundle_release_dir" >/dev/null
legacy_bundle_extract_dir="$tmp_dir/extracted-legacy-bundle"
mkdir -p "$legacy_bundle_extract_dir"
tar -xzf "$legacy_bundle_release_dir/$archive_base.tar.gz" \
	-C "$legacy_bundle_extract_dir"
legacy_bundle_dir="$legacy_bundle_extract_dir/$archive_base"
legacy_bundle_smoke_output="$tmp_dir/legacy-bundle-smoke.c"
"$legacy_bundle_dir/blorp-bootstrap-compiler" \
	__compiler-host-compile-wrapper \
	-o "$legacy_bundle_smoke_output" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$legacy_bundle_smoke_output" ]; then
	fail "a pre-transition bootstrap must be isolated with its own helper generation"
fi

sibling_release_dir="$tmp_dir/sibling-dist"
sibling_prepare_marker="$tmp_dir/sibling-prepare-called"
BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_RELEASE_OCAML_MIDDLE="$fake_bin/blorp-ocaml-middle" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	BLORP_TEST_PREPARE_MARKER="$sibling_prepare_marker" \
	BLORP_TEST_EXPECTED_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_TEST_EXPECTED_OCAML_MIDDLE="$fake_bin/blorp-ocaml-middle" \
	scripts/package-release "$sibling_release_dir" >/dev/null
sibling_extract_dir="$tmp_dir/extracted-sibling-release"
mkdir -p "$sibling_extract_dir"
tar -xzf "$sibling_release_dir/$archive_base.tar.gz" -C "$sibling_extract_dir"
if ! cmp "$fake_bin/blorp-bootstrap-compiler" \
	"$sibling_extract_dir/$archive_base/blorp-bootstrap-compiler"
then
	fail "release packaging must prefer a bootstrap compiler beside the release binary"
fi

if BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_RENDERER_BRIDGE="$fake_bin/blorp-compiler-renderer" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/partial-bridge-dist" \
	>"$tmp_dir/package-partial-bridge.output" 2>&1
then
	fail "release packaging must reject partial bridge overrides"
fi
if ! grep -Fq "must be provided together" \
	"$tmp_dir/package-partial-bridge.output"
then
	fail "partial bridge overrides must produce a precise diagnostic"
fi

if BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_OCAML_HOST="$tmp_dir/missing-host" \
	BLORP_RELEASE_OCAML_MIDDLE="$fake_bin/blorp-ocaml-middle" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/incomplete-dist" \
	>"$tmp_dir/package-missing-helper.output" 2>&1
then
	fail "release packaging must reject a missing private helper"
fi

if BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_BOOTSTRAP_COMPILER="$tmp_dir/missing-bootstrap-compiler" \
	BLORP_RELEASE_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_RELEASE_OCAML_MIDDLE="$fake_bin/blorp-ocaml-middle" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/missing-bootstrap-dist" \
	>"$tmp_dir/package-missing-bootstrap.output" 2>&1
then
	fail "release packaging must reject a missing bootstrap compiler"
fi
if ! grep -Fq "Release bootstrap compiler not found or not executable" \
	"$tmp_dir/package-missing-bootstrap.output"
then
	fail "a missing bootstrap compiler must produce a precise diagnostic"
fi

incomplete_bootstrap_dir="$tmp_dir/incomplete-bootstrap-bundle"
mkdir -p "$incomplete_bootstrap_dir"
cp "$fake_bin/blorp-bootstrap-host" \
	"$fake_bin/blorp-bootstrap-renderer" \
	"$fake_bin/blorp-bootstrap-parser" \
	"$incomplete_bootstrap_dir/"
cp "$fake_bin/$bootstrap_layout_name" "$incomplete_bootstrap_dir/"
if BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_BOOTSTRAP_COMPILER="$fake_bin/blorp-bootstrap-compiler" \
	BLORP_RELEASE_BOOTSTRAP_TOOLCHAIN_DIR="$incomplete_bootstrap_dir" \
	BLORP_RELEASE_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_RELEASE_OCAML_MIDDLE="$fake_bin/blorp-ocaml-middle" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/incomplete-bootstrap-bundle-dist" \
	>"$tmp_dir/package-incomplete-bootstrap-bundle.output" 2>&1
then
	fail "release packaging must reject an incomplete immutable bootstrap bundle"
fi
if ! grep -Fq "Release bootstrap bundle is missing executable" \
	"$tmp_dir/package-incomplete-bootstrap-bundle.output"
then
	fail "an incomplete immutable bootstrap bundle must produce a precise diagnostic"
fi

mock_bin="$tmp_dir/mock-bin"
downloads="$tmp_dir/downloads"
mkdir -p "$mock_bin" "$downloads"
cat >"$mock_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

url=""
output=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o)
			output="$2"
			shift 2
			;;
		-*) shift ;;
		*)
			url="$1"
			shift
			;;
	esac
done
cp "$BLORP_TEST_DOWNLOAD_DIR/$(basename "$url")" "$output"
SH
chmod +x "$mock_bin/curl"

cat >"$mock_bin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
	-m) printf '%s\n' x86_64 ;;
	-s) printf '%s\n' Linux ;;
	*) printf '%s\n' Linux ;;
esac
SH
chmod +x "$mock_bin/uname"

dev_asset="blorp-dev-${release_target}.tar.gz"
cp "$archive" "$downloads/$dev_asset"
write_checksum "$downloads/$dev_asset"
install_dir="$tmp_dir/install"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$install_dir" \
	scripts/install-dev >/dev/null

for executable in "${current_toolchain_executables[@]}"; do
	if ! cmp "$fake_bin/$executable" "$install_dir/$executable"; then
		fail "the dev installer must install $executable from the archive"
	fi
done
initial_bootstrap_generation=$(cat "$install_dir/.blorp-bootstrap/active")
installed_bootstrap_dir="$install_dir/.blorp-bootstrap/$initial_bootstrap_generation"
for executable in "${bootstrap_bundle_executables[@]}"; do
	if ! cmp "$fake_bin/$executable" \
		"$installed_bootstrap_dir/$executable"
	then
		fail "the dev installer must install isolated $executable from the archive"
	fi
done
if ! cmp "$fake_bin/$bootstrap_layout_name" \
	"$installed_bootstrap_dir/$bootstrap_layout_name"
then
	fail "the dev installer must install the bootstrap layout manifest"
fi

installed_repack_dir="$tmp_dir/installed-repack-dist"
BLORP_RELEASE_BINARY="$install_dir/blorp" \
	BLORP_RELEASE_RENDERER_BRIDGE="$install_dir/blorp-compiler-renderer" \
	BLORP_RELEASE_PARSER_BRIDGE="$install_dir/blorp-compiler-parser" \
	BLORP_RELEASE_TYPECHECK_BRIDGE="$install_dir/blorp-compiler-typecheck" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$installed_repack_dir" >/dev/null
installed_repack_extract="$tmp_dir/installed-repack"
mkdir -p "$installed_repack_extract"
tar -xzf "$installed_repack_dir/$archive_base.tar.gz" \
	-C "$installed_repack_extract"
for bootstrap_file in \
	"$bootstrap_layout_name" \
	"${bootstrap_bundle_executables[@]}"
do
	if ! cmp "$installed_bootstrap_dir/$bootstrap_file" \
		"$installed_repack_extract/$archive_base/$bootstrap_file"
	then
		fail "repackaging an installed toolchain must preserve active $bootstrap_file"
	fi
done

pre_transition_root="$tmp_dir/pre-transition/blorp-pre-transition-${release_target}"
mkdir -p "$pre_transition_root"
for executable in "${current_toolchain_executables[@]}"; do
	cp "$fake_bin/$executable" "$pre_transition_root/$executable"
done
cp "$legacy_bootstrap_source/blorp-ocaml-host" \
	"$pre_transition_root/blorp-ocaml-host"
cp "$legacy_bootstrap_source/blorp-compiler-renderer" \
	"$pre_transition_root/blorp-compiler-renderer"
cp "$legacy_bootstrap_source/blorp-compiler-parser" \
	"$pre_transition_root/blorp-compiler-parser"
cp "$legacy_bootstrap_source/blorp-compiler-typecheck" \
	"$pre_transition_root/blorp-compiler-typecheck"
pre_transition_archive="$tmp_dir/pre-transition.tar.gz"
tar -C "$(dirname "$pre_transition_root")" -czf "$pre_transition_archive" \
	"$(basename "$pre_transition_root")"
cp "$pre_transition_archive" "$downloads/$dev_asset"
write_checksum "$downloads/$dev_asset"
pre_transition_install="$tmp_dir/pre-transition-install"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$pre_transition_install" \
	scripts/install-dev >/dev/null
pre_transition_generation=$(
	cat "$pre_transition_install/.blorp-bootstrap/active"
)
pre_transition_bootstrap_dir="$pre_transition_install/.blorp-bootstrap/$pre_transition_generation"
if ! cmp "$legacy_bootstrap_source/blorp-ocaml-host" \
	"$pre_transition_bootstrap_dir/blorp-bootstrap-host"
then
	fail "the dev installer must isolate an older toolchain's bootstrap host"
fi
for helper_pair in \
	"blorp-compiler-renderer blorp-bootstrap-renderer" \
	"blorp-compiler-parser blorp-bootstrap-parser" \
	"blorp-compiler-typecheck blorp-bootstrap-typecheck"
do
	set -- $helper_pair
	if ! cmp "$legacy_bootstrap_source/$1" \
		"$pre_transition_bootstrap_dir/$2"
	then
		fail "the dev installer must isolate the older $1"
	fi
done
pre_transition_smoke="$tmp_dir/pre-transition-smoke.c"
"$pre_transition_install/blorp-bootstrap-compiler" \
	__compiler-host-compile-wrapper \
	-o "$pre_transition_smoke" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$pre_transition_smoke" ]; then
	fail "the synthesized legacy bootstrap bundle must compile a source file"
fi

PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$install_dir" \
	scripts/install-dev >/dev/null
upgraded_bootstrap_generation=$(cat "$install_dir/.blorp-bootstrap/active")
if [ "$upgraded_bootstrap_generation" = "$initial_bootstrap_generation" ]; then
	fail "installing another bootstrap generation must atomically switch the active bundle"
fi
for bootstrap_file in \
	"$bootstrap_layout_name" \
	"${bootstrap_bundle_executables[@]}"
do
	if [ ! -f "$install_dir/.blorp-bootstrap/$initial_bootstrap_generation/$bootstrap_file" ]; then
		fail "an in-flight compiler must retain its complete previous bootstrap generation"
	fi
done
upgraded_smoke="$tmp_dir/upgraded-bootstrap-smoke.c"
"$install_dir/blorp-bootstrap-compiler" \
	__compiler-host-compile-wrapper \
	-o "$upgraded_smoke" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$upgraded_smoke" ]; then
	fail "the atomically activated bootstrap generation must compile a source file"
fi

legacy_root="$tmp_dir/legacy/blorp-legacy-${release_target}"
mkdir -p "$legacy_root"
cp "$fake_bin/blorp" "$legacy_root/blorp"
legacy_archive="$tmp_dir/legacy.tar.gz"
tar -C "$(dirname "$legacy_root")" -czf "$legacy_archive" "$(basename "$legacy_root")"
cp "$legacy_archive" "$downloads/$dev_asset"
write_checksum "$downloads/$dev_asset"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$tmp_dir/incomplete-install" \
	scripts/install-dev >"$tmp_dir/incomplete-install.output" 2>&1
then
	fail "the dev installer must reject an archive without private helpers"
fi
if ! grep -Fq "did not contain the complete Blorp compiler toolchain" \
	"$tmp_dir/incomplete-install.output"
then
	fail "an incomplete dev archive must produce a precise diagnostic"
fi

bootstrap_repo="$tmp_dir/bootstrap-repo"
bootstrap_downloads="$tmp_dir/bootstrap-downloads"
mkdir -p "$bootstrap_repo/scripts" "$bootstrap_repo/compiler" "$bootstrap_downloads"
cp scripts/blorp-compiler-bootstrap "$bootstrap_repo/scripts/"

bootstrap_tag=dev-aaaaaaaaaaaa
bootstrap_asset="blorp-${release_version}-${release_target}.tar.gz"
cp "$archive" "$bootstrap_downloads/$bootstrap_asset"
write_checksum "$bootstrap_downloads/$bootstrap_asset"
bootstrap_sha=$(sha256_file "$bootstrap_downloads/$bootstrap_asset")

write_bootstrap_manifest() {
	local layout="$1"
	local sha="$2"

	cat >"$bootstrap_repo/compiler/bootstrap.env" <<EOF
BLORP_BOOTSTRAP_REPO=example/blorp
BLORP_BOOTSTRAP_TAG=$bootstrap_tag
BLORP_BOOTSTRAP_VERSION=$release_version
BLORP_BOOTSTRAP_LAYOUT=$layout
BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=$sha
BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=$sha
BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=$sha
EOF
}

write_bootstrap_manifest toolchain "$bootstrap_sha"
bootstrap_cache="$tmp_dir/bootstrap-cache"
bootstrap_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path)
bootstrap_toolchain_dir=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-toolchain-dir)
bootstrap_compiler_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-compiler-path)
if [ "$bootstrap_toolchain_dir" != "$(dirname "$bootstrap_path")" ]; then
	fail "the bootstrap resolver must expose its verified complete-toolchain directory"
fi
if [ "$bootstrap_compiler_path" != "$bootstrap_toolchain_dir/blorp-bootstrap-compiler" ]; then
	fail "the bootstrap resolver must expose the dedicated immutable compiler"
fi
for executable in "${toolchain_executables[@]}"; do
	if [ ! -x "$(dirname "$bootstrap_path")/$executable" ]; then
		fail "a toolchain bootstrap must cache $executable"
	fi
done
if [ ! -f "$(dirname "$bootstrap_path")/$bootstrap_layout_name" ]; then
	fail "a toolchain bootstrap must cache the bootstrap layout manifest"
fi

printf 'corrupted bootstrap compiler\n' \
	>"$(dirname "$bootstrap_path")/blorp-bootstrap-compiler"
chmod +x "$(dirname "$bootstrap_path")/blorp-bootstrap-compiler"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-compiler-path >/dev/null
if ! cmp "$fake_bin/blorp-bootstrap-compiler" \
	"$(dirname "$bootstrap_path")/blorp-bootstrap-compiler"
then
	fail "bootstrap cache validation must repair a corrupted immutable compiler"
fi

printf 'corrupted bootstrap helper\n' \
	>"$(dirname "$bootstrap_path")/blorp-bootstrap-parser"
chmod +x "$(dirname "$bootstrap_path")/blorp-bootstrap-parser"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-compiler-path >/dev/null
if ! cmp "$fake_bin/blorp-bootstrap-parser" \
	"$(dirname "$bootstrap_path")/blorp-bootstrap-parser"
then
	fail "bootstrap cache validation must repair a corrupted immutable helper"
fi

printf 'corrupted helper\n' >"$(dirname "$bootstrap_path")/blorp-compiler-parser"
chmod +x "$(dirname "$bootstrap_path")/blorp-compiler-parser"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path >/dev/null
if ! cmp "$fake_bin/blorp-compiler-parser" \
	"$(dirname "$bootstrap_path")/blorp-compiler-parser"
then
	fail "bootstrap cache validation must repair a corrupted private helper"
fi

legacy_toolchain_root="$tmp_dir/legacy-toolchain/$archive_base"
mkdir -p "$legacy_toolchain_root"
for executable in "${current_toolchain_executables[@]}"; do
	cp "$fake_bin/$executable" "$legacy_toolchain_root/$executable"
done
legacy_toolchain_archive="$tmp_dir/legacy-toolchain.tar.gz"
tar -C "$(dirname "$legacy_toolchain_root")" -czf "$legacy_toolchain_archive" \
	"$(basename "$legacy_toolchain_root")"
cp "$legacy_toolchain_archive" "$bootstrap_downloads/$bootstrap_asset"
write_checksum "$bootstrap_downloads/$bootstrap_asset"
legacy_toolchain_sha=$(sha256_file "$bootstrap_downloads/$bootstrap_asset")
write_bootstrap_manifest toolchain "$legacy_toolchain_sha"
legacy_toolchain_compiler=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/legacy-toolchain-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-compiler-path)
if [ "$legacy_toolchain_compiler" != \
	"$(dirname "$legacy_toolchain_compiler")/blorp-ocaml-host" ]
then
	fail "a pre-transition toolchain must use its immutable OCaml host as the bootstrap compiler"
fi

cp "$legacy_archive" "$bootstrap_downloads/$bootstrap_asset"
write_checksum "$bootstrap_downloads/$bootstrap_asset"
legacy_sha=$(sha256_file "$bootstrap_downloads/$bootstrap_asset")
write_bootstrap_manifest single "$legacy_sha"
legacy_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/legacy-bootstrap-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path)
if [ ! -x "$legacy_path" ]; then
	fail "the explicit single layout must support the currently pinned legacy archive"
fi
if [ -e "$(dirname "$legacy_path")/blorp-ocaml-host" ]; then
	fail "the single bootstrap layout must not invent private helpers"
fi
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/legacy-bootstrap-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-toolchain-dir \
	>"$tmp_dir/single-toolchain-dir.output" 2>&1
then
	fail "a single-binary bootstrap must not claim to provide a complete toolchain"
fi
if ! grep -Fq "does not provide a complete compiler toolchain" \
	"$tmp_dir/single-toolchain-dir.output"
then
	fail "requesting a toolchain directory from a single bootstrap must explain the mismatch"
fi

write_bootstrap_manifest toolchain "$legacy_sha"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/incomplete-bootstrap-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
	>"$tmp_dir/incomplete-bootstrap.output" 2>&1
then
	fail "the toolchain bootstrap layout must reject an archive without helpers"
fi

echo "PASS: releases and bootstrap caches preserve the complete compiler toolchain"
