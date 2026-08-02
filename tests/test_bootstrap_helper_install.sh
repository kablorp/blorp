#!/usr/bin/env bash
# Regression tests for installing the pinned compiler bridge helper generation.

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/blorp-bootstrap-helper-install.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

toolchain_dir="$tmp_dir/toolchain"
install_dir="$tmp_dir/install"
stamp_path="$tmp_dir/state/installed-bootstrap.id"
installer="$PWD/scripts/install-compiler-bootstrap-helpers"
helpers=(
	blorp-compiler-renderer
	blorp-compiler-parser
)

mkdir -p "$toolchain_dir" "$install_dir"
printf 'retired installed worker\n' > "$install_dir/blorp-compiler-typecheck"
chmod +x "$install_dir/blorp-compiler-typecheck"
for helper in "${helpers[@]}"; do
	printf 'first generation: %s\n' "$helper" > "$toolchain_dir/$helper"
	chmod +x "$toolchain_dir/$helper"
done

"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-first schema-v1"
if [ -e "$install_dir/blorp-compiler-typecheck" ]; then
	fail "installation did not remove the retired typecheck worker"
fi

for helper in "${helpers[@]}"; do
	if [ ! -x "$install_dir/$helper" ] ||
		! cmp -s "$toolchain_dir/$helper" "$install_dir/$helper"
	then
		fail "initial installation did not copy $helper exactly"
	fi
done
if [ "$(cat "$stamp_path")" != "dev-first schema-v1" ]; then
	fail "initial installation did not record the helper generation"
fi

rm "$install_dir/blorp-compiler-parser"
"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-first schema-v1"
if ! cmp -s \
	"$toolchain_dir/blorp-compiler-parser" \
	"$install_dir/blorp-compiler-parser"
then
	fail "installation did not repair a missing helper"
fi

printf 'corrupt\n' > "$install_dir/blorp-compiler-renderer"
chmod +x "$install_dir/blorp-compiler-renderer"
"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-first schema-v1"
if ! cmp -s \
	"$toolchain_dir/blorp-compiler-renderer" \
	"$install_dir/blorp-compiler-renderer"
then
	fail "installation trusted the stamp instead of repairing corrupted helper bytes"
fi

retired_typecheck_worker="$toolchain_dir/blorp-compiler-typecheck"
printf 'retired benchmark worker\n' > "$retired_typecheck_worker"
chmod +x "$retired_typecheck_worker"
"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-first schema-v1"
if [ -e "$install_dir/blorp-compiler-typecheck" ]; then
	fail "installation copied the benchmark-only typecheck worker"
fi

rm "$install_dir/blorp-compiler-parser"
mkdir "$install_dir/blorp-compiler-parser"
if "$installer" \
	"$toolchain_dir" \
	"$install_dir" \
	"$stamp_path" \
	"dev-first schema-v1" \
	>"$tmp_dir/non-regular.output" 2>&1
then
	fail "installation accepted a non-regular helper target"
fi
if ! grep -Fq "Refusing to replace non-regular compiler helper target" \
	"$tmp_dir/non-regular.output"
then
	fail "non-regular helper rejection did not explain the invalid target"
fi
rm -rf "$install_dir/blorp-compiler-parser"
"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-first schema-v1"

for helper in "${helpers[@]}"; do
	printf 'second generation: %s\n' "$helper" > "$toolchain_dir/$helper"
done
"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-second schema-v1"
for helper in "${helpers[@]}"; do
	if ! cmp -s "$toolchain_dir/$helper" "$install_dir/$helper"; then
		fail "pin rotation did not replace $helper"
	fi
done
if [ "$(cat "$stamp_path")" != "dev-second schema-v1" ]; then
	fail "pin rotation did not update the helper generation"
fi

mock_bin="$tmp_dir/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/cp" <<'MOCK'
#!/usr/bin/env bash
echo "unexpected helper copy" >&2
exit 99
MOCK
chmod +x "$mock_bin/cp"
PATH="$mock_bin:$PATH" \
	"$installer" "$toolchain_dir" "$install_dir" "$stamp_path" "dev-second schema-v1"

echo "PASS: pinned compiler helper installation is complete and self-repairing"
