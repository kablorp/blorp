# Publish scalar constants as checked literals

## Boundary and scope

Baseline is accepted main `355d050a8fcab68508c48ec3d596ad922c9d8280`.
This implements only audit finding F2. The checker accepts closed Int, Float
and String initializers and already retrieves their complete rows when resolving
direct or qualified reads. It nevertheless publishes `ReadConstant(id)` and a
success constant table. Specialize looks up the same row again, with that table
forwarded through nine translation helpers, then produces an ordinary literal.

Project the accepted value at the existing checker lookup into `AcceptedInteger`,
`AcceptedFloat` or `AcceptedString`. Existing freezing produces the ordinary
checked literal. Keep one small private projection in `check/expressions.brp`:

```blorp
private pure func constant_base(value: ClosedConstant) -> PendingBase:
    match value:
        IntegerConstant(integer): AcceptedInteger(integer)
        FloatConstant(number): AcceptedFloat(number)
        StringConstant(text): AcceptedString(text)
```

The two current lookups change only their successful projection:

```blorp
constant_row(context.constants, id, name.span)
    .map(pure func(row): PlannedLeaf(constant_base(row.value), row.value_type.value_type))
```

Remove `AcceptedConstant`, checked `ReadConstant`, `CheckedFunctions.constants`,
their leaf-observer cases, and Specialize's nine parameters/forwarded arguments
and late lookup. Six production modules are sufficient: Check's expressions,
inference, model, check and recursion, plus Specialize. Lower/Own/Verify/Emit
production stays unchanged. Keep checker-local `CheckedConstant`/`ClosedConstant`
in their present home; moving definitions adds unrelated import churn.

Checker-local declaration IDs/table remain necessary for namespace/import
identity, privacy, constant-called errors, annotation/initializer validation and
unused declarations. Preserve their order and exact diagnostics. Preserve the
current read spans: direct name, full qualified base, and the inner name/base
span under grouping. Do not substitute declaration or annotation spans. Float
payloads pass through unchanged; String payloads remain immutable values, with
independent target materialization and owners at every runtime use.

Aggregate/reference/opaque constants remain deferred. Clarify the current scalar
boundary in `CONSTANTS_PLAN.md` without implementing or deleting those future
designs. Update owning README prose; no syntax or language semantics change.
No evaluator, constant catalogue, cache, runtime global, new phase or other audit
finding is included.

## Budget and acceptance

Production forecast is 45–60 ADD / 60–80 DEL, about 15–25 net lines removed.
Hard scope limits: at most 75 production ADD and at least 10 net lines removed.
Test owners forecast about 90–120 ADD / 45–70 DEL; hard 150 ADD / +90 net.
One ordinary native fixture may add at most 25 lines, with one registration in
the existing owner. Count production/tests/fixtures/docs separately; do not
compress formatting or delete coverage to satisfy a limit.

Judge overall simplification and resource direction, as the user clarified on
2026-10-18; every individual metric need not improve. Source-to-C proxy increases
above 0.5%, or targeted allocation/instruction increases above 1%, prompt owning
phase investigation. Hard ceilings are +1% for whole construction allocations
and min3 instructions, +3% per targeted control, and all tighter existing native
caps. Stop/rescope a breach; do not silently move the baseline or tune unrelated
code. Report RSS and retained checkpoints; investigate material RSS increases
above the greater of 1% or 1 MiB. One complete additional matched batch may
resolve ambiguity; retain all originals. Small isolated movements do not create
a requirement for every metric to decline or another automatic approval step.

## Tests and measurements

First migrate the existing four checker literal tests and selected/qualified
test; add one grouped MIN/MAX read oracle. They compile on B but fail assertions
because B publishes `ReadConstant`. Retain admission, dense IDs, namespace,
privacy and exact error tests. Cover decoded UTF-8/NUL and raw String bytes.
Keep downstream per-use String value/owner/drop and unused-emission oracles;
add a bounded Specialize assertion for repeated reads in generic instances.

One `constant/managed_generic.brp` main will combine repeated String constants,
distinct Int/Float generic instantiations, UTF-8/NUL and a negative-zero constant.
Use exact stdout, including `-0\n`, through the existing native harness. The
fixture does not prove unused values allocate nothing; existing emission tests
own that oracle. Kill and restore a bounded incorrect scalar projection and
show the named phase tests fail, then pass with exact source restoration.

```sh
bin/blorp test --suite --timeout 180 blorp_2/test/unit/test_check/test_constants.brp blorp_2/test/unit/test_check/test_constant_imports.brp
bin/blorp test --suite --timeout 180 blorp_2/test/unit blorp_2/test/runtime blorp_2/test/test_grammar
make -C blorp_2 test-compiler test-e2e
bin/blorp test --suite --timeout 180 blorp_2/test/tooling
```

This worktree borrows the verified FRESH repository host with explicit
`--std-dir`; record equivalent direct commands, not an unrun Makefile PASS.
Build the candidate pilot once; run the sole e2e entrypoint with required
instructions, unchanged caps, strict zero accounting and existing sanitizers.
Compare B/C normal CLI outcomes and successful C bytes for every frozen fixture
root, including the new fixture, without normalization. Inspect representative C.

Freeze sources/libraries/tools and inputs before production edits. Reuse the
source-matched F1 normal/diagnostic pair as B only after hash/provenance checks;
take fresh measurements. Measure the host constructing B/C compiler C plus
six pilot controls: `constant/integer.brp`, `constant/float.brp`,
`constant/pipe.brp`, `constant/aliases.brp`, `constant/managed_generic.brp` and
`generic/named/managed.brp`. Keep input/library/output paths fixed per comparison.
Use diagnostic allocations and serial normal samples B1,C1,C2,B2,B3,C3, reporting
original min3 instructions and median3 RSS. Require within-role normal/diagnostic
C identity and B/C fixture C identity. Source construction C may differ between
roles. The source-to-C workload is a host construction proxy, omitting linking,
target self-compilation and its unavailable later-stage lifetime measurements.

Root owns integration and the serialized compiled lane. Independent code-reviewer
and test-runner review the plan before its separate commit, then the final code,
tests and evidence before acceptance. Preserve raw evidence under ignored build
and in the primary checkout before archival. Land an accepted green result as
one squash commit on main, push origin/main, and verify the remote SHA.
