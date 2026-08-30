#!/usr/bin/env bash
# Regression tests for single-binary release, installation, and bootstrapping.

set -euo pipefail

cd "$(dirname "$0")/../../.."

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
		printf 'commit: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
		printf 'target: x86_64-unknown-linux-gnu\n'
		printf 'channel: dev\n'
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
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$release_dir" >/dev/null

release_binary="$release_dir/blorp-${release_target}"
if [ ! -x "$release_binary" ]; then
	fail "release output must be the executable Blorp compiler"
fi
if [ "$(find "$release_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')" -ne 1 ]; then
	fail "release output must contain exactly one binary per target"
fi
if ! cmp "$fake_bin/blorp" "$release_binary"; then
	fail "release output must preserve the selected compiler"
fi

isolated_output="$tmp_dir/isolated-compile.c"
"$release_binary" compile --no-format \
	-o "$isolated_output" \
	blorp/test/runtime/memory/leak_check_baselines/empty_main.brp
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

dev_asset="blorp-${release_target}"
cp "$release_binary" "$downloads/$dev_asset"

legacy_dev_asset="blorp-dev-${release_target}.tar.gz"
legacy_dev_base="blorp-${release_version}-${release_target}"
legacy_dev_root="$tmp_dir/legacy-dev/$legacy_dev_base"
mkdir -p "$legacy_dev_root"
cp "$release_binary" "$legacy_dev_root/blorp"
tar -C "$tmp_dir/legacy-dev" -czf "$downloads/$legacy_dev_asset" \
	"$legacy_dev_base"
write_checksum "$downloads/$legacy_dev_asset"

install_url=$(PATH="$mock_bin:$PATH" \
	BLORP_INSTALL_REPO=example/blorp \
	BLORP_INSTALL_TAG=dev-test \
	scripts/install-dev --print-url)
if [ "$install_url" != \
	"https://github.com/example/blorp/releases/download/dev-test/$dev_asset" ]
then
	fail "the dev installer must resolve the direct target binary"
fi
install_dir="$tmp_dir/install"
mkdir -p "$install_dir/.blorp-bootstrap/old-generation"
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

printf 'not an executable\n' >"$downloads/$dev_asset"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$install_dir" \
	scripts/install-dev >"$tmp_dir/invalid-install.output" 2>&1
then
	fail "the dev installer must reject an invalid downloaded binary"
fi
if ! cmp "$fake_bin/blorp" "$install_dir/blorp"; then
	fail "a rejected download must not replace the installed compiler"
fi
cp "$release_binary" "$downloads/$dev_asset"

sed 's/target: x86_64-unknown-linux-gnu/target: aarch64-unknown-linux-gnu/' \
	"$release_binary" >"$downloads/$dev_asset"
chmod +x "$downloads/$dev_asset"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$install_dir" \
	scripts/install-dev >"$tmp_dir/wrong-target-install.output" 2>&1
then
	fail "the dev installer must reject a compiler for another target"
fi
if ! cmp "$fake_bin/blorp" "$install_dir/blorp"; then
	fail "a wrong-target download must not replace the installed compiler"
fi
cp "$release_binary" "$downloads/$dev_asset"

legacy_install_dir="$tmp_dir/legacy-install"
mv "$downloads/$dev_asset" "$downloads/$dev_asset.saved"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$legacy_install_dir" \
	scripts/install-dev >/dev/null
if ! cmp "$fake_bin/blorp" "$legacy_install_dir/blorp"; then
	fail "the dev installer must remain compatible with the previous release assets"
fi
mv "$downloads/$dev_asset.saved" "$downloads/$dev_asset"

bootstrap_repo="$tmp_dir/bootstrap-repo"
bootstrap_downloads="$tmp_dir/bootstrap-downloads"
mkdir -p "$bootstrap_repo/scripts" "$bootstrap_repo/blorp/build" "$bootstrap_downloads"
cp scripts/blorp-compiler-bootstrap "$bootstrap_repo/scripts/"
bootstrap_tag=dev-aaaaaaaaaaaa
bootstrap_asset="blorp-${release_version}-${release_target}.tar.gz"
archive_base="blorp-${release_version}-${release_target}"
archive_root="$tmp_dir/bootstrap-archive/$archive_base"
mkdir -p "$archive_root"
cp "$release_binary" "$archive_root/blorp"
tar -C "$tmp_dir/bootstrap-archive" -czf \
	"$bootstrap_downloads/$bootstrap_asset" "$archive_base"
write_checksum "$bootstrap_downloads/$bootstrap_asset"
bootstrap_sha=$(sha256_file "$bootstrap_downloads/$bootstrap_asset")

write_bootstrap_manifest() {
	local layout="$1"
	local artifact_sha="${2:-$bootstrap_sha}"
	cat >"$bootstrap_repo/blorp/build/bootstrap.env" <<EOF
BLORP_BOOTSTRAP_REPO=example/blorp
BLORP_BOOTSTRAP_TAG=$bootstrap_tag
BLORP_BOOTSTRAP_VERSION=$release_version
BLORP_BOOTSTRAP_LAYOUT=$layout
BLORP_BOOTSTRAP_SHA256_AARCH64_APPLE_DARWIN=$artifact_sha
BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=$artifact_sha
BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=$artifact_sha
EOF
}

bootstrap_cache="$tmp_dir/bootstrap-cache"
legacy_bootstrap_dir="$bootstrap_cache/$bootstrap_tag/toolchain/$release_target/$bootstrap_sha"
mkdir -p "$legacy_bootstrap_dir"
printf 'legacy compiler\n' >"$legacy_bootstrap_dir/blorp"
chmod +x "$legacy_bootstrap_dir/blorp"

write_bootstrap_manifest single
single_bootstrap_dir="$bootstrap_cache/$bootstrap_tag/single/$release_target/$bootstrap_sha"
mkdir -p "$single_bootstrap_dir"
cp "$fake_bin/blorp" "$single_bootstrap_dir/blorp"
chmod +x "$single_bootstrap_dir/blorp"
single_binary_sha=$(sha256_file "$single_bootstrap_dir/blorp")
cat >"$single_bootstrap_dir/MANIFEST" <<EOF
repo=example/blorp
tag=$bootstrap_tag
version=$release_version
layout=single
target=$release_target
archive_sha256=$bootstrap_sha
file_sha256_blorp=$single_binary_sha
EOF
mv "$bootstrap_downloads/$bootstrap_asset" \
	"$bootstrap_downloads/$bootstrap_asset.saved"
bootstrap_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path)
mv "$bootstrap_downloads/$bootstrap_asset.saved" \
	"$bootstrap_downloads/$bootstrap_asset"
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
	blorp/test/runtime/memory/leak_check_baselines/empty_main.brp
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

direct_bootstrap_asset="blorp-${release_target}"
cp "$release_binary" "$bootstrap_downloads/$direct_bootstrap_asset"
direct_bootstrap_sha=$(sha256_file "$bootstrap_downloads/$direct_bootstrap_asset")
write_bootstrap_manifest direct "$direct_bootstrap_sha"
direct_bootstrap_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path)
if [[ "$direct_bootstrap_path" != */direct/* ]] ||
	! cmp "$fake_bin/blorp" "$direct_bootstrap_path"
then
	fail "the bootstrap resolver must install a pinned direct binary"
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
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/missing-binary-dist" \
	>"$tmp_dir/missing-binary.output" 2>&1
then
	fail "release packaging must reject a missing compiler"
fi

echo "PASS: releases install one direct compiler binary and bootstrap caches remain valid"
