# MemoryCounter scalar native adapter preparation

The public `read_memory_counter(MemoryCounter) -> Int` now exhaustively encodes
the selector to an explicit native tag before calling a private Int builtin.
`MemoryCounter` remains an enum; runtime signatures, storage and tags are unchanged.
This prepares its eventual managed payload-free spelling without introducing a
scalar Core union or a general native ABI framework.

The wire contract remains C `long -> long`, selectors 0–15 in
`runtime.c`/`runtime_decl.c`. The encoder pins those numbers explicitly rather
than deriving them from ordinals. The same match can consume managed immortal
singleton selectors, as the ordinary/fixed pilot demonstrates.

## Reproduction and artifacts

Base: `073b78ae63d82273fe918be8c3e80e49172bc527`, isolated
`codex/fixed-union-native-adapter`. All compiled jobs were serialized manually.
Raw artifacts are retained at `/tmp/blorp-memory-adapter-production.VCNWS9`:

- `baseline.log`, `baseline.core`: unchanged fixture before preparation.
- `prep.diff`, `prep-test.log`: independently passing test-only parity-helper
  cleanup; sixteen literal tags and three named constructors remain independent
  of the runtime selector helpers. Measured intervals were not changed.
- `check_native_route.py`, `structural-red.log`, `structural-green.log`: same
  executable structural oracle rejects the old direct enum/native route, then
  verifies actual callable IDs, private Int parameter/result/native argument,
  public reader's nested encoder call, and all sixteen constructor-ID to explicit
  literal pairs against the native contract (not enum ordinals). A disposable
  in-memory copied case with ManagedAllocations changed from 0 to 1 is rejected;
  `structural-tamper.log` retains that negative control. Raw Core is unchanged.
  No runtime bug was invented.
- `candidate.core`, `candidate.c`, `pilot.brp`: raw final Core/C and an exact
  fixture-body copy with appended scratch main invoking all five tests.
- `narrow-final.log`, `gates/`, `gates.log`: complete runtime evidence.
- `fixpoint.log`, `fixpoint/`: unmodified self-host gate artifacts.

The unchanged 60-line oracle is retained at
[`fixed_union_memory_adapter/check_native_route.py`](fixed_union_memory_adapter/check_native_route.py),
SHA-256 `9502363dbf98791fc2e6ca6fcd0fa3313013394da110d77715bd1a035932db07`.
It intentionally checks this embedded-memory workload and its current enum
declaration, not arbitrary imports. Its declaration-kind assertion must be
revisited when actual source migration changes MemoryCounter to a union.
Run with ordinary Python (not `python -O`, which disables assertions).

To reproduce without the original `/tmp` artifacts, create a fresh scratch copy:

```sh
adapter_work_dir=$(mktemp -d /tmp/blorp-memory-adapter.XXXXXX)
cp blorp/test/runtime/memory/test_union_counter_native_adapter.brp "$adapter_work_dir/pilot.brp"
```

Append exactly this main to the scratch copy using an editor; preserve its fixture
body and do not add main to the maintained TestSuite:

```blorp
func main(args: List[String]):
	passed: Bool = (
		test_canonical_reads_preserve_managed_and_raw_counters()
		and test_ordinary_reads_preserve_managed_and_raw_counters()
		and test_fixed_reads_preserve_managed_and_raw_counters()
		and test_all_native_tags_and_values_agree_with_canonical_readers()
		and test_runtime_derived_selectors_preserve_values_and_zero_events()
	)
	print("pilot result: ${passed.to_string()}")
```

Then run serially after obtaining the compiled-job token:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status
bin/blorp test --leak-check --release --timeout 180 \
  blorp/test/runtime/memory/test_memory_counter.brp \
  blorp/test/runtime/memory/test_union_counter_native_adapter.brp \
  blorp/test/runtime/sys/test_memory_utils.brp
bin/blorp compile --no-format --dump-core \
  --dump-core-file="$adapter_work_dir/candidate.core" \
  -o "$adapter_work_dir/candidate.c" "$adapter_work_dir/pilot.brp"
python3 benchmarks/results/fixed_union_memory_adapter/check_native_route.py \
  "$adapter_work_dir/candidate.core"
