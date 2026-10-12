# Local modules and selective function imports

Status: implemented and validated. The [results report](../benchmarks/results/blorp_2_modules_2026-10-11.md)
records independent gates, mutation oracles, matched costs and current limits.
Baseline: `42b723ac5dcf5af60f5b0e641f962dfcf654af4a`.

## Working example and scope

`test/e2e/fixtures/import/basic/main.brp`:

```blorp
import:
    ./helper: answer
func main() -> Int:
    answer()
```

Its sibling `helper.brp`:

```blorp
pure func answer() -> Int:
    42
```

Compile with the existing pilot command, passing the root file. The shell loads
its dependencies. Compile the emitted, unmodified C at `-O0` and run its real
main: exit 42, empty stdout and stderr. The baseline rejects the import syntax.

This increment supports local selective **function** imports. Relative paths
begin with `./` or leading `../` segments and may contain named subdirectories.
Paths omit `.brp`; the loader supplies that extension. Imports are module-level
and precede declarations. Each row selects one or more names. Import syntax uses
the existing indentation, comments and blank-line rules. Declarations remain
public by default. Aliases, qualified module calls, bare/library/package paths,
type/constructor imports, automatic type-enabled UFCS and private declarations
remain later increments; reject unsupported forms with teaching diagnostics.

Existing unions, records, generics, local shadowing, purity and ownership continue
to work inside every module. Importing a function does not import its siblings,
types or constructors, and does not change the scope of its implementation.

## Established implementations and the bounded choice

Study implementation facts separately from surface syntax:

