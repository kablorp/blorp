# Duplicate field parser measurement

Baseline: `295cb1441d6a3c3f53e85df57c5c14cd26c31b30`. Original matched candidate includes expression and declaration typed spelling dictionaries. Declaration dictionary is rejected; final fallback retains the existing declaration scan and first-hit break, comparing interned SpellingId values directly.

All 22 paired diagnostic oracles match, all managed live-object deltas return to 0. First occurrence IDs/spans and ordered diagnostic spans are printed explicitly; successful expression values and IDs/field declaration type IDs and spans are also exposed.

Each run lexes once before 3000 direct expression or declaration-field parses. Managed allocation/release/live/backing-malloc scalar endpoints exclude lexing, printing and oracle traversal. Retired instructions measure the whole normal executable, including one-time setup/oracle; repetition dominates. Reported allocation counters do not prove raw-buffer bytes or retained RSS.

Normal and diagnostic executables are compiled from the same C using clang -O2, changing only BLORP_MEMORY_DIAGNOSTICS=0/1. Diagnostic samples use BLORP_MEMORY_STATS=1; normal samples clear memory/leak switches. Five alternating instruction samples per pair, reporting minimum/median. Host supports /usr/bin/time -l and emits retired instructions; -I is unsupported. The requested self_compile_measure lock wrapper is a no-op, so machine-wide quiet is unverified.

|Form|Names|Width|Managed/parse baseline|Managed/parse dictionary|Retired instructions change (min)|
|---|---|---:|---:|---:|---:|
|expression|distinct|1|96|96|+0.184%|
|expression|distinct|2|143|143|+0.453%|
|expression|distinct|8|426|425|-0.215%|
|expression|distinct|64|3061|3057|-1.745%|
|expression|distinct|256|12087|12081|-7.888%|
|expression|repeated|1|96|96|+0.199%|
|expression|repeated|2|131|131|+0.829%|
|expression|repeated|8|420|419|-0.009%|
|expression|repeated|64|3114|3110|-1.425%|
|expression|repeated|256|12334|12328|-6.417%|
|declaration|distinct|0|9|10|+8.063%|
|declaration|distinct|1|48|49|+3.580%|
|declaration|distinct|2|89|90|+2.101%|
|declaration|distinct|8|336|337|-1.590%|
|declaration|distinct|64|2635|2636|-19.571%|
|declaration|distinct|256|10509|10510|-47.458%|
|declaration|repeated|0|9|10|+7.456%|
|declaration|repeated|1|48|49|+3.037%|
|declaration|repeated|2|92|93|+1.600%|
|declaration|repeated|8|351|352|-0.541%|
|declaration|repeated|64|2762|2763|-10.002%|
|declaration|repeated|256|11020|11021|-30.299%|

Commands and evidence: `measure.py`, `measurements.json`, `provenance.json`, `*-source-manifest.json`, `*-alloc.txt`, `*-time.txt`, `compiler-status.txt`, `compiler-version.txt`, snapshot `probe.brp` and parser sources. Generated C/binaries and complete raw logs remain in the external scratch packet linked below.

Focused candidate dictionary suites: tree_record_forms 13/13, tree_record_parser 11/11, tree_expression_parser 55/55. Baseline added cases: forms 13/13 and expressions 55/55. Final equality-only fallback suites also pass 79/79. Broad gates and zero-stop corpus census belong to coordinator.


## Accepted declaration fallback

Allocation counts and backing-malloc counts are identical to baseline for all 12 declaration workloads, and all 12 full output oracle hashes match. Managed live-object deltas return to 0. Existing first-hit break is retained; this change removes text lookups, not the scan. Tiny instruction fluctuations are not evidence of a material speedup.

|Names|Width|Managed/parse baseline and fallback|Retired instructions change (min)|
|---|---:|---:|---:|
|distinct|0|9|-1.082%|
|distinct|1|48|-0.619%|
|distinct|2|89|-0.258%|
|distinct|8|336|-2.262%|
|distinct|64|2635|-18.526%|
|distinct|256|10509|-43.691%|
|repeated|0|9|-0.673%|
|repeated|1|48|-0.099%|
|repeated|2|92|+0.037%|
|repeated|8|351|-1.341%|
|repeated|64|2762|-9.462%|
|repeated|256|11020|-28.046%|


Recommendation: accept the expression dictionary (tiny/normal guards within 1%, wide 256 instruction reductions of 6.4–7.9%) and the declaration typed equality scan (equal allocations, normal 8 reductions of 1.3–2.3%, wide 256 reductions measured above). Reject the declaration dictionary despite its wide wins because it adds a managed object per parse and regresses empty/small guards.

The frozen baseline, dictionary candidate and equality fallback import trees differ only in the two assigned parser files. The expression dictionary result belongs to the isolated duplicate detection change; later coordinator ending-policy edits are excluded. Source manifests and generated C/native binary hashes are in provenance.json. The instruction wrapper has no global exclusion, and machine-wide quiet remains unverified.

Final focused command: `bin/blorp test --timeout 180 blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_tree_record_forms.brp blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_tree_record_parser.brp blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_tree_expression_parser.brp`; 79/79 pass. `git diff --check` passes. No commits or broad gates run by this worker.

Reproduction: create a frozen git archive of baseline 295cb, copy probe.brp.txt to its root as probe.brp, create independent candidate/fallback source snapshots by extracting the `patch` string from `dictionary.patch.json` or `accepted.patch.json`, then using `git apply` in an extracted baseline tree, then compile with the current FRESH bin/blorp using `compile --no-format --std-dir SNAPSHOT/standard_library/src -o VERSION.c SNAPSHOT/probe.brp`. Compile VERSION.c twice with `clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=0` or `=1`, linking `-lm -lpthread`. Run the diagnostic program with `BLORP_MEMORY_STATS=1` and one workload label (e.g. `True-False-256`); run normal program with `/usr/bin/time -l` and the same label. Retained runners describe the five alternating pair samples and exact oracle comparison. Runner paths are relative to their own directory and expect baseline/candidate/fallback binaries there. The full raw packet is at `/tmp/blorp-parser-cleanup-20261007/duplicate-fields/`.

The patches are JSON-wrapped to retain exact diff context without conflicting with repository whitespace checks. Decode `patch` with Python `json.loads`, write it as a .patch file in scratch, and verify its SHA-256 against `patch_sha256` before applying.

The retained compiler status/version text omits trailing empty lines; complete original stdout remains in the raw scratch packet. Compiler and measured-source hashes are unchanged.
