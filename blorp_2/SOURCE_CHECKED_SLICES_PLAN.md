# Replace seven compiler substring calls with checked byte slices

Status: bounded source plan, not an applied migration or execution/cost result.
Root publishes the reviewed plan before code and separately grants compiled work.
The [seven-callsite ledger](../build/bootstrap-evidence/compiler-source-api-migrations-2026-10-19/preview-01/checked_slices/SEVEN_CALLSITE_CONTRACTS.json)
anchors actual producers, ranges, failure contracts and existing test owners.

## Planning identity and held prerequisites

Planning main is `f627d5aaf64775bb23e4f2e15a955450c0cb336b`; its compiler source
and target library still match Numeric `a656f5ce1`. Neither is silently selected as
a SOURCE cost B. The [source](../build/bootstrap-evidence/compiler-source-api-migrations-2026-10-19/preview-01/checked_slices/SOURCE.preview.patch)
and [test](../build/bootstrap-evidence/compiler-source-api-migrations-2026-10-19/preview-01/checked_slices/TESTS.preview.patch)
previews remain unapplied. Matching host and target [Slice](STRING_SLICE_PLAN.md)
acceptance is required: the host31 wrapper is held and absent from ROOTSTD91;
no wrapper or target Slice compiler/runtime/library change is copied here.
Existing managed-loop/M3 and other source-readiness prerequisites remain explicit.
Option(Some, None) and Result(Ok, Err) already come from the target prelude for
compiler user modules. Float's new matches require no extra operation import.
Preserve the import-closure worker's existing Option/Result operation and main IO
imports. Merge only this slice's StringOps/phase-error imports and parser's
compiler_source; do not overwrite that worker's files. The original preview's
coordination JSON overstates constructor-import needs; this paragraph corrects it
without rewriting that sealed history.

## Seven half-open ranges and failure order

Use `StringOps.slice(value,start,end)->Option[String]`, preserving exact UTF-8,
NUL and normalization spelling. No blanket start+length rewrite or reconstruction.

| Caller | Range | Endpoint authority |
| --- | --- | --- |
| lex.quoted_token | contents_start,closing | ASCII quotes and validated scalar/escape scan |
| lex.numeric_token_end | start,end | Present ASCII numeric syntax and bounded run_end |
| lex.code_token | cursor,end | Present ASCII identifier start and bounded run_end |
| lex.pipe_block | text_start,line_end | ASCII marker, validated scalar scan, LF/EOF |
| parse.consume_name | token.span.start,token.span.end | Lexer keyword over retained source_text |
| parse.string_value | cursor,stop | Zero/decoded next to ASCII escape/opener or EOF |
| emit.c_float_literal | digit,digit+1 | Digit 0..15 in sixteen-byte ASCII alphabet |

The first six callers already return Result. Direct Some arms preserve the old
owned work; None constructs an internal Diagnostic at compiler_source(), span 0..0,
note=None. Message is `internal compiler error: invalid UTF-8 slice for ` plus the
ledger's exact context; help is `report this compiler error with the input program`.
Two small phase-local helpers suffice; no shared slicing engine or eager error
allocation on Some. Numeric-suffix errors and quoted/pipe validation still occur
first. Pipe None stores Err without updating value/end/continuation; raw-run None
stores failure and exits before later decoding. Empty runs remain valid. Valid
reserved-name diagnostics stay exact; forged invalid offsets receive the internal
error instead of truncated keyword text. No fallback String or unchecked unwrap.

## Bounded Float leaf change

Finite nonzero magnitude normalizes exactly into [1,2). Fraction starts in [0,1);
exact multiply by 16 yields [0,16); at most 15 exact unit subtractions leave [0,1).
Thus digit is 0..15 and end is 1..16, without overflow; all endpoints are ASCII.
Thirteen iterations consume 52 fraction bits. NaN/infinities/signed zero bypass it.
A String result offers no sound failure value for None. Change only c_float_literal
to Result[String,EmissionFailure], add payload-free InvalidFloatDigitSlice to the
existing phase union, and propagate through its sole production consumer,
append_operation, which already returns Result[String,Diagnostic]. Existing
render(span,error) preserves the Float occurrence span, note=None and standard
help; exact message is `internal compiler error: invalid hexadecimal Float digit slice`.
Valid values remain Ok with identical literal bytes. A loop-local failure carries
the exceptional exit; add no ?= inside loop/match blocks. No Lower/Own/Verify or
wide pipeline type change, new unsafe API, substitute digit or formatter is needed.

## Tests, bounds and costs

Characterize B before code. Preserve quoted/Unicode/escape, numeric/identifier,
pipe/runtime-text, reserved-name/lifetime and Float/emission suites. The preview
adapts fifteen Float assertions through a Result-checking helper without changing
literal expectations; it adds forged keyword bounds/continuation and typed
emission-renderer checks. The 870-file planning manifest is source identity, not
an executable-case count. Existing full tests/harness remain the semantic gate.
Prove source-valid faults: move endpoints into UTF-8 scalars, use end-1 on a
nonzero-start run, shorten the Float alphabet to 15 and use largest-finite, and
force the typed Float failure to prove emitter propagation. Require named exact
byte/value/Diagnostic failures; setup errors are not kills. Restore exact bytes
before fresh affected GREEN; retain failed attempts. Inspect unmodified C and
use existing strict C11/O0 sanitizer real mains, positive balanced strict counts,
current components/full native gates and actual target-source frontier evidence.
Hard proposed ceilings: production 100 gross/+60 net across five files; tests 160
gross/+160 net; no new fixtures/public API docs; notes at most 10 lines. Preview is
production +83/-39 (net+44), tests +60/-16 (net+44). No allowance stacks.
The [fixed-B SOURCE contract](BOOTSTRAP_SOURCE_PLAN.md#source-cost-acceptance)
requires +3% allocations AND normal min3 instructions for EACH owned unchanged
input AND the supporting-host source-to-C proxy, with every old absolute, strict
zero, identity/diagnostic and LOC limit. Root fixes accepted B/C/full libraries,
corpus/paths and host/STD/tool/metric roles before setup; no roll after failure.
HOST allocations stay the unique positive schema1
artifact_construction_complete.total_allocations checkpoint, never exit TOTAL.
Any host31/STD transition needs its separate explicit matched epoch for B/C.
Historical R0 failures/trends retain their verdicts. No feature-budget transfer,
waiver or old Slice 491/HOST/successful-sample repetition. Root/independent review
and current full acceptance precede commit; any prerequisite, scope, counter,
semantic/ownership/identity or numerical failure stops. Path.normalize stays held;
this plan adds no Path design or implementation.
