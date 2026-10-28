# Compiler Faults

Open defects in the old compiler under `blorp/src`: wrong acceptance, internal
errors, invalid C and wrong results. The old compiler receives fixes only;
diagnostic wording and other improvements are not tracked. Add a minimal
input, the actual behavior, the expected behavior and the raising site when
one is found. Delete closed entries; regression fixtures and Git preserve
completed work. Numbers are stable and never reused.

Start with [Worker Checklist](WORKER_CHECKLIST.md). Find a fixed output phrase
with `rg -n -F '<phrase>' blorp/src`, then cite its raising site.

| ID | Open fault |
| --- | --- |
| CF-001 | Bare print emits an undeclared wrapper |
| CF-004 | Unknown uppercase pattern binds silently |
| CF-005 | Int[] silently becomes Int |
| CF-006 | Triple-quoted string becomes empty |
| CF-007 | Duplicate functions and parameters accepted |
| CF-009 | Pure function reads mutable module var (design decision open) |
| CF-013 | Tensor equality on non-numeric elements passes typecheck, then stops in trait resolution |
| CF-014 | An unqualified `fixed_point(1.5, 2)` call typechecks, then C emission fails (undeclared identifier without an import; unresolved call kind with a bare `import: fixed_point`) |
| CF-015 | Perceus conflates binders that share a name and differ by id (`perceus/uses.brp`, `perceus/balance.brp`) |
| CF-016 | Importing a constructor a union does not export, from a file that also imports `compiler_new/.../tables/span`, makes `check` print only a cascade of "internal compiler error: compile-time evaluation received a missing standard Range field authority" (in the span module's global constants), hiding the real "constructor ... is not exported" error |
| CF-017 | A payload-less variant of a generic union built in another module emits an undeclared C identifier: `union Read[M]: Got(M) / Missing` in `reads.brp`, and `Missing` returned from a function in `main.brp` gives `use of undeclared identifier 'Missing'` from the C compiler |
| CF-018 | `recv`, `try_recv` and `recv_timeout` on a `Channel` of a user enum, `Int128` or `UInt128` emit C that initializes a `blorp_StackOption_*` from `void*` and does not compile (`specialize_collection.brp`, channel receive) |
| CF-019 | A `concurrent:` task returning `Int128` or `UInt128` leaks its result box under `--leak-check` (`c_type_layout.brp`, `erased_slot_needs_release_type`) |
| CF-020 | `List.unique` and `List.partition` leak one managed record per element under `--leak-check` (`synth_list.brp`, `partition_push` and `synthesize_unique`) |
| CF-021 | A cancellation inside a hash or equality callback during a `Dict`/`Set` lookup, between boxing the key (`blorp_box_struct`, 128-bit boxes) and the lookup's release of it, leaks the key box (`specialize_collection.brp`, `dict_get_releasing_key_box` and `resolve_erased_key_temp_release`) |
| CF-022 | `a.not_equals(b)` is rejected as a missing field, although `not_equals` is an Equatable method every implementation has |
| CF-023 | Comparing a generic record with a record literal, `w == {value = 1}` for `Wrap[Int]`, is an internal error: "matched record type 'Wrap' has no field metadata" |
| CF-024 | Suspected: `freshen_shadowed_match_bindings_if_catalog_admits` (`perceus/shadow_catalog.brp`) may duplicate a subtree across match arms without minting fresh node ids, so a node id is not unique. A parked `(node id, name)` summary memo for `summarize_linear_ownership_uses` (about 7M allocations saved) emitted non-identical C and hit an ASan heap-use-after-free in the compiler test suite, which points here. No minimal input yet |
| CF-025 | `into_opaque` written directly as a generic call argument, `listed.append(into_opaque Id(position))`, is rejected with "Conflicting type arguments for generic function 'list__append'"; binding `id = into_opaque Id(position)` first compiles. Reproduction in [the perf fixes report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_perf_fixes_2026-10-15.md), "Host-compiler defects" 3 |
| CF-026 | An or-pattern nested in a constructor pattern passes `bin/blorp check`, then emission fails with `#error "Blorp backend could not emit function body: ready"` (`child_kind=raw_match`); expected: the function compiles, as a top-level or-pattern does. Minimal input: `fixed union State` with `First`, `Second`, `Third`; `pure func ready(status: Option[State]) -> Bool:` matching `None: False`, `Some(Third): False`, `Some(First \| Second): True`; called from `main`. Raised in `emit_unsupported_function_error` (`stage_10_backend/emit.brp`) |
| CF-027 | A list pattern over `List[Option[T]]` with an unmanaged scalar `T` selects the wrong arm at runtime with no diagnostic: `match values: [Some(found)]: found / _: 99` on `[Some(5)]` returns 99 instead of 5. Fails for `T` = `Int`, an opaque type over `Int`, `Float` and `Bool`, also nested (`(_, [Some(a), Some(b), Some(c)])`, `Case(_, [Some(found)])`). Works for `Option[String]`, `Result[Int, String]`, managed and fixed unions, and for `[found]` on `List[Int]` or `Some(found)` on `Option[Int]` alone, so the stack-`Option` element representation is the likely cause. Raising site not yet located |
| CF-028 | A record bound at the top of a loop body and read in only one nested match arm leaks on the other paths: Blorp 2's `namespace/namespace.brp`, with a `SiteProbe { path, selection }` record bound at the top of `select_methods`' loop and read only in its `ReceiverNotVisible` arm (an 8-line change, in [the namespace scopes report](https://github.com/kablorp/blorp/blob/1e07c4dce85e51cd7ad911142e9bc96a5e0d91c7/benchmarks/results/blorp_2_namespace_scopes_2026-10-15.md)), leaks 8 objects (448 bytes: 4 `List`, 4 `ModulePath`) on `blorp_2/test/e2e/fixtures/return/zero.brp` under `BLORP_LEAK_CHECK=strict`; expected: no leak. Single-file reductions do not leak yet. Raising site not yet located |
| CF-029 | `from_opaque Wrap(w).get_or(0, row)`, with `opaque type Wrap = List[Row]`, is rejected with "Generic type parameter T inferred as Row and Wrap"; expected: it compiles, as binding `rows: List[Row] = from_opaque Wrap(w)` and then calling `rows.get_or(0, row)` does. Raising site not yet located |
| CF-030 | Unwrapping a value of a generic opaque type miscompiles ownership. Minimal input: `fixed record Rows[V] { entries: List[V], slots: List[Int] }`, `opaque type Box[V] = Rows[V]`, `pure func make[V](value: V) -> Box[V]` returning `into_opaque Box[V]({ entries = [value], slots = [0] })`, and `pure func count[V](box: Box[V]) -> Int` binding `rows: Rows[V] = from_opaque Box[V](box)` and returning `rows.entries.length()`; `main` binds `box: Box[String] = make("three")` and returns `count(box) + count(box)`. Expected: exit status 2. Actual: SIGSEGV (status 139), because the unwrap releases the borrowed `box`. `from_opaque Box[V](box).entries.length()`, or passing the unwrapped value to a helper, leaks 3 objects under `--leak-check` instead. The monomorphic `opaque type Box = Rows` is correct. Blorp 2's `utils/int_map.brp` is a plain record because of it. Raising site not yet located |
| CF-031 | `?=` inside a bound `match` exits only the arm, then execution continues after the match. Expected: return the failure from the enclosing function. Minimal input below; raising site not yet located. Blorp 2 rejects this placement. |
| CF-032 | Reported in the earlier quality investigation: an `Ok`/`Err` match used directly as a `?=` initializer fails with "Incompatible error type for ?="; an explicitly typed Result temporary avoids it. The original failing input was not retained. A simple Bool/Int/String example passes on the frozen host, so the fault remains unverified pending reduction. `infer_question_bind_statement` infers without an expected type (`stage_06_typecheck/infer.brp:22504`); the reported message is raised at line 22548. This source observation alone does not prove the fault. |

## Nested Result propagation

CF-031 reproduction:

```blorp
pure func parse(n: Int) -> Result[Int, String]:
    if n < 0:
        Err("negative")
    else:
        Ok(n)

func run(n: Int) -> Result[Int, String]:
    chosen: Result[Int, String] = match n < 100:
        True:
            parsed ?= parse(n)
            Ok(parsed)
        False: Ok(0)
    print("reached the line after the match")
    chosen

func main() -> Int:
    match run(0 - 1):
        Err(_): 0
        Ok(_): 1
```

Expected: exit 0 without printing. Actual: exit 0 after printing the line.
Use an explicit `match` and return its carrier from the function instead.

CF-032 still needs a standalone failing input. On the frozen host, a
`choose(ready: Bool) -> Result[Int, String]` function using
`value ?= match ready: True: Ok(1) / False: Err("not ready")` and then
`Ok(value)` compiles. Do not use it as a regression for the reported fault.
The source rewrite retains the explicit-carrier idiom below; it provides the
expected type directly, but is not evidence that the unannotated form fails:

```blorp
result: Result[Int, String] = match ready:
    True: Ok(1)
    False: Err("not ready")
value ?= result
```
