# Blorp 2 keyword authority

The lexer now owns the only spelling-to-keyword mapping. Reserved words carry
`KeywordToken(Keyword)`; punctuation and layout carry `SymbolToken(Symbol)`.
The parser uses those typed roles and quotes the validated source span only
when rendering a reserved-name diagnostic. The inverse spelling table and its
round-trip test inventory are removed. Input syntax and diagnostic text stay
unchanged. Production is **131 added / 157 deleted, net −26 lines**; tests are
306/115, fixtures 22/0, and README 6/0, against the frozen emitter baseline.

`LexedProgram.source_text` borrows the immutable input through lexing/parsing.
A standalone retained lexer product therefore retains that input. Neither the
parsed result nor its diagnostic retains the full source. There is no new
lookup table, generator, cache, compiler layer or production tracing.

## Frozen boundaries

Baseline production is accepted `c4ec843d6`; later accepted changes before
this measurement affect documentation and test literal formatting only.
The existing pilots are O0 with `BLORP_MEMORY_DIAGNOSTICS=1`. Both variants
use identical fixture/library bytes and physical input/output paths.

| Artifact | SHA-256 |
| --- | --- |
| Baseline pilot | `5c97ab90a2747802f61c33bf2fa0098e31c26389e25c2c89ba97ab20884b06d2` |
| Baseline compiler C | `7a88e4c053afc592c9bdcb8f56a65d7fb2103e3eb760ecd4891f931bb63368b8` |
| Candidate pilot | `6258891fa351a8456f72a62d6786029fbd3525aa0802eeb08c27c4f650f33cb8` |
| Candidate compiler C | `433d2e1d3f44328b6fe5da329dbf4612b1cfc55fdd15940317de3daa627b8858` |
| Frozen normal host | `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17` |
| Frozen diagnostic host | `86ba69ffea8200080157edb25cbc49825654a14d2c09a6161dec447ab0e648be` |

The host is CLI-O0/runtime-O2/split8, bootstrap `dev-0e1598ed616e`, Apple Clang
21 on macOS arm64. It remains FRESH and unchanged. Complete source/library
hashes are retained in the whole-cost freeze manifest.
No host or pilot was rebuilt during the cost collection or mutation tests.

## Component, representation and lifetime evidence

Focused lexer/parser/syntax/grammar suites pass **600 callbacks in 58 suites**.
The direct classifier probe shows no additional per-word allocation; generated
C confirms that adopting `Option[TokenKind]` adds no heap box at that boundary.
Ordinary Clang layout dumps of each variant's unmodified compiler C establish
Token **56→56**, TokenKind **40→40**, and LexedProgram **64→72 bytes**. Installed
type names identify each carrier; host `memory.size_of` is supplementary only.

Direct active-counter windows around lex and lex-plus-parse have identical
allocation/release counts. One/two calls on the same frozen parser source cost
96,331/192,662 allocations for lex and 211,221/422,442 for lex-plus-parse. These
check fixed-work call scaling, not a varying word-mix slope. Separate normal
phase-workload process minima rise **0.295890%**, below 0.5%; that process includes
host/native compilation, startup, I/O, assertions and reporting, so it does not
measure isolated phase instructions.

The lifetime test reads a unique dynamic source inside a helper, releases all
full-source owners, and holds the actual parsed product or diagnostic across
live-counter observations. Both variants retain 9 objects/800 bytes on success
and 3 objects/234 bytes on rejection, returning to setup levels after dropping
the result. An accidental parsed-product source-retention mutant fails the
success oracle while its rejection control passes; restoring the source is green.

Seven further valid, host-compiled behavioral mutations are killed: keyword as
identifier, wrong keyword role, reserved-only word as function keyword, wildcard
as keyword, shifted quote start, truncated quote end, and wrong module's source
text at the typed lexer-to-parser boundary. Their red runs execute **48 passing
and 24 intentionally failing callbacks**; all **72 restored callbacks** pass.
The wrong-module case is explicitly a test-local boundary fault injection, not
a claim of a current production bug. Setup errors are not counted as reds.

