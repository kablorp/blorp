# Blorp 2 architecture audit, 2026-10-10

Audited revision: `49dbb089122685b479459ad37a874c754dbe0544` (`blorp-2`).
Independent compiler-expert audit; no tracked compiler or test changes. The
concurrent comparison-script and host-main work is outside this audit. Findings
come from current sources, not earlier approvals. No memory-derived claims.

## Verdict

The architecture is a sound incremental basis. It preserves a pure pipeline,
separate identity domains and complete immutable success products. Semantic
names disappear at checking; I found no semantic String lookup in specialization,
lowering, ownership or verification. There is one reproduced publication-boundary
defect, one bootstrap-constraint violation, and a concrete scaling weakness.
None is evidence that the compiler needs a replacement architecture.

## Facts, ownership and lifetime

| Boundary | Authority and published contract | Builder/lifetime |
| --- | --- | --- |
| Input → lex | `LexedProgram`: tokens and half-open byte spans (`syntax.brp:69–87`) | Explicit source inputs; local token list (`lex.brp:67–72`). Token spelling Strings live until parsing finishes. |
| Parse | `ParsedProgram`: complete syntax, accepted prelude, one extended NameTable (`parse.brp:55–66,1623–1695`) | Private ParserState; NameId is spelling identity within this table and extensions. Private parser constructors seal the result. |
| Check | `CheckedProgram`: declaration-owned Function/Union/Record IDs, owner-qualified variants/type parameters, function-local bindings; one signature per function (`check.brp:41–120,153–267`) | Namespace/signature context and substitution slots are transient. All bodies and recursive-instantiation rules succeed before publication (`3418–3438`). Failure retains parsed authority only for diagnostics. |
| Specialize | `SpecializedProgram`: concrete instance identities and complete concrete bodies/layouts (`specialize.brp:9–74,185–194`) | Local request queue deduplicates complete nominal keys; substitutions and initiating spans disappear at publication (`1260–1405`). Binding IDs are interpreted only inside their concrete function instance. |
| Lower | `LoweredProgram`: ordered immutable computed values and explicit returning arms (`lower.brp:35–126`) | Private ValueBuilder maps binding versions to ValueIds; aliases share a value, reassignment changes the mapping. ValueIds are function-wide, including branches. |
| Ownership | Public raw `OwnershipProgram`: exact value/owner/borrow/return operations (`own.brp:38–140`) | Local use tables and drop schedule are discarded. OwnerId denotes an obligation, not an object or a ValueId. This is deliberately unverified input. |
| Verify → emit | Only verification seals the exact raw operations/contracts as VerifiedProgram (`verify.brp:51–56,1054–1100`); emitter projects those operations | Verifier independently reconstructs availability/obligation state; emitter never repairs cleanup. Runtime contracts are shared authority, not insertion's decisions. |

Getters expose immutable contents but cannot reseal a modified copy. Function
signatures carried between phases are translated representations of one fact,
not independently editable registries. The verifier's signature lookup and type
checks (`verify.brp:227–313,493–507`) are intentional independent validation of
public raw IR; removing them as redundant checking would weaken its oracle.

### String inventory after parsing

- Parsed syntax occurrences contain `WrittenName {id, span}`, not spelling.
  ParsedContents retains NameTable and the accepted prelude's prefix table.
  This is the only successful post-parse product carrying name strings.
- CheckedProgram, SpecializedProgram, LoweredProgram, OwnershipProgram and
  VerifiedProgram contain **no String-valued semantic fields**. `StringType`
  is a typed language type, not a host String carrier.
- `check_render.brp:102–108,590–638` resolves names/types solely to present
  errors. `prelude.brp:93–103` checks ID membership using name_spelling; it
  does not infer a role from the returned spelling. Runtime lookup compares
  NameIds and produces RuntimeOperation (`73–81`).
- Specialization/ownership/verifier String parameters construct Diagnostic
  message/help text on errors (`specialize.brp:270`, `own.brp:143`,
  `verify.brp:59`). They are not semantic tags or lookup keys.
- Emit and string_runtime produce C bytes and ABI names from typed identities
  and closed operations (`emit.brp:74–96`). Main's paths/source/printed text
  belong to the explicit I/O shell. Target String literal bytes are not yet
  admitted by the input grammar.

## Findings

### F1 — P2, high confidence: the verification seal accepts an unused empty union

`verify.brp:1068–1100` validates every raw record layout but does not validate
all union layouts. Variant operations validate rows only when referenced.
Appending `ConcreteUnion {variants=[]}` to an otherwise valid raw program
therefore succeeds. `emit.brp:225–258,684–686` emits that row as
`enum blorp_u_0{};`, which Clang rejects with `use of empty enum`.

