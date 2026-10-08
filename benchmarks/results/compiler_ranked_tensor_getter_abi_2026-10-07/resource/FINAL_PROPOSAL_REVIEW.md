# Independent final renderer proposal and public controls review

**APPROVE: 0 blockers, 0 should-fix, 0 nits.** This is static approval of the
unapplied proposal; root-owned exact two-row allowlist deletion and actual applied
final bytes still need readback. Native correctness/resource acceptance is separate.

Exact renderer delta: `23c7f33b0bc0762ef49311f7a866d22f678d78d58365fd413cf04de842e3ab68`.
Approved preparation: `5fe71603571ab2614b80fc6d6b22b168fb056bb7039e5d78e19a28a497dd9e9b`.
Anticipated final emitter: `24b9bf114c3db06ba8277bccff6e1559d147ad112adc99a33df6991984bebc31`.
Frozen owning suite: `0f48eb4314c49466dbc67f07285dd06721d5118911a79ad8bc6294d22f06342e`.
All artifact hashes match; independently generated preparation-to-final diff equals
exact proposal bytes. Read-only git apply --check passes against applied preparation.

Only the two suffix branches become an exhaustive match of the three admitted
representations. Float64 keeps double / 0.0 / blorp_vector_read_f64; Float32 keeps
float / 0.0f / blorp_vector_read_f32; erased keeps the same erased renderer and temp
seed. Exact twelve-name admission, rank/offset validation, sole checked-parts
constructor, CoreUnboxKind scalar authority and projected struct C-type authority
remain as already reviewed. Argument evaluation, cleanup, known rejected/unknown
fallback and DirectRuntimeCall production emission paths are untouched.

Reviewed all 324 changed owning-suite lines (321 added, 3 import-line replacements).
Seven public output controls cover all twelve operations via simple and statement
Builtin emission, receiver and argument binding order, short/long arity, wrong rank,
dynamic dimensions, unsupported f16/impostor/extra suffix #error rejection, ordinary
pipeline runtime projection, explicit Float/Float32/Float16 unbox across ranks/plain
and shape calls, and shaped inline-record versus existing plain cast fallback.
Erased controls deliberately use a Float tensor with Ptr result. Assertions pin
public C behavior and actual rejection diagnostics rather than private enum shape.

The standalone prepared-emitter controls explicitly bypass late-Core projection;
production legitimate calls become DirectRuntimeCall. Struct-unbox production is
an actual checked-parts consumer. This is a semantics-preserving reader cleanup,
not a demonstrated behavioral bug. Root/test-runner report all seven controls pass
before refactor; this reviewer ran no native commands. Earlier baseline syntax and
incorrect output-premise revisions are retained and must remain documented in the
final evidence, not presented as compiler regressions.

Paired-output resource authority is explicit: maintained self_compile_measure
487–501 saves diagnostic output C and derives total allocations from monotone
checkpoint deltas; 507–518 compares EACH normal instruction sample C hash against
that diagnostic output and fails on mismatch. validate_compiler_pair 398–417
requires normal/diagnostic runtime modes 0/1 and matching exact headers. Therefore
saved C is diagnostic emission proven equal to all three normal samples. The
existing controller also requires baseline/candidate saved C identity and pins
raw JSON/C immediately and through final revalidation. No template change needed.

ABI/Option/temporary-tuple/guard allocation and ARC costs remain unverified until
matched stage-2 proof. No speed/cheapness claim, source edits or native jobs.
