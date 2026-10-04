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
	blorp/test/runtime/memory/leak_check_baselines/sleep_cancelled_string.brp
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
bootstrap_asset="blorp-${release_target}"
cp "$release_binary" "$bootstrap_downloads/$bootstrap_asset"
bootstrap_sha=$(sha256_file "$bootstrap_downloads/$bootstrap_asset")

write_bootstrap_manifest() {
	local layout="$1"
	cat >"$bootstrap_repo/blorp/build/bootstrap.env" <<EOF
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
write_bootstrap_manifest direct
if [ "$("$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-tag)" != "$bootstrap_tag" ]; then
	fail "the bootstrap wrapper must read its default tag from bootstrap.env"
fi
overridden_tag=$(BLORP_COMPILER_BOOTSTRAP_TAG=dev-000000000000 \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-tag)
if [ "$overridden_tag" != "$bootstrap_tag" ]; then
	fail "an ambient environment variable must not override the bootstrap manifest"
fi
bootstrap_path=$(PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path)
if [ ! -x "$bootstrap_path" ]; then
	fail "the bootstrap resolver must cache the compiler"
fi
if [[ "$bootstrap_path" != */direct/* ]] ||
	! cmp "$fake_bin/blorp" "$bootstrap_path"
then
	fail "the bootstrap resolver must install the pinned direct binary"
fi
bootstrap_smoke="$tmp_dir/bootstrap-smoke.c"
"$bootstrap_path" compile --no-format \
	-o "$bootstrap_smoke" \
	blorp/test/runtime/memory/leak_check_baselines/sleep_cancelled_string.brp
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

bootstrap_marker="$(dirname "$bootstrap_path")/MANIFEST"
if ! grep -Fxq "artifact_sha256=$bootstrap_sha" "$bootstrap_marker" ||
	! grep -Fxq "file_sha256_blorp=$bootstrap_sha" "$bootstrap_marker"
then
	fail "the direct cache marker must record the downloaded binary digest"
fi
mv "$bootstrap_marker" "$bootstrap_marker.interrupted"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path >/dev/null
if [ ! -f "$bootstrap_marker" ] || ! cmp "$fake_bin/blorp" "$bootstrap_path"; then
	fail "an interrupted cache install must be repaired"
fi

wrong_sha=$(printf '%064d' 0)
write_bootstrap_manifest direct
sed "s/^BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=.*/BLORP_BOOTSTRAP_SHA256_X86_64_UNKNOWN_LINUX_GNU=$wrong_sha/" \
	"$bootstrap_repo/blorp/build/bootstrap.env" \
	>"$bootstrap_repo/blorp/build/bootstrap.env.tmp"
mv "$bootstrap_repo/blorp/build/bootstrap.env.tmp" \
	"$bootstrap_repo/blorp/build/bootstrap.env"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/bad-checksum-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
		>"$tmp_dir/bad-checksum.output" 2>&1
then
	fail "the bootstrap resolver must reject a wrong target digest"
fi
if ! grep -Fq 'failed checksum verification' "$tmp_dir/bad-checksum.output"; then
	fail "the wrong target digest must report a checksum error"
fi

write_bootstrap_manifest direct
grep -v '^BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU=' \
	"$bootstrap_repo/blorp/build/bootstrap.env" \
	>"$bootstrap_repo/blorp/build/bootstrap.env.tmp"
mv "$bootstrap_repo/blorp/build/bootstrap.env.tmp" \
	"$bootstrap_repo/blorp/build/bootstrap.env"
if "$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-id \
	>"$tmp_dir/missing-field.output" 2>&1
then
	fail "the bootstrap resolver must reject a missing target digest"
fi
if ! grep -Fq 'missing BLORP_BOOTSTRAP_SHA256_AARCH64_UNKNOWN_LINUX_GNU' \
	"$tmp_dir/missing-field.output"
then
	fail "the missing digest must identify its manifest field"
fi

write_bootstrap_manifest direct
unknown_bin="$tmp_dir/unknown-bin"
mkdir -p "$unknown_bin"
cat >"$unknown_bin/uname" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
	-m) printf '%s\n' mips64 ;;
	-s) printf '%s\n' Linux ;;
esac
SH
chmod +x "$unknown_bin/uname"
if PATH="$unknown_bin:$mock_bin:$PATH" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
		>"$tmp_dir/unknown-target.output" 2>&1
then
	fail "the bootstrap resolver must reject an unknown target"
fi
if ! grep -Fq 'Unsupported compiler bootstrap target: Linux/mips64' \
	"$tmp_dir/unknown-target.output"
then
	fail "the unknown target must report its platform"
fi

write_bootstrap_manifest single
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
		>"$tmp_dir/single-layout.output" 2>&1
then
	fail "the bootstrap resolver must reject the historical single layout"
fi
if ! grep -Fq 'unsupported layout: single' "$tmp_dir/single-layout.output"; then
	fail "the historical layout must explain why it is unsupported"
fi

write_bootstrap_manifest toolchain
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/unknown-layout-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
		>"$tmp_dir/toolchain-layout.output" 2>&1
then
	fail "the bootstrap resolver must reject an unknown layout"
fi
if ! grep -Fq 'unsupported layout: toolchain' "$tmp_dir/toolchain-layout.output"; then
	fail "the unknown layout must identify the unsupported value"
fi

if BLORP_RELEASE_BINARY="$tmp_dir/missing-blorp" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/missing-binary-dist" \
	>"$tmp_dir/missing-binary.output" 2>&1
then
	fail "release packaging must reject a missing compiler"
fi

echo "PASS: releases install one direct compiler binary and bootstrap caches remain valid"
