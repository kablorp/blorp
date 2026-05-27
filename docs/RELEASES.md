# Releases

Blorp publishes binaries through GitHub Releases.

## Channels

- `canary` is a moving prerelease produced after `CI` passes on `main`.
- `vX.Y.Z...` tags produce immutable versioned releases.

Canary builds are for dogfooding and early testing. Link new users to tagged
preview releases once a preview has been cut.

## Versioning

Use SemVer-style versions while Blorp is pre-0.1.0:

- Preview release: `v0.0.1-preview.1`
- Patch release: `v0.0.2`
- Main canary: generated as `0.0.1-dev.<short-sha>`

The source fallback version lives in `compiler/lib/version.ml` as
`source_version`. Release workflows override it at build time with
`BLORP_BUILD_VERSION`, so `blorp --version` reflects the release tag or canary
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

The initial targets are:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `aarch64-apple-darwin` or `x86_64-apple-darwin`, depending on the macOS runner

Each archive contains:

- `blorp`
- `README.md`
- `LICENSE`

## Operational Notes

- Do not treat canaries as stable preview releases.
- Do not mutate tagged release assets after publishing; create a new tag instead.
- Downloading `blorp` does not remove the need for a local C toolchain. `blorp
  run` and `blorp compile` still invoke the platform C compiler.
- If macOS distribution starts warning users about unidentified binaries, add
  code signing and notarization as a dedicated release-hardening workstream.
