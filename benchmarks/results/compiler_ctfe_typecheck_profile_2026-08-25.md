# Demand-Driven CTFE Typecheck Profile

Date: 2026-08-25

## Contract

The representative workload uses three iterations, 24 dependency modules, and
32 functions per module. Its immutable target global reaches function zero in
each module, so exactly 24 of 768 dependency bodies are reachable per graph.
All runs retained parsed programs and produced checksum `2529`.

The narrow control uses the same module chain with one function per module. Its
checksum is `297`.

## Results

| Workload | Baseline median (us) | Demand-driven median (us) | Change |
|---|---:|---:|---:|
| 24 modules x 32 functions | 208,294 | 120,881 | 42.0% faster |
| 24 modules x 1 function | 103,764 | 64,336 | 38.0% faster |

Representative baseline samples:

```text
208294 208184 207922 212958 211754
```

Representative demand-driven samples:

```text
120881 125020 121519 120847 119194
```

Narrow baseline samples:

```text
103764 137824 102410
```

Narrow demand-driven samples:

```text
64357 64336 65329 64197 63879
```

## Observed Work

The representative run reports `72` dependency body checks across three graph
runs, or exactly 24 per graph. Before the change it reported `768` checks per
graph. Widening each module from one function to 32 no longer changes the body
check count.

The selected-module regression additionally reports one reused body: a body
checked for CTFE is reused when assembling that dependency as ordinary output.

## Command

```bash
BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 \
  benchmarks/compiler_ctfe_typecheck_profile 3 24 32 retained
```
