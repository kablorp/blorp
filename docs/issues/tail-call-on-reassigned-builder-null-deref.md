# A tail call on a reassigned builder variable reads a null owner

Status: open. Found with the pinned bootstrap compiler
(`scripts/blorp-compiler-bootstrap --print-id`); not checked against a newer one.

In `parse_named_type` of
`blorp/src/compiler_new/stage_01_discovery/parse/type_parser.brp`, a branch of
an `if` / `else if` / `else` chain that reassigns the `var out: DiscoveryBuilder`
and then ends with a method call on it as the tail expression made the
bootstrap-built compiler dereference a null builder:

```
out = out.append_plain_diagnostic(BoundInTypeDiagnostic, span)
out.append_named_type(None, first_name, first_span, first_span, [])   -- tail
```

The compiled `last_node_id` (`nodes.length() - 1`) read a null builder at the
first type the standard library parses, so every `check` with the discovery
stage crashed (EXC_BAD_ACCESS at 0x10) before reaching user code. Assigning the
call to `out` and ending the branch with `out`, as the neighbouring branch
does, avoids it.

## Reproduction

1. In `parse_named_type`, replace the two lines
   `out = out.append_named_type(...)` / `out` of the `OrdinaryArgument` branch
   with the single tail call above.
2. `make`, then
   `BLORP_FRONT_END=stage bin/blorp check --no-format any_file.brp`: exit 139.

A reduced program with the same shape (a record threaded through a
`var`, reassigned in an `if` branch, ended by a method-call tail, with a
`while` loop in the branch) compiles and runs correctly under the same
bootstrap, so the trigger needs more of the surrounding function (several
`else if` arms and a later `out = out.parse_array_suffixes(...)`). Reducing it
further is the open work.

## Proposed fix

Find the Perceus decision that drops the owner of `out` before the tail call
when the branch is not the last in the chain, using the Core before and after
Perceus of `parse_named_type`; add a Core test for it.