This is a real **raw-IR/publication contract defect**, reproduced below. Normal
parsed programs cannot declare an empty union, so it is not evidence of a
current source-level miscompile. Duplicate/foreign labels are already rejected
(`verify.brp:788–855`). Union and variant IDs are indexed identities rather
than separately stored ID fields; PayloadShape is a closed NoPayload/IntPayload
sum, so unsupported payload kinds cannot be forged as another string/tag.
Do not inflate those into separate findings.

Bounded remedy: check every admitted layout once before sealing, including
unused rows; add a direct raw verifier negative and a valid-unused-row positive.
This should precede recursive layout contracts, where an unchecked unused row
can also affect destruction. Small production growth, no new pass or registry.

### F2 — P2, high confidence: compiler sources have drifted into excluded trait operators

The agreed eventual bootstrap subset excludes traits and requires concrete
functions. Current compiler sources use `<` in `check.brp:770,778`, `>` in
`own.brp:170`, `verify.brp:361`, `emit.brp:277`, and String `+` in
`check_render.brp:149,381,450,516,545` and `parse.brp:1149`.
The language reference explicitly defines these through traits
(`docs/GUIDE.md:2415–2476`).

The host currently supports them, so this is **bootstrap-readiness drift**, not
a target-runtime correctness bug. Replace them with IntOps comparisons and
the existing concat helper. No trait implementation is justified by these uses.
It is a small direct cleanup; it need not wait for recursive data and should
not grow into a source-text scanner framework.

### F3 — P2, high confidence in work mechanism: verifier materializes absent sibling slots

Each arm starts from prefix state (`verify.brp:883–892`) while ValueIds continue
function-wide. Its first definition appends None until the absolute ordinal is
reached (`621–624`). For A arms with one new value apiece this writes
`A(A−1)/2` absent slots: **130,816 holes for 512 actual arm values**. Managed
arms similarly pad UnavailableOwner slots (`886–887`). This is accidental dense
storage of unavailable siblings, not a requirement of global value identity.

Existing sibling-isolation negatives are valuable; the 256-arm e2e checks C
depth and a broad cost ceiling, not this boundary's scaling. The isolated probe
below does **not** establish quadratic wall time: its small measured timings
are roughly linear at these sizes. The source nonetheless has quadratic
absent-slot work.

Bounded remedy: represent the immutable visible prefix plus the current arm's
ordinal interval/local rows, as ownership use analysis already does
(`own.brp:210–231`). Preserve all sibling rejection cases and ID uniqueness.
Measure construction and lookup together before accepting a refactor. No map,
cache or second identity allocator is needed. This may eliminate padding loops
and sentinel variants, but net production LOC reduction is not guaranteed.

## Gaps and hypotheses, not additional defects

**Physical builder uniqueness needs evidence.** Private growing builders are
threaded through pure calls and closures (`lower.brp:153–173,179–220,436–455`;
`specialize.brp:831–909`). The source satisfies local mutation/immutable
publication, but it does not itself prove that the host's generated retain/COW
behavior keeps each collection unique. Inspect generated C and measure a
phase-only linear-size workload before changing carriers. Linear name/instance
searches and repeated type/call traversals (`names.brp:48–70`,
`specialize.brp:417–434,599–616,846–862`) are also measurement targets.
One directly avoidable parser join is intern_name followed by find_name
(`parse.brp:234–236`): returning the issued ID with the extended table removes
the second scan without a cache. Do not claim these dominate current compiles.

**Recursive managed data requires new facts, not relaxed rejection.** Today
PayloadShape admits only Int; lower_capture hardcodes Int (`lower.brp:346`),
value_ownership treats every existing union as unmanaged (`own.brp:191–208`),
and owner aliases/releases are String-specific (`emit.brp:411–466`). This is
correct for the implemented subset. Before admitting recursive children,
publish one complete variant/storage/owned-child contract, reserve identities
only inside the builder, carry actual selected-parent provenance, and verify
escapes/transfers independently. The existing recursion plan already identifies
these requirements; they are not an urgent generic representation framework.

`check.brp` (3,651 lines) combines declaration validation, expression checking,
generic constraints and termination analysis. Boundaries are private and
discernible, but future edits are harder to review here. A bounded extraction
of generic constraints when they next change is reasonable; splitting files
alone does not remove work or establish a new correctness guarantee. The flat
16-module src layout is otherwise proportionate to this pilot.

## Established practice and local choices

