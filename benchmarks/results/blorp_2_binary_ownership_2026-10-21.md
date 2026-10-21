# Binary ownership query

Status: implementation qualification passed, 2026-10-21.

M1 replaces Specialize's seven-case `ValueOwnership` result with the existing
`Bool` inside `Result[Bool, Diagnostic]`. Every production reader used only the
owning/unmanaged distinction. Concrete record/union layouts retain their existing
identities and physical representations; checked nominal lookup still returns
exact existing diagnostics for missing identities. Own/Verify's actual operations,
transfers, borrows, raw layout validation and emission helpers are unchanged.
There is no new stored fact, carrier, traversal, cache or runtime ABI.

Production: **77 added / 109 deleted, net -32 lines** across four modules.
Tests: **136 added / 88 deleted, net +48 lines** across fourteen owners.
The existing 253 registrations, source examples and quoted literals are retained.
Tests now observe concrete signatures/constructions/physical representations where
the removed classification formerly carried an identity or storage distinction.
The separate test-port batch contributes no production changes and is
excluded from these M1 line counts.

## Matched frozen-input costs

Original and parent are the same source epoch:
`cdfa1bc6009da61415f26b9f812f1dfbf23a6ebc`. Both compilers were generated through
actual Make recipes by published pinned seed `blorp2-seed-1686659309e5`, without
legacy production generation. Parent compiler C is `f8309136d4a0f53625d2ca4062579874b314adf1e2f649f82074f4fe2b80785a`;
candidate compiler C is `3bd8ae255b3e6a9afe23b315d0e252f3e0304c917a8ff69a299c9370c10da6da`.
Each normal/diagnostic pair shares its C, Apple Clang 21.0.0, `-O0`,
`BLORP_MEMORY_DIAGNOSTICS=0/1`, and `-lm -lpthread`.

Both compile the same frozen original source and target library, with identical
absolute main/library/CWD/output paths. Output is absent before each invocation;
archiving occurs afterward. An exact private mode0600 environment snapshot is
used (SHA256 `01b8f2c9723eb8c6a87316071491678da927fbaedf86cd78ce972e553d2de952`),
with memory variables removed for normals and only strict leak mode added for
allocation observations. Inputs, membership, modes, binaries and tools are guarded.
All our compiled jobs are serial; unrelated machine activity is uncontrolled.
There is no latency claim or extra warmup. The fixed schedule is strict P/C,
then P1 C1 C2 P2 P3 C3, with no replacement samples or baseline reset.

| Metric | Original/parent | Candidate | Change |
| --- | ---: | ---: | ---: |
| Allocations | 30,998,075 | 30,683,130 | -314,945 (-1.0160%) |
| Normal retired instructions, minimum of three | 899,669,130,074 | 899,486,486,920 | -0.0203% (effectively flat) |
| Peak RSS, median of three | 306,806,784 B | 297,615,360 B | -2.9958% |

Both allocation observations are positive, exactly balanced and leak-free. All
eight observations emit identical frozen-input C. The prospective independent
allocation/instruction ceilings are +3%, checked as integer products against the
original; satisfying a ceiling alone does not establish a benefit. M1 retains
its actual code reduction without a material offsetting resource regression.
Normal instruction samples, in role order: parent 899,714,534,128 /
899,673,709,634 / 899,669,130,074; candidate 899,527,971,338 /
899,486,486,920 / 899,544,248,697. RSS is supplementary, with no retained-byte
or attribution claim; parent samples are 307,822,592 / 306,167,808 / 306,806,784 B
and candidate samples 303,939,584 / 297,615,360 / 296,910,848 B.

Generated-C inspection confirms the old classification carrier was **by value**,
so its removal is not itself proof of heap savings. Own's classification dispatch
falls from six tag tests to one Bool test. The record query also avoids eagerly
constructing a Diagnostic before successful `Option.to_result`: the unchanged
error helper now executes only in `None`. These are the actual simplifications;
there is no added child walk. The allocation delta covers the whole compilation,
not an isolated attribution to either mechanism.

## Correctness and evidence

The frozen baseline and candidate each pass all 379 focused checks, with identical
stdout. The source-valid CallableType-to-False mutation executes all five stored
callable checks, fails only `callable signature seals one environment obligation`,
and exits 1. Exact byte/mode restoration returns five PASS and exit 0; complete
input/index guards close. Host TestSuite C is temporary and is not retained;
a separate post-restoration actual Make generation reproduces the canonical
pre-fault compiler C exactly.

The complete component gate passes **4,505 checks**, zero failures: 3,983 host
callbacks, 334 nested checks and 188 target callbacks across 27 target suites.
All 27 target strict reports balance with zero leaks. The separate port retains
12 explicitly deferred Lexer cases without PASS credit.

Actual default Make generation and three successive compiler generations emit
identical C. All **577 fixtures** match under A/B, with independently audited CLI
contracts: 482 accepted, 95 rejected. Compiler streams are empty; build logs
contain only expected Make output. The self-built B compiler passes **580
maintained e2e cases**, zero failures (1,367 PASS rows including nested/wrapper
checks). All original assertions, fixture inputs and limits remain unchanged.

Current-source strict and ASan/UBSan compiler runs each report **30,668,789
allocations and releases, zero leaks/bytes**, empty stdout and no sanitizer
diagnostics. The sanitizer link streams are empty. Both emit the same unchanged
compiler C as every generation and canonical candidate. These observations use
current M1 source, not the different frozen input in the cost comparison.

Broad e2e retains **117 original allocation-debt FAIL markers** under the existing
CI policy. Disabled broad instruction checks are unmeasured, not a resource PASS;
the explicit normal observations above supply M1's instruction evidence.

Raw commands, hashes, before/after guards, streams and samples are retained under
`build/layout-m1-2026-10-21/`; source packet `source01`, generated-C review
`c-review01`, fault `callable-fault`, and measurements `measurement`. The complete
4,445-file fixpoint proof is copied and hash-verified in `fixpoint-proof`; independent
code, test-runner, cost and fixture-contract review receipts are retained alongside it.
