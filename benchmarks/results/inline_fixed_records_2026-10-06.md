# Inline fixed records (2026-10-06)

Eligible `fixed record` types are stored by value: a C struct with no object
header, built with a compound literal, read with `.`, updated as a plain copy,
and never retained, released or checked for uniqueness. Eligibility and the
storage of each position are described in
[`docs/FIXED_LAYOUT_ROADMAP.md`](../../docs/FIXED_LAYOUT_ROADMAP.md#inline-fixed-records-landed).

## Stage-2 self-compile

Both compilers were built at `BLORP_CLI_C_OPTIMIZATION=-O2` with Apple clang
21.0.0 (clang-2100.3.34.2), aarch64-apple-darwin, 8-way split, and measured
with `benchmarks/self_compile_measure --stage2` compiling the same frozen
input, `c148b2d2c` (origin/main). The candidate is the final branch source
on that base.

| Metric | Baseline `c148b2d2c` | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Allocations | 248,130,812 | 243,243,245 | -1.97% |
| Retired instructions (min of 2) | 228,549,074,092 | 226,500,312,111 | -0.90% |
| Peak RSS bytes | 2,189,246,464 | 2,168,913,920 | -0.93% |
| Output C bytes | 83,525,058 | 83,456,136 | -0.08% |

Instruction samples: baseline 228,783,889,056 and 228,549,074,092; candidate
226,618,109,483 and 226,500,312,111.

The phases that gain are the ones whose hot records became inline:
`source_discovery_complete` -1,511,150 (-8.21%; discovery table rows,
`LineColumn`), `core_lowering_complete` -2,548,893 (-12.69%;
`CoreSourceLocRow`, `lib/source` `Cursor` and `SourceLineColumnSpan`),
`typed_frontend_complete` -576,239 (-1.56%), Perceus -233,077. The largest
increase is `pass_mono_complete` +29,570 (+0.11%): the representation
decision and the identity-builtin check read every declaration once.

An earlier draft of the identity check walked every function body on every
compile; it cost 2.6M allocations in `pass_mono_complete` and turned the
instruction delta to +0.32%. The check now reads body roots and walks bodies
only when a program uses an identity builtin on an inline record.

Caveats:

- The generated C differs by design, so the pair is not an output-identity
  comparison. Generated-C review, the ownership gates and the fixpoint below
  carry correctness.
- Two samples per side; the 0.90% instruction gap is larger than the spread
  of either side (0.10% and 0.05%).

## Records that became inline

In the compiler's own final Core, 71 records are inline and 48 fixed records
keep the managed layout (each holds a `Bool`, a managed field or another
managed record). The compiler's stage-3 C defines the same 71 headerless
structs. The inline records include:

- discovery tables: `BodyRow`, `RowRange`, `SourceRow`, `MemberRow`,
  `ImportRow` and 27 other `tables/rows` rows, `LineColumn`, builder opening
  fields, `WrittenQualifier`;
- lexer and parser: `LambdaBodyLevel`, `LineSpacesScan`, `TokenRange`;
- typecheck: `IndexSpan`, `ImplMethodTarget`, module ranges, DFS and visit
  frames, `QualifiedTypeNameSplit`;
- Core and backend: `CoreSourceLocRow`, `DfsFrame`, `ListSpreadPlan`,
  `StaticMatrixDimensions`, `PositiveBinaryFloat`;
- shared: `lib/source` `Cursor` and `SourceLineColumnSpan`, `json`
  `JsonScanner`, LSP `ProtocolPosition`, `ProtocolRange` and `PositionScan`.

Method: `bin/blorp compile --no-format --dump-core --dump-core-file` on
`blorp/src/main.brp`, counting `inline_record` declarations and `"form":"fixed"`
heap records.

## Generated C

`codegen_audit/should_pass/blorp_backend_inline_fixed_record.brp` (a
`Segment` of two `Point`s, updated in a nested record update):

```c
typedef struct brp_ty0 {
  double f0;
  double f1;
} brp_ty0;
typedef struct brp_ty1 {
  brp_ty0 f0;
  brp_ty0 f1;
} brp_ty1;

static brp_ty1 brp_21(brp_ty1 brp_v_f4, double brp_v_fm) {
brp_ty1 brp_v_fK = brp_v_f4;
brp_ty0 __t10_0 = brp_v_fK.f0;
brp_ty0 __t10_4;
{
brp_ty0 brp_v_g5 = brp_v_f4.f1;
double __t10_1 = (brp_v_f4.f1.f0 + brp_v_fm);
double __t10_2 = brp_v_g5.f1;
brp_ty0 __t11_3 = ((brp_ty0){ __t10_1, __t10_2 });
  __t10_4 = __t11_3;
}
brp_ty1 __t11_5 = ((brp_ty1){ __t10_0, __t10_4 });
  return __t11_5;
}
```

No constructor, allocation, reference count or copy-on-write check remains.
Inline structs are defined before every other type, each after the inline
records its fields hold; record representation orders the declarations.

## Validation

On the final source, rebased onto `c148b2d2c`:

- `make hygiene-check`: passes (identity census baseline refreshed in this
  change for the representation decision table and the `InlineRecordDecl`
  arms beside `HeapRecordDecl` arms; both follow from Core naming types by
  spelling).
- `scripts/compiler-check --changed --base origin/main`: 5,010 passed,
  including the codegen audit and core sanitizer.
- `scripts/test --no-build --serial compiler-core-sanitize leak runtime cli`:
  8,543 passed.
- `scripts/compiler-fixpoint`: stages 1, 2 and 3 emit identical C, with the
  same 71 inline structs as the measured candidate.

Runtime allocation tests (`blorp/test/test_runtime/test_memory/`):
`test_inline_fixed_record_allocations.brp` pins zero allocations for
construction, nested update, parameters and results, loop updates, branch
joins, `Char` fields, generic instances, sized numbers and
equality/hash/order, with `Bool`, `String` and ordinary-record controls that
still allocate; `test_inline_fixed_record_boundaries.brp` pins the exact count
at each boxed or inline boundary.
