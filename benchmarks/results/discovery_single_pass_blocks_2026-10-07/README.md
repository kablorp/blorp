# Single-pass discovery blocks: accepted direct accumulator

The final read_block parses the first statement before entering the remaining-statement loop. A successful first parse establishes nonemptiness; direct leading/last/start bindings remain within that branch. Later successes append the former last and replace it. No per-statement record/Option wrapper is needed. Empty, EOF and unsupported-statement cases return the original entry; the block is minted only after its dedent. No grammar or legacy parser changes.

The precise record/Option spike was rejected: at 256 statements it allocated 5.51% more managed objects and retired 15.83% more instructions. Its original isolated sources, tests, binary pairs, raw samples and receipt remain alongside the accepted candidate.

## Validation

Repository bin/blorp was FRESH throughout. Isolated baseline 295cb, rejected record candidate and accepted direct candidate each passed 65 body tests. The added payload invariant test covers 1/2/8/64/256 statements: source order, literal values, every statement/expression ID and span, leading/last shape, owner span/block ID/counts, next-declaration cursor and zero diagnostics. Existing tests cover comment-only empty blocks, late unsupported rollback, nested/control blocks and long statement lists. This semantics-preserving refactor has no known baseline behavioral failure.

Commands (workspace cwd):

```
scripts/compiler-build-status
bin/blorp test --timeout 180 --std-dir SNAPSHOT/standard_library/src SNAPSHOT/blorp/test/test_compiler_new/test_stage_01_discovery/test_parse/test_tree_body_parser.brp
python3 /tmp/blorp-parser-cleanup-20261007/single-pass-blocks/build.py baseline
python3 /tmp/blorp-parser-cleanup-20261007/single-pass-blocks/build.py candidate
benchmarks/self_compile_measure lock -- python3 /tmp/blorp-parser-cleanup-20261007/single-pass-blocks/measure.py candidate
git diff --check
```

All 5 full AST/census/cursor-and-issued-ID checksum oracles match, with zero census problems and measured live-object delta 0. The source manifests differ at exactly tree_body_parser.brp; candidate contains only this worker's read_block change. Compiler SHA, clang fingerprint and native flags match. Provenance files record all hashes, compiler version, FRESH status and flags. Root compiled leases serialized every compile/test/native sample; repository lock subcommand currently passes through. Host time rejects -I, so runner uses `/usr/bin/time -l` and requires the retired-instructions field.

## Matched measurements

Each workload parses 3000 bodies from an immutable entry established by pre-lexing and function-header parsing. Scalar allocation interval excludes input construction, lexing, head parsing, full AST dump and census. Both pairs use the same generated C per source, normal macro 0 and diagnostic macro 1, Apple clang 21 at -O2. Normal samples run without diagnostic stats, alternating five baseline/candidate samples per width. Minima are reported; these are direct parser microbenchmarks, not whole-compiler timing.

| Statements | Managed allocations baseline/candidate | Minimum retired instructions baseline/candidate | Change |
| --- | --- | --- | --- |
| 1 | 186000 / 180000 | 135023439 / 131250925 | -2.79% |
| 2 | 294000 / 288000 | 203823009 / 199530020 | -2.11% |
| 8 | 930000 / 921000 | 611003197 / 598910243 | -1.98% |
| 64 | 6828000 / 6810000 | 4357902872 / 4318012055 | -0.92% |
| 256 | 27000000 / 26976000 | 17216498908 / 17054915767 | -0.94% |

Raw counters/samples/hashes are in measurements.json and baseline/candidate-width-alloc/time files. The accepted design lowers managed allocations at every width and retired instructions by 0.92–2.79%; singleton/two-statement guards improve. This is a bounded parser cleanup, not a broad compilation-speed claim.

## Generated C inspection

candidate-read-block.c.txt retains emitted C function brp_aX (candidate.c lines 78069–78391). Its start span is an immediate scalar extracted before last is initialized; the loop updates one list through ensure-capacity and retains previous-last into it. Closure calls finished_block directly, with no second statement traversal and no accumulator record construction. The first parse result tuple itself remains live until the match finishes, so the narrow start binding does not by itself establish earlier first-statement release; no lifetime benefit is claimed. Measured live-object deltas are 0.

Full shared compiler-new/parity and corpus-stop census gates, and final code-reviewer/test-runner verdicts, belong to the coordinator. No commits made.

## Retained reproduction packet

`accepted.patch.json` and `rejected-record.patch.json` store the exact isolated source changes in their `patch` string against 295cb. Extract that revision with `git archive` (compiler sources, standard library and build inputs), copy `probe.brp.txt` into each snapshot root as `probe.brp`, and extract the corresponding JSON `patch` string and apply it with `git apply`. Copy `build.py.txt` and `measure.py.txt` to a scratch directory under their .py names with snapshots named `baseline-src`, `candidate-src`, and optionally `record-candidate-src`. Run the build script from the repository cwd so it uses the checkout's FRESH bin/blorp. The retained build runner replaces its original machine-specific workspace literal with `Path.cwd()`; compiler flags and measured program source are unchanged.

The JSON files retain every scalar counter and all five instruction samples per workload, oracle hashes and paired compiler/C/binary hashes. Full snapshots, source manifests, generated C, binaries and logs remain at `/tmp/blorp-parser-cleanup-20261007/single-pass-blocks/`. Machine-wide quiet was unverified because the repository lock wrapper is a pass-through. These measurements support the direct body-parser changes only; whole-compiler timing and RSS were not measured.

The patches are JSON-wrapped to retain exact diff context without conflicting with repository whitespace checks. Decode `patch` with Python `json.loads`, write it as a .patch file in scratch, and verify its SHA-256 against `patch_sha256` before applying.
