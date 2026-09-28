# Float to_string, Unicode case mapping, and inline list widths

Date: 2026-09-28

Base revision: `58143f9c1` (static runtime string results). Each candidate
is the base plus one runtime change, measured alone:

1. Float to_string probes 7, then 15, then bisects instead of trying every
   precision from 7 to 17.
2. upper/lower on non-ASCII text map each code point once into a stack
   buffer instead of a span array with two lookups per code point.
3. Generic inline list get/set use fixed-size copies for widths 1, 2, 4 and 8
   instead of a run-time-sized `memcpy` (a libc call per element at `-O2`).

Toolchain: Apple clang 21.0.0 (clang-2100.3.34.2), aarch64-apple-darwin,
`bin/blorp` built by `make` (cli `-O0`, runtime `-O2`). The generated C embeds
the compiler's runtime, so base C was emitted by `bin/blorp` built at the base
and candidate C by `bin/blorp` built at each item's commit. The machine was
shared with other agents (load average 25-50), so instruction counts carry
some noise; wall time was not used.

## Method

```bash
bin/blorp compile --no-format benchmarks/blorp/<name>.brp -o /tmp/<name>_<base|cand>.c
clang -fwrapv -O2 -pthread -w -I blorp/src/lib/runtime/native \
  -DBLORP_MEMORY_DIAGNOSTICS=0 /tmp/<name>_<base|cand>.c -o /tmp/<name>_<base|cand> -lm
/usr/bin/time -l /tmp/<name>_<base|cand>   # three runs each, minimum reported
```

Program output was compared byte for byte between base and candidate.

## Results

| benchmark | base instructions | candidate instructions | delta | output |
| --- | ---: | ---: | ---: | --- |
| `float_to_string.brp` (400K quotients) | 8,283,029,327 | 4,668,929,174 | -43.6% | identical (`checksum: 224929567`) |
| `unicode_case_map.brp` (200K upper + lower) | 4,842,205,978 | 1,496,268,636 | -69.1% | identical (`checksum: 51522039`) |
| `inline_list_access.brp` (60K list equalities) | 5,612,884,433 | 2,365,745,890 | -57.9% | identical (`checksum: 140000`) |

Generated C sha256 prefixes (base / candidate): float `719b57743e43f315` /
`ff636d81f6f185f8`, case map `842254592d26d320` / `211ad9208f0ce042`, list
`5e76ab317bc0ff2d` / `e176c189a458f5b2`. The C differs only in the embedded
runtime.

## Output identity beyond the benchmarks

- Float to_string: 18.3M doubles compared with the original linear search,
  0 mismatches (retained sample: `blorp/test/runtime/test_runtime_float_to_string.py`).
- Case mapping: every Unicode scalar value alone and as Final_Sigma context
  plus random sigma, case-ignorable, expanding and invalid-UTF-8 texts,
  4.9M cases, 0 mismatches (retained sample:
  `blorp/test/runtime/test_runtime_unicode_case_map.py`; `10 full` runs the
  whole sweep).

No stage-2 self-compile was measured; none of the three paths is expected to
matter there.
