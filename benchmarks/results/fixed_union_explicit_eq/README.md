# Explicit-source binary equality pilot

This pilot preserves selected concrete non-generic explicit `equals` and
`not_equals` callable identities through the existing typed call/Core/CTFE path.
It does not complete common Eq, publish default implementations, change generic
selection, or claim a performance improvement.

## Retained default-method boundary

Run the intentionally failing manual reproduction:

```sh
bin/blorp test --timeout 180 benchmarks/results/fixed_union_explicit_eq/default_not_equals_repro.brp
```

Current result: one runtime PASS, one folded FAIL. Both expectations remain
unchanged. The outer raw binary `!=` folds structurally before entering the
default method, despite the custom explicit `equals` returning False.

`DefaultImplementationMethodHeaderValue` already owns a graph-issued callable
ID and a receiver-substituted signature. Declaration preparation deliberately
skips these headers when publishing accepted implementation method facts
(`implementation_method_infos_from_header` in `decl.brp`). The later concrete
body registry can materialize them by their exact callable IDs.

Two follow-up steps remain: publish valid existing default callable facts at
the accepted declaration boundary, then preserve correct selected calls within
their bodies (or observe and validate safe runtime fallback). The current default
body's unresolved `equals(a, b)` becomes a CTFE intrinsic call; that intrinsic is
UNSUPPORTED, not structurally evaluated. Publishing default facts alone therefore
does not prove successful compile-time evaluation of the default body.

The failing reproduction is not part of the passing runtime corpus and is not
claimed closed by this pilot. Automatic default Eq remains dependent on this
work and the separate generic-selection/bounds prerequisites.

## Existing aliased-trait preparation limitation

```sh
bin/blorp compile --no-format --stop-after=lower benchmarks/results/fixed_union_explicit_eq/aliased_builtin_impl_repro.brp
```

The intended `ANSWER` remains True, but both a 073-derived comparison compiler
(with unrelated `MemoryCounter` standard-library additions) and the candidate
reject this source before the binary-call pilot with
`internal typecheck error: invalid accepted implementation record for trait 'Equatable'`.
This pre-existing aliased-builtin implementation registration boundary is not
repaired here. Transparent receiver aliases, imported explicit implementations,
and a separately declared unrelated namesake trait can reach the pilot and are
covered independently; that does not establish support for their failing combined
aliased-builtin control.

## Validation and exclusions

The pristine073 original four-test baseline fails both folded controls and passes
both runtime controls (2/4). The candidate passes those four and the expanded
nine-test corpus, including imported explicit methods, receiver aliases,
evaluation-once/source order, and ordinary/fixed union controls. The namesake
trait case is only an unchanged builtin scalar control, not aggregate dispatch
or aliased-trait registration coverage.

Native/builtin scalar kinds, legacy enums, generic declarations, uninstantiated
generic method signatures, and resource-containing accepted record/union
declarations retain their existing route. The resource-carrier typed-AST test
asserts the completed declaration really contains a resource and is non-generic
before checking that its operators remain raw binary expressions.

Frozen production `infer.brp` SHA256 is
`8a7b15e73de616e2f2606d094ca65a779b35a4a49de1378e0932d212ede5e4af`
after a bounded formatting-only correction of added hunks. Remaining whole-file
formatter deltas are pristine073 debt; the detailed evidence retains the
comparison. Rebuilt binary and same-input generated C are unchanged, and final
runtime9/leak plus declaration170 reruns pass.
The O2/O2 stage1 candidate is FRESH, bin SHA256
`4611891e58f941a14acaedc203e7c867e87f054f759e3c4182a77d22d7da1036`.
Selected inference gates pass 519/519, CTFE gates pass 191/191, declaration
typed-AST owner passes 170/170, and serial compiler/runtime/leak/Core sanitizer
gates pass 14733/14733 (6520/4673/1165/2375 respectively).
O2 compiler fixpoint passes: all three retained C stages are byte-identical,
SHA256 `6b395442baf9f17ce565237323eb2bf452005a0f259d13a500fa00d93ae97060`.
Existing single-worker generated-C audit passes 228/228. The final original-four
standalone rerun passes 4/4. Both stage1 and retained stage2 expanded fixture
per-test leak checks pass 9/9 with zero tracked live objects per exercised test.
The final process allocation line is a reset post-suite harness interval, not
total fixture allocation cost or a compiler-performance measurement.

Raw logs, original red evidence, selected Core and generated C are retained in
`/tmp/blorp-explicit-eq-baseline.AsZOhr/`; [EVIDENCE.md](EVIDENCE.md) records exact provenance
and individual artifacts. Generated C preserves independently selected methods,
operand evaluation order and releases, and native scalar `long == long`.
Changed folded constants are intentional; there is no baseline/candidate C
identity, allocation reduction, latency, or stage2 performance claim.
