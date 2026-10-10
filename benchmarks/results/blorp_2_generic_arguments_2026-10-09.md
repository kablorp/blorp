# Blorp 2 multiple runtime arguments

This bounded increment accepts ordered runtime arguments for ordinary functions
and functions with one type parameter. UFCS supplies the receiver first, then
explicit arguments. It retains unary runtime builtins, zero/one constructor
payloads, zero-argument `main`, the managed-match restrictions, and the current
rejection of uncontextualized generic constructors. It adds neither multiple
type parameters nor inference from an expected return type.

## Boundary and provenance

The parsed expression has recursive direct-call children and explicit postfix
arguments. Function signatures own ordered `TypeUse` parameters; parameter
bindings identify their signature position explicitly. The checker resolves a
call target and complete contract once, synthesizes arguments in order, infers
the single type argument consistently across structural occurrences, and
publishes checked children and the instantiated target. Specialization and
lowering consume this checked boundary. Lowering evaluates every argument into
ordered value definitions before the C call. Ownership records every operand,
including repeats; borrowed parameter provenance contains its exact `ValueId`.
The independent verifier checks the complete parameter-position map, operand
types and exact borrow provenance.

The frozen accepted baseline is Git HEAD
`da8fa4c7134e3c636fb7b67f35918f8d7cdc50b0`, not an earlier tail-string baseline.
Retained artifacts live in the ignored directory
`blorp_2/build/generic-expansion/arguments/`:

- `baseline/sources.tar`: baseline production sources and original workloads.
- `baseline/compiler`: SHA256
  `63bc41957cf2814feef10fee784ce97585340509636e99e45aae7b3361479990`.
- `baseline/compiler.c`: SHA256
  `11c841b2bfb13ff61357a244eadcb1ed4786b7e2071d3965e44af1e08c182917`.
- Repository host `bin/blorp`: SHA256
  `f6d946861a5a07faa506cb598e0e64d8af0f89289551737b5e0dc42443554a8c`.
- Candidate pilot `build/compiler`: SHA256
  `1957b4dbd5ce1e2f02f6aa3cd078c3cb7bbe2568d51fcb1b31bf1b831597f411`.
- Candidate pilot C: SHA256
  `bdec9026d57e3cdd720df7fd0f91ce81c165c1a07dd75bb4aa43af70e80e91d5`.
- Final source/test/README/grammar/plan manifest `candidate-sources.sha256`:
  SHA256 `29eab2d66f7882b2c915b7e3d0ae142eb3db31ea30046543f2420597a3fcbade`.

The pilot is built by the existing Makefile using the repository host compiler,
`clang -O0 -DBLORP_MEMORY_DIAGNOSTICS=1`, `-lm -lpthread`. No host source,
bootstrap, persistent cache or alternate fixture entrypoint changed.

## Tests and generated C

Before implementation, `generic_arguments.brp` was rejected at `1:33` with
`only zero or one parameter or argument is supported` and help
`use at most one typed parameter and one call argument`. The exact output is
retained as `tdd.stderr`.

The final new direct in-process argument suite passes 23 tests. It covers
distinct binding identities, later-position inference, repeated structural
constraints, exact disagreeing-argument diagnostics, specialization of all
parameters, left-to-right lowering, returning the second borrowed parameter,
repeated borrowing, complete verifier parameter positions, swapped provenance,
wrong owners, and swapped heterogeneous operands. Direct last-use inputs check
both distinct owned operands and reject an invalid later operand. A temporary
mutation recording only the first operand failed exactly those two liveness
callbacks; `first-operand-mutation.log` retains the failure. The production file
was restored byte-for-byte afterward.

An inventory against HEAD preserves all prior unit callbacks except the obsolete
comma-rejection callback, replaced by a comma-token acceptance test. The earlier
full strict ASan/UBSan unit run passed 395 tests with 426,947 allocations and
releases, zero leaked objects and bytes. After the final contract/traversal
refinement and two liveness additions, the affected argument, checker, lexer,
specialization, generic and grammar suites pass 183 tests under ASan/UBSan with
`BLORP_LEAK_CHECK=strict`: 190,562 allocations and releases, zero leaks.

The initial `make -C blorp_2 test` run passed the units, runtime and grammar
suites. It exposed two new fixtures accidentally reformatted into unsupported
multiline chains and the tight allocation cap described below. The chains were
restored to the pilot's documented single-line expression syntax. Independent
final review and full-gate validation use the final manifest above.

All eight final native fixtures compile unmodified emitted C using
`-std=c11 -Wall -Wextra -Werror -pedantic -O0 -fsanitize=address,undefined
-fno-sanitize-recover=all`. Their expected exits are:

