# Accepted union layout fact preservation

Local preparatory refactor against `d390d5e950de116404f5d419a010c88b1217f3f3`.
`AcceptedUnionEntry.layout` replaces its redundant `is_enum` column. The existing
`UnionLayout` definition moves to a zero-import leaf with case order unchanged:
`TaggedUnion`, then `FieldlessEnum`. Graph entries copy the issued header fact;
bootstrap entries project their existing validated builtin classification.
No eligibility, typed materialization/recovery, traits, native ABI, or Core
representation policy changes. The infer guard still excludes legacy scalar
entries, generics, and resource-containing aggregates.

`accepted_union_is_enum` is a transitional projection, not a new selector.
Foreign scalar admission, including recursive Option, currently consumes it.
Before shared shape-derived scalar eligibility, admission needs independent
explicit native authority: ordinary scalar storage without a native contract
must not admit direct or Option FFI. This preparation does not implement that
future negative admission oracle or claim native/P2a closure.

## Provenance and raw evidence

Worktree: `/Users/keithphilpott/.codex/worktrees/fixed-union-accepted-layout/blorp`.
Artifact root: `/tmp/blorp-accepted-layout.cHwyXP/` (raw filenames below).
Baseline is the retained ROOT stage-1 d390 compiler, SHA256
`3c180d29e0d8e8d14f9acd24c118e8f04491f5ca25e05870e4bb1225a6845ea3`.
Candidate is FRESH stage 1, O2/O2, split8, diagnostics0, Apple Clang21,
compiled by pinned `dev-d44472d3a5d0`, SHA256
`84c8d666c3791ff554e7f92e4693682bd8e52d3a978a33a49977ae14d8e512b7`.
The reviewed import cleanup rebuilt to exactly the same binary bytes.
`status-final-bytes.log` retains final FRESH provenance.

Schema red was captured before production edits with the baseline compiler:
`test --release --timeout 180 .../test_accepted_union_authority.brp`.
First diagnostic: `AcceptedUnionEntry has no field 'layout'`.
`schema-red.log` SHA256:
`8a64c0185fb1df6b96d481d6379f3421cd3a98680661a8e2022ced00f805fa48`.
Additional errors include missing generated embedded inputs in the new worktree;
they are retained, not interpreted as the schema assertion. The pristine existing
baseline suite separately passed 10/10 (`baseline-existing-green.log`). This is
schema TDD for a bijective fact-preserving change, not a runtime bug fix.

Final reviewed source/test/manifest set SHA256:
`cc12863c3bfaf0df758981808ff7ab791657f4b5e905d81a1c951ba64ded079d`.
Computed over sorted changed paths plus the new leaf, concatenating each UTF-8
path, NUL, file bytes, NUL; this evidence note is excluded. `source-final.diff`
retains tracked changes; the new leaf SHA256 is
`3f634cad88d9c5e924785122fe85b18caf8c951d63d706ddca9109d161ab3448`.

## Results and scope

* Owning accepted/header/completion suites: 10 + 59 + 31 = 100/100,
  repeated on final reviewed source (`owning-reviewed.log`). Tests preserve
  localized/imported layout, Option bootstrap layout, and exact rejection text
  when only the copied graph/builtin layout fact conflicts. Deliberately injected
  FieldlessEnum-with-String test metadata remains unchanged, not shape-validated.
* Declaration suite 170/170; explicit binary equality 9/9; canonical counter 1/1;
  adapter pilot 5/5 (`narrow-regression.log`), plus memory utilities 4/4
  (`memory-utils.log`): memory controls total 10/10. Existing pilot active managed
  and raw probes report all 36 event deltas zero. Process-end 3/3 counters are
  only the post-suite harness interval, not total program allocations.
* Manifest validation: 367 production modules, 266 suites, 9 checks.
* Actual changed-module gate, O2: 1855/1855, 13 suites plus maintained leak check,
  repeated at final reviewed bytes (`changed-reviewed.log`). Counts overlap the
  narrow runs and are not additive independent coverage. The maintained helper
  deletes its internal successful logs; complete captured helper stdout remains.
