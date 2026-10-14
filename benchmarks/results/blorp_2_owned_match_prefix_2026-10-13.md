# Owned prefixes in terminating matches

Status: implementation, isolated tests, matched costs, two independent expert
reviews and combined live integration pass. This
increment of the [roadmap](../../blorp_2/ROADMAP.md) adds ordinary terminating
match support; managed annotated tail loops and general joins remain deferred.

## Ownership contract

Prefix definitions use ordinary stored-slot acquisition before construction and
projected acquisition after definition. Every active prefix root or acquired
projection remains alive until the selected arm exits. The arm secures its
returned obligation before prefix cleanup and excludes only that exact returned
owner. Each arm receives an independent prefix snapshot and a disjoint local
owner interval; sibling ordinal gaps cannot be observed.

Independent verification checks prefix and arm-local owner domains separately,
including sequential field transfers and exact returned owner/value identity.
The match carries its actual OwnedArgument scrutinee backing. Both tag access and
every payload read validate that backing, including unmanaged Int/Void payloads.
A copied scalar may outlive its parent after the read, but the read itself needs
a live parent. This also permits a projected union to use its acquired owner
after its original record ancestor has retired.

The implementation adds no new runtime destruction algorithm, tracing or test
framework. Emission mechanically projects verified ownership operations.

## Frozen evidence

The corrected source hashes are:

- own.brp: `bfc836cf08270338d36a88685265b7d81f5d3c2084a6544869cf78d9006786ce`
- verify.brp: `04e1be1d9c1a302af4b7532c1eaa54bf5ca7f59589e64284818d729c170958a7`
- emit.brp: `b308a366bf69c4c5762b0b21c2d0592d8e212d9d2d5a567bcb2eb8ff505dba08`

The isolated corrected compiler is
`b30c9b607e873308f67bbaaedfa1cd3e5e42edacf7f880c5c162341d6d011bdc`;
generated host C is
`ad9a44b9a6ef478dba026015c7f2548ba2c668895c1191dca1608e106ad893fa`.
It uses the FRESH repository host `286a1720…`, Apple Clang 21, O0 and memory
diagnostics. Its isolated checker excludes the concurrent contextual changes.
The corrected emitter replaces three introduced String operator expressions with
explicit concat calls; all 23 sampled target C outputs remain byte-identical to
the original green checkpoint, including nine record and three union shapes.

Ignored artifacts live under child-root `blorp_2/build/roadmap/owned-prefix/`:

| Check | Result |
| --- | --- |
| Original normal-main red | Exact old ownership restriction, exit 1, no C/stdout, zero compiler leaks. |
| Three new phase/raw suites before final coverage addition | 26 callbacks pass. |
| Isolated whole unit inventory | 1,570 callbacks/103 suites pass. |
| Restored changed legacy suites | 387 callbacks/18 suites pass. |
| Grammar | 156 callbacks/8 suites pass. |
| Runtime helper tests | 20 aggregate and 35 String native invariants pass, plus both wrappers. |
| New ordinary-main fixtures | 21 fixtures, 44 native inputs pass. |
| Retained representative programs | Five fixtures, 12 native inputs pass. |
| Corrected emitter/runtime focused gate | 30 phase assertions, 20 aggregate native invariants and one wrapper pass. |

The native fixtures compile unmodified strict C11/O0 C with ASan/UBSan and run
their real main. Exact outputs cover selected-arm effects, aliases, reassignment,
root/child escapes and projected scrutinees. Existing per-fixture cost ceilings
remain unchanged. Native LeakSanitizer is unavailable on this Apple toolchain;
per-object helper tests and phase obligation checks provide separate evidence.

## Oracle and cost checks

Raw tests author target ownership IR independently of insertion. An isolated
source mutation omitting prefix return completion fails exactly the two arm-leak
callbacks, with seven controls passing. Another omitting per-payload scrutinee
liveness fails exactly the Int/Void lifetime callbacks, with seven controls
passing. String still rejects later through its owning acquisition, demonstrating
why unmanaged payload reads need their own tests. Final review added an independent
raw PrefixSlot duplicate-constructor transfer test and a distinct-owner positive.
All 11 raw prefix tests pass. A narrow mutant validating fields against the
initial prefix snapshot fails exactly the new duplicate test, with 29 controls
passing. Production source remains unchanged.

Generated host C shows one initial prefix/local vector sharing retain, local
setters consuming the current root without a per-Drop retain, and one completed
publication. Each selected arm may incur one initial snapshot copy. The new
cleanup/output work is O(P*A), for P retained prefix obligations and A arms.
This does not establish whole-verifier or whole-compiler linearity; inherited
value-fact reconstruction and specialization scans remain.

Twenty unchanged controls at sizes 16/32/64/128 use the same frozen inputs,
library path, toolchain and three serialized samples per binary. All outputs are
byte-identical, and every compiler invocation has strict balanced accounting.
Worst allocation growth is +0.0593%; worst minimum retired-instruction growth is
+0.8959%, both below the predeclared 3% ceilings. Raw pairs and summaries are in
`cost-results/control/`.

Forty-eight new-input proxies vary prefix count 16/32/64/128, arm count 2/4/8 and
roots/aliases/acquired projections/four arm-local owners. All three samples per
input report zero compiler leaks. For 128 roots at 2/4/8 arms, allocations are
38,733/42,809/50,971, minimum instructions approximately 154.2/174.1/220.3M,
and emitted C is 45,879/55,603/75,051 bytes. These candidate-only samples cannot
establish a baseline speedup because the old compiler rejects the inputs.
Exact dimensions and samples are in `cost-inputs/manifest.json` and
`cost-results/prefix/`. These are compilation proxies, not self-compilation.

Feature production growth is +198 physical lines. Unit growth is +1,377,
including 1,184 lines in three new suites;
fixture/group growth is +503. Unrelated legacy formatting was restored before
these counts. Exact snapshots, fingerprints, C excerpts, commands, mutation
restoration evidence and limitations are linked by the local `results.md`.

The combined live snapshot passes 1,800 unit/runtime/grammar printed checks in
115 suites and 275 normal-main end-to-end cases, with no source drift. Standard
recorder packets and preserved compiler/source artifacts are under repository-root
`build/roadmap/integrated-20261013/`. The integrated compiler SHA256 is
`370bb7b4cb406d2c7008fc721e7a5554d077776299d0ca70f596f213722ebcad`;
this differs from the isolated candidate because it includes contextual inference.
