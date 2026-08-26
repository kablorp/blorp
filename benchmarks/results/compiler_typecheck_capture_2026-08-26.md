# Compiler CLI Typecheck Capture

Date: 2026-08-26

## Capture Contract

The explicit diagnostic command below builds the normal CLI source graph for
one root, writes the schema-1 `typecheck_graph` request atomically, and exits
before typechecking:

```bash
capture=$(mktemp "${TMPDIR:-/tmp}/blorp-typecheck-graph.XXXXXX.json")
./blorp check --no-format --capture-typecheck-request "$capture" \
  compiler/src/stage_12_cli/main.brp
```

The capture contains raw source text and local paths and must remain outside
the repository.

## Initial Self-Hosted Replay

The captured compiler CLI request was 10,920,215 bytes and contained the
`main` target, 337 dependency modules, and 337 selected dependency artifacts.
Target-only replay retained the full prepared graph while emitting one target
artifact:

```bash
benchmarks/compiler_typecheck_replay "$capture" \
  --target-only --timeout 90 --json
```

| Metric | Value |
| --- | ---: |
| Replay elapsed | 79.662 s |
| Planned CTFE dependencies | 321 |
| Retained CTFE typed declarations | 15,177 |
| Retained CTFE typed-expression nodes | 499,705 |
| Target typed-expression nodes | 1,468 |
| Replay response bytes | 2,031,707 |

The largest measured checkpoint intervals were 40.719 s for CTFE dependency
typechecking, 8.228 s for graph parsing, and 5.605 s for declaration-skeleton
construction. Target body typechecking took 0.521 s and artifact projection
took 0.142 s.

## Consequence

This is a correct self-hosted feedback loop, but not yet a fast one. The next
typechecking optimization should investigate repeated CTFE dependency
typechecking and retained-program construction before changing isolated target
body inference. The capture command itself took 9.4 s and is outside replay
time; reuse one local capture while iterating on the worker.
