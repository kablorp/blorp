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
The installer detects the matching binary for your system, verifies its
`.sha256` file, and puts one file at the requested path, usually
`$HOME/.local/bin/blorp`.

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

The source fallback version lives in `compiler/lib/version.ml` as
`source_version`. Release workflows override it at build time with
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
blorp-<version>-<target>.tar.gz
blorp-<version>-<target>.tar.gz.sha256
```

Dev releases publish stable asset aliases for copy-paste download URLs. The
moving `dev` tag and each immutable `dev-<short-sha>` tag both include these
aliases:

```text
blorp-dev-<target>.tar.gz
blorp-dev-<target>.tar.gz.sha256
```

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

Each archive contains:

- `blorp`
- `README.md`
- `LICENSE`

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
