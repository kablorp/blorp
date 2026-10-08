# M4 parser integration on current main

The accumulated M4 parser work through feature commit
`d5bf20be48638481cadf8344325d847f59e0430d` is squash-integrated over main
`39aff089ef41d60925ed7564e0ab139f8dfd34a4`. The feature fork was
`5fed50a38bf09d8e0e32c92965d59604a90c91fa`; all six intervening main commits
are retained.

The integration deletes the obsolete recipe module and retains direct tree
minting, header/body entry, expanded expression/body coverage and the six
corrected corpus sources. Twelve newly introduced fieldless declarations use
`fixed union` to match main's enum retirement. Both the enum-as-ordinary-name
and contextual-name Guide paragraphs survive the documentation conflict.
The reviewer verified that main-only production changes are untouched,
including scalar payload, callback and record lifetime changes. Historical
source-patch payloads remain byte-identical to the feature tip. Evidence text
uses portable path aliases as described below.

Independent host validation uses the repository compiler:

- Integration build: FRESH; worker focused checks: 302/302.
- `scripts/compiler-check --changed --base 39aff089ef41d60925ed7564e0ab139f8dfd34a4`:
  624/624 across eight owning suites, including fuzz and rejected-declaration
  differential checks.
- `scripts/compiler-new-parity --stop-census`: zero first stops across 3,618
  current corpus files. This verifies the combined tree, including upstream
  additions since the historical 3,605-file census.

The documented landing command is
`scripts/docker-gate --premerge-gate -- --no-sanitize`. It uses the configured
remote gate host and Linux amd64 container, with private snapshot
`8e77bc1088a9ab1d03dffac37c36434a970383db`, Clang 18.1.3, eight-way split,
and `-O2` CLI/runtime optimization. The clean build and quality checks pass.
The container compiler is FRESH; its SHA256 is
`7d48f70f03ca93a07950ec315fb3a83947e21d8b2404e77230461edcc9b5708a`.
One quality test skips because `scripts/record-validation` already implements
the interface whose absence it probes. Benchmark tooling is skipped by the
gate's input scope. The runtime registry's ThreadSanitizer-only test skips
unless `BLORP_TEST_TSAN=1`; the ordinary concurrent race test runs. The
documented command omits the dedicated premerge sanitizer stage. The standard
LSP gate still runs its built-in ASan stdio transport checks; its separate
leak-instrumentation assertion skips in that ASan rerun and passes in the normal
run. This is not parser/compiler ownership sanitizer coverage or a performance
measurement.

The full Linux test set passes 19,225/19,225:

| Gate | Passed |
| --- | ---: |
| compiler-blorp | 6,991 |
| compiler-tools | 256 |
| compiler-new | 1,060 |
| compiler-new-parity | 3,634 |
| std-check | 1 (91 modules) |
| runtime | 4,780 |
| leak | 1,221 |
| doctest | 1,057 |
| LSP | 36 |
| CLI deep checks | 189 |

The codegen audit passes 233/233. The CLI nested log was removed by the gate's
normal cleanup before it could be copied; its actual 189/189 verdict remains
in the aggregate log. Nine other nested gate logs are retained.

The first full Docker run exits 1 at the security scan after all compiled,
quality, audit and smoke stages pass. It finds machine-local paths in evidence
text: 931 matching lines, including 12 already on exact main. This is a receipt
portability failure, not a compiler/test failure. The original Docker and
premerge verdicts remain **FAIL** in the retained report.

Seventy-one evidence files are normalized to `<worktree:NAME>`, `<repo>`, `~`
and `$TMPDIR`; five of them are pre-existing main records. Eight historical
payload manifests are refreshed to hash the normalized bytes. The
[normalization ledger](discovery_m4_main_integration_2026-10-07/path-normalization.json)
retains original and normalized byte counts/hashes with original commit
provenance. Original manifest bytes are retained separately. This changes only
machine-root prefixes and manifest metadata: source patches, compiler inputs,
test assertions, measurements and source/binary hashes remain unchanged.
Current integration logs also use portable prefixes and retain both captured
raw and normalized-text hashes; no original verdict is rewritten.

After that evidence-only correction, the exact unchanged security scanner,
both staged/worktree whitespace checks, hygiene and artifact scan all pass.
The previously unreached final checks are completed separately. Source/test/
script freeze is unchanged, the active-input diff to the tested Docker snapshot
is empty, and the host binary remains FRESH with SHA256
`3f7a5ae841d0ed96ea7bd97f9fb11a15cb3dc4f41f384b3ee9959c60e3027f69`.
This is matched completion of the passing compiled stages and corrected
evidence checks; it is not a rewritten overall Docker verdict. The
[packet manifest](discovery_m4_main_integration_2026-10-07/MANIFEST.json)
hashes the retained reports, logs, input freezes and normalization ledger.

The full parity gate passes 3,634 checks with zero AST mismatches. Its count is
3,618 tracked corpus files plus seven graph and nine adapter/allowance checks;
the host and Docker corpus path lists are identical. The every-corpus-root
adapter traversal compares 3,476 accepted modules and records 189 rejected by
the existing parser, including recursively loaded modules outside the listed
roots. All 3,476 accepted modules
assemble and compare in full; every unassembled/stop counter is zero. All seven
compile, test, embedded-library and package root runs agree. The existing two
lexer divergence allowances and rejected-diagnostic differences remain visible
in the raw report; zero AST mismatches does not claim identical rejected-body
diagnostics.

These are correctness and coverage results. M4 remains open for rejected-body
subset parity, outcome unification, `StopReason` deletion and rejected-head
lexical recovery removal. Non-corpus grammar gaps described in the historical
slice records also remain open. No performance improvement is claimed.
