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
| CF-025 | `into_opaque` written directly as a generic call argument, `listed.append(into_opaque Id(position))`, is rejected with "Conflicting type arguments for generic function 'list__append'"; binding `id = into_opaque Id(position)` first compiles. Reproduction in `benchmarks/results/blorp_2_perf_fixes_2026-10-15.md`, "Host-compiler defects" 3 |
| CF-026 | An or-pattern nested in a constructor pattern passes `bin/blorp check`, then emission fails with `#error "Blorp backend could not emit function body: ready"` (`child_kind=raw_match`); expected: the function compiles, as a top-level or-pattern does. Minimal input: `fixed union State` with `First`, `Second`, `Third`; `pure func ready(status: Option[State]) -> Bool:` matching `None: False`, `Some(Third): False`, `Some(First \| Second): True`; called from `main`. Raised in `emit_unsupported_function_error` (`stage_10_backend/emit.brp`) |
| CF-027 | A constructor pattern inside a list pattern selects the wrong arm at runtime with no diagnostic: `match values: [Some(found)]: found / _: 99` on `[Some(5)]` (a `List[Option[Int]]`) returns 99 instead of 5. `[found]` on a `List[Int]` and `Some(found)` on an `Option[Int]` both work; the same shape as a variant field (`Case(_, [Some(found)])`) also falls through. Raising site not yet located |
