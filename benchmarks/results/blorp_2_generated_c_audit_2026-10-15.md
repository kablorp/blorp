# Blorp 2 generated C audit — 2026-10-15

Frozen source: `fb19670d471d86c3f7798e2ece161623e4561941`, branch
`codex/fresh-main`. This audits the C that the pilot produces for input
programs. The host-generated `blorp_2/build/compiler.c` is outside the corpus.
No compiler, runtime, fixture or test source was changed.

The overall shape is sound: flat value locals, explicit control flow, typed
layouts, and explicit ownership obligations. The audit found a reproducible
GCC portability issue and an avoidable numeric-List destruction loop at O0.
The more substantial growth risks are already accepted roadmap limitations:
always-fresh List updates and managed recursion. No demonstrated use-after-free,
double-free or leak was found in the inspected paths; this is not a proof of
leak freedom or all-program correctness.

## Scope and evidence

The host was freshly built and reports FRESH at the frozen commit. The pilot
was built once with `make -C blorp_2 test-compiler`, at O0. A separate normal
`make -C blorp_2 test-e2e` run passed **415 cases, 0 failures**. Its target
programs use strict C11/O0 and ASan/UBSan; its compilation allocation and
instruction checks were unchanged.

The corpus independently attempts all 414 `.brp` files under
`blorp_2/test/e2e/fixtures`, using the normal pilot CLI and target-library root.
339 produce C; 75 return compiler status1. The latter inventory includes
rejected inputs and support modules that are not standalone entrypoints; these
counts do not imply 75 failing e2e cases. Emitted C was not rewritten, and
native checks use each program's ordinary `main`.

Local raw artifacts are under ignored `build/c-output-audit-2026-10-15/`:

- `host-build.log`, `host-status.txt`, `pilot-build.log`, `e2e.log`.
- `fixture-files.txt`, `corpus.tsv`, and `corpus/<fixture-relative-path>.c`,
  with pilot compilation stdout/stderr beside each output.
- `assembly/`: Apple Clang21 O0/O2 assembly and optimized-object symbols.
- `probes/`: an additional ordinary-main Blorp Float reproduction, its unchanged
  generated C, binaries, outputs, diagnostics, assembly and exact `commands.txt`.
- `gcc-version.txt` and `docker-image.txt`: Ubuntu GCC13.3 on arm64, in cached
  image `sha256:4dccce65789d11443df626ca94e4f9cf83a7b16d88a919c8bc82030fe239834e`.
- `census.rb`: a reproducible lexical-only depth/size observation. It excludes
  comments and quoted contents but does not preprocess C, validate syntax or
  cross-kind delimiter pairing, or measure native AST/resource use.
- `independent-validation.txt`: independently reproduced outputs and verified
  inventory, source hashes, assembly, symbols and test receipts.

Below, `src/...` and `ROADMAP.md` anchors are relative to `blorp_2/`; generated
`.c` anchors are relative to the artifact directory's `corpus/`. Other raw
artifact paths are relative to the artifact directory.

All native work was serialized by the coordinator. Two independent
compiler-expert audits reviewed ownership/runtime and code shape separately.
No wall-time speedup is claimed from source counts or assembly inspection.

## 1. Float's native compilation contract is incomplete for GCC

**Confirmed portability defect, P2; conditional numerical contract failure.**

`src/runtime/float.brp:12` emits:

```c
#pragma STDC FP_CONTRACT OFF
```

The existing `calculator/float_literals.c:47` fails the harness's strict flags
with GCC13.3:

```text
error: ignoring '#pragma STDC FP_CONTRACT' [-Werror=unknown-pragmas]
```

