#!/usr/bin/env bash
# Regression tests for single-binary release, installation, and bootstrapping.

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
cat >"$fake_bin/blorp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
	compile)
		shift
		output=""
		source_file=""
		while [ $# -gt 0 ]; do
			case "$1" in
				--no-format) shift ;;
				-o) output="${2:?missing output path}"; shift 2 ;;
				-*) echo "unexpected compile option: $1" >&2; exit 1 ;;
				*) source_file="$1"; shift ;;
			esac
		done
		if [ -z "$output" ] || [ ! -f "$source_file" ]; then
			echo "compile requires an output and an existing source file" >&2
			exit 1
		fi
		printf 'int main(void) { return 0; }\n' >"$output"
		;;
	--version)
		printf 'blorp 0.0.1-dev.aaaaaaaaaaaa\n'
		;;
	*)
		echo "unexpected fake blorp command: ${1:-<missing>}" >&2
		exit 1
		;;
esac
SH
chmod +x "$fake_bin/blorp"

release_version=0.0.1-dev.aaaaaaaaaaaa
release_target=x86_64-unknown-linux-gnu
release_dir="$tmp_dir/dist"
BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$release_dir" >/dev/null

archive_base="blorp-${release_version}-${release_target}"
archive="$release_dir/$archive_base.tar.gz"
extract_dir="$tmp_dir/extracted-release"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"
package_dir="$extract_dir/$archive_base"
if [ ! -x "$package_dir/blorp" ]; then
	fail "release archive must contain the Blorp compiler"
fi
if find "$package_dir" -maxdepth 1 -type f -name 'blorp-*' | grep -q .; then
	fail "release archive must not contain private compiler executables"
fi
if ! cmp "$fake_bin/blorp" "$package_dir/blorp"; then
	fail "release archive must preserve the selected compiler"
fi

isolated_output="$tmp_dir/isolated-compile.c"
"$package_dir/blorp" compile --no-format \
	-o "$isolated_output" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$isolated_output" ]; then
	fail "the packaged compiler must compile in isolation"
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
		-f|-s|-S|-L|-fsSL) shift ;;
		-o) output="$2"; shift 2 ;;
		*) url="$1"; shift ;;
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
mkdir -p "$install_dir/.blorp-bootstrap/old-generation"
for retired in \
	blorp-ocaml-host \
	blorp-compiler-parser \
	blorp-compiler-typecheck \
	blorp-compiler-renderer
do
	printf 'retired helper\n' >"$install_dir/$retired"
done
printf 'retired launcher\n' >"$install_dir/blorp-bootstrap-compiler"
printf 'retired bundle\n' >"$install_dir/.blorp-bootstrap/old-generation/worker"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$install_dir" \
	scripts/install-dev >/dev/null
if [ ! -x "$install_dir/blorp" ]; then
	fail "the dev installer must install the compiler"
fi
for retired in "$install_dir"/blorp-* "$install_dir/.blorp-bootstrap"; do
	if [ -e "$retired" ]; then
		fail "the dev installer must remove retired compiler infrastructure"
	fi
done

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
	cat >"$bootstrap_repo/compiler/bootstrap.env" <<EOF
BLORP_BOOTSTRAP_REPO=example/blorp
BLORP_BOOTSTRAP_TAG=$bootstrap_tag
BLORP_BOOTSTRAP_VERSION=$release_version
BLORP_BOOTSTRAP_LAYOUT=$layout
BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=$bootstrap_sha
BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=$bootstrap_sha
BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=$bootstrap_sha
EOF
}

bootstrap_cache="$tmp_dir/bootstrap-cache"
legacy_bootstrap_dir="$bootstrap_cache/$bootstrap_tag/toolchain/$release_target/$bootstrap_sha"
mkdir -p "$legacy_bootstrap_dir"
printf 'legacy compiler\n' >"$legacy_bootstrap_dir/blorp"
printf 'legacy helper\n' >"$legacy_bootstrap_dir/blorp-ocaml-host"
chmod +x "$legacy_bootstrap_dir/blorp" "$legacy_bootstrap_dir/blorp-ocaml-host"

write_bootstrap_manifest single
bootstrap_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path)
if [ ! -x "$bootstrap_path" ]; then
	fail "the bootstrap resolver must cache the compiler"
fi
if [ "$bootstrap_path" = "$legacy_bootstrap_dir/blorp" ] ||
	[[ "$bootstrap_path" != */single/* ]]
then
	fail "the single-binary layout must not reuse a legacy toolchain cache"
fi
bootstrap_smoke="$tmp_dir/bootstrap-smoke.c"
"$bootstrap_path" compile --no-format \
	-o "$bootstrap_smoke" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$bootstrap_smoke" ]; then
	fail "the pinned compiler must compile through its ordinary command"
fi

printf 'corrupted compiler\n' >"$bootstrap_path"
chmod +x "$bootstrap_path"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path >/dev/null
if ! cmp "$fake_bin/blorp" "$bootstrap_path"; then
	fail "bootstrap cache validation must repair a corrupted compiler"
fi

write_bootstrap_manifest toolchain
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/single-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
		>"$tmp_dir/toolchain-layout.output" 2>&1
then
	fail "the bootstrap resolver must reject an unknown layout"
fi

if BLORP_RELEASE_BINARY="$tmp_dir/missing-blorp" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/missing-binary-dist" \
	>"$tmp_dir/missing-binary.output" 2>&1
then
	fail "release packaging must reject a missing compiler"
fi

echo "PASS: releases and bootstrap caches preserve the single compiler binary"
