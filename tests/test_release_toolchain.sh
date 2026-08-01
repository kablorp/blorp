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

toolchain_executables=(
	blorp
	blorp-ocaml-host
	blorp-compiler-renderer
	blorp-compiler-parser
	blorp-compiler-typecheck
)

fake_bin="$tmp_dir/release-bin"
prepared_workers="$tmp_dir/prepared-workers"
mkdir -p "$fake_bin" "$prepared_workers"
cp /bin/sh "$fake_bin/blorp-ocaml-host"
for worker in \
	blorp-compiler-renderer \
	blorp-compiler-parser \
	blorp-compiler-typecheck
do
	printf '#!/bin/sh\n# current %s\nexit 0\n' "$worker" >"$fake_bin/$worker"
	chmod +x "$fake_bin/$worker"
done

cat >"$fake_bin/blorp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
	__compiler-bridge-prepare)
		if [ "${BLORP_OCAML_HOST_BIN:-}" != "${BLORP_TEST_EXPECTED_OCAML_HOST:?}" ]; then
			echo "prepare did not receive the selected OCaml host" >&2
			exit 1
		fi
		mkdir -p "$2"
		cp "${BLORP_TEST_WORKER_DIR:?}/blorp-compiler-renderer" \
			"$2/compiler_renderer_bridge.bin"
		cp "${BLORP_TEST_WORKER_DIR:?}/blorp-compiler-parser" \
			"$2/compiler_parser_bridge.bin"
		cp "${BLORP_TEST_WORKER_DIR:?}/blorp-compiler-typecheck" \
			"$2/compiler_typecheck_bridge.bin"
		: >"${BLORP_TEST_PREPARE_MARKER:?}"
		exit 0
		;;
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
		exit 0
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
prepare_marker="$tmp_dir/prepare-called"
BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	BLORP_TEST_PREPARE_MARKER="$prepare_marker" \
	BLORP_TEST_EXPECTED_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_TEST_WORKER_DIR="$fake_bin" \
	scripts/package-release "$release_dir" >/dev/null
if [ ! -e "$prepare_marker" ]; then
	fail "release packaging must prepare one coherent current worker set"
fi

archive_base="blorp-${release_version}-${release_target}"
archive="$release_dir/$archive_base.tar.gz"
extract_dir="$tmp_dir/extracted-release"
mkdir -p "$extract_dir"
tar -xzf "$archive" -C "$extract_dir"
package_dir="$extract_dir/$archive_base"
for executable in "${toolchain_executables[@]}"; do
	if [ ! -x "$package_dir/$executable" ]; then
		fail "release archive must contain executable $executable"
	fi
done
if ! cmp "$fake_bin/blorp" "$package_dir/blorp" ||
	! cmp "$fake_bin/blorp-ocaml-host" "$package_dir/blorp-ocaml-host"
then
	fail "release archive must preserve the selected public binary and OCaml host"
fi
isolated_compiler_dir="$tmp_dir/isolated-compiler"
mkdir -p "$isolated_compiler_dir"
cp "$package_dir/blorp" "$isolated_compiler_dir/blorp"
isolated_output="$tmp_dir/isolated-compile.c"
"$isolated_compiler_dir/blorp" compile --no-format \
	-o "$isolated_output" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$isolated_output" ]; then
	fail "the packaged public compiler must compile without private workers"
fi
for retired in "$package_dir"/blorp-bootstrap-*; do
	if [ -e "$retired" ]; then
		fail "release archive must not contain retired bootstrap artifact $(basename "$retired")"
	fi
done

override_dir="$tmp_dir/override-workers"
mkdir -p "$override_dir"
for worker in \
	blorp-compiler-renderer \
	blorp-compiler-parser \
	blorp-compiler-typecheck
do
	printf '#!/bin/sh\n# override %s\nexit 0\n' "$worker" >"$override_dir/$worker"
	chmod +x "$override_dir/$worker"
done
override_release_dir="$tmp_dir/override-dist"
BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_OCAML_HOST="$fake_bin/blorp-ocaml-host" \
	BLORP_RELEASE_RENDERER_BRIDGE="$override_dir/blorp-compiler-renderer" \
	BLORP_RELEASE_PARSER_BRIDGE="$override_dir/blorp-compiler-parser" \
	BLORP_RELEASE_TYPECHECK_BRIDGE="$override_dir/blorp-compiler-typecheck" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$override_release_dir" >/dev/null
override_extract="$tmp_dir/override-extract"
mkdir -p "$override_extract"
tar -xzf "$override_release_dir/$archive_base.tar.gz" -C "$override_extract"
for worker in \
	blorp-compiler-renderer \
	blorp-compiler-parser \
	blorp-compiler-typecheck
