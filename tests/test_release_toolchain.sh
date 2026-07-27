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
toolchain_executables=(
	blorp
	blorp-ocaml-host
	blorp-ocaml-middle
	blorp-compiler-renderer
	blorp-compiler-parser
	blorp-compiler-typecheck
)
for executable in "${toolchain_executables[@]}"; do
	cp /bin/sh "$fake_bin/$executable"
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

for executable in "${toolchain_executables[@]}"; do
	if ! cmp "$fake_bin/$executable" "$install_dir/$executable"; then
		fail "the dev installer must install $executable from the archive"
	fi
done

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
if [ "$bootstrap_toolchain_dir" != "$(dirname "$bootstrap_path")" ]; then
	fail "the bootstrap resolver must expose its verified complete-toolchain directory"
fi
for executable in "${toolchain_executables[@]}"; do
	if [ ! -x "$(dirname "$bootstrap_path")/$executable" ]; then
		fail "a toolchain bootstrap must cache $executable"
	fi
done

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