[GCC documents that this pragma is unimplemented](https://gcc.gnu.org/onlinedocs/gcc/Floating-point-implementation.html).
The normal tested Clang path accepts it. Warning suppression is not the remedy
for the separate numerical requirement: each Blorp Float operation must round
as binary64 rather than silently fuse across operations.

The additional normal-main probe parses its two values from argv, then computes:

```blorp
pure func calculate(first: Float, second: Float) -> Float:
    subtract(multiply(first, second), 1.0)
```

For `1.0000000000000002` and `0.9999999999999998`, separately rounded
multiplication yields 1, so subtraction must print `0`.

| C build of the same unmodified generated probe | Printed result |
| --- | --- |
| Apple Clang21, strict C11, O2 | `0` |
| GCC13.3, `-std=c11 -O2` | `0` |
| GCC13.3, `-std=c11 -O2 -ffp-contract=off` | `0` |
| GCC13.3, `-std=c11 -O2 -ffp-contract=fast` | `-4.930380657631324e-32` |
| GCC13.3, ordinary `gcc -O2` default GNU C mode | `-4.930380657631324e-32` |

Fast-contraction assembly contains `fmadd`; strict-default assembly contains
separate `fmul`/`fsub`. These flags do not trip the generated `__FAST_MATH__`
guard. The explicit fast-contraction observation is not a claim that every GCC
configuration fails; the tested strict-C11 default produces the expected zero.
The ordinary GNU-mode result is an additional reason to specify supported
native settings instead of treating them as an implementation detail.

**Bounded follow-up:** make non-contraction an explicit native build contract,
use tested compiler flags, and make the pragma policy compatible with supported
C compilers. Cover both exact numeric results and the strict warning gate in
the existing runtime/e2e boundaries. This belongs to target runtime/emission
and native invocation settings, not type inference or ownership IR. No fix
was made during this audit.

## 2. Unmanaged List destruction performs useless O0 work

**Confirmed unnecessary work, P2 efficiency; removed by the tested O2 compiler.**

`list/append_int.c:47` contains the final-release loop:

```c
for(int64_t index=0;index<value->length;index++){
    int64_t element=value->values[index];
    (void)element;
}
free(value);
```

Int elements have no cleanup. `src/emit/emit.brp:2287-2295` already derives
`NoOwnership`, then renders its destruction fragment as an empty String.
`src/runtime/list.brp:151-154` emits traversal regardless of that fact.

The Apple Clang21 O0 assembly preserves the counter, length check, slot load
and backedge (`assembly/append_int_O0.s:216`). At O2 the helper contains only
atomic decrement, a conditional branch and `free` (`append_int_O2.s:193`).
Thus this is real development-mode work, not a claim of production O2 slowdown.

**Bounded follow-up:** retain the already-known absence of child cleanup in the
List runtime-builder input, for example as an optional destruction fragment,
and emit no element loop for that case. Do not rediscover semantic ownership
by comparing rendered C strings. Focused evidence should include a small emission
test, existing unmanaged and owning-element runtime cases, and O0
assembly/instruction confirmation. Ordinary change gates and matched compiler
cost requirements still apply. This needs neither COW nor consuming-ABI inference.

## 3. Fresh List updates have quadratic builder costs

**Confirmed structural scaling cost; deliberately deferred.**

`list/append_int.c:47` allocates `count+1` slots and copies the entire prefix.
`append_entries.c:47` additionally retains every copied managed occurrence.
`src/runtime/list.brp:184-225` establishes the fresh-result contract for
append/set; concat similarly copies both inputs.

```c
result=malloc(...(count+1)...);
for(uint64_t index=0;index<count;index++){
    element=values->values[index];
    /* acquire element when it owns managed data */
    result->values[index]=element;
    result->length++;
}
```

N successive appends from empty therefore copy N(N-1)/2 old slots, independent
of how quickly C itself compiles. This is an algorithmic derivation, not a
measured timing regression. Snapshot semantics and repeated-slot ownership are
correct; removing those acquisitions in emitted C would break the contract.

`ROADMAP.md:583-590` explicitly measures always-fresh append at the fixpoint
and makes unique-root reuse a subsequent increment. Preserve that ordering,
but keep representative builder workloads in the measurement plan. Long-term
reuse requires explicit permission to consume/update a root and proof about
aliases and capacity; it is not a C peephole optimization.

## 4. Managed recursion and destruction still have stack limits

**Known accepted limits, with distinct causes.**

- `recursive/tree.c:48`, corresponding to `sum(values,index,acc)`, calls itself
  and then drops the current `get()` result before returning. Its cleanup
  continuation prevents an ordinary C tail call. Stack grows with List width,
  even if the tree itself is shallow. The existing code preserves ownership;
  keeping the get-result owner live does not by itself prove more heap
  allocation because this fixture retains the source List throughout.
  Producer: `src/own/own.brp:919-934`; M3 in `ROADMAP.md:430-450` owns managed
  loop-carried values and their transfers.
- Record/List layout groups release through mutually recursive helpers:
  `record_drop -> union_drop -> list_drop -> record_drop` in `recursive/tree.c`.
  This grows with value depth, independently of traversal order. Direct unary
  boxed-union chains instead use an iterative drop loop that stops on sharing.
  Producers: `src/emit/emit.brp:707-777,1415-1577` and
  `src/runtime/list.brp:151-154`.

The repository deliberately accepts recursive group release for now and has
measured stack-depth evidence in
[`blorp_2_recursive_mixed_2026-10-15.md`](blorp_2_recursive_mixed_2026-10-15.md).
Different raw/source-shaped probes have different thresholds; this audit does
not repeat or combine them. A worklist release remains a measured-demand
follow-up in `ROADMAP.md:488-498`, not a reason to add a trampoline everywhere.
Construction, traversal and teardown need separate depth tests so an earlier
stack overflow is not misidentified as a destructor failure.

## 5. Helper inclusion is coarse, with some unused optimized code

**Low-priority footprint concern; no material latency claim.**

Using a concrete List emits dup/drop/repeat/length/get as a family, even when
some operations are unused. `list/literal_int.c:47` has a repeat helper although
the fixture constructs a literal. Its O2 object still defines
`blorp_list_repeat_0_i`, and also `blorp_int_to_string` from the String family
(`assembly/literal_int_O2.symbols`). These are global C functions, so the tested
object generation keeps them. This establishes object code presence, not final
executable size or a measured native-compile regression.

String presence pulls the base helpers; Float presence pulls all arithmetic,
including remainder's `fmod`. More precise demand is a possible later refinement
of existing typed runtime-feature facts. Measure source/object/native cost
before expanding the demand model. Making every helper static by itself would
also need to respect the strict unused-function warning gate.

## What looks healthy

- Calls take previously evaluated locals, so source effects do not depend on
  C's unspecified argument evaluation order.
- Integer helpers perform unsigned wrapping and convert back only through
  representable signed values. Division and remainder handle zero and
  `INT64_MIN / -1` explicitly.
- Optional parse/get scratch values are initialized before result construction.
- Self-tail loops assign from captured immutable values, then `continue`,
  preserving swapped and repeated arguments. `tail_recursion/swap_left.c:2`
  is a small example; the ordinary-main accumulator fixture tests one million
  iterations in the normal e2e suite.
- Concrete layouts and forward declarations avoid recursive by-value sizes.
  Specialization follows the entrypoint and deduplicates concrete identities.
- `record/shared_string.c:43` acquires two occurrences of one String and drops
  both fields once. `record/identity_escape.c:42` secures an aliased result before
  the caller's original owner is released. Escaped fields in
  `record/update/escaped_children.c:47` acquire before their parent is dropped.
- Extra locals, owner aliases and `(void)` casts preserve clear sequencing and
  obligations; verbosity alone is not an optimization defect.

The lexical census found maximum brace depth **6**, parentheses **3**, brackets
**1**, with zero nonzero final delimiter counts. Largest output was
`match/many_arms.c` at **47,240 bytes**. `return/zero.c` is **181 bytes** and pulls
only `<stdint.h>`; hello is **2,280 bytes**, including its String runtime.
There is no observed accumulating statement-expression nesting problem in this
corpus. These lexical facts do not establish scaling for a self-hosted compiler
or replace supported-toolchain native stress tests.

## Recommendation

Address the Float compiler contract before claiming GCC portability, then remove
the O0 unmanaged-List traversal as a small independent change. Keep List reuse
and managed-loop/release work on their existing roadmap, with representative
scale tests. The findings do not justify a backend rewrite or broad cleanup of
safe temporary variables.

Independent compiler-expert reviews approved the report; independent validation
passed with zero unexpected failures. The validator checked all 493 frozen
input hashes, regenerated three fixtures and the Float probe byte-identically,
reproduced native findings and verified the 415/0 e2e receipt without rerunning
the full suite. No implementation, production tracing, new test framework,
fixture rewrite or alternate entrypoint was introduced. Existing e2e and the
additional Blorp-main probe provide the execution evidence; ASan/UBSan success
alone is not proof of leak freedom.
