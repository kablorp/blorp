# Ordered checked call operands

Status: two independent code and cost reviews approve; final strict and
maintained CI-policy qualification completed. This is an ordinary source cleanup,
not seed publication or M8 acceptance.

## Result and ownership

The checker freezes each call's operands once in written order, including its
UFCS receiver first. The checked call owns that stream for the checked program's
lifetime; recursion analysis and specialization consume it directly.

```blorp
fixed union CheckedCallOperand:
    ValueOperand(CheckedExpr)
    CallableOperand(CallableParameterId, CallableChoice, Span)

fixed record CheckedCall {
    target: CallTarget,
    operands: List[CheckedCallOperand],
    span: Span
}
```

`InvokeFunction` now holds only `CheckedCall`. `UserFunction` retains declaration
identity and generic type arguments; callback choices live in the operand stream.
`CallableArgument` and the transient `ResolvedArguments` disappear. A single
ordered translation loop replaces the three-cursor merge and its two impossible
missing-operand diagnostics. There is no filtered ordinary/callback collection,
extra retained catalogue, cache or visitor framework.

Callable destination parameter IDs, forwarded source IDs and occurrence spans
remain explicit and distinct. Ordinary-child call discovery visits value operands
before their parent call; type discovery visits the node before its ordinary
children. Both skip callback capture metadata, whose existing separate discovery
remains. Callback preparation and specialization keys preserve their previous
relative order. Translation erases named/noncapturing callbacks and inserts
capturing environments at their written slots. Callable-target environment
prepending is unchanged. Only a confirmed self-tail call makes the transient
dense value list required by the existing `RecurWith` boundary.

Child freezing, solved-signature publication, parameter/result admission and
complete-argument validation retain their order. Call and expression spans keep
their separate meanings. No parser, language, runtime, concrete IR or later-stage
representation changes are included.

## Lines and prospective limits

Complete production migration: **207 added / 212 deleted, net -5 physical lines**
across six modules. The total is 10,229 to 10,224. The initial -17 checkpoint was
recounted after expanding three long constructor expressions for readability;
no compressed formatting was used to retain a saving.

Tests: **1,048 added / 602 deleted, net +446 lines** across 49 migrated observer
files and one new 133-line suite. Existing named test callbacks and their
identity, type, span, ownership and absence assertions remain. Early review
caught dropped callback-absence checks and two inappropriate fallback arms;
these were corrected before final approval. Documentation is reported separately
and is not counted as a production reduction.

Before production edits, the limits required net production LOC reduction;
rejection or rescoping for repeated actual-self-built allocation or instruction
increases above **0.5%**; and bounded investigation for RSS increases above **2%**.
RSS was an investigation trigger, not a hard ceiling. The original prospective
plan is retained separately in the evidence packet. No ceiling or fixture cap
was widened. The user's overall-direction guidance permits an explicitly mixed
tradeoff; it does not excuse significant allocation/instruction regressions.

## Provenance and method

Base: `15dd947d596cc4012dec6648a1ced835969a7292`. All **612** frozen
compiler/library/fixture inputs match that base's Git blobs. Every measured
compilation uses the same physical input, library, working directory and output
path for its paired comparison and checks frozen pins before and after execution.
The source patch SHA-256 is
`4f71fc6e7b9420c8987c39636e0239da64566b8e5f1b159ece9a9379f628039e`.
The 56-file candidate source/library manifest SHA-256 is
`6d94970e291c07f5478ad794474d7a04d00a6131396ce32d2558a9cd26f1ee87`.

The previous qualified actual-self-built baseline artifacts were reused only
after all 56 producer files matched this base and fresh pinned-seed generation
reproduced their exact compiler C. Toolchain and flags match: Apple Clang 21,
**-O0**, memory diagnostics 0/1 and `-lm -lpthread`, following Blorp2's maintained
target link policy. The repository host is FRESH from immutable
`dev-07bc7629a132`, commit 15dd947, CLI O0/runtime O2.

Both paired normal and diagnostic images are actual self-built target compilers.
Baseline normal/diagnostic hashes are `6b196ce5...3fcb34` /
`4568c148...e404af`; candidate hashes are `b932b7ed...d3e2d1d` /
`10ac92bf...1a3318`. Complete hashes, flags, commands, source snapshots and streams
remain in the raw packet. The generic legacy self-compile harness targets the
legacy CLI; this local paired runner exercises Blorp2's actual CLI and allocator.