| Fixture | Exit |
| --- | ---: |
| `generic_arguments` | 7 |
| `generic_arguments_first_string` | 1 |
| `generic_arguments_second_string` | 3 |
| `generic_arguments_repeated_string` | 3 |
| `generic_arguments_later` | 42 |
| `generic_arguments_box` | 7 |
| `multiple_arguments_order` | 9 |
| `multiple_arguments_wide` | 39 |

Every run has empty stdout and stderr. Their C, native binaries, compile logs
and run logs remain beside this report's raw artifacts. Inspection confirms
separate local definitions before calls, receiver-first operand order, indexed
parameter names, and an ordinary flat signature for 40 parameters. In the
second-String fixture the helper retains parameter 1 before returning it; the
caller releases both original operands only after the call, then replaces the
source binding. Distinct returned lengths 1 and 3 protect the first/second cases.
The e2e harness strengthens its existing UBSan invocation to ASan plus UBSan.

## Matched cost proxy

The ceiling before implementation was investigation of any repeatable cumulative
increase above 25% against this frozen HEAD on unchanged workloads, and
investigation of production growth above 1,200 physical lines. Existing native
cost caps were initially held fixed. Measurements use the existing harness path:

```sh
/usr/bin/time -l -o REPORT.time /usr/bin/env BLORP_LEAK_CHECK=strict \
  PILOT_COMPILER blorp_2/src/prelude_temp.brp FIXTURE OUTPUT.c
```

This measures one instrumented pilot compilation, including process startup and
file I/O. Building the pilot, compiling C and running native programs are outside
the boundary. It is a retained cost proxy, not a self-compilation measurement.

All 60 original workloads were remeasured; all 60 emitted C files are
byte-identical to the baseline. `all-fixture-costs.tsv` retains every allocation
and instruction comparison. The largest allocation increase is 15.33% for
`match_constructor_spine`. Six representative workloads, including that maximum,
have three sequential paired baseline/candidate samples under `matched/`.
Allocation counts are deterministic; instructions below use the minimum of
three as the repository protocol requires.

| Workload | Allocations before → after | Change | Instructions before → after | Change |
| --- | ---: | ---: | ---: | ---: |
| return_zero | 684 → 685 | +0.15% | 30,709,106 → 30,692,977 | -0.05% |
| nested_calls | 1,292 → 1,325 | +2.55% | 32,517,564 → 32,498,597 | -0.06% |
| mortal_string | 1,020 → 1,034 | +1.37% | 31,666,751 → 31,675,372 | +0.03% |
| generic_box | 2,091 → 2,164 | +3.49% | 34,692,270 → 34,816,849 | +0.36% |
| union_values | 3,574 → 3,641 | +1.87% | 38,810,852 → 38,939,629 | +0.33% |
| match_constructor_spine | 7,628 → 8,797 | +15.33% | 49,588,062 → 52,707,110 | +6.29% |

The initial union result was 3,655 allocations. Reusing the authoritative
signature `TypeUse` list reduced this to 3,648; appending recursive specialization
occurrences into one collector instead of materializing child lists reduced it
to 3,641. The coordinator deliberately approved the single allocation-cap
adjustment from 3,600 to 4,000. The instruction cap remains 40 million and all
other existing caps remain unchanged. Matched union instruction medians are
38,879,480 → 39,075,298 (+0.50%); minima are reported in the table. No further
special cases were introduced to recover the remaining 41 allocations.

Production physical `.brp` lines, measured consistently against HEAD, are
9,218 → 9,693 (+475, including the unchanged six-line explicit prelude). Test
physical `.brp` lines are 17,018 → 18,103 (+1,085). Neither deleted coverage nor
compressed formatting accounts for the production result.

## Host defect and following boundary

The host compiler generated incompatible C for a nested `Result[Void, Diagnostic]`
arity expression: a `blorp_Result*` was assigned to a `blorp_StackResult` at
`host_result_repro.c:47926`. `host_result_repro.brp`, its C and compile log retain
the small reproduction. The pilot uses a direct optional arity diagnostic before
constructing a successful contract, an ordinary clearer representation of this
optional failure. The pinned host was not modified. The retained repro warrants
a separate host Result-representation/codegen investigation.

The subsequent typed-checker-error slice can start at `syntax.brp`'s `Diagnostic`
and `DiagnosticNote`, checker `rejection`, `internal_error` and `type_rejection`,
the public `check` result, `main.brp`'s `CompilationDiagnostic`, and
`render_diagnostic`. This increment preserves exact rendered messages, spans
and help and introduces no new error API.
