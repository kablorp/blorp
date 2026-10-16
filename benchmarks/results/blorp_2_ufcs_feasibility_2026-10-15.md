# UFCS declaration validation: first prototype rejected on cost

The first declaration-time receiver-clash prototype fails its pre-set tiny-input
cost gates. On the unchanged `return/zero.brp` input it adds **276 allocations
(+3.27%)** and **1,091,394 retired instructions (+2.58%)**. The limits are +1%
allocations and +0.5% instructions. This is a rejected feasibility experiment,
not a completed or merge-ready implementation. The limits remain unchanged.

## Exact boundary and result

These measurements cover the pilot's complete normal source-to-C CLI
invocation, including loading the configured temporary library and checking
its prelude. The input contains only:

```blorp
func main() -> Int:
	0
```

Both compilers receive the same input and library bytes from this worktree.
The target C is byte-identical across all six recorded runs. Every run reports
balanced allocations and zero leaked objects/bytes under
`BLORP_LEAK_CHECK=strict`. No target-native execution is claimed here.

| Run, in serial baseline/candidate pairs | Baseline instructions | Candidate instructions | Baseline allocations | Candidate allocations |
| --- | ---: | ---: | ---: | ---: |
| 1 | 49,677,982 | 43,538,086 | 8,428 | 8,704 |
| 2 | 42,333,345 | 43,458,579 | 8,428 | 8,704 |
| 3 | 42,337,742 | 43,424,739 | 8,428 | 8,704 |
| Minimum | **42,333,345** | **43,424,739** | **8,428** | **8,704** |

The first baseline instruction sample is visibly higher; the last two baseline
samples agree within 0.011%, and all candidate samples remain above the +0.5%
limit. A preceding candidate invocation measured 50,898,146 instructions and
the same 8,704 allocations; it is retained separately and excluded from the
three-pair comparison. No explicit baseline warmup was run before pair 1.
This limitation does not explain the deterministic allocation failure or the
instruction breach relative to the two stable baseline samples.

The allocation ceiling is `min(9300, ceil(8428 × 1.01)) = 8513`; the candidate
uses 8704 every time. The instruction ceiling is `42333345 × 1.005`, about
42.545M; the minimum candidate uses 43.425M. Compiled work stopped at this
repeatable breach. The retained 32- and 128-module stress inputs, unchanged
accepted corpus, full gate, frontier, and mutation matrix were **not run**.

These are input-program proxies. Blorp 2 cannot compile itself yet, so they
are not self-compilation measurements or evidence about its whole future cost.

## Provenance

Measured on 2026-10-15 local time (2026-10-16 UTC), arm64 macOS, Apple Clang
21.0.0 (`clang-2100.3.34.2`). All builds, tests and samples used the
coordinator's exclusive compiled-command slot; no worker compilation overlapped.

- Frozen baseline source: `fb257c94659a10d09bc6c56215af64c13845bd4d`.
- Baseline pilot SHA-256:
  `0f08564c3dd3b1228cc24b9be923cfd5aca33ef398610417ce12aea9e9dbd832`.
- Baseline generated C SHA-256:
  `e1b044511151d29a97f312a2b12895adc18228df079aef91ec029a9168bb1259`.
- Exact frozen host SHA-256:
  `899e0a92cfe1bc91f992bd3ccdd0755448903eb91d91780ac4870bd13d8cfa17`.
  Its build status was checked FRESH. It uses bootstrap `dev-0e1598ed616e`,
  CLI `-O0`, runtime `-O2`, eight-way split.
- This worktree's own `make` also succeeded and reported FRESH, host SHA-256
  `f8ed45758300eb1160bbed053b39e3c61c974d75b20f0cf11f0f32269ed40edc`.
  Its embedded revision differs. The Makefile generated candidate C with this
  host; regeneration with the exact frozen host produced **byte-identical C**,
  removing a host-payload mismatch from the measured pilot comparison.
- Candidate pilot SHA-256:
  `c7a6b49c824b2367ba029a0d5b1f383d950f18d2562347597ed260473c7116bf`.