Diagnostic samples provide allocations; normal samples provide instructions and
peak RSS through `/usr/bin/time -l`, timing the compiler directly. Full normal
order is B1,C1,C2,B2,B3,C3. Retain all three samples, report minimum instructions
and median RSS. Background machine activity is uncontrolled and the measurement
compatibility lock is a passthrough, not a machine lock. No latency claim is made.

## Matched actual-target results

| Frozen compiler source | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 27,315,461 | 27,295,361 | -20,100 (-0.0736%) |
| Minimum instructions, 3 normal runs | 739,653,645,144 | 739,770,860,226 | +0.0158% |
| Median peak RSS, 3 normal runs | 268,566,528 B | 268,615,680 B | +49,152 B (+0.0183%) |

Instructions and full peak RSS are effectively flat. Both strict diagnostic runs
have equal allocations/releases, zero tracked leaks and zero outstanding bytes.
Both diagnostic and all six normal runs emit exactly **17,134,812 bytes**, SHA-256
`98f5b33457b44e79f504bc11aa01b76e78e6f77a76ccfe4acec66b14aae8d42b`.

A fixed prospective guard batch covers ordinary calls (`call/one.brp`), named
callbacks (`generic/named/ordered.brp`) and managed captures
(`generic/lambda/capture_managed.brp`). Each uses one strict diagnostic pair and
three alternating normal pairs: **24 processes**, all retained. C is identical
within every fixture; diagnostic counts balance with zero leaks/bytes.

| Input | Baseline allocations | Candidate allocations | Minimum instruction change | Median RSS change |
| --- | ---: | ---: | ---: | ---: |
| Ordinary | 101,007 | 100,642 (-0.3614%) | +0.0628% | +81,920 B (+0.9311%) |
| Named callbacks | 113,157 | 112,749 (-0.3606%) | +0.0609% | +245,760 B (+2.7778%) |
| Managed captures | 182,825 | 182,340 (-0.2653%) | +0.0612% | +16,384 B (+0.1538%) |

All measured target inputs allocate less; instruction changes are small and
below the prospective limit. These are compilation costs, not fixture runtime
speed claims. The compiler's own generated C falls **8,421 bytes (-0.0491%)**,
from 17,134,812 to 17,126,391. The pinned seed, its compiled A, and the resulting self-built B emit
that same changed-source C, SHA-256
`c0f31daf55acc43b9354d9adf63719ca5f6057a22e6bbebe575a259b0dfd978a`.
Both changed-source strict runs balance 27,286,302 allocations/releases with
empty stdout and zero tracked leaks/bytes. These are separate from the frozen
input measurements above.

## Representation and RSS assessment

The host-only public `check` + `specialize` probe loads the frozen full program
before resetting memory statistics, performs ten complete successful pairs, and
reads counters while the 54-module parsed input remains alive. Counts balance
but increase from **64,387,110 to 64,506,160 (+0.1849%)**. Its whole-process
instruction count includes setup and is not a phase-only instruction metric.
This is a legacy-host representation proxy, not the target allocator.

Generated C explains why the representation costs differ. The legacy host's
`CheckedCallOperand` has allocating boxed-union constructors (unique reuse is
possible); the old callback record stored its fixed parameter/span fields inline.
The target stores the new operand as an **inline owning tagged union**:
`candidate1-self.c` maps CheckedForm's call arm through record r74 to list[u51];
u51 stores its value pointer or callable fields by value. List slots are
`struct blorp_u_51 values[]`, and operand construction uses compound literals.
It adds no separate target heap wrapper. The exact mapping, C hashes and bounded
excerpts are retained in `reviews/operand-representation.json`. This establishes
the representation difference, not a complete causal account of the -20,100.

Named-input RSS crosses the investigation trigger. Its three baseline values
are **8,847,360, 9,076,736, 8,814,592 B**; candidate values are
**9,076,736, 9,093,120, 9,125,888 B**. Their ranges only touch at 9,076,736 B;
this is not proof of noise. The fixed cross-input contrast gives +80 KiB,
+240 KiB and +16 KiB, while the full compiler-source median changes by +48 KiB.
Source/C inspection also establishes that inline operand list slots carry the
largest variant's payload rather than just an ordinary expression pointer.
Neither observation identifies the peak-RSS phase or cause. Strict accounting
establishes balance, not low peak memory.