## Whole-pilot and source-build costs

The finite collection makes **3,048 compiler calls**: 928 strict, 2,112 normal,
six normal host source-to-C calls and two diagnostic checkpoint calls. All 445
corpus inputs preserve outcomes (349 accepted/96 rejected), full diagnostics
and shared C. Three full-provider stresses and 16 reserved-name/control inputs
also preserve outcomes. Every strict counter is positive and balanced, with
zero leaked objects or bytes. Timing takes three alternating pairs per declared
successful input, with both memory variables unset **outside** `/usr/bin/time`.

| Metric | Baseline | Candidate | Change | Limit |
| --- | ---: | ---: | ---: | ---: |
| Accepted-corpus allocations | 4,569,988 | 4,569,988 | 0% | no growth |
| Corpus sum of per-input min3 instructions | 14,447,575,499 | 14,483,148,884 | +0.246224% | +0.5% |
| 32x1 instructions | 65,879,131 | 65,984,289 | +0.159623% | +0.5% |
| 32x16 instructions | 238,263,225 | 238,399,787 | +0.057316% | +0.5% |
| 128x8 instructions | 578,228,909 | 578,083,905 | −0.025077% | +0.5% |
| Host source-to-C min3 instructions | 42,395,963,724 | 42,399,823,040 | +0.009103% | +5% |
| Host artifact-construction allocations | 22,900,921 | 22,916,323 | +0.067255% | +5% |

All 451 allowance-zero inputs have identical allocation counts. Exactly the
13 predeclared reserved-name diagnostic cases add one allocation. The original
315→316 short rejection **fails the old no-growth limit**; the separately
reviewed [diagnostic allowance](../../blorp_2/KEYWORD_AUTHORITY_PLAN.md#reserved-name-diagnostic-allocation-exception)
permits at most baseline+1 for that first diagnostic only. Longer, EOF, binding,
UTF-8 and multi-module contexts all satisfy the bound. Other errors and accepted
programs retain no-growth. No e2e fixture budget changes.

The added diagnostic substring copies only the validated keyword span. A future
typed span carried to final source-aware rendering could avoid eager spelling
materialization; it needs a separate design and measurements and is not proven
free. Normal instructions for rejected inputs were not measured. Host metrics
are different-source source-to-C proxies, **not self-compilation**, and their
allocation checkpoint is cumulative through artifact construction.

## Review and destination

Root and independent compiler experts reviewed the source, transient ownership,
physical carriers, tests and explicit diagnostic cost decision. A separate test
runner reviewed and executed the recipes. Seven expected diagnostic files have
only reviewed, reversible checkout-root relocations; actual outputs are never
path-normalized. Raw commands, source/binary manifests, C, streams, counters and
endpoint checks remain in `quality-keyword-integrated` under ignored
`build/quality-keywords-integrated/` in `phase_cost_layout_v2/`,
`critical-prep-703f30626-v2/independent-gates/`, `long-focused-gates/`,
`remaining-acceptance/` and `remaining-mutants/`.

The actual main destination passes the literal `make -C blorp_2 test` once:
**2,830 component checks and 445 e2e checks**, with one O0 pilot build. Its
compiler C is byte-identical to the paired candidate above. The destination
host remains FRESH at SHA prefix `390bdd0d`; it is distinct from the frozen
measurement host and is not substituted into those comparisons.

The subsequent dynamic frontier parses **34/36 source modules**. Its two first
stops remain Char literals (`lex.brp`, byte 7471) and function-type syntax
(`specialize.brp`, byte 11650), so this is no self-compile claim. Make/frontier
take 250.61/19.83 seconds. Full destination logs, counts, source proofs and
separate O0/O2 artifacts are retained under the primary checkout's ignored
`blorp_2/build/keyword-landing/`. All gates pass with no source or test repair
at the destination.
