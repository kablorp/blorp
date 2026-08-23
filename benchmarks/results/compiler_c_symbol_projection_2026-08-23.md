# Compiler C Symbol Projection

Date: 2026-08-23

This compares the compiler at `c2498f40` with the callable-projection candidate
using the same bounded fixture and the production compile route. Both runs used
the same fixture hash
`a72ae47c4a6cfb2724c4b143a09f8cdf9498917ff7e2da9fba7e5974458e66df`.
The benchmark validated the exact runtime output
`C_SYMBOL_HASH_CHECKSUM=243` on every sample before retaining results. Ten
samples per compiler alternated baseline/candidate execution order.

## Results

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Generated C bytes | 25,208 | 15,586 | -38.17% |
| Callable identifier bytes | 3,906 | 646 | -83.46% |
| Maximum callable identifier bytes | 176 | 41 | -76.70% |
| `-O0` object bytes | 13,792 | 10,512 | -23.78% |
| `-O2` object bytes | 12,072 | 5,920 | -50.96% |
| Compile-to-C median | 1.065310 s | 1.063487 s | -0.17% |
| Host C `-O0` median | 0.076655 s | 0.076963 s | +0.40% |
| Host C `-O2` median | 0.087846 s | 0.087284 s | -0.64% |
| Compile-to-C peak RSS | 46,415,872 | 46,612,480 | +0.42% |
| Host C `-O0` peak RSS | 61,079,552 | 61,046,784 | -0.05% |
| Host C `-O2` peak RSS | 72,564,736 | 71,778,304 | -1.08% |

Compile-to-C stayed inside the roadmap's 2% regression limit. Host-C timing is
too short and noisy on this fixture to support a speedup claim; the retained
benefit is the clear generated-C and object-size reduction. Raw timing samples
are in
[`compiler_c_symbol_projection_2026-08-23.tsv`](compiler_c_symbol_projection_2026-08-23.tsv).

## Reproduction

```bash
benchmarks/compiler_c_symbol_projection \
	--compiler ./blorp --compiler-root . \
	--baseline-compiler /path/to/baseline/blorp \
	--baseline-compiler-root /path/to/baseline \
	--samples 10 --skip-build --json
```

Baseline compiler SHA-256:
`dda5db2b8b266261cd5a240568591895cb39269c37abda8976b4c17b91646427`.
Candidate compiler SHA-256:
`3259fe26f5817e649d274c511446d740f68a14a859c4b48564a1050dad9ac4f2`.
The host compiler was Apple Clang 21.0.0. Both sides used `-fwrapv -pipe -w`,
the matching checkout's `runtime_decl.c`, and identical `-O0`/`-O2` modes.
