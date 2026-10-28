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
bin/blorp test --timeout 5 blorp/test/test_runtime/test_types/test_bool.brp
bin/blorp test --leak-check --suite --timeout 5 \
  blorp/test/test_runtime/test_memory/leak_check_baselines/sleep_cancelled_string.brp
bin/blorp test --sanitize --timeout 5 blorp/test/test_runtime/test_types/test_bool.brp
bin/blorp lsp </dev/null >"$lsp_out"
```

The preview smoke also checks the `--std-dir` route:

```bash
bin/blorp check --no-format --std-dir standard_library/src \
  blorp/test/test_runtime/test_types/test_bool.brp
```

The codegen audit owns the warning sweep because normal generated-C
compile/test routes suppress noisy warnings. Clang `-Wparentheses-equality`
from extra defensive comparison parentheses is currently benign;
`-Wunsequenced` and `-Wincompatible-pointer-types` are not accepted. Review
any new warning before preview rather than adding a blanket suppression.
Test-artifact timeout defaults and overrides live in
[`scripts/README.md`](../scripts/README.md#test-gates).

## Blorp 2 bootstrap seeds

Blorp 2 seeds use `.github/workflows/blorp2-seed.yml`, separately from legacy
CLI releases. After the reviewed source/library integration is committed
and its active self-hosted qualification has an accepted outcome with deferred
coverage disclosed, Root can create
and push an immutable tag with SSH credentials that trigger Actions:

```bash
source_sha=$(git rev-parse HEAD)
seed_tag="blorp2-seed-${source_sha:0:12}"
git tag "$seed_tag" "$source_sha"
git push origin "refs/tags/$seed_tag"
```

The workflow validates the tag against the actual source commit and the three
native targets: macOS ARM64 on macOS 15, Linux x64 and Linux ARM64 on Ubuntu 24.04.
The workflow uses no legacy host. The pinned B2 seed generates reference A,
then A emits compiler C,
Clang links self-built B in normal/diagnostic modes, and B reproduces that C.
Only B normal is published as `blorp2-<target>`. The explicit self-hosted
components, selected native e2e cases, process-runtime lifecycle checks,
strict compiler accounting and ordinary-main strict smoke must pass.
Unported unit/runtime/grammar/tooling and remaining native e2e cases are DEFERRED;
their sources remain for incremental ports. Qualification metadata must state
that boundary, without claiming a full native correctness/resource PASS.
Each platform also compares every maintained accepted/rejected fixture under A/B:
exit status, stdout, stderr and emitted-C presence/bytes must match. The complete
fixture inventory, actual counts, per-fixture logs and hashes remain in provenance.
Each run must also satisfy the CLI contract: success emits nonempty C with empty
streams; rejection exits 1 with no C, empty stdout and a nonempty diagnostic.
Other statuses block publication even if A/B agree. Frozen test sources are
included in the post-gate source-mutation check.
Normal and diagnostic B link logs must be empty; new diagnostics block publication.
A temporary diagnostic B from the same approved C adds ASan/UBSan with recovery
disabled and performs the existing whole-source strict accounting check. Its
link log must be empty and its complete stderr must be the exact balanced strict
report; emitted C must match. Provenance retains its hash and flags, and the
sanitized binary is not published. Full native/resource suites remain DEFERRED;
fixture parity alone does not prove execution of those fixture mains. The current reviewed producer supports static trait bounds,
default methods, contextual method references and automatic equality for
named records/unions, including generic aggregates. Its configured prelude selects the canonical trait through
an ordinary imported binding, permitting that trait to live in a library module
while _base remains import-free. It also supports consuming String concatenation
with checked capacity growth and unique-buffer reuse, plus the pure
`string.append_int` builtin with stack-formatted decimal digits. The production
library keeps its old integer-append body until this supporting seed is published,
verified and pinned. The seed tag identifies the final approved source commit, retained in each archive's
`source-commit.txt`; compiler and library inventories must match across platforms.
The reviewed workflow and release documentation changes accompany compiler
support before integer-append library activation. Compiler C is locked
to SHA-256
`cdd5e9e7405e4fd9f14a4a128d2229d843073a1ce88d79b6cb87111f9666e6e6`, checked
immediately after A emits C and before B qualification. Each provenance archive
retains `reviewed-compiler-c.sha256`; the publisher checks the emitted C against
that digest and requires all platforms to agree. The earlier stored-callable/tuple
bridge recorded source `9c12cc79e3b7b919af93debde139595b4288e42e` and compiler C
`46c041be4c5be389cd5e6b6d288f5abd8e673ca78b003914849232ac456ee4e3`.
Native fixture cost limits and original resource-policy oracles remain in source;
they are not executed or relabelled as PASS while the driver is deferred.
Hosted instruction measurement remains disabled and unmeasured on all three
platforms. The raw macOS time preflight is observational, not cost qualification.
Active self-hosted component output, compiler parity, strict/sanitizer results,
native smoke and explicit deferrals remain visible in Actions and provenance;
all failures in those active gates block publication.

All three platforms must agree on compiler C and source/library inventories.
The release retains one `blorp2-compiler.c.gz`, three provenance archives and
`SHA256SUMS` alongside the binaries. Provenance includes the full source commit,
seed/A/B digests, target/library inventories, flags, Clang and platform
SDK/libc/dependency details, raw diagnostics, explicit coverage deferrals and gate logs. Actions' `GITHUB_TOKEN`
creates the release; local API credentials are unnecessary. An existing release for the requested seed tag is refused, never overwritten. Preserve referenced seeds and their
provenance indefinitely; expiring Actions logs alone are not release evidence.

The first seed was qualified through an explicit legacy reference A and the
`record-initial-bootstrap-debt` policy, bound to compiler C SHA-256
`3d0def0d00f6c6ec003923d7acb2f8854fa506a6cf6b7c04611322a47b7b7f8b`.
That historical qualification remains recorded with the first seed; it does not
qualify the bridge. Subsequent seeds use `scripts/blorp2-compiler-bootstrap` and
the real seven-field
`blorp_2/bootstrap.env` pin to generate A; the release retains that seed identity,
manifest and binary digest. No missing-manifest or test-time legacy fallback
exists. Unported TestSuite suites remain explicitly deferred.
A pin requires actual published three-platform digests and a clean-checkout
seed-only build proof. Never commit a missing or placeholder pin.