- Rust's [definition IDs](https://github.com/rust-lang/rust/blob/1.98.0/compiler/rustc_span/src/def_id.rs)
  separate declaration identity from spelling. Its
  [resolver](https://github.com/rust-lang/rust/blob/1.98.0/compiler/rustc_resolve/src/lib.rs)
  records an imported binding's original declaration. Borrow that distinction.
  Its [iterative import resolver](https://github.com/rust-lang/rust/blob/1.98.0/compiler/rustc_resolve/src/imports.rs)
  serves a richer environment; direct imports of inventoried local declarations
  do not require it here.
- OCaml's [identifiers](https://github.com/ocaml/ocaml/blob/5.4.0/typing/ident.ml)
  compare declaration stamps rather than names. Its
  [environment](https://github.com/ocaml/ocaml/blob/5.4.0/typing/env.ml) and
  [module typing](https://github.com/ocaml/ocaml/blob/5.4.0/typing/typemod.ml)
  distinguish opening visible components from publishing signature items.
  Borrow visibility without implicit reexport; omit interface-file caches and
  recursive-module initialization machinery.
- GHC's [reader environment](https://github.com/ghc/ghc/blob/master/compiler/GHC/Types/Name/Reader.hs)
  distinguishes occurrence lookup, resolved names and import provenance. Its
  [renamer](https://github.com/ghc/ghc/blob/master/compiler/GHC/Rename/Names.hs)
  resolves selected imported entities and constructs visibility facts. Keep
  accepted types and body-local inference separate from that visibility.
- Elm's [import environment](https://github.com/elm/compiler/blob/master/compiler/src/Canonicalize/Environment/Foreign.hs)
  explicitly distinguishes qualified/unqualified values, types and constructors,
  preserves their home module and reports missing exposed names. Borrow home
  identity and exact selector diagnostics. Elm's
  [build graph](https://github.com/elm/compiler/blob/master/builder/src/Build.hs)
  rejects module cycles; that is a separate policy from declaration lookup.
- Scala's [ImportInfo](https://github.com/scala/scala3/blob/main/compiler/src/dotty/tools/dotc/typer/ImportInfo.scala)
  models selectors and symbol-backed import sites. Keep selector provenance
  explicit here; wildcard, renamed and implicit imports are outside this slice.

Blorp's existing module surface publishes local declarations, not imported names
(`blorp/src/compiler/stage_04_modules/module_surface.brp`). Preserve that rule.

Dependency cycles are allowed in this restricted increment. Every function has
an annotated signature, imports target only local declarations, and modules have
no runtime initialization. Inventory the complete input before resolving imports
and checking bodies. Loading each normalized module path once bounds cycles and
diamonds. This is distinct from permitting cyclic runtime values, which remain
forbidden. Adding initializers or reexports requires revisiting their own rules.

## Identity, ownership and publication

| Fact | Authority | Lifetime and consumers |
| --- | --- | --- |
| Source path and bytes | Loading shell's input inventory | One compilation; parsing and diagnostic projection |
| Module identity | Module inventory | One compilation; declaration ownership and namespace lookup |
| Source occurrence | Qualified Span with source identity and local byte range | Preserved through diagnostics and semantic/IR spans |
| Spelling identity | One shared parser/interner table | All module parses extend the same authority; diagnostics borrow spellings |
| Function/union/record identity | Program-wide declaration inventory | Dense ordinal per kind; accepted and concrete facts refer to the same declaration |
| Import visibility | Frozen namespace built from inventories and selectors | Checking only; never accepted signature or inference state |
| Accepted signature | Checker-owned signature inventory | Body checking and specialization; one signature authority |
| Entry identity | Root module's local main declaration | Accepted program through emission |

Keep one flat parsed declaration list per kind. Store the owning ModuleId directly
on a declaration, avoiding extra allocated wrappers or duplicate module ASTs.
Module rows own imports and end locations. Declaration IDs follow module inventory
order, then declaration order within their kind. One-module inputs preserve
their existing IDs and generated C.

Imports create visible bindings to original function IDs. Resolve selectors
against the target module's **local** declaration inventory, never its imported
bindings. Preserve selector spans for conflict diagnostics. Namespace candidate
sets can explicitly represent ambiguity; semantic conflicts are diagnosed before
bodies are accepted. Preserve the existing no-import diagnostic order: prelude
conflicts, type/variant declarations, function signatures, then bodies.

Check every annotation and body in its defining module. Nominal type identities
in accepted signatures remain valid when their spelling is invisible to a caller.
Constructor and UFCS lookup still obey the caller's visibility and existing
type-directed rules. A local value shadows a direct call; receiver-call lookup
continues to bypass local value bindings.

Only root-local main supplies the executable entrypoint. Other modules' functions
named main are ordinary helpers. Imported main cannot satisfy a missing root
entrypoint. Apply entry ABI restrictions to its selected identity.

## Pure pipeline and source loading

The shell reads files, normalizes paths relative to each importing file and
invokes the same pure parser needed for compilation. Parsed import requests drive
loading; do not add a second header scanner, concatenate source strings or rewrite
names. Reuse parsed ASTs and the shared name authority when publishing the complete
input. Loading a dependency once per invocation is graph construction, not a
persistent compiler cache.

After source loading, namespace construction, checking, specialization, lowering,
ownership, independent verification, emission and diagnostic rendering are pure.
Paths/spellings may be used at the filesystem and diagnostic boundaries; semantic
consumers use typed identities. Missing inputs and invalid selectors publish no C
and do not overwrite an existing output file.

Source identities must preserve secondary diagnostic locations across files.
Use opaque numeric source/module identities, with central named source roles and
checked translations. A host representation probe found that an enum field made
Span managed: constructing 64 spans added 128 allocations compared with the
numeric carrier. Preserve inline scalar spans. Intentional internal diagnostics
have an explicit compiler origin, rather than claiming an unrelated input file.

## Acceptance and measurements

Write failing tests first and demonstrate these behaviors:

1. Basic import, transitive dependency and diamond load execute through main.
2. Dependency cycles terminate loading and compile; calls retain normal recursion
   rules. Each logical module has one declaration inventory.
3. Same-spelled helpers and nominal types in different modules keep distinct
   identities. An imported function calls its own unselected helper.
4. Unselected/transitive functions and foreign constructors remain invisible.
   Direct calls, UFCS and local shadowing observe the proper namespace.
5. Missing module/function, duplicate target/selector/local binding, unsupported
   syntax and prelude collisions check exact text, help and source spans.
6. Imported main remains ordinary; missing/invalid root main rejects. Invalid
   unused dependency declarations are still checked.
7. Cross-file purity/type errors and secondary annotation notes name the correct
   source and local offset.
8. Existing unit/runtime/grammar suites, strict sanitizer/leak runs, and e2e pass.
   All existing no-import fixture C remains byte-identical.

Measure a frozen baseline/candidate pair at the same owned-input compilation
boundary. This is a proxy, not self-compilation. Initial investigation ceilings
for the existing fixture corpus are +15% allocations and +10% retired instructions;
repeatable excess requires investigation and rescoping before acceptance. Retain
existing per-fixture ceilings; adjust only deliberately with explained evidence.
Report handwritten production and test LOC separately. Prefer direct lists over
unmeasured indexes and avoid extra publication layers.

Use [scripts/record-validation](../scripts/record-validation) for command receipts.
Baseline binaries, probes, raw samples and receipts live under ignored
`build/imports/` (source representation probes also under `build/provenance/`).
The retained results report will link the final evidence and unresolved limits.
