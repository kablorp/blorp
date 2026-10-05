# Discovery record construction and token storage, 2026-10-03

Current representation probes for M1 and M2 of
[`DISCOVERY_REDESIGN.md`](../../docs/DISCOVERY_REDESIGN.md). The older M1/M2
ledgers describe their original branches; they do not establish the cost of
the ordinary records adopted here.

## Provenance and boundary

- Integration base: `02c0786a609f6ef7b65f5fd6eba243af8fbd66bf`.
- Frozen compiler SHA-256:
  `f005132ec745aae0924ec9d107176895da95be1a19ce012c5585880a7008390c`.
  It contains the adopted M1/M2 sources and was built with bootstrap
  `dev-8228a8fa12e3`, CLI `-O0`, runtime `-O2`, eight C translation units.
- Probe executables: Apple clang 21.0.0, `-O2 -fwrapv`; separate plain and
  `-DBLORP_MEMORY_DIAGNOSTICS=1` builds. Managed counts come from the latter;
  instructions and RSS come from the former under `/usr/bin/time -l`.
- One process ran at a time. Instruction results below use the minimum of
  three samples. No wall-time improvement is claimed.
- Raw sources, C, binaries, compiler, command lists and samples are retained
  in `/tmp/blorp-discovery-record-costs/`. `metadata.json`,
  `token-summary.json`, `mint-summary.json`, `sample-commands.json`, and
  `mint-sample-commands.json` identify the input and individual runs.

These are construction and lexer probes, not a whole-compiler comparison or
the M6 switch gate. M1 syntax values remain ordinary records. The token
experiment changes only `tables/token.brp` from `fixed record Token` to
`record Token` in a frozen copy.

## M1: construction and return

Tool: `blorp/test/compiler_new/tools/id_mint_cost.brp`. Each mode retains
every completed node in a list. Expression/name instruction counts subtract
the same mode at zero calls and the empty loop/list cost (32.45 instructions
per call); each measured run has 120,000 calls. Allocations subtract the
empty loop at 12,000 calls. Index modes use 2,000 calls for allocation counts.

| Shape | Allocations per node | Instructions per node |
| --- | ---: | ---: |
| Expression on the bare mint | 5 | 2,688 |
| Expression through the opaque parse-state shape | 7 | 3,669 |
| Name use through the parse-state shape | 6 | 3,118 |
| Experimental single-layer expression | 4 | 2,131 |
| Field through the parse-state shape | 7 | quadratic, below |
| Field on the bare mint | 5 | quadratic, below |
| Import through the parse-state shape | 6 | quadratic, below |

The parse-state probe is a small stand-in with source, cursor, mint and
diagnostics, rather than the later production parser's complete state. The
single-layer probe uses an integer in place of an opaque syntax ID and does
not preserve the mint ownership contract; it is measured, not adopted.

The index append cost remains quadratic. Startup-subtracted retired
instructions for four times as many nodes grow about fourteen times:

| Index mode | 2,000 nodes | 8,000 nodes | Ratio |
| --- | ---: | ---: | ---: |
| Field through state | 51,202,304 | 727,043,220 | 14.20 |
| Field on mint | 49,134,919 | 719,091,602 | 14.64 |
| Import through state | 50,102,094 | 722,927,985 | 14.43 |

This retains the compiler-cost dependency recorded by the original M1
probe: appending through a shared mint record copies the growing index.
The tuple and state hand-off increments must be measured again before M6;
this report does not claim they are implemented or that the direct parser
meets its switch ceiling.

Reproduction after compiling the tool to C and linking both probe builds:

```bash
BLORP_MEMORY_STATS=1 ./mint-diag state 12000
BLORP_MEMORY_STATS=1 ./mint-diag empty 12000
/usr/bin/time -l ./mint state 120000
/usr/bin/time -l ./mint state 0
/usr/bin/time -l ./mint empty 120000
/usr/bin/time -l ./mint empty 0
```

## M2: token storage

Tool: `blorp/test/compiler_new/tools/token_storage_probe.brp`. The frozen
corpus is the base's 505 compiler, runtime-library and standard-library
source files. Each module is lexed independently with its own module ID and
spellings. Both builds produce **2,188,161 tokens**. Input texts stay alive
through the memory snapshots; temporary spellings, literals and
interpolation scans are released before retained storage is read.

`corpus-paths.txt` records repository-relative paths and `file-list.txt`
records frozen absolute paths. The auxiliary concatenation `corpus.brp` is
12,726,784 bytes including separators, SHA-256
`e40ddc6dbf5578bdfec5558ccec050c586e5ef19d1e6124561c9a30c20faa74e`;
the actual workload reads the separate source files.

| Metric | Fixed record | Ordinary record |
| --- | ---: | ---: |
| Managed allocations during lexing | 1,306,125 | 3,494,286 |
| Retained managed objects | 506 | 2,188,667 |
| Retained bytes | 77,530,720 | 113,388,936 |
| Lex-only instructions, minimum of three | 3,633,611,317 | 4,605,752,626 |
| Lex plus five token reads, minimum of three | 4,024,512,062 | 5,113,877,616 |
| Lex-only RSS, minimum of three | 89,194,496 | 148,373,504 |

The ordinary record adds exactly one managed allocation and retained object
per token. The fixed record saves 31.6% of retained bytes and 21.1% of
lex-only instructions in this probe. The fixed-record instruction samples
spread about 1.7%; ordinary-record samples spread under 0.2%. Every plain
stdout file matches between layouts for the same read count, including the
five-read token checksum.

Generated C confirms the mechanism: the fixed record is an inline
24-byte value; its list has no element release callback. The ordinary record
is a 40-byte managed object and its constructor calls `blorp_alloc`.

**Decision:** retain the provisional `fixed record Token` while the record
simplification plan permits this explicit storage exception. Syntax names,
binders and nodes remain ordinary records. This result establishes the
token layout choice; the current stage and bridge cost is recorded in the
[paired M2 measurement](discovery_redesign_m2_current_2026-10-03.md).

```bash
BLORP_MEMORY_STATS=1 ./fixed-token-diag file-list.txt 0
BLORP_MEMORY_STATS=1 ./record-token-diag file-list.txt 0
/usr/bin/time -l ./fixed-token file-list.txt 0
/usr/bin/time -l ./record-token file-list.txt 0
/usr/bin/time -l ./fixed-token file-list.txt 5
/usr/bin/time -l ./record-token file-list.txt 5
```