do
	if ! cmp "$override_dir/$worker" "$override_extract/$archive_base/$worker"; then
		fail "release packaging must preserve the selected $worker"
	fi
done

if BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_RENDERER_BRIDGE="$fake_bin/blorp-compiler-renderer" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/partial-dist" \
	>"$tmp_dir/partial.output" 2>&1
then
	fail "release packaging must reject partial worker overrides"
fi
if ! grep -Fq "must be provided together" "$tmp_dir/partial.output"; then
	fail "partial worker overrides must produce a precise diagnostic"
fi

if BLORP_RELEASE_BINARY="$fake_bin/blorp" \
	BLORP_RELEASE_OCAML_HOST="$tmp_dir/missing-host" \
	BLORP_RELEASE_VERSION="$release_version" \
	BLORP_RELEASE_TARGET="$release_target" \
	scripts/package-release "$tmp_dir/missing-host-dist" \
	>"$tmp_dir/missing-host.output" 2>&1
then
	fail "release packaging must reject a missing OCaml host"
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
printf 'retired launcher\n' >"$install_dir/blorp-bootstrap-compiler"
printf 'retired bundle\n' >"$install_dir/.blorp-bootstrap/old-generation/worker"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$install_dir" \
	scripts/install-dev >/dev/null
for executable in "${toolchain_executables[@]}"; do
	if [ ! -x "$install_dir/$executable" ]; then
		fail "the dev installer must install $executable"
	fi
done
if [ -e "$install_dir/blorp-bootstrap-compiler" ] ||
	[ -e "$install_dir/.blorp-bootstrap" ]
then
	fail "the dev installer must remove the retired private bootstrap bundle"
fi

incomplete_root="$tmp_dir/incomplete/$archive_base"
mkdir -p "$incomplete_root"
cp "$fake_bin/blorp" "$incomplete_root/blorp"
incomplete_archive="$tmp_dir/incomplete.tar.gz"
tar -C "$(dirname "$incomplete_root")" -czf "$incomplete_archive" \
	"$(basename "$incomplete_root")"
cp "$incomplete_archive" "$downloads/$dev_asset"
write_checksum "$downloads/$dev_asset"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$downloads" \
	BLORP_INSTALL_DIR="$tmp_dir/incomplete-install" \
	scripts/install-dev >"$tmp_dir/incomplete-install.output" 2>&1
then
	fail "the dev installer must reject an archive without private workers"
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
	fail "the bootstrap resolver must expose its verified toolchain directory"
fi
bootstrap_smoke="$tmp_dir/bootstrap-smoke.c"
"$bootstrap_path" compile --no-format \
	-o "$bootstrap_smoke" \
	tests/test_blorp/memory/leak_check_baselines/empty_main.brp
if [ ! -s "$bootstrap_smoke" ]; then
	fail "the pinned public compiler must compile through its ordinary command"
fi
for executable in "${toolchain_executables[@]}"; do
	if [ ! -x "$bootstrap_toolchain_dir/$executable" ]; then
		fail "the bootstrap resolver must cache $executable"
	fi
done
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-compiler-path \
	>"$tmp_dir/retired-option.output" 2>&1
then
	fail "the bootstrap resolver must reject the retired compiler-wrapper option"
fi

printf 'corrupted public compiler\n' >"$bootstrap_path"
chmod +x "$bootstrap_path"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path >/dev/null
if ! cmp "$fake_bin/blorp" "$bootstrap_path"; then
	fail "bootstrap cache validation must repair a corrupted public compiler"
fi

printf 'corrupted parser worker\n' >"$bootstrap_toolchain_dir/blorp-compiler-parser"
chmod +x "$bootstrap_toolchain_dir/blorp-compiler-parser"
PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$bootstrap_cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path >/dev/null
if ! cmp "$fake_bin/blorp-compiler-parser" \
	"$bootstrap_toolchain_dir/blorp-compiler-parser"
then
	fail "bootstrap cache validation must repair a corrupted private worker"
fi

write_bootstrap_manifest single "$bootstrap_sha"
if PATH="$mock_bin:$PATH" \
	BLORP_TEST_DOWNLOAD_DIR="$bootstrap_downloads" \
	BLORP_COMPILER_BOOTSTRAP_CACHE_DIR="$tmp_dir/single-cache" \
	"$bootstrap_repo/scripts/blorp-compiler-bootstrap" --print-path \
	>"$tmp_dir/single-layout.output" 2>&1
then
	fail "the bootstrap resolver must reject the retired single-binary layout"
fi

echo "PASS: releases and bootstrap caches preserve the current compiler toolchain"