* Leaf and accepted-authority formatting pass (`format-reviewed.log`);
  inherited accepted-test import/line-wrapping debt remains reported by formatter.
  No broad formatter cleanup. `git diff --check` passes.

Repeat owning checks with `bin/blorp test --release --timeout 180` and the three
paths `blorp/test/compiler/stage_06_typecheck/test_accepted_union_authority.brp`,
`blorp/test/compiler/pipeline/test_type_header_graph.brp`, and
`blorp/test/compiler/pipeline/test_global_header_completion.brp`.
The broader maintained command was:

```sh
BLORP_CLI_C_OPTIMIZATION=-O2 make
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-build-status
scripts/compiler-check --validate-manifest
BLORP_CLI_C_OPTIMIZATION=-O2 scripts/compiler-check --changed --base d390d5e950de116404f5d419a010c88b1217f3f3
```

## Bounded raw output identity

Baseline capture occurred before candidate build, separately from schema red.
Both compilers used identical `--no-format --dump-core --dump-core-file=...`
and `-o ...` settings on the same frozen `identity.brp` path. Its SHA256 is
`737e0fdf87ef4c7998e8956e502329f478ccf0d8fa4ee517e859e5e303b2cae4`.
It reads the canonical MemoryStatsActive selector and exercises ordinary/fixed
nullary and String-payload matching. Final Core retains both managed unions with
erased payload storage and the unchanged MemoryCounter enum. Scratch setup
initially used an invalid selector name and missing main parameter; corrected
before the frozen successful capture, with no production fix.

Raw baseline/candidate/reviewed Core SHA256:
`2b55e5d1fa6d6a9d62949aea9adc5b67fa287e8bd2c1574d267963965dcc8755`.
Raw C SHA256:
`67836793b4fab4bfcbdfc49b761b5dc37679012ebea189ba068c40ee407932e7`.
Both `cmp` checks pass without normalization. Outputs are `baseline.core/.c`
and `reviewed.core/.c`; capture logs are retained alongside them.
This is bounded fixture identity, not compiler-self source identity, universal
ownership/ABI proof, self-host/fixpoint proof, or a cost/performance speed claim.

For reproduction, save these exact bytes as one scratch `identity.brp` and use
that same absolute input path for both compiler invocations. A new scratch path
may change output hashes; baseline/candidate identity at that path must still
hold. The original frozen input is retained below so reproduction does not
depend on surviving `/tmp` data:

```blorp
import:
	memory: MemoryCounter(MemoryStatsActive), read_memory_counter

enum NativeChoice:
	NativeFirst
	NativeSecond

union OrdinaryChoice:
	OrdinaryEmpty
	OrdinaryText(String)

fixed union FixedChoice:
	FixedEmpty
	FixedText(String)

pure func ordinary_value(choice: OrdinaryChoice) -> Int:
	match choice:
		OrdinaryEmpty:
			0
		OrdinaryText(text):
			text.length()

pure func fixed_value(choice: FixedChoice) -> Int:
	match choice:
		FixedEmpty:
			0
		FixedText(text):
			text.length()

func main(args: List[String]) -> Int:
	seed = read_memory_counter(MemoryStatsActive)
	ordinary = if seed == 1:
		OrdinaryText("ordinary")
	else:
		OrdinaryEmpty
	fixed = if seed == 1:
		FixedText("fixed")
	else:
		FixedEmpty
	ordinary_value(ordinary) + fixed_value(fixed)
```

```sh
"$baseline_compiler" compile --no-format --dump-core --dump-core-file="$scratch/baseline.core" "$scratch/identity.brp" -o "$scratch/baseline.c"
bin/blorp compile --no-format --dump-core --dump-core-file="$scratch/candidate.core" "$scratch/identity.brp" -o "$scratch/candidate.c"
cmp "$scratch/baseline.core" "$scratch/candidate.core"
cmp "$scratch/baseline.c" "$scratch/candidate.c"
```
