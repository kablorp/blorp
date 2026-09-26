# Callable rows owned locally during header preparation (2026-09-25)

## Change and ownership check

`prepared_module_environments` no longer keeps a growing `callables` list in
each `PreparedModuleCallableBase`. It visits the canonical callable headers in
their existing order, appends accepted rows to one local `active_rows` list,
then stable-sorts and publishes that module's rows at a module transition.
Header conversion still updates the same module state and emits the same
missing-name error. The former `prepare_accepted_module_callable` wrapper is
inlined, so a per-header result record is not introduced. This is one traversal
plus per-module sorting, not a module-by-header rescan. The header graph's
module grouping is asserted by the extended callable-header test.

The FRESH `-O2` compiler's generated C (SHA-256
`c978ed032a4d9845251a9130f2159b511e469f341c2f188a67fed29d808e32aa`)
passes `active_rows` directly to `blorp_list_ensure_capacity_checked` near
line 348151, without a retain of that list before the COW check. The prior
[clear-slot probe](typecheck_callable_clear_slot_rejected_2026-09-25.md)
failed this exact check. This proves the source cut removes that particular
record-held alias; it is not a runtime attribution of every list copy.

## Matched callable-header workload

Baseline source is clean `62c88fdc`; candidate source is `c57f1b9e` plus the
uncommitted `decl.brp` and test diff. Commits between them change only notes.
Both binaries used the same `dev-048a5864cd98` bootstrap, Apple clang 21,
FRESH CLI/runtime `-O2`, and the same benchmark entry fixture. The benchmark runner
used `BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1` and the explicit baseline or
candidate binary; its profile-mode host C is `-O0`. Each fixture has 10
iterations, retained parsed programs, and zero parameters/dimension
constraints per header. All runs reported valid workloads, zero errors, and
matching source/typed declaration counts and checksums.

| Modules × headers | Baseline list copied bytes | Candidate list copied bytes | Baseline allocations | Candidate allocations |
| ---: | ---: | ---: | ---: | ---: |
| 1 × 32 | 3,236,560 | 3,203,920 | 203,410 | 203,200 |
| 1 × 64 | 3,584,720 | 3,438,160 | 251,940 | 251,430 |
| 1 × 128 | 4,772,560 | 4,152,400 | 348,790 | 347,660 |
| 1 × 256 | 9,114,320 | 6,563,920 | 542,280 | 539,890 |
| 1 × 512 | 25,662,160 | 15,319,120 | 929,050 | 924,120 |
| 4 × 64 | 8,213,360 | 7,628,080 | 691,610 | 689,320 |

At 512 headers, process-wide copied-list payload fell by 10,343,040 bytes
(40.3%) and allocations fell by 4,930 (0.53%) across the ten iterations.
Dictionary copied bytes were identical for each matched fixture (16,782,160
for one module; 33,325,600 for four). The *remaining* process-wide list-copy
curve is still super-linear. These counters cover all list-copy sites and
capacity growth; the experiment does not claim that the other copies are
resolved or that every byte saved came from one append.

The 512-header raw logs are
`/tmp/typecheck-callable-local-rows-baseline-512.log` (SHA-256
`5db9ba94bd2ca28028a40d2f2a6c1eb94996e57caadf3caf2ddc60ebf13eef02`)
and `/tmp/typecheck-callable-local-rows-inline512.log` (SHA-256
`cdf710dab334cd9eb34cfd2b32a0adf9bd31d0ea057863b1824f883465d90cf9`).
The other ephemeral logs use the same prefix with `base32`, `base64`,
`base128`, `base256`, `baseMixed`, `inline32`, `inline64`, `inline128`,
`inline256`, and `inlineMixed` suffixes. A reproducer for the wide case is:

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
BLORP_COMPILER_BENCHMARK_COMPILER=/absolute/path/to/baseline-or-candidate/bin/blorp \
  benchmarks/compiler_callable_header_profile 10 1 512 0 0 retained
```

## Frozen-input compile and gates

Both self-compiles used frozen input `101976d38fb0b3153141ab7440b7db1684db8174`
and three retired-instruction samples. The clean baseline binary SHA-256 was
`967bfbaaab647e26fdbc13d54ac0b78c352769ff3f49acefc09d207f120ede07`;
the inline candidate was
`87e6aabc4ea9ce5a2ff3010ab97fc7bc4198a11c44e6f4d7bddea2f63760cb2c`.
The baseline was freshly built at `-O2`, and the candidate was separately
checked FRESH at `-O2`. The harness used `--skip-build-check` to avoid a
default-optimization rebuild. The baseline
and candidate JSON are `/tmp/typecheck-callable-local-rows-baseline.json`
(SHA-256 `54618e41240ddc0bbe91009b666df4c9e1e8d398c80283e450a4265dfd079a45`)
and `/tmp/typecheck-callable-local-rows-inline.json`
(SHA-256 `d2194535da6d40edc20052437fbf24822b8dcddbdf20d6a9b4ac3968fc94560d`).

| Frozen workload | Baseline | Candidate | Result |
| --- | ---: | ---: | --- |
| Self typed-frontend allocations | 29,837,783 | 29,825,136 | −12,647 (−0.04%) |
| Self total allocations | 209,634,333 | 209,621,686 | −12,647 (−0.01%) |
| Self minimum retired instructions | 168,847,965,486 | 168,659,968,851 | −0.11% |
| Small typed-frontend allocations | 847,964 | 847,363 | −601 (−0.07%) |
| Small total allocations | 1,545,254 | 1,544,653 | −601 (−0.04%) |
| Small minimum retired instructions | 1,289,141,903 | 1,289,319,468 | +0.01% |

Every candidate self-compile instruction sample was below every baseline
sample: baseline `[168892710002, 168927332602, 168847965486]`, candidate
`[168767450856, 168665352100, 168659968851]`. Small-program samples
overlapped: baseline `[1289141903, 1289590682, 1289514153]`, candidate
`[1289319468, 1292167075, 1291643278]`; the small minimum difference is
not a repeatable regression signal. Peak RSS was one sample per side and rose
0.22% on self-compile and 0.37% on small; neither is a stable RSS claim.

Generated C was byte-identical: self 83,571,359 bytes, SHA-256
`7c413d235c7e3ff080474e4f79f87dd15e528310597de53cfdd8c5120dd77195`;
small 42,475 bytes, SHA-256
`b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`.
Focused declaration and callable-header suites passed 166/166 and 10/10.
The selected `scripts/compiler-check --changed --base c57f1b9e` passed
241/241, and the independent `scripts/test --no-build compiler-blorp` gate
passed 5,115/5,115. A separate read-only source review found no actionable
ordering, ownership, or complexity defect.

The older owner-local result JSON was **not** used as an acceptance baseline:
its frozen-input generated C differed from this branch. This result compares
only the clean `62c88fdc` binary and its production-identical inline candidate.
No Core/backend/runtime source was changed in this cut. The bootstrap-built
compiler therefore observes this typecheck edit; the harness's generic
stage-2 warning about other worktree runtime changes is not evidence that
this frontend cut was hidden.
