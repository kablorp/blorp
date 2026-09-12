# Direct Accepted Callable Identity Step 2e Results — 2026-09-11

- Baseline compiler: `01ed61ac229a89598a6d9509346590cc6cadad7fdd5e1f113c8901f5c4c33022`
- Candidate compiler: `64ea7d421dece6d2020435b62b40414d69da94035562046e2013aa87b4cf6315`
- Baseline source revision: `304fbc8c`
- Platform: macOS arm64, `/usr/bin/time -lp`
- Sampling: one Issue 83 baseline run plus one final candidate run at the
  checked-bodies stage; no repeated wall-time sampling

Command:

```bash
env BLORP_COMPILER_BENCHMARK_SKIP_BUILD=1 /usr/bin/time -lp \
	benchmarks/compiler_typecheck_phase_profile bodies 1 32 4 16 16 memory
```

Both runs produced semantic checksum `2057305071532051463`, constructor checksum
`-2142865109331864226`, 34 primary outputs, and zero secondary outputs. The
`bodies` stage executes direct callable lookup and inference; the initially
screened `accepted` stage does not and is therefore excluded from this result.

Allocations remain `17232`, releases remain `12924`, retained objects remain
`4308`, and allocated bytes remain `350408`. Retired instructions move from
`6265136939` to `6274672205` (+0.1522%). Cycles move from `1766913472` to
`1785861678` (+1.0724%). Maximum RSS improves from `24887296` to `24821760`
(-0.2633%), peak footprint moves from `17563984` to `17596728` (+0.1864%), and
compiler size moves from `19423920` to `19424368` (+0.0023%).

One-shot setup time moves from `424480` to `431841` microseconds and the measured
window from `16431` to `18384` microseconds. These volatile signals are retained
but are not used as latency claims. The mechanism-level conclusion is limited
to exact allocation/retention/byte neutrality, retired instructions and memory
within the 1% guard, and one-shot cycles within 1.08% while direct resolution
preserves exact semantic identity.
