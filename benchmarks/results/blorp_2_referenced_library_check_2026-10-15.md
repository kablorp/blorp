# Checking only referenced library declarations (negative result)

The proposal: in a user compile, check a library declaration only if the
compile references it, directly or transitively. Unreferenced library
declarations would be left to a library test suite. The motivation was the
list intrinsics increment, where three generic wrappers added a constant cost
to every compile
([list intrinsics report](blorp_2_list_intrinsics_2026-10-15.md#whole-pilot-cost-on-existing-inputs-and-one-raised-ceiling)).

**Decision: not implemented.** Checking is only about a quarter of what a
wrapper costs; the rest is lexing and parsing, which must stay complete. The
two designs that remove the checking share either save little or repeat name
resolution. Neither pays for the change it needs.

## Provenance

| Artifact | Identity |
| --- | --- |
| Source | `origin/main` at `6a23eb7ab` |
| Host `bin/blorp` (FRESH) | `e8541a711ef9566b3f9182b6a77d1505fe3cc3c402d3f0c4ffaa4cd82d54b408` |
| Baseline pilot | `33e1eea7e6a09e09435d0cac2c3c1d7e78f963d0cfbeddfaef8541820320ac47` |
| Baseline generated host C | `359b117149bc207f8421ee86befcbbcd95d031213f492f4823785f337321e948` |
| Variant A pilot (library bodies skipped) | `dbfa5d251a4b4695a384bb781ef45a3cfcd632d51585e6a93ab752b04d6a88e0` |
| Variant B pilot (library signatures, callables and bodies skipped) | `1d86dc44619b80b00b90bfc416e0ece55407f930cf9e6bf84bd6b62b1974f563` |

All pilots are `make -C blorp_2 test-compiler` builds. Toolchain: Apple clang
21.0.0, `-O0 -DBLORP_MEMORY_DIAGNOSTICS=1 -lm -lpthread`, Apple M4,
macOS 26.7.1. Each variant was a temporary source edit, built, measured and
then reverted. The A and B edits stop checking at the first non-root module,
so they are valid proxies only for inputs like `return/zero.brp`, which
reference no library function. Their generated C is byte-identical to the
baseline's on that input.

Measurements use the e2e harness's command, run serially:

```bash
BLORP_LEAK_CHECK=strict /usr/bin/time -l <pilot> \
  --library-root blorp_2/standard_library_temp \
  blorp_2/test/e2e/fixtures/return/zero.brp out.c
```

`lib3` is a copy of `standard_library_temp` without `append`, `set` and
`concat`. Instruction counts are the minimum of three runs. These are proxy
measurements on a small input, not the self-compile.

## Where a wrapper's cost goes

At `6a23eb7ab` the three wrappers cost 1,022 allocations per compile on
`return/zero.brp`. That is more than the 884 reported earlier, because list
literals have landed since.

| Pilot | Full library | `lib3` | Three-wrapper delta |
| --- | ---: | ---: | ---: |
| Baseline | 8,818 | 7,796 | 1,022 |
| No library checking (variant B) | 6,797 | 6,045 | 751 |
| Stop after loading | 6,131 | 5,380 | 751 |

All 751 allocations that remain with no library checking at all are spent in
loading. A doubling experiment splits loading further: lex and then parse
each module twice, then take the extra cost with the full library minus the
extra cost with `lib3`.

| Stage | Three wrappers | Per wrapper | Share of the whole `zero.brp` compile |
| --- | ---: | ---: | ---: |
| Lex | ≈439 | ≈146 | 3,317 of 8,818 (38%) |
| Parse | ≈313 | ≈104 | 2,358 of 8,818 (27%) |
| Check (namespace, signatures, callables, bodies) | ≈271 | ≈90 | — |

Loading must stay complete. The prelude imports every operation module
(`int`, `float`, `string`, `list`) with `methods_only`, so UFCS resolution
needs them all loaded. The proposal could therefore remove at most about 90 of
the about 340 allocations each new wrapper adds.

## The two designs and why each was rejected

Before checking, nothing records which library functions a body references.
The namespace holds only module-level bindings. UFCS needs library signatures
before any body is checked: `build_callables` builds the method table from
every accepted signature in a method-selected module, and receiver matching
reads the candidate's first parameter type.

| Variant on `return/zero.brp` | Allocations | Retired instructions |
| --- | ---: | ---: |
| Baseline | 8,818 | 43.93M |
| A: skip unreferenced library bodies | 8,065 (−753, −8.5%) | 42.37M (−3.5%) |
| B: skip library signatures, callables and bodies | 6,797 (−2,021, −22.9%) | 39.13M (−10.9%) |

Average cost per library function (23 are loaded): signature ≈46, callable
binding ≈9, body ≈33 allocations.

**A: worklist over bodies, all signatures still checked.** No new walk is
needed: `function_calls` in `check/model.brp` already lists each checked
body's resolved callees. The design seeds the worklist with every user
function and closes it over library callees. It changes the rule, though: an
unreferenced library function with a bad signature or builtin contract is
still rejected. It also needs a new representation for skipped rows.
Signature rows, checked-function rows and `CheckedFunctions.functions` are
dense lists indexed by `FunctionId`, read by callables, recursion validation
and specialization. About 20 unit-test files read
`checked_functions(program).functions` by position. Rejected because 8.5% on
a trivial program does not pay for that change.

**B: name-level reachability before signatures.** This implements the rule as
proposed. It needs a new pass over parsed bodies (about 70 lines) and
callee-name resolution (about 50 lines): direct calls through
`function_candidate`, alias-qualified calls through `local_function`, and
receiver calls by module and name, ignoring the receiver type. A closure adds
about 30 more lines, and the same row representation change as A is needed.
Rejected because the new pass copies the candidate rules of namespace and
callables into a second place, which `blorp_2` principle 1 forbids. If the
two copies disagreed, specialization would fail on an unchecked callee.

## Library coverage

Today no suite deliberately checks every library declaration. Every e2e
compile checks `int`, `float`, `string` and `list` implicitly through the
prelude, and `io` is checked in the 83 fixtures that import it. If library
checking ever becomes selective, a coverage suite is required first.

- Compiling each library module as a root does not work. The root is a
  `UserModule`, so it needs `main` (otherwise `MissingMain`). It also receives
  the prelude, and the prelude importing that root's path is rejected with "a
  library module cannot import a user module".
- A unit suite would work if it assembles the real library sources with the
  `UserModule` role through `parse_modules_with_base` / `append_module`, as
  existing unit tests do. A list of every library function written into a
  fixture would also work, but it would be a hand-kept pinning test.

## Follow-up (hypothesis)

Lexing costs about 5 allocations per token (≈146 for a roughly 30-token
wrapper) and 38% of the allocations in a small compile; parsing costs
another 27%. Both dominate per-declaration cost and apply to user code too.
Measure lex and parse at compiler size before acting, and judge any change
against the self-compile time-to-C row, not allocation counts.
