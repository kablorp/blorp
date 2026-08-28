# Typed Member And UFCS Completion

**Status:** Blocked on compiler projection

## Goal

After `receiver.`, offer exact record/struct fields, callable methods, trait
methods, and UFCS functions applicable to the receiver's resolved type. Rank
and deduplicate candidates deterministically while preserving import,
visibility, generic-bound, purity, and overload rules.

## Missing Contract

The current accepted typechecked graph describes valid completed programs. The
LSP needs a compiler-owned query for an incomplete completion site that returns
an opaque receiver identity/type and already-filtered candidate facts. The LSP
must not reconstruct this from source text or reach into private `Env`/`Scope`
state.

Before implementation, a compiler-facing issue must specify:

- how a completion hole survives parse and semantic preparation;
- the receiver type representation safe to expose across the stage boundary;
- field ownership and visibility;
- UFCS and trait-method applicability, imports, bounds, and overload order;
- behavior for unresolved or partially inferred receivers; and
- deterministic candidate identity and display information.

## Required Future Tests

The eventual work must cover records and structs, aliases, generic receivers,
trait bounds, imported and private methods, UFCS free functions, overloaded
names, unresolved receivers, incomplete syntax, purity constraints, duplicate
suppression, and UTF-16 replacement ranges.

Do not start by scanning all functions for a compatible first parameter. That
would duplicate type checking, miss compiler policy, and make completion both
slow and semantically inconsistent.
