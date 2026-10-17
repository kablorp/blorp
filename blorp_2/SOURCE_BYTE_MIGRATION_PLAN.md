# Compiler source byte classification migration

## Status, problem and dependencies

Implementation is frozen against accepted A
`0cdba16a459c1a1f5792a70ea2071f98f453b96f`, with exact D production/test diff
SHA256 `81cfcf7586761ff70204c805e1bc3f237bcbb1b3aaf83ee77537d2f9e0d83f96`.
The fresh original cumulative screen **FAILED**: D=9959 exceeds its 9923 cap.
Remaining fixed A/D cost, identity, inventory and correctness gates are pending
under the [one-time landing policy](#one-time-landing-policy-after-the-failed-screen).
That explicit policy change does not turn the original failure into a pass or
authorize further execution or candidate publication.

The original design and planning anchors below describe historical base
`545a6a07d32fb4c713442e441ddc8d93cd544756`. Their initial five-file proposal
and then-pending dependencies remain historical rationale; the actual frozen
cohort and policy amendments below own current scope and acceptance.

The [source plan's String boundary](BOOTSTRAP_SOURCE_PLAN.md#string-and-library-boundary)
requires counted integer-byte access and checked scalar encoding. Compiler
source still constructs one-byte Strings for classification, consumes Char
values and materializes `List[Char]` to emit literal bytes. Those dependencies
block the intended source subset and can split valid UTF-8 while examining it.
This is a behavior-preserving source refactor, not new input syntax.

Host `string.byte_at` and `string.from_codepoint` landed in `86777d833`.
The matching target APIs have separate focused/broad validation work; their
feature-cost acceptance and integration remain prerequisites. Current temporary
String declarations on this planning base do not yet provide them. Freeze the
accepted target commit and supporting host/runtime/library epoch before writing
production. Do not copy a host binary or quietly change the selected libraries.
The coordinator controls the serialized compiled lane. Compiled work requires
a separate grant and must not overlap another worker's compiled commands.

The authoritative interfaces are:

```blorp
pure func byte_at(value: String, index: Int) -> Option[Int]
pure func from_codepoint(value: Int) -> Option[String]
```

`byte_at` observes unsigned bytes; None is out-of-bounds, while Some(0) is NUL.
`from_codepoint` validates the full Int before narrowing and returns exact UTF-8
for every scalar, including NUL and noncharacters. Input Strings are trusted
valid UTF-8. Existing lexer rejection/diagnostic paths remain; this slice neither
adds admission nor removes checks because admission exists elsewhere.

## Scope and fact ownership

The table's line anchors describe the historical five-file planning boundary:
lex, parse, names and emit were the four Char consumers; main adds byte-column
classification. The actual reviewed migration also changes `src/utils/syntax.brp`
only to remove the replaced `DECIMAL_DIGITS` constant: six production files.
The separately bounded lazy repair changes `src/check/signatures.brp` and its
owning test, as detailed in the actual-cohort amendment below. The linked
[delivery item 4](BOOTSTRAP_SOURCE_PLAN.md#delivery-order-and-parallel-ownership)
gets only that boundary clarification. The failed screen and pending gates do
not establish migration acceptance or advance the recorded source frontier.

| Owner | Exact boundary | Required preservation |
| --- | --- | --- |
| [lex](src/lex/lex.brp):275–310, 376–494, 662–693, 739, 768, 920–965 | `is_byte`, `byte_is`, `byte_in`, UTF-8/quoted/Char readers, `punctuation`, code/comment/pipe/indentation reads | Existing ByteClass, Utf8Form, scanners, evaluated order, unsupported-Char errors and extents |
| [parse](src/parse/parse.brp):803–874, 894–1001, 2732–2743 | Integer/Float classification, continuation and escape reads, hex accumulation/scalar encoding, fixed escapes and type-parameter validation | Rigid token validation, range/error priority, raw spelling, count/shape rules and byte spans |
| [names](src/utils/names.brp):102–125 | `spelling_bucket` reads unsigned bytes directly | Exact wrapping `multiply(add(hash, byte), prime)`, constants, bucket normalization, full spelling equality and NameId issuance |
| [emit](src/emit/emit.brp):191–209 | `append_string_bytes` replaces `StringOps.chars` and `to_int` with byte iteration | Decimal bytes, comma order, logical length, and empty `{0}` storage |
| [main](src/main.brp):37–51 | `render_file_location` observes LF through byte access | Byte columns, LF reset, negative/past-EOF span behavior and rendered text |

No shared classifier, table, cache, new AST/IR state, closure/function-type
infrastructure, numeric literal patterns, library API or runtime representation.
Use named ASCII Int constants at the narrowest useful owner. Punctuation and
fixed-escape dispatch use direct numeric predicates, not Int/Char/String literal
patterns. Keep helpers first-order; introduce no callbacks to map Option values.
The parser adds only two private digit-value helpers, returning Option[Int], and
rewrites its existing type-parameter validator; remove the replaced alphabet
lower/search helpers rather than retaining a second classification path.

Leave whole-boundary slices unchanged: lex quoted contents:465, numeric
spelling:515, identifier spelling:700 and pipe runs:998; parse reserved-keyword
spelling:760 and raw String runs:1029. The fixed ASCII alphabet slice in
[float_literal](src/emit/float_literal.brp):66 stays. Checked slicing, joins,
filesystem admission, general HOF/pattern migration and opaque/hash work remain
separate. Do not repair adjacent semantics under this refactor.

## Literate changes and caller-specific absence

Current lexer predicate (`lex`:296) reads a Char solely to recover its byte:

```blorp
match StringOps.get(text.bytes, position):
    Some(character):
        is_byte(to_int(character), expected)
    None:
        False
```

The replacement changes `expected` to Int and consumes the byte directly:

```blorp
match StringOps.byte_at(text.bytes, position):
    Some(byte):
        IntOps.equals(byte, expected)
    None:
        False
```

Apply the same direct substitution to existing scanners without moving reads or
changing their termination/error branches. Decimal and hexadecimal helpers take
an Int byte and return its digit value or None. Reject non-ASCII bytes explicitly
by the accepted numeric ranges. Absence is handled by each caller, never by an
invented byte, empty String or global `get_or(0)` convention.

Current Float validation (`parse`:864) uses:

```blorp
Text.equals(spelling.substring(start, 1), "0")
    and DECIMAL_DIGITS.contains(spelling.substring(IntOps.add(start, 1), 1))
```

For forged Float tokens `"0"` and `"-0"`, the second substring is empty and
`contains("")` succeeds. Keep that absent-second-byte compatibility only here:
when the first byte is ASCII zero, a missing second byte retains the existing
leading-zero diagnostic. A present second byte must be a decimal digit for that
diagnostic. Callers preserve None for absent bytes; the Int-byte digit helpers
return None for non-digits.
Preserve forged integer rejection and the existing negative accumulation/range
checks; do not let arithmetic overflow outrank an invalid digit.

Unicode escape handling keeps the existing seventh hexadecimal digit consumption
(`hex_digits` stops after more than MAX_UNICODE_HEX_DIGITS), then validates
opening/closing shape and the one-to-six digit count. Only a shape-valid escape
calls `from_codepoint`, once. Some supplies `DecodedEscape.bytes`; None enters
the existing invalid-Unicode-escape error calculation, including its capped
digit position and `character_end` expansion. The API owns scalar-range/surrogate
validation; do not duplicate those checks merely to declare None unreachable.
No String is allocated speculatively for a malformed escape shape. Unknown and
truncated forged quoted-token escapes keep their existing parser error and span,
even where ordinary source would already be rejected by lexing.

Current name hashing (`names`:112–116) unwraps a Char in
`multiply(add(hash, to_int(byte)), SPELLING_HASH_PRIME)`. Change only the read and
remove `to_int`. Keep the bounded-loop None invariant documented; do not change
the hash to another algorithm suggested by its FNV-like constants.

Current emission (`emit`:198–203) iterates `StringOps.chars(bytes)` and appends
`to_int(character)`. Its replacement is the existing append loop driven by EOF:

```blorp
while True:
    match StringOps.byte_at(bytes, position):
        Some(byte):
            if IntOps.greater_than(position, 0):
                projected = projected.concat(",")
            projected = projected.append_int(byte)
            position = IntOps.add(position, 1)
        None:
            break
```

Retain the existing empty-array fallback after that loop. Some(0) is emitted and
counted; it cannot terminate iteration. In diagnostic rendering, by contrast,
the loop still ends at `span.start`: None is not LF and still advances the column.
Do not clamp a forged past-EOF span. For `"éx"`, offset 2 reports column 3 and
offset 5 reports column 6; LF after multibyte text still starts column 1.

## Characterization and sensitive mutations

Source-refactor tests must pass on the accepted baseline before production.
Do not manufacture a feature red. Reuse existing TestSuites and language fixtures:

- [String syntax](test/unit/test_parse/test_string_literals_syntax.brp):117–218
  already checks UTF-8/NUL/scalar boundaries, normalization/noncharacters,
  unknown `\\é`, invalid `\\u{é}`, invalid scalar escapes and seven-digit errors.
  Preserve exact source, message, help, note and half-open byte span.
- [Parser literals](test/unit/test_parse/test_parse.brp):259–299 already forges
  IntegerLiteral spellings. Add analogous FloatLiteral `"0"`/`"-0"` controls
  with the existing leading-zero error and unchanged token span; add a forged
  trailing escape characterization if the existing suite does not cover it.
- [Names](test/unit/test_utils/test_names.brp):97 onward: add multilingual
  reinterning/extension/rehash observations through public APIs, retaining
  existing collision/full-equality tests. Review arithmetic directly; changing
  a consistent hash alone need not change public identities.
- [Main](test/unit/test_main/test_main.brp): use `render_diagnostics` and existing
  source helpers for byte columns, LF after multibyte text and past-EOF spans.
- [Emitter](test/unit/test_emit/test_string_literals_ownership.brp):337–369
  already pins NUL-containing arrays, `{195,169,240,159,152,128}`, empty storage
  with logical length zero and a long literal. Reuse existing String e2e cases.

Mutate one fact at a time, record the named failure, restore exact bytes, then
rerun green: remove the Float absent-byte compatibility; shorten diagnostic
scalar expansion to one byte; stop emission at Some(0); reject uppercase hex
digits (add a baseline uppercase-escape case if needed); or accept encoder None
as an empty decoded String. A full-spelling-equality mutation must be killed by
the existing name-collision oracle. Compiler errors, setup failures and timeouts
do not establish the intended oracle. No production test export or new observer.

Preserve the seventh-digit scan rule by source comparison. Do not claim that a
stop-at-six mutation is necessarily killed by rejection/span tests: the existing
cap followed by `character_end` can produce the same public diagnostic. Use only
demonstrably sensitive behavioral mutations; do not export private scan state
or invent a counter to force this distinction into a test.

## Commands, identity and costs

Commands below are future acceptance commands, run from the authorized checkout
after dependency acceptance and root's serialized compiled-lane grant. The
supporting host must be FRESH for its own checkout; `make` rebuilds when needed.

```sh
scripts/compiler-build-status
make
scripts/compiler-build-status
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_parse/test_string_literals_syntax.brp \
  blorp_2/test/unit/test_parse/test_parse.brp \
  blorp_2/test/unit/test_utils/test_names.brp \
  blorp_2/test/unit/test_emit/test_string_literals_ownership.brp \
  blorp_2/test/unit/test_main/test_main.brp
bin/blorp test --suite --timeout 180 \
  blorp_2/test/unit/test_lex blorp_2/test/unit/test_parse
mkdir -p build/source-byte-migration
bin/blorp compile --no-format --stop-after=lower --dump-core-after=lower \
  blorp_2/src/main.brp \
  > build/source-byte-migration/pre-dce-core.log 2>&1
make -C blorp_2 test
```

The first focused command is the repeatable characterization/mutation loop;
individual owning suites are the shortest iteration where appropriate. Full
pilot acceptance builds its compiler once and exercises unmodified fixture C
and real mains under the existing sanitizer/e2e protocol. This plan adds no
alternate main, emitted-C repair or new execution harness.

Require complete target C identity between local baseline B and candidate C,
plus matching outcomes/stdout and exact rendered diagnostics on every unchanged
owned input, including existing Unicode/NUL/long-literal fixtures. Cumulative
R0/C keeps and reviews complete raw target C diffs for all accepted intervening
features, including UTF-8 argv rejection/cleanup and both integer-facing String
helpers. No C normalization or fixture adaptation is permitted. A cumulative
diff not explained by those accepted features is a stop, not an identity waiver
for this source refactor. Inspect raw host-generated compiler C changes
separately: the compiler source changed, so its own generated C is not an identity
oracle. Preserve source, C and binary hashes and the actual bootstrap frontier.

Inspect the complete source inventory of all 38 compiler modules, together with
a bounded static check of these five files. Corroborate source references against
the fresh pre-DCE `lower` dump using the established source-plan invocation above;
retain module/declaration coverage and resolved callee evidence. A `perceus` dump
follows DCE and proves only reachable-code facts. The lower dump alone also does
not prove complete source coverage: reconcile every module and relevant source
reference, including forms absent from the dump, before claiming a complete
resolved call inventory. Require no compiler-owned Char values/literals/conversions,
`String.get`/`String.chars` reads or String alphabet lower/search calls. Identify
these APIs by resolved library owner, including import aliases; `List.get` remains
required. Comments, diagnostic wording, unchanged whole-boundary slices and
host-shim internals do not establish such a
dependency. Retain the source inventory, Core artifact and exact invocation.
If existing tooling cannot establish coverage or resolution, stop and report that
limit; introduce no scanner/export and delete no parity rows.

Planning estimates are 180–280 gross/+40–90 net production and 80–140 gross/
+60–120 net tests, not measured patch counts. Hard physical ceilings remain
**320 gross added / +110 net production**, **180 gross
added / +150 net tests**, **zero new fixture files/lines**. Count deletions and
documentation separately. Do not compress formatting, delete coverage or stack
another pilot's allowance. Scope expansion or a breach stops before further work.

The [source-plan cost protocol](BOOTSTRAP_SOURCE_PLAN.md#acceptance-and-cost-boundaries)
uses these three explicit variants under one frozen accepted supporting-host,
runtime/toolchain and build-mode epoch:

| Variant | Source and temporary target library | Comparison |
| --- | --- | --- |
| R0 | Exact unmodified reset `78bc406d6646eb7a1b61700b71d1faa9e9eaca09`, with its original temporary target library | Total cumulative baseline; not a supporting-host baseline |
| B | Immediately preceding accepted feature-era source with its matching temporary target library | Local baseline |
| C | This source migration over B, with the same feature-matched temporary target library as B | Candidate |

Use the same explicitly selected, frozen supporting-host standard library for all
R0/B/C producer builds and host proxies. Pin that uniform host-stdlib selection
and each variant's target-library selection separately. R0 keeps its original
temporary target library because its target compiler does not support the new
builtin labels; no historical host-stdlib selection is implied. Rebuild all
three with the same frozen supporting host and flags. Report host/runtime
transition costs separately; do not change epochs within the pair.

The cumulative program corpus is the original **452 exact program files** shared
with R0. Verify actual membership and bytes against the frozen inventory; counts
alone, names or path-prefix heuristics cannot establish that boundary. Local B/C
also includes the four accepted API fixtures (`byte_at.brp`, `byte_at_zero.brp`,
`from_codepoint_ownership.brp`, `from_codepoint_nul.brp`) from the accepted feature
inventory, with their exact bytes. Keep all four in local identity/cost checks,
full gates and their existing absolute caps. They are new relative to R0: do not
require R0 to compile unsupported APIs or change its original target library.
This plan adds no fixtures. Finite call accounting belongs to the later reviewed
recipe.

For allocations and normal min3 instructions, require **C/B <= 1.03 for every
local input**, **total C/R0 <= 1.03 for every shared reset input**, and **both
ratios for the host source-to-C proxy**. Total cumulative cost includes every
intervening accepted feature and its target-library changes. It is deliberately
stricter than subtracting feature costs: neither a feature's separate acceptance nor
another input's gain provides a deduction or allowance. Report all raw metrics
and the applicable ratios.

R0 source stays byte-identical. Do not backport accepted target features into it,
adapt sources/fixtures/C, construct a counterfactual R1 overlay or silently swap
target libraries to make a comparison pass. Any local or cumulative 3% breach stops
the stage and returns evidence to root before further work; it never triggers an
automatic overlay. An incompatible workload or unexplained output/diagnostic
change also stops for root. Host wrapper/Option dispatch may increase instructions
even when temporary Strings disappear; no successful cost result is predicted.

Reuse existing measurement recipes and one physical input/CWD/output boundary,
with three serial alternating normal pairs and separate strict leak/count runs.
Freeze source/library membership and hashes, host/bootstrap/toolchain/flags,
compiler C/binary provenance and raw samples. Root assigns paths and lane; no
shared scratch writes, host/std switch or measurement controller is implicit.
Preserve stricter fixture limits. A local or cumulative per-input breach stops;
neither aggregate allocation wins nor future-bootstrap credit waives it.

## Sequence, review and handback

1. Review this plan independently and with root, then publish its plan-only
   commit. No production or test implementation is authorized yet.
2. After target API acceptance/integration and an explicit writer/lane grant,
   freeze the accepted base/epoch, obtain passing baseline characterizations and
   baseline output/cost artifacts. No merging while a measured pair is running.
3. Implement only the five-file change; add bounded tests, prove sensitive
   mutations/restoration, then inspect the exact diff, generated C and inventory.
4. Obtain independent implementation/code-reviewer and test-runner evidence,
   the focused/full gates and both local/cumulative cost verdicts before root
   integrates. Keep the plan and implementation separately reviewable.

Return branch/commits and exact patch hashes; production/test/documentation and
fixture counts; baseline, mutant and restored outcomes; output/diagnostic identity;
inventory/source-subset evidence; raw sample paths and per-input/proxy verdicts.
Stop for a host defect, admission/identity disagreement, changed diagnostic
priority, ownership ambiguity, missing observer, required new mechanism or cap
breach. Reduce and report the witness to root; do not fix an adjacent subsystem
or silently widen the contract. Root and independent review precede any commit.

## Actual deliverable after accepted file reads

This amendment supersedes the historical candidate/cohort and identity wording
above, without changing the original cost denominators or ceilings. Accepted
base A is `0cdba16a459c1a1f5792a70ea2071f98f453b96f`, including CWD and
`ReadFileBuiltin`. Its source tree is
`30cb259e19bd3bde4e7ffda952059910fd78c5b9`; its complete temporary-library
tree is `38530dc355893aca1207580a3dcd4ab810a55f17`. Actual candidate D is
that base plus the previously reviewed six-file source migration and bounded
lazy builtin-error construction repair. D keeps all accepted features and the
complete base library; no stale-source overlay or subtraction is permitted.

The preserved historical worktree is
`/Users/keithphilpott/.codex/worktrees/bootstrap-lazy-errors/blorp`, branch
`codex/bootstrap-lazy-errors`, HEAD
`405a28f2d7f53e8289b2e1bc701f1ed55203f086`. Its twelve-file production/test
patch SHA256 is
`4afdbb7ffa98064f6073a8acdf269eb11e58af7fe04b76d2df7c512088ac571f`.
The patch applied cleanly, without three-way merging, to A in
`/Users/keithphilpott/.codex/worktrees/source-port-current/blorp`, branch
`codex/source-port-current`. The refreshed production/test diff SHA256 is
`81cfcf7586761ff70204c805e1bc3f237bcbb1b3aaf83ee77537d2f9e0d83f96`.
These are source-inspection facts, not new passing tests or cost evidence.

The sixth migration file, `src/utils/syntax.brp`, only removes the replaced
`DECIMAL_DIGITS` constant. Migration production is +285/-209, net +76;
four tests are +136/-2, net +134, within the original separate ceilings.
The lazy repair changes only `src/check/signatures.brp` (+9/-8, net +1) and
`test/unit/test_check/test_list_updates.brp` (+30/-4, net +26). Its separate
ceilings remain 15 gross/+3 net production and 40 gross added test lines.
Six existing List None arms construct the same typed mismatch only on rejection;
the primitive fallback matches its explicitly typed Option before constructing
the same invariant error. Keep the `to_result` import used elsewhere. Preserve
`ReadFileBuiltin: Ok(Builtins.ReadFile(site.designated.result))` and the CWD
arm unchanged. No new semantic spelling lookup, helper, framework or cache.

The lazy semantic characterizations previously passed before and after the
repair; they are not a functional red. Preserve their exact typed operation,
source, span, message, help and absent-note assertions and prior mutation
evidence. The genuine failing-before acceptance is the historical cost gate.

### Frozen paths, identities and cost comparisons

The authoritative historical primitives remain under
`/Users/keithphilpott/.codex/worktrees/source-byte-migration-plan/blorp/build/source-byte-migration/cost-preparation/direct/`.
Use `config.sh`, `strict.sh`, `normal.sh`, `new-fixtures.sh` and `host-proxy.sh`
as the inspectable command/assertion authority. Do not execute their historical
setup or overwrite their scripts, source snapshots, pilots or raw samples.
Any necessary recipe delta is recorded separately for root and peer review;
this amendment adds no controller.

R0 and B retain their original source snapshots, pilot binaries and respective
`cost-run/libraries/reset` and `cost-run/libraries/local` paths. The fixed CWD is
the original `cost-run/input`; output remains the original `cost-run/same-output.c`.
A/D use the same complete new frozen target-library path,
`cost-run/libraries/actual-D-read-file`, under that historical packet root.
Record that explicit library-path difference, complete membership and byte
manifest. Source snapshots for A and D and new raw samples live under the new
worktree's ignored `build/source-port-current/` directory. D is always the actual
deliverable, including file reads, never the historical candidate C.

The original 452 shared fixture bytes, four original API fixtures and immutable
historical artifacts remain untouched. Only a future explicit compiled lease
permits complete canonical source/library installation and writes to the owned
shared output, outside measured intervals. Verify exact membership/bytes before
and after installation; do not merge stale files into a complete snapshot.

Migration-only correctness requires exact complete A/D fixture C, exit status,
stdout and semantic diagnostic bytes. This explicitly supersedes the historical
`strict.sh` B/C C comparison only in the new recorded recipe. Retain complete
raw B/D and R0/D C deltas and review every difference against accepted CWD/file
read and prior feature changes. Never normalize output; unexplained differences
stop. Historical R0/B remain binding cost denominators, with both original
integer tests `100 * D <= 103 * B` and `100 * D <= 103 * R0` on every applicable
input and the host source-to-C proxy. Also require local A/D <=1.03. No reset,
feature deduction, aggregate credit or widened allowance.

The four original API fixtures retain B/D local and absolute caps. Add the five
current feature fixtures (`current_directory/basic.brp`,
`current_directory/ownership.brp`, `file_read/basic.brp`, `file_read/nul_path.brp`,
`file_read/ownership.brp`, all under `test/e2e/fixtures/`) unchanged from A.
Their installation at new canonical paths requires the future explicit lease;
it must not overwrite any original fixture, and their complete bytes are pinned.
These use A/D local +3% allocations and normal min3 instructions plus their
existing 205000-allocation/600000000-instruction ceilings. They have no invented
R0 baseline. Current full acceptance includes all existing feature/native cases.

### First screen and stop rule

One hypothesis: constructing builtin rejection data only on rejection reduces
valid-signature work enough for the complete D deliverable to meet the original
cap. After root and independent recipe review and an explicit serialized lease,
build D with the frozen supporting host/stdlib and original canonical boundary;
link normal/diagnostic pilots with the original O0 flags. First run the direct
strict `c0004` binding/basic screen using R0/B/D, plus A for source-only identity.
Use new raw directories and preserve every call; do not overwrite old samples.
Require positive balanced counts, zero leaks and exact diagnostic checks.
The historical R0 count is 9634, B is 10081; D must be at most 9923 allocations.
Stop and report immediately if the screen fails, without another optimization.

If it passes, execute the complete original shared/API allocation and normal
min3 protocol, current A/D comparisons and frozen-host source-to-C proxies;
retain every unfiltered sample and original absolute cap. Run granular owning
suites and current full unit/runtime/grammar/e2e acceptance. All work remains
serial on root's lease. The binding host-proxy allocation metric is exactly
`direct/host-proxy.sh`: unset `BLORP_LEAK_CHECK`, set `BLORP_MEMORY_STATS=1`,
require status 0 and exact `Generated <output>` plus LF, and extract the positive
`total_allocations` from the unique schema1 `artifact_construction_complete`
checkpoint. Preserve its local/cumulative integer ratios, frozen host/std epoch
and flags. Do not substitute exit-time strict totals or the file-read feature's
different proxy metric. Normal proxy instructions remain minimum-of-three.

Separately, the old supporting host's known compile-time strict
leak exception permits only documented FAILED status 99 with complete valid C;
strict-host stdout is empty because its atexit path exits before flushing.
Normal host status 0 requires exact `Generated <output>` plus LF. Pilot and native
strict runs still require zero leaks. No compiled execution, commit or publication
is authorized by this amendment; root assigns those steps separately.

### One-time landing policy after the failed screen

The original experiment above is **FAILED**, not accepted: fresh serial c0004
allocations were R0=9634, B=10081, A=10081 and D=9959. D exceeds the original
9923 cumulative cap by 36 (+3.373468964% over R0), despite reducing A/B by 122
(-1.210197401%). All four strict runs were balanced and leak-free with identical
complete C, status and semantic output. The [maintained result](../benchmarks/results/blorp_2_source_byte_lazy_screen_2026-10-17.md)
preserves provenance, raw evidence and unresolved acceptance. No additional
optimization followed the failure. The counts establish no particular host
defect, and A=B on this input: CWD/read_file supply no cost deduction.

Under the user's explicit authorization for roadmap changes with multiple
expert agreement, the coordinator approved this one-time changed landing
criterion after independent compiler-expert and stderr-expert recommendations.
It supersedes only the historical R0/D and B/D percentage checks as landing
requirements for the exact byte-migration plus lazy-error slice frozen below.
Those historical denominators and the failed original result remain recorded;
this is neither a passing original experiment nor a new supporting-host epoch.
All other acceptance requirements remain binding.

The purpose is to remove the reviewed compiler-source Char/classification
dependencies through the accepted byte/scalar APIs without distorting the sound
implementation to fit one observed count. The measured benefit is the c0004
local allocation reduction only; no whole-corpus, instruction or proxy benefit
is established. The explicit tradeoff is that historical cumulative growth
over 3% no longer blocks this one precisely bounded slice. Broader bootstrap
performance and actual full-source self-compilation remain open requirements.

Freeze A at `0cdba16a459c1a1f5792a70ea2071f98f453b96f`, including its complete
accepted temporary library. Freeze D at production/test diff SHA256
`81cfcf7586761ff70204c805e1bc3f237bcbb1b3aaf83ee77537d2f9e0d83f96` over A.
The earlier source/library manifests, physical paths, flags, actual source
inventory, supporting host pair/std epoch and preserved observations do not
change. Main `8ed7687dfa12d548fdb099d29a143092c1578bf2` adds only tests/docs
relative to A; its compiler source and target-library trees still equal A's
`30cb259e19bd3bde4e7ffda952059910fd78c5b9` and
`38530dc355893aca1207580a3dcd4ab810a55f17`, respectively. Do not substitute
later compiler/library changes or alter candidate bytes under this decision.

For every unchanged A/D input separately, including all current feature inputs,
and for the original frozen-host source-to-C proxy, require both exact tests:

```text
100 * D_allocations <= 103 * A_allocations
100 * D_normal_min3_instructions <= 103 * A_normal_min3_instructions
```

Retain every existing absolute input/e2e ceiling. The original 452 shared files,
four String API fixtures and five CWD/file-read fixtures retain their exact
bytes and identities; no fictional R0 baseline is introduced for newer inputs.
The proxy allocation metric remains the unique schema1
`artifact_construction_complete total_allocations` checkpoint with
`BLORP_MEMORY_STATS=1`, leak mode unset, status 0 and exact Generated stdout.
Do not replace it with exit-time strict totals. Normal instructions still need
three unfiltered alternating A/D samples under the same quiet frozen epoch.

Reuse the four existing c0004 strict observations; never resample them under
this decision. Other inputs/proxies remain unexecuted preparation until root
approves their exact remaining command schedule and grants the exclusive lane.
Retain all raw samples and commands, complete A/D fixture C and exact diagnostic
identity, source inventory/semantic behavior, granular owner and full current
unit/runtime/grammar/e2e acceptance. Positive balanced pilot/native strict counts
and zero leaks remain mandatory; the separately documented old-host limitation
does not relax them. Migration/lazy production and test ceilings remain separate
and unchanged. A new failed gate or unexplained difference stops for root review;
it never automatically widens this exception.

This policy covers this frozen slice only. Do not roll A forward to D, reuse the
exception for a later pilot, grant another waiver, change another threshold or
subtract accepted feature costs. Genuine self-compilation and any future
supporting-host transition require their own matched evidence and explicit
policy; they cannot retroactively turn the original R0/D failure into a pass.
Documentation review and publication authorize no source change, measurement,
resampling or landing of D; root schedules the remaining acceptance separately.
