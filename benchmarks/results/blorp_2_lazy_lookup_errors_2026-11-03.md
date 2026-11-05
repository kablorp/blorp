# Blorp 2 lazy lookup errors (2026-11-03)

`Option.to_result(error)` evaluates its error before it knows whether the
lookup failed, so a lookup that succeeds still builds a `CheckError` or
`Diagnostic` and its message strings. Commit `356bd1406` added
`or_checker_invariant`, `or_internal_error` and `or_verification_error` for
the hottest such sites. This change converts the remaining 130 eager sites
in `blorp_2/src`. Each error is now built only in its lookup's `None` arm:

- 90 sites in those three families call the family's `or_` helper. This
  includes well_formed's 6 `invalid(span)` lookups and the two lookups in
  `signatures.function_label` that shared one pre-built error.
- 8 `render_fault` sites call a new private `or_render_fault` in
  `check/render.brp`.
- 32 sites in families with one to five eager sites (record, constructor,
  value, match, trait and signature errors; emit's `render`;
  `source_bundle_error`; builtins; load; parse) use a `match`, the form
  `356bd1406` used in emit. B2 requires the type annotation on
  `x: T ?= match` when the arms are a bare `Ok(present)`.
  `builtins.designated_pair` built its error before two lookups and a shape
  test; it is now one tuple match whose fallback arm builds the error.

The two `to_result` calls left, in `main.brp`, take string literals, which
allocate nothing now that literals are shared. Opportunity H of the
2026-11-03 allocation study.

## Provenance

The change was measured against `a0b81f14c`, and again against `41810bb15`
after main moved and was merged in (`a1e78c478`).

| | Base | Candidate | Base after the merge | Candidate after the merge |
| --- | --- | --- | --- | --- |
| Source | `a0b81f14c` | `1eeea2bce` | `41810bb15` | `a1e78c478` |
| B C, from the pinned seed (sha256) | `5ab29e18…` | `785f68be…` | `37129873…` | `2759d0df…` |
| B's self C (sha256) | `f1920018…` | `0c0b98e7…` | `a075e4b0…` | `5699e4e6…` |
| Bytes of the first self C | 22,663,857 | 22,641,926 (−0.1%) | | |

- Machine: Apple M4, Apple clang 21.0.0, load average 2.5 to 3.8 from other sessions.
- Each B is `make -C blorp_2 compiler` in its own checkout. All runs were serial.
- In both pairs, base B's self C equals its fixed-workload output, so base is at its fixpoint.
- In both pairs, base B also writes the candidate's own self C for the
  candidate source, byte for byte.
- Raw samples are in the session scratchpad's `measure/` directory.

## Results

| Metric | Expected | Against `a0b81f14c` | Against `41810bb15` |
| --- | --- | --- | --- |
| Fixed workload: output C | identical | identical (`f1920018…`) | identical (`a075e4b0…`) |
| Fixed workload: strict allocations | about −1.6% | 14,778,762 → 14,556,788 (−221,974, −1.50%) | 14,799,571 → 14,577,352 (−222,219, −1.50%) |
| Fixed workload: retired instructions, -O2, minimum of 3 alternating runs | lower | 12,014,790,190 → 11,895,286,116 (−0.99%) | 12,043,339,881 → 11,911,300,716 (−1.10%) |
| Production lines (`blorp_2/src`) | small | +197 / −157, net +40 | same |
| Test lines | | +168 (126 suite, 39 fixture, 2 harness, 1 Makefile) | same |

The three -O2 runs were 12,014,790,190, 12,018,460,911 and 12,043,416,053
for base, and 11,895,286,116, 11,897,266,073 and 11,916,089,105 for the
candidate against `a0b81f14c`. Against `41810bb15` they were
12,043,339,881, 12,047,535,832 and 12,064,905,429, and 11,911,300,716,
11,920,322,576 and 11,924,537,619. The study's 235,915 was measured at `71bafb8ea`, two commits
earlier, on a source that allocated 14,756,055 in all.

**Changed C** (against `a0b81f14c`). The self C differs from base only in the 104 functions
whose source changed, in the instances of `option.to_result` (76 → 2) and
the four `or_` helpers (`or_checker_invariant` 9 → 40, `or_internal_error`
10 → 24, `or_verification_error` 7 → 10, `or_render_fault` 0 → 5), and in
the typedefs and prototypes for those instances. The comparison
normalizes generated numbers, which shift when the instance set changes.

## Commands

```bash
make -C blorp_2 compiler                       # in each checkout: B from the pinned seed
B=<checkout>/blorp_2/build/compiler
$B --library-root <checkout>/blorp_2/standard_library <checkout>/blorp_2/src/main.brp C_x.c
clang -O2 -DBLORP_MEMORY_DIAGNOSTICS=0 -w C_x.c -o P_x -lm -lpthread   # Pd_x with =1
/usr/bin/time -l P_x --library-root base/blorp_2/standard_library base/blorp_2/src/main.brp out_x.c   # 3 alternating runs
BLORP_LEAK_CHECK=strict Pd_x --library-root base/blorp_2/standard_library base/blorp_2/src/main.brp outd_x.c
cmp out_base.c out_cand.c
```

## Tests

- `test_check/test_lookup_rejections.brp` checks seven reachable converted
  rejections with exact message, help and span. They pass the same under
  base and candidate B, and all seven fail when the converted `None` arms'
  spans are widened by one byte.
- The e2e fixture `lookup_errors/append_modules.brp` lexes, parses and
  appends 64 modules in-process. Its strict allocations were 1,467; the
  same fixture built by base B allocates 1,533, which is one
  `Diagnostic` per module plus the error's two literals on first use.
  After `29c8fd40d` stopped heap-allocating the environment of a capturing
  callback passed to a static callee, the fixture's `and_then` callback
  allocates 64 fewer, so the pin is now 1,403.
- `parse.consume_annotation`'s `None` arm is not reachable from source,
  since the lexer always leaves a token after `@`, so it has no test.

## Gates

| Gate | `1eeea2bce` (on `a0b81f14c`) | `a1e78c478` (merged with `41810bb15`) |
| --- | --- | --- |
| `make -C blorp_2 test` | exit 0, 1,239 PASS, 0 FAIL | exit 0, 1,281 PASS, 0 FAIL |
| Strict leak reports, including the strict-accounting self-compile | 17, all balanced | 17, all balanced |
| `scripts/blorp2-fixpoint --prove`, run alone | exit 0, FIXPOINT, 666 fixtures identical | exit 0, FIXPOINT, 673 fixtures identical |