The bounded assessment accepts this small mixed tradeoff: a simpler single
operand authority, -5 production lines, fewer allocations on all measured target
inputs, effectively flat instructions/full RSS, and the retained adverse named
RSS result plus host-probe increase. Two independent cost reviewers concur.
There is no footprint or speedup claim, new tracing mechanism, resampling to
make the RSS result green, or hard ceiling being waived.

## Correctness and qualification

The initial two baseline-compatible direct tests pass on unchanged production.
Their migrated and strengthened versions pin mixed direct/UFCS value, named,
capturing and forwarded operands, destination/source callable identities,
exact source/start/end spans, and exclusion of capture metadata from ordinary
call discovery. Existing native order, forwarding, erased ABI and tail-argument
coverage remains. Owning runs pass **1,077 checker tests** and **300
specialization/operand tests**; the latter includes the new two-case suite.

Five independent mutants each produce one intended named semantic failure:
wrong callable positions, width-preserving shifted spans, capture-metadata
traversal, environment prepending, and callback-key reversal. The three checker
mutants each fail one of two tests; the specialization mutants each fail one
of ten. Each exact restoration replays green: **26 restored PASS / 0 FAIL**.
All 56 source/library and two test pins match after every restoration, and the
final production patch is byte-identical to the measured candidate.

The independent test runner completed `make -C blorp_2 test` on the frozen
candidate: **4,180 hosted component PASS / 0 FAIL**. The strict native gate exits
2: **92 native callbacks PASS / 467 FAIL**, plus the failing umbrella, and
**781 nested PASS / 0 FAIL**. Every failed callback and its ordered category/cap
matches the exact base: **112 allocation and 355 retired-instruction overruns**.
There are no new semantic, setup, sanitizer, counter-validity, strict-accounting
or independent file-state failures. This is inherited resource debt, not a
strict gate PASS.

Baseline reuse verifies the exact base compiler C and diagnostic binary plus
**642 unchanged relevant native harness/fixture/build-policy inputs**. It reuses
only failed-callback/category/cap evidence, not old timings or component counts;
no relevant drift or unexplained new failure required a fresh baseline e2e.
The old host build metadata differs; its compiler/runtime/library logic and the
target producer inputs are unchanged, as recorded in the reuse receipt.

The maintained source CI-policy equivalent then runs against the **same default
compiler image**, with instruction measurement disabled and
`record-allocation-debt`: **559 native callbacks PASS / 0 FAIL**, one umbrella
PASS and **781 nested PASS / 0 FAIL** (raw **1,341 PASS / 0 FAIL**, exit 0,
empty stderr). It retains **112 allocation FAIL debt records**; instructions
are **UNMEASURED**. The default generated compiler C matches the self-reproducing
candidate (`c0f31daf...dfd978a`), and its executable SHA-256 is
`c8ae776404a3e4a689514b8c703b7c06ff2183d5614f57add75efc50212cf6ab`.
All **1,082** source, test, library, policy and artifact pins remain unchanged
through both modes. Full commands, streams, comparison and test-runner receipts
are retained in the evidence packet.

Ordinary source CI explicitly disables instruction measurement and records
allocation debt, per `.github/workflows/ci-platform.yml` and `blorp_2/README.md`.
It preserves allocation FAIL records and blocks behavioral, counter-validity,
strict-accounting and sanitizer failures. CI instructions are **unmeasured**,
not PASS. Strict-local budget failures remain visible; this is distinct from
the C-hash-bound seed-publication exception. No seed, cap or policy change.

Full raw evidence originates under ignored `build/ordered-call-operands/` in
the implementation worktree. Before publication it is copied and hash-verified
in the primary checkout at
`/Users/keithphilpott/CLionProjects/blorp/build/ordered-call-operands-2026-10-20/`.
The preservation manifest covers every packet file; final staged-tree reviews
and publication receipts are supplemental evidence. No raw samples or binaries
are committed. The production source and test changes remain exactly the
reviewed, measured and qualified images.