- [Rust HIR](https://rustc-dev-guide.rust-lang.org/hir.html) distinguishes
  definition, owner/local-node and body identities. Blorp's identity separation
  and authoritative products follow the same principle; Rust's incremental
  maps are not a reason to add maps here.
- [Bidirectional Typing](https://arxiv.org/abs/1908.05839) supports the explicit
  synthesis/checking split. The pilot's annotated first-order subset does not
  presently require general HM inference. Its argument-only generic matching
  is a deliberate restriction, not a complete unification engine.
- [Rust monomorphization](https://rustc-dev-guide.rust-lang.org/backend/monomorph.html)
  establishes precedent for concrete-instance collection before codegen. The
  parameter-growth graph (`check.brp:3220–3376`) is a conservative local
  termination rule, not Rust's algorithm or a general polymorphic-recursion
  decision procedure. Keep its proof assumptions and negative tests as types
  grow; finite instance sets may still be large.
- [Lean explicit RC](https://lean-lang.org/doc/api/Lean/Compiler/LCNF/ExplicitRC.html)
  uses liveness and derived borrows. Its
  [borrow inference](https://lean-lang.org/doc/api/Lean/Compiler/LCNF/InferBorrow.html)
  also accounts for cleanup after tail calls. Blorp's all-borrowed-parameter,
  owned-result ABI is a simpler current choice. It must not imply constant-stack
  calls or Lean's ownership optimizations.
- [Perceus](https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf)
  uses explicit control flow and ownership resources; the pilot's returning-arm
  IR is an appropriate small start. Keeping a parent alive to arm return is
  safe but does not establish Perceus's earliest-death/garbage-free property.
  [GHC Core Lint](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/debugging.html#ghc-flag-dcore-lint)
  supplies precedent for independently checking compiler IR; our verifier is
  narrower and mandatory for accepted managed output.

## Recommended sequence

1. Repair F1 with direct raw-IR tests before recursive layout work.
2. Remove F2's source operators as a small separate bootstrap cleanup.
3. Implement the agreed unary recursive-union slice with complete child/borrow
   facts and iterative destruction, using the plan's granular negative tests.
4. Address F3 with the managed-prefix boundary or a separate measured refactor;
   retain function-wide identities and eliminate unavailable sibling storage.
5. Measure builder COW, interning and instance lookup on representative growing
   inputs; make only the changes those measurements justify. Defer broad
   modularization, caches, general CFG/SSA machinery and ABI inference until a
   supported example needs them.

## Reproduction and evidence appendix

The reproduction and raw logs are ignored scratch under
`blorp_2/build/architecture-audit/`. The TestSuite intentionally asserts that the
reported bug is present; its PASS is a reproduction, not a correctness gate.

```sh
scripts/compiler-build-status
bin/blorp test --suite --leak-check --timeout 180 \
  blorp_2/build/architecture-audit/test_audit_probe.brp
clang -std=c11 -O0 -Wall -Wextra -Werror \
  blorp_2/build/architecture-audit/empty_union.c \
  -o blorp_2/build/architecture-audit/empty_union
```

Observed: both scratch callbacks pass; the generated enum is empty; Clang
rejects it. Logs: `probe.log`, `empty-union-clang.log`. The verifier probe
prepares each source/ownership program before reading counters and repeats
only verify ten times. The target is the host-compiled verifier, not pilot
self-compilation or target-program runtime. One serial O0 diagnostic sample:

| Arms | 10 verify runs: managed allocations | Elapsed microseconds |
| ---: | ---: | ---: |
| 64 | 10,090 | 2,941 |
| 128 | 20,980 | 5,409 |
| 256 | 44,030 | 9,804 |
| 512 | 92,680 | 21,752 |

MemoryStatsActive was 1. These are one-run observations, not matched before/after
performance results. Counters/elapsed reporting is outside the bracket;
verification result cleanup and the repeat loop are inside. No broad gates
were rerun for this read-only audit. Initial scratch-only import/signature/test
registration errors were corrected before the retained successful run; no host
compiler defect was inferred from them.

Host: FRESH, Apple Clang 21.0.0, CLI/test O0, runtime O2. Host SHA-256:
`494413b6febc7121aa8beeed10af0c16cf2acbaf6b692edbef960fae0e72ba05`.
Audited verify source SHA-256:
`bbad1295f514718f97cdfc576ebfc1f811d1da6b504b8ca7ad35f3ab340e2181`.
Scratch probe SHA-256:
`e3578bd05e16f638340aff22fa465690794c8f46621ee7656948e125cb8c42b4`.
Primary sources above checked on 2026-10-10. No source-level ownership failure
was reproduced in the currently admitted subset; this is not an exhaustive
proof of absence of such failures.