- Candidate generated C and frozen-host regeneration SHA-256:
  `7dabe83e025dcb91d24d67b684f2bc82ecad70f93f4f82204905171faf55726d`.
- Candidate source/library manifest SHA-256:
  `c1b9cc55e95948bf100f4739f802b12d9a67c4e639292c831f63fdb4e44d9efc`.
- Measured input SHA-256:
  `51f11cef22e25bf44d65a974bd75b598e845fedf7209838c97a8c863746092e9`.
- Both pilots are linked at `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1`, with
  `-lm -lpthread`. Generated C was not rewritten.

The baseline's compiler/C, input archives, hashes and original 429-fixture
results are coordinator-owned artifacts under
`blorp_2/build/quality-remaining/baseline/` in the integration worktree.
This report records the facts needed to interpret this experiment without any
historical scratch directory. It makes no new whole-corpus identity claim.

## Reproduction and retained evidence

From this worktree, after obtaining the serial slot:

```bash
make
scripts/compiler-build-status
make -C blorp_2 test-compiler \
  BLORP2_COMPILER=build/quality-ufcs/prototype/compiler \
  BLORP2_COMPILER_C=build/quality-ufcs/prototype/compiler.c
BLORP_LEAK_CHECK=strict /usr/bin/time -l \
  -o build/quality-ufcs/measure/zero-candidate-1.time \
  build/quality-ufcs/prototype/compiler \
  --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/return/zero.brp \
  build/quality-ufcs/measure/zero-candidate-1.c
```

Run the same CLI command with the frozen baseline pilot, retaining separate
stdout/stderr/time/C files for each of three paired samples. Use a warmup of
each compiler for any subsequent experiment. The existing normal CLI entrypoint
and unmodified generated C are the whole measurement boundary.

Raw evidence stays under ignored `build/quality-ufcs/`:

- `measure/zero-{baseline,candidate}-{1,2,3}.{time,stderr,stdout,c}` contains all
  measured samples and C outputs.
- `prototype/` contains compiler/C, exact-frozen-host regenerated C, the source
  manifest, binary hashes, Clang version, build log and preceding candidate run.
- `tdd/baseline.log` and `focused.log` contain the test results below.
- `tdd/baseline/` freezes the pre-implementation production sources and original
  two-test regression through its ordinary TestSuite entrypoint.
- `host-freshness.txt`, `own-host.sha256` and `make-host.log` retain local host
  build evidence. `input-sha256.txt` pins the copied bounded stress/repro inputs;
  they were not substituted for the measured repository fixture.

## Correctness scope and implementation size

The baseline fails **2/2** new unused/different-arity regression callbacks.
The candidate passes **13/13** focused tests: five declaration/visibility/hint
tests and eight shared-overlap unification tests. They cover exact primary and
ordered note spans for unused clashes, different arities, a private local
conflicting with a public imported receiver, a private provider staying hidden,
and a unique generic receiver retaining its concrete constructor hint. Solver
tests cover disjoint heads, generic List overlap, repeated-variable consistency
and conflict, independent parameter owners, phantom slots, rigid actual caller
parameters and occurs-only disjointness. Broader planned coverage is pending.

The preliminary production delta is **+13 physical lines**, including the new
216-line validator; tests add **277** lines. Counts are separate and use normal
formatting. No compiler counters, fixture caps, timeouts or host behavior changed.
No commits or integration were performed. Independent code reviews and the
complete gate remain required before any landing.

## Diagnosis limit and next bounded question

The prototype shares `inspect_inference_equality` between receiver selection
and declaration overlap, removes the old accepted-type matcher, counts actual
distinct introductions before reconstructing groups, checks each unordered
new/new or inherited/new pair once, and retains only the exact supplied
prelude subset for inherited/inherited proof reuse. It has one matching path.

This experiment establishes the failure at the **complete tiny compilation**
boundary. It does not yet attribute the added work to counting, namespace
provider enumeration, introduction carriers, group construction, or solver
visits. There is no fresh profile that supports blaming unification. The next
bounded investigation is current-prototype calls/exact attribution across those
functions, comparing simpler direct existing paths. It may not add a cache,
another matcher or a wider limit. New compiled work requires a re-granted slot.
