# Releases

Blorp publishes binaries through GitHub Releases.

## Channels

- `dev` is a moving prerelease produced after `CI` passes on `main`.
- `dev-<short-sha>` is an immutable prerelease produced from the same successful
  `main` build as `dev`.
- `vX.Y.Z...` tags produce immutable versioned releases.

Dev builds are for dogfooding, bisecting, and early testing. Link new users to
versioned preview releases once a preview has been cut.

## Latest Dev Build

The latest successful `main` build is published as a moving `dev` release.
The installer detects the matching binary for your system and puts it at the
requested path, usually `$HOME/.local/bin/blorp`.

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev | bash
```

Remove it with:

```bash
rm -f "$HOME/.local/bin/blorp"
```

Manual downloads are available from:

```text
https://github.com/kablorp/blorp/releases/tag/dev
```

To pin a specific successful `main` build, install from the immutable dev tag
shown in the matching release notes:

```bash
curl -fsSL https://raw.githubusercontent.com/kablorp/blorp/main/scripts/install-dev |
  BLORP_INSTALL_TAG=dev-<short-sha> bash
```

## Versioning

Use SemVer-style versions while Blorp is pre-0.1.0:

- Preview release: `v0.0.1-preview.1`
- Patch release: `v0.0.2`
- Main dev build: generated as `0.0.1-dev.<short-sha>`
- Immutable dev tag: `dev-<short-sha>`

The source fallback version lives in `blorp/build/VERSION`. Release workflows
override it at build time with
`BLORP_BUILD_VERSION`, so `blorp --version` reflects the release tag or dev
commit without editing source for every build.

`blorp --version` reports:

- language/compiler version
- commit SHA
- target triple
- release channel
- dirty state
- embedded standard-library hash

## Binary Assets

Release assets are named:

```text
blorp-<target>
```

The release tag carries the version, so each release contains exactly one file
per supported target. The moving `dev` tag provides stable download URLs, while
immutable `dev-<short-sha>` and `v*` tags preserve exact compiler builds.

The initial targets are:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `aarch64-apple-darwin` or `x86_64-apple-darwin`, depending on the macOS runner

Target mapping:

| System | Target |
|--------|--------|
| macOS Apple Silicon | `aarch64-apple-darwin` |
| macOS Intel | `x86_64-apple-darwin` |
| Linux x86_64 | `x86_64-unknown-linux-gnu` |
| Linux ARM64 | `aarch64-unknown-linux-gnu` |

Manual downloads need executable permission before use, for example
`chmod +x blorp-aarch64-apple-darwin`.

## Operational Notes

- Do not treat dev builds as stable preview releases.
- `dev` is intentionally mutable and always points at the latest successful
  `main` build.
- Push `v*` release tags only after the target commit has passed the intended
  CI/premerge gate; tag releases build directly from the pushed tag.
- Do not mutate `dev-*` or `v*` release assets after publishing; create a new
  tag instead.
- Downloading `blorp` does not remove the need for a local C toolchain. `blorp
  run` and `blorp compile` still invoke the platform C compiler.
- If macOS distribution starts warning users about unidentified binaries, add
  code signing and notarization as a dedicated release-hardening workstream.

## Preview Validation

Before cutting a preview, run `scripts/premerge-gate` and
`scripts/test package` (see
[`scripts/README.md`](../scripts/README.md#premerge-gate)) and check every
README-supported example restored under `examples/`. Do not gate a preview on
ignored `scratch/` files. A nonzero exit, timeout, leaked background process,
or untriaged generated-C warning is a gate failure. The premerge gate includes
the broad compiler, tool, standard-library, runtime, leak, doctest, CLI, and
LSP gates, codegen audit, preview CLI/runtime smoke,
sanitizers, and platform validation when available.
The package lifecycle gate is separate and must not be skipped just because
the premerge gate passed.
When preview examples are restored, record their exact check, run, and format
commands here so the release gate is explicit and repeatable.
The repository README currently names `examples/hello.brp`:

```bash
bin/blorp check --no-format examples/hello.brp
bin/blorp run --timeout 5 --no-format examples/hello.brp
bin/blorp format --check examples/hello.brp
```

For a narrow manual smoke while diagnosing a failure, use temporary outputs:

```bash
tmpc=$(mktemp "${TMPDIR:-/tmp}/blorp-preview.XXXXXX.c")
smoke=$(mktemp "${TMPDIR:-/tmp}/blorp-preview.XXXXXX.brp")
lsp_out=$(mktemp "${TMPDIR:-/tmp}/blorp-lsp-preview.XXXXXX.out")
trap 'rm -f "$tmpc" "$smoke" "$lsp_out"' EXIT

cat > "$smoke" <<'BRP'
func main(args: List[String]) -> Int:
	print("preview smoke")
	0
BRP

bin/blorp check --no-format "$smoke"
bin/blorp compile --no-format -o "$tmpc" "$smoke"
bin/blorp run --timeout 5 --no-format "$smoke"
bin/blorp test --warmup-only
bin/blorp test --timeout 5 blorp/test/runtime/types/test_bool.brp
bin/blorp test --leak-check --suite --timeout 5 \
  blorp/test/runtime/memory/leak_check_baselines/sleep_cancelled_string.brp
bin/blorp test --sanitize --timeout 5 blorp/test/runtime/types/test_bool.brp
bin/blorp lsp </dev/null >"$lsp_out"
```

The environment smoke also checks the timeout, standard-library, no-format,
and sanitizer routes:

```bash
env BLORP_TIMEOUT=5 bin/blorp test blorp/test/runtime/types/test_bool.brp
env BLORP_STD=standard_library/src BLORP_NO_FORMAT=1 \
  bin/blorp check blorp/test/runtime/types/test_bool.brp
env BLORP_SANITIZE=1 bin/blorp test --timeout 5 \
  blorp/test/runtime/types/test_bool.brp
```

The codegen audit owns the warning sweep because normal generated-C
compile/test routes suppress noisy warnings. Clang `-Wparentheses-equality`
from extra defensive comparison parentheses is currently benign;
`-Wunsequenced` and `-Wincompatible-pointer-types` are not accepted. Review
any new warning before preview rather than adding a blanket suppression.
Test-artifact timeout defaults and overrides live in
[`scripts/README.md`](../scripts/README.md#test-gates).