# Negative control must fail with wrong native mapping for ManagedAllocations.
python3 benchmarks/results/fixed_union_memory_adapter/check_native_route.py \
  "$adapter_work_dir/candidate.core" --tamper
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/test --no-build --serial --release-artifacts \
  --log-dir "$adapter_work_dir/gates" std-check runtime leak
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-fixpoint \
  --work-dir "$adapter_work_dir/fixpoint"
"$adapter_work_dir/fixpoint/blorp-stage2" test \
  --leak-check --release --timeout 180 \
  blorp/test/runtime/memory/test_memory_counter.brp \
  blorp/test/runtime/memory/test_union_counter_native_adapter.brp
```

For the structural red control, compile the same scratch input using a FRESH O2
compiler built from the pre-adapter base revision above, retain its raw Core,
and run the same oracle on that dump. It must reject the missing private scalar
reader; there is no expected baseline runtime failure. The tamper option edits
only a disposable in-memory copied case and does not modify its input artifact.

## Results and limits

Baseline and prepared pilot: 5/5. Final focused owners: canonical 1/1, pilot 5/5,
memory utilities 4/4. Serial gates: std-check 1/1, runtime 4,664/4,664,
leak 1,170/1,170; total 5,835/5,835.

All four measured intervals, before and after the adapter, report exactly zero
managed allocations, releases, backing malloc, raw malloc/calloc/realloc/aligned,
cleanup scratch and fiber-mmap event deltas. MemoryStatsActive and OracleStatsActive
are asserted 1 at both endpoints. Each of sixteen tags has canonical/repeated-value
parity. The runtime-derived loop visits all selectors four times; its generated C
retains managed-pointer selection, `->tag` encoding, native calls and singleton
temporary releases. No containers/reports/output are constructed inside intervals.

Final checksums are canonical 12,287,168, ordinary 12,298,432, fixed 12,309,696,
dynamic 128,212. They are observable outputs, not an across-process identity oracle:
AllocatorBytesInUse measures changing whole-process allocator state. Exact
allocation-event deltas and same-counter repeats are the relevant comparison.
Per-test tracked-live-object checks pass; process-exit 3/3 allocations/releases
describe only the post-suite harness interval.

FRESH compiler: stage 1, O2 CLI/runtime, split 8, Apple clang 21.0.0,
compiled_by `dev-d44472d3a5d0`. SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| baseline compiler | e35cefd0a9e3189ddaa5a795cfc75ed80fd837a7f18c25b95d0834dd6bc972b3 |
| candidate compiler | d4866fa2cafa0da8948bdc124da1d67b5801775d73f5bf7114015367f84add3b |
| memory.brp | bb4100e486fa3032d1843565a2a137844ddf6e8d7e7f8fdfe9b00a190fd3dd1e |
| prepared pilot | d0a78f43bef6d7e1871506ae6ecec6b2c5822e816c2eeb7de18fc969308fcec4 |
| raw candidate Core | d440795016973e796599247000f2251d55bb397c3b107c7786542c0a62b978c5 |
| raw candidate C | 189a3b11b97296a777cf3248e31078dc82e06d1d40d7ab052f743ebde0b6a2ec |

Unmodified O2 self-host fixpoint passed. All three raw compiler C outputs are
byte-identical, SHA-256
`1777f13835242b5ea4ecb7909f3c580589203fa8441659d28036d394b728f102`.
Stage-2 binary SHA-256 is
`ff6fbf8da5a3b2652da05528710dc9d21696035272f239827bc42dcd4e9bb4bd`;
stage-3 is `87e8836b4036922d0a8bd7ee5a89c3e4ea9eee8581e056b3d9d94fc0a6dc46ec`.
The retained stage-2 executable also passed canonical 1/1 and pilot 5/5 with
active zero-event intervals (`stage2-narrow.log`). Old/new generated compiler C
identity is not required: embedded memory source and reader routing intentionally
change; no normalization or old/new byte-identity claim was used.
No retired-instruction or latency improvement, universal ABI/no-boxing guarantee,
or executed cancellation safety claim is made. No enum conversion or bootstrap
publication is included; earlier raw measurement JSON is untouched.
