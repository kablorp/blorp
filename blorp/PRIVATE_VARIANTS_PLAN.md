# Private variants plan

**Status: in progress, 2026-11-25.** Keith approved the design and asked for
this plan, then started it with landing 0. Landings 0 to 3 have landed;
landing 4, the migration, is next. Landing 0 belongs to [`EQUALITY_PLAN.md`](EQUALITY_PLAN.md),
which records its results.

**The direction.** Keith chose it in discussion:

- Opaque types become unions whose variants are private.
- The migration first enables private variants, then moves every opaque use
  to them, then deletes the opaque machinery.
- He settled five questions under [Decisions](#decisions).

**The reviews.** A parser and soundness review (Opus) and an ergonomics
review (Sonnet) both found the design sound with changes. Their findings are
folded in below. A third review (Opus) checked rule 2 after Keith changed
it, and found it sound with changes. Every blocker is resolved, and Keith
settled its question as [Decisions](#decisions), item 5.

**Evidence.** The change inventory comes from a read-only survey of
`e65b646b5`. The reviews spot-checked it and extended it. The full survey, with
`file:line` evidence, is in the main checkout's ignored
`build/audit-2026-11-17/opaque-inventory.md`.

## Problem

Opaque types are a second kind of nominal type beside records and unions,
with their own declaration form and two conversion keywords:

```blorp
opaque type FunctionLabel = String

from_opaque FunctionLabel(enclosing).some_string_method()
match from_opaque DeclarationInventory(inventory).functions.get(id.function_number()):
```

- **The conversions read badly.** A prefix keyword reads as if it covered
  everything to its right, but the grammar makes the form a primary. It is
  the only prefix-keyword expression left. 84 of the 260 `from_opaque` forms
  in `src` and the library are followed directly by `.field` or
  `.method()`, and some sites already add parentheses to show where it ends:
  `(from_opaque LineIndex(index)).starts`.
- **The type name is redundant.** In 257 of 267 `from_opaque` forms, the
  operand's declared type already names it.
- **The machinery is large.** About 1,395 production lines implement this
  kind of type alone, across lex, parse, ids, namespace, 19 check files,
  specialize, format and the LSP. Most of it repeats what unions already do:
  a nominal identity, type parameters and bounds, equality derivation,
  recursion rules, and erasure at layout.

## Design

### The rules

```blorp
union UserId:
    private Init(Int)

private pure func user_id(value: Int) -> UserId:
    Init(value)                     -- build

pure func number(id: UserId) -> Int:
    Init(value) = id                -- read: one variant, so the binding always matches
    value
```

1. **Private variants.** A variant may be marked `private`. It can be built,
   matched and destructured only in its declaring module. The union keeps one
   copy of the declaring module, on `CheckedUnion`, and each variant carries
   only its privacy. A variant is private when it is marked, or when its
   union is private. That effective privacy has one producer,
   `effective_visibility`, which `VariantRow` stores and the parser's
   resource shape rule calls; namespace, check, the hidden head and the
   visible-variants query read `VariantRow`. `ParsedVariant` keeps only the written
   mark, for the formatter and rule 4.
2. **Bare names when unambiguous.** Every variant, public or private, enters
   its module's scope under its bare name, and the module's own variants may
   share a spelling. A bare `Init` resolves where only one variant in scope
   has that spelling; otherwise each bare use is reported as ambiguous, and
   `UserId.Init` always works. A qualified `email.Unchecked` is ambiguous in
   the same way when module `email` declares several public `Unchecked`
   variants. An imported or prelude variant keeps today's rule: it conflicts
   with any other variant of its spelling, and the conflict is reported once,
   at the import or declaration (decision 5). A variant also conflicts with a
   constant of its spelling; the naming rules keep functions and aliases
   lower-case.
3. **Outside the module.** Naming a private variant is an error, whether to
   build it, in a pattern, in an import selection, or through an alias
   (`email.Checked`). A `match` on a union with private variants must cover
   them with `_`. No diagnostic that another module sees may name a private
   variant the user did not write: not "did you mean" suggestions, the
   unimported-pattern help, the list of a union's variants, or an
   exhaustiveness witness. The rule governs a message's text, not its
   locations: a note may point into the declaring module, a private
   payload's line among them, as the automatic-equality note does when a
   private payload holds a closure. That source is the reader's to open, and
   the location is the error's cause.
4. **Redundant marks.** In a `private union`, `private` on a variant is an
   error: its variants are already private. `private` on a variant means
   only access (decision 4).
5. **Payload privacy.** A private variant's payload may mention private types.
   The rule that a public function, field or payload cannot mention a private
   type exempts it. About 28 of the 67 opaque types sit over private types:
   every `*Identity` record, `DeclarationRows`, `NameRows`, `ProgramBuilder`,
   `Lifecycle`, and the library's `DictContents`.
6. **Same names.** A variant may not share its union's name. The convention
   for a single private variant is `Init`. The README calls it a convention,
   and the language does not require it.
7. **Destructuring bindings.** These extend from flat tuples to a union with
   exactly one variant, whose binding always matches:
   `UserId.Init(value) = id` and `Pair.Init(left, right) = pair`. A union with
   more than one variant needs `match`.
8. **Payload layout.** A union with one variant and one payload, whose payload
   never reaches the union again by any path, is stored as that payload, with
   no tag and no wrapper. This is how opaque types are laid out today.
9. **Resource unions.** `resource union Reader: private Init(Int)` replaces
   `resource type Reader = Int`, under decision 1 below.

The parser owns the parts of these rules that are local to one declaration:
reading `private`, the duplicate check within one union, the redundant mark
(rule 4), the same-name ban (rule 6) and a resource union's shape (rule 9). It has every fact, and principle 7
puts a rejection at the earliest phase that can detect it. Access outside the
module (rules 1 and 3) belongs to namespace and check.

### What other modules see

```blorp
-- email.brp
union Email:
    private Checked(String)         -- only `parse` makes one
    Unchecked(String)               -- anyone may make one

pure func parse(text: String) -> Email:
    if text.starts_with("mailto:"):
        Email.Checked(text)
    else:
        Unchecked(text)
```

```blorp
-- signup.brp
import:
    email: Email(Unchecked), parse

pure func label(address: Email) -> String:
    match address:
        Unchecked(text): "unverified ${text}"
        _: "verified"               -- `_` covers the private variants

pure func forged() -> Email:
    Email.Checked("x@y")            -- error: Email.Checked is private to module ./email
```

At run time a private variant falls through the public variants' tests into
the `_` arm. This is how rustc treats a `#[non_exhaustive]` enum from another
crate.

### Diagnostics

Each rejection checks its exact message, help and span (`blorp/AGENTS.md`).
"Example function" means the first public function, in declaration order,
whose result type is the union; a trait method never counts. That choice is
deterministic. A module is named by the path its importer wrote, as older
qualified-name messages do. Where no such
function exists, the help is the generic form.

| Case | Message | Help |
| --- | --- | --- |
| A private variant used outside its module | `Email.Checked is private to module ./email` | `build the Email with a function ./email exports, such as parse` |
| A private variant named through an alias | `email.Checked is private to module ./email` | the same |
| A variant of a private union, from another module | today's private-name message, `Secret is private to ./email` | today's help |
| An import selection of a private variant, bare (`email: Checked`) or under its union (`Email(Checked)`) | `Email.Checked is private to module ./email` | `select Email, and use the functions ./email exports` |
| A bare name that several variants in scope share, merged with today's `UnimportedVariantValue` | `Init is a variant of several unions in scope: UserId, TypeId` | `write it through one of them: UserId.Init, TypeId.Init` |
| `email.Unchecked`, when `email` declares several public `Unchecked` variants | `Unchecked is a variant of several unions in module ./email: Email, Draft` | `select the union, and write Email.Unchecked` |
| An outside `match` with no `_` | `this match on Email is not exhaustive: Email has variants private to module ./email` | `add a _ arm to cover them`, naming the position in nested patterns, as in `Some(_)` |
| A duplicate variant in one union | `UserId already has a variant named Init` | `rename one of them` |
| `private` on a variant of a `private union` | `Step is private, so its variants already are` | `remove private from Shift` |
| A variant spelled like its union | `variant UserId shares its union's name` | `name the variant, for example UserId.Init, so that UserId always means the type` |
| Destructuring a union with several variants | `Email has 2 variants, so Email.Checked(text) = address could fail to match` | `use match to handle each variant` |
| A destructuring's arity mismatch | `UserId.Init has 1 payload, but this binding names 2` | `bind one name, as in UserId.Init(value) = id` |
| A destructuring of a value of another type | `this binding destructures UserId.Init, but the value is an Email` | `destructure the value's own union` |
| A generic build without an expected type | `cannot infer T for Id.Init` | `add a type annotation, such as id: Id[User] = Id.Init(1)` |
| A resource union with a second variant, a second payload, a public variant or type parameters | `a resource union has exactly one private variant with one payload` | `declare resource union Reader: private Init(Int)`; for a private union, `private resource union Writer: Init(Int)` |
| A `match` on a resource union | `a resource cannot be matched` | `destructure it in its module, as in Reader.Init(handle) = reader` |

**One report per conflict.** Each rejection is reported once, at its cause:

- An arm that names a private variant outside its module reports the access
  error, and its `match` is not also reported as not exhaustive.
- A destructuring of a union with several variants reports that alone, not an
  arity mismatch as well.
- An ambiguous name lists every candidate in one message, in declaration
  order. Only the module's own variants can be candidates, so outside its
  module a private variant never is (rule 3).
- A variant that meets an imported or prelude variant of its spelling gets
  today's conflict, once, at the import or declaration (decision 5). Only an
  ambiguity among the module's own variants is reported at a bare use,
  because sharing a spelling is legal until a bare use. A module reports its
  first problem in source order, so the first such use is the one reported.
- A resource union that breaks several shape rules gets one shape error.

### Layout, equality and recursion

- **Erasure.** A union under rule 8 is erased in specialize, at the type
  level, the way opaque types are erased today. This is Haskell's `newtype`
  and Rust's `#[repr(transparent)]`. Lower, own, verify and emit never see
  it, so no fourth union layout is needed. The C types and layouts of every
  migrated type stay as they are, generic ones such as `Dict[K, V]`
  included.
- **One storage fact.** Check classifies each union once, as
  `StoredAsPayload | StoredByValue | StoredOnHeap`, replacing the
  `contains_itself: Bool`. That is one fact with one producer
  (`blorp/AGENTS.md` principle 1).
  - **The walk.** The `StoredAsPayload` walk follows every path: type
    arguments (phantom ones included), records, `List`s and callables. So a
    rose tree (`union Tree: Node(List[Tree])`) is not erased. It is today's
    `validate_opaque_representation`, changed from rejecting to classifying.
  - **It is conservative.** It can decline to erase a union that would be
    safe to erase, but it never erases one that is not. The README says so.
- **Equality.** It is the derived union equality: a union is `Equatable` when
  its payloads are, and no type loses equality. A single-variant union keeps
  today's template, which already drops the tag test. Under erasure its arm
  binds the payload to the scrutinee itself, a shape no program produced
  before; landing 2's spike showed lower, own and verify accept it, clean
  under sanitizers and the strict leak check. A managed payload is retained
  and released once per side per comparison. Opaque types' separate representation equality
  (`RepresentationBody`) goes. A type that relied on it gets an
  `equality for X` C function where the C used to call the payload's equality
  directly.
- **Unreachable tests.** A `TestVariant` on an erased union cannot arise. A
  domain with one head compiles without a test, and derived equality
  handles the single variant.
- **`fixed`.** An identity type held by a `fixed record` field or a `fixed
  union` payload is declared `fixed union TraitId: private Init(Int)`.

### Generic types

```blorp
union Id[T]:
    private Init(Int)

union Dict[K: Hashable, V]:
    private Init(DictContents[K, V])

pure func first_user() -> Id[User]:
    Id.Init(1)                      -- T comes from the expected type
```

A generic union's variant needs an expected type, as `Option.None` does.
`into_opaque` also took arguments from its operand. The review confirmed that
every generic build in `src`, the library and the tests has an expected type.

### Invariants and where each is enforced

Each fact has one enforcement site, and every other phase reads it.

| Invariant | Its one site |
| --- | --- |
| A private variant is named only in its module | Its effective privacy, produced once by `VariantRow` (rule 1) and read by `with_union`, `offer` and check's `resolve_union_variant` |
| Only a module's own variants share a spelling | `enter`, which still reports a conflict when an imported or prelude variant meets another variant of its spelling |
| A bare variant name resolves only when one variant in scope has its spelling | Detection: namespace's `named_value`, which returns every candidate as a `NamedVariants` arm, from a per-module `variants` table that imports and selections read through one reader. Reporting: one check helper, called by the eight sites that can meet a variant and by rule 7's destructuring head |
| No message another module sees names a private variant the user did not write | One query of the union's variants visible from a module, which the four error paths and the exhaustiveness witness ask |
| In one union, variant names are unique and differ from the union's, and a private union's variants carry no `private` | The parser, for one declaration |
| Outside its module, only `_` covers a union's private variants | The pattern domain's hidden head |
| A union is stored one way | `UnionStorage`, classified once in check; specialize publishes each union's erasure from it once, at sealing, so lower, own, verify and emit never see an erased union |
| A resource union has one private variant with one payload, and is never matched | The parser, for its shape, which one declaration decides; check, at `match`, for the rejection |
| A destructuring always matches | Check, which rejects a union with several variants; from landing 7, verify also proves it |

### Not in this change

**A `Resource[T]` type in place of the `resource` qualifier.** This plan
keeps `resource` as a qualifier on the declaration, as decision 1 has it.
Keith raised `Resource[...]` on 2026-11-23 and deferred it to its own
discussion.

**A migration error for `opaque`.** Root `AGENTS.md` rule 14 adds one only
when it helps a first-time user, and no user has written an opaque type.
After landing 6, `opaque`, `into_opaque` and `from_opaque` are ordinary
names.

**Field access through a union in its own module.** `id.owner` reading the
payload record's field directly would make one-field reads one line again. It
is rejected for now: it is implicit behaviour, and the union would act as its
payload in one module and as a sealed type elsewhere. Recorded so that
reviewers do not rediscover it.

## Decisions

Keith settled these on 2026-11-23:

1. **Resource unions.** A resource union has exactly one variant, it is
   private, and it has exactly one payload, so it is always erased. The
   variant is marked `private` in a public union, and is private through
   the union in a private one (rule 4). It is never matched, only
   destructured, and only in its own module:

   ```blorp
   resource union Reader:
       private Init(Int)

   func read_chunk(reader: Reader, limit: Int) -> Result[Bytes, ReadError]:
       Reader.Init(handle) = reader
       native_read(handle, limit)
   ```

   This keeps today's semantics exactly: only the declaring module wraps or
   unwraps a resource. A destructuring binds no alias, because no binding may
   hold a resource. One payload is required because a second payload would
   need a subject alias. Check rejects a `match` on a resource union with its
   own diagnostic. Today `supports_root` accepts any union, and admission
   raises a checker invariant.
2. **Destructuring's scope.** Rule 7 applies to every union with exactly one
   variant, whatever its payload count. Its landing order is set by the
   review (see [Landings](#landings)).

3. **Bare names when unambiguous** (rule 2). Keith wants `Init` usable on its
   own in its module. A bare use resolves where it is unambiguous, and an
   ambiguous one is reported where it is used. Resolution stays in namespace
   and needs no types. It applies to every variant, so `private` changes only
   access. In the 11 modules that hold 50 of the 67 opaque types, such as
   `model.brp` and `ids.brp`, bare uses stay ambiguous and are written
   `UserId.Init`.
4. **Rule 4 stands.** The parser review found that rule 4 conflicted with a
   union-scoped private variant: two private unions in one module could not
   both have an `Init`, and a private resource union needed the mark. Keith
   dropped the rule on that finding, but rule 2 removed the scope, so the
   conflict is gone. In a private union the mark would do nothing, which was
   Keith's concern, so it is an error again:

   ```blorp
   private resource union Writer:
       Init(Int)                    -- private, because Writer is
   ```

5. **Imported and prelude variants keep today's conflict.** Keith chose it
   on 2026-11-23. The rule-2 review had found that, if every variant could
   share a spelling, a conflict would move from its cause to every use:
   - selecting `Foo(None)` makes every `None` in the module an ambiguity
     error;
   - selecting both `ReadError(NotFound)` and `WriteError(NotFound)` is legal,
     but then neither can be used bare.

   So only a module's own variants share a spelling. An imported or prelude
   variant still conflicts with any other variant of its spelling, reported
   once at the import or declaration. `Init` still stands on its own in its
   module, those errors stay at their cause, and it saves about 20 lines.

## Every change, by phase

### Deleted: the opaque machinery (about 1,395 production lines)

| Phase | What goes | ~Lines |
| --- | --- | ---: |
| Lex, syntax | The `opaque`, `into_opaque` and `from_opaque` tokens; `OpaqueWrap` and `OpaqueUnwrap`; `ParsedOpaque` | 24 |
| Parse | `consume_opaque_conversion`, `consume_opaque`, their help texts, dispatch and accumulation | 128 |
| Ids, assemble | `OpaqueId`, `OpaqueRow`, `inventory_opaques`, the opaque tables; `next_nominal` goes from a three-way to a two-way source-order merge | 90 |
| Namespace | `OpaqueHead`, the opaque entries and counter | 18 |
| Check: expressions, inference | The whole inference path for the two conversions: planning, worklist, finishing, freezing and bounds proof | 356 |
| Check: declarations | `checked_opaque`, `stored_type`, the opaque tables and arms. About 70 lines return as the storage walk. | 210 |
| Check: traits, model | Representation equality: `RepresentationBody`, `EqualityRepresentation`, `OpaqueEquality`, `method_body`'s chain loop, `representation_implementation`; `CheckedOpaque`, `OpaqueNominal` | 157 |
| Check: render, errors | Four conversion errors, the representation-recursion error, `UnknownOpaqueType` and the others, plus their wording | 156 |
| Check: smaller files | `prove_opaque` and `prove_declared_bounds` (well_formed); opaque referents (name_uses); representation dependencies (recursion); two opaque tables per body context (callables, bodies, check, constants) | 116 |
| Specialize | The opaque arms, which become the erasure arms for rule-8 unions | 78 |
| Format, LSP | Opaque declaration and conversion printing; the `OpaqueHead` token arm | 62 |

Deleting it also removes:
- 13 fields and 6 parameters that exist only to carry opaque tables, such
  as `ResolutionContext`, which carries two of them;
- about a dozen enum cases whose arms appear across check: `TypeHead`,
  `NominalId`, `TypeParameterOwner`, `NominalRow`, `ImplementedBody`,
  `EqualityMember`, `EqualityOwner`, `CheckedForm`, `ExpectedTypeSite`,
  `ConstraintOrigin`, `PendingBase`, and six error variants;
- one grammar production for declarations, one for expressions, and two
  formatter node kinds.

### Added: what unions gain (about 835 production lines)

| Rule | Where | ~Lines |
| --- | --- | ---: |
| 1. Private flag | The written mark on `ParsedVariant`; the effective privacy on `VariantRow`, read by `CheckedVariant`; the module stored once on `CheckedUnion`; grammar; formatter | 30 |
| 2. Bare names | A per-module `variants` table, `Dict[Int, List[Entry]]`, that variants enter in place of `names`; one reader of a spelling's variants for `enter`, `claimant`, `offer` and the selections; a `NamedVariants` arm of `NamedValue`, and one check helper that eight sites call; the ambiguity error, merged with `UnimportedVariantValue`; the ambiguous qualified name; the namespace docstrings. The rule-2 review's estimate of 150, with a range of 120 to 190, less about 20 for decision 5 | 130 |
| 1, 4, 6. Declaration-local rules | The parser checks the duplicate within one union, the redundant mark and the same-name ban | 35 |
| 3. Outside rejection and exhaustiveness | The access check in `resolve_union_variant`, which covers values and patterns; alias and import rejection; the paths that must not name a private variant (`unknown_value_error`, `UnimportedConstructorPattern` and its help, the `UnionHasNoVariant` help, and the exhaustiveness witness); a hidden head in the pattern domain that only `_` covers | 130 |
| 5. Payload privacy | Private access for a private variant's payload in `resolved_union` | 6 |
| 7. Destructuring, erased unions | `VariantBinding` syntax. Variant binders allow one to N names, unlike the tuple path's two to four, and the parser commits to destructuring once it sees `) =`, as the tuple path does. `ReadPayload`, which generalizes `ProjectOpaque`; the arity and type errors | 140 |
| 7. Destructuring, other single-variant unions | own models a standalone payload read as it models a record-field read: an `OwnedArgument` parent, `Projection`, `borrowed_extents`. verify gets a path that proves the single variant. specialize and lower get a variant field read | 110 |
| 8. Payload layout | The `UnionStorage` classification and any-path walk; specialize's erasure arms, mostly moved from the opaque arms; derived equality from `ReadPayload`s | 195 |
| 9. Resource unions | `UnionKind = OrdinaryUnion \| FixedUnion \| ResourceUnion` replaces `fixed: Bool`; the shape rules and the match rejection; the resource authority re-keyed from opaque rows to unions, through `NominalId` during the transition | 60 |

### Migrated: the opaque types themselves

| Area | Declarations | `into_opaque` | `from_opaque` |
| --- | ---: | ---: | ---: |
| `src` | 61 | 110 | 218 |
| `standard_library` | 6 (2 resources) | 19 | 42 |
| `test` | about 90 lines | 129 | 68 |

- **Declarations** grow from one line to two.
- **Builds** become `X.Init(value)`.
- **Reads become statements.** In `src`, 184 of 218 reads are not already a
  whole binding, so each needs one. That adds about 220 lines with the
  library. The review judged it worth it: no prefix keyword hides its scope,
  no type name repeats, and the binding names an intermediate.
- **Evaluation order.** A read moved out of an argument list must keep its
  place in evaluation order: reads are hoisted in the order the arguments
  evaluate.
- **Hand-written equality.** 29 `implements Equatable` blocks on identity
  types repeated what derived equality already gives. Landing 0, which is
  `EQUALITY_PLAN.md`'s landing 3, deleted them first, for −149 lines. The
  migration neither rewrites them nor reads through them.

### Also changed

These are outside the compiler source:

- **README.** "Opaque and private types" becomes **Private variants**. It
  keeps one line saying that opaque types are gone, before 0.1. It opens
  with the `UserId` example and a complete `main`, then teaches, in order:
  1. A private variant is built, matched and destructured only in its module.
  2. A module's own variants may share a name. A bare name works wherever
     it is unambiguous, and `Union.Variant` always works. A private union's variants are already
     private, so they take no mark.
  3. Other modules use the functions the module exports, and their `match`
     needs `_`.
  4. A union with one variant and one payload has its payload's layout.
  5. Resource unions.
  6. The `Email` example, for mixed variants.

  It links a two-file fixture. "Automatic equality" and the namespace rules
  are updated too.
- **`grammar.ebnf`** (about 16 lines), **`docs/CODE_STYLE.md:20, 72`** (opaque
  type accessors) and **`standard_library/README.md:175, 274, 439, 709`**.
- **The build.** `blorp/Makefile`'s `FORMAT_EXCLUDED` changes with the
  formatter, so landing 6 also runs `test_bootstrap.sh`.
- **Tests.** `test_grammar/test_conformance.brp`, `test_keywords`, the
  formatter's node tests, and `test/driver/driver.brp`, which lists the three
  machinery suites to remove.

### Simplifications this enables

1. **One nominal kind fewer.** After the deletions, `NominalId` has one case
   and collapses into `AggregateId`, and so does `EqualityOwner`. About 20
   two-arm matches become one. This is an optional, mechanical follow-up.
2. **One equality derivation, one bounds proof, one recursion question per
   walk.** These are counted above.
3. **Specialize's `opaques` table.** It stays only because erasure needs the
   checked union. If `SealedUnions` instead publishes the erasure, mapping a
   key to either a union instance or the payload's concrete type, then the 37
   lines that thread it go. That costs about 30 lines at seal time. Decide by
   measurement.

### Where the new design is more complex

- **Variants get a scope table of their own.** One spelling may hold
  several variants, so variants leave the table of one entry per spelling,
  and their ambiguity is reported at a use, not at a declaration. A second `Init` in a module makes that
  module's existing bare uses ambiguous, and each is reported where it is
  used.
- **Exhaustiveness depends on the module.** The same `match` is complete
  inside the declaring module and incomplete outside.
- **Reads become statements,** as counted above.
- **Generic builds need an expected type.**
- **The payload-layout walk must follow every path.** Opaque types never
  needed it, because a recursive representation was simply rejected.
- **Ownership gets a new shape.** A standalone payload read outside a
  selection needs its parent kept alive, which own and verify model for
  record fields today but not for union payloads.

## Line estimate

Production means `src` and `standard_library`, give or take about 150 lines.

| | Deleted | Added | Net |
| --- | ---: | ---: | ---: |
| Opaque machinery | 1,395 | | −1,395 |
| Union features, rules 1-9 | | 836 | +836 |
| Migrated declarations and reads | | 285 | +285 |
| **Production, landings 1 to 7** | | | **about −275** |
| With landing 0, the 29 equality blocks (landed) | 149 | | **about −425** |
| With landing 8, the `NominalId` collapse | ~30 | | **about −455** |

Landing 0 also removes the reads inside those blocks, so landing 4 may add up
to about 50 lines fewer than its estimate.

Tests come out roughly flat, give or take about 300:

- **Removed:** the machinery suites and opaque rejection fixtures, about
  −1,150.
- **Added:** new tests for rules 1-9 and their diagnostics, plus the own and
  verify phase tests for standalone payload reads, about +1,000.
- **Changed:** the migrated uses and the layout fixture review, about +235.

## Landings

The order follows Keith's outline: enable private variants, migrate, then
delete. The seed rotates once.

0. **Landing 0: delete the hand-written identity equality.** This is
   `EQUALITY_PLAN.md`'s landing 3, and that plan owns it. Its condition is
   met: the pinned seed, `blorp-seed-8eb8e16546b3`, carries derived opaque
   equality (`90e3f7753`). It went first, so that the migration has no
   blocks to carry, and landed on 2026-11-23 with 29 blocks, one more than
   counted.
1. **Landing 1: private variants.** Rules 1-6, all their diagnostics, and
   the 34 same-name fixture renames, plus formatter, LSP, README and grammar
   support. Opaque types still work. Under rule 2, variants may share a
   spelling:
   - **Tests.** Today's conflict test, `variants_shared_imports`, stands.
     New tests cover two declared variants sharing a spelling, a declared
     `None` that conflicts with the prelude's, an ambiguous `email.Unchecked`,
     and `hidden.Secret` rejected for an unmarked variant of a private union.
   - **Docs.** It updates the namespace docstrings that state the rule of one
     entry per spelling (`namespace.brp:3-4, 354, 410-412, 1212-1213`) and
     the README's rule (`README.md:579-581`).
   - **Results.** It landed on 2026-11-24 with +651 production lines and
     +1,303 test lines against its parent, `6918684fb`. Of those, 39 and 59
     are blank lines that main's body spacing rule, which landed while it
     was in CI, adds to its code. Without blank lines it is +599 and +1,094,
     the same before and after the merge.
     - **Cost.** `self-compile-cost --rounds 5`, because the three-round run
       read within 0.05% of the instruction ceiling. On the fixed-input row,
       instructions moved −0.03%, allocations +0.014% and peak heap +0.08%,
       and the C was identical. The own-source row rose 1.1% in
       instructions, which is the compiler's own new code.
     - **Rules.** Breaking each of 30 rules and behaviours fails only its own
       tests.
     - **Probes.** About 80 programs found no bugs. Their diagnostic findings
       became the review fixes, the deferred fixes under
       [Ceilings](#ceilings), and the clarification of rule 3's locations.
2. **Landing 2: destructuring, layout and resource unions.** Rules 7, 8 and 9
   go together, because a resource union can be read only by destructuring.
   Rule 7 covers erased unions only.
   - **Layout fixture review.** 52 test files declare a union with one variant
     and one payload, among them the managed-union layout tests built on
     `union Box[T]: Box(T)`. Under rule 8 those become erasure tests without
     saying so. Each gets a second variant, or is kept and labelled as an
     erasure test, and its ceilings are re-measured.
   - **Resources.** The resource authority is keyed on `NominalId`, which
     covers both forms during the transition.
   - **Dict.** The dict literal lookup accepts a union-headed `Dict`, the only
     foundation type found by its head (`traits.brp`'s
     `dict_literal_functions` matches only an opaque head today).
   - **Results.** It landed on 2026-11-24 with +747 production lines and
     +1,872 test lines against `9823919fa`.
     - **Cost.** Fixed-input instructions rose +0.178% by callgrind (Linux
       arm64, deterministic) and +0.18% by `self-compile-cost --rounds 9`.
       Allocations fell 0.021%, peak heap rose 0.001%, and the C was
       identical. The cost is spread: specialize's erasure, where
       `concrete_types` is no longer inlined (+5.4M), the resource walk's
       lookup of each union and record type (+4.1M), parser inlining (+2.0M),
       the destructuring lookahead (+1.7M), opaque types through the shared
       erasure functions (+1.6M), and the narrowed type translation (+4.1M,
       a list drop the base also pays).
     - **The spike.** Lower, own and verify accept a match arm bound to the
       scrutinee itself, so derived equality keeps its singleton template.
     - **Review and probes.** The review found no blockers, and its fixes are
       in. 75 probes found no miscompiles or leaks. The one verifier failure
       they found predates this plan and has its own session.

   No union in `src` or the library has one variant with one payload, so the
   fixed-input C stays byte-identical through landings 1 and 2.
3. **Landing 3: rotate the seed.** It must carry rules 1, 2, 5, 7 (erased) and 9, the
   union-headed `Dict`, and rule 8.
   - **Rule 5:** about 28 of the opaque types sit over private types, so
     without it the migrated `src` and `dict.brp` cannot build.
   - **Rule 8:** without it every identity type is a tagged struct in the
     candidate, which shows as a cost regression that is not real.

   The rotation is judged by the `-O2` self-compile and the small compiles
   (`AUDIT_CLEANUP_PLAN.md`, change 6). If e2e instruction ceilings fail only
   through the rotation, the landing stops for Keith, as on 2026-11-18.
   - **Results.** It landed on 2026-11-25. It pins `blorp-seed-aad181bcdc73`,
     built from landing 2's commit.
     - **Cost.** It was a plain rotation. `self-compile-cost b366e2a17
       7776ec62f --rounds 9` showed the fixed-input allocations and peak heap
       unchanged, instructions −0.04%, and the C identical.
     - **Ceilings.** No e2e ceiling moved.
     - **Gates.** The fixpoint proof and `test_bootstrap.sh` passed, and so
       did the dispatched Seed job on all three targets (run 45671313877).
       The first gate run failed only the intermittent `fs fold_lines` case,
       which also failed on main's CI (run 45136016643) and has its own
       session. A rerun of the e2e suite, `make -C blorp test-e2e
       INSTRUCTION_CHECK=on`, passed.
4. **Landing 4: migrate.** This covers `src`, the library, and the tests that use opaque
   types, as opposed to those that test them, area by area. The oracle:
   - **The fixed-input row's C is identical,** since it compiles the base's
     source.
   - **The own-source C is identical,** apart from the derived-equality
     functions each commit names. It is compared with a diff that ignores
     `blorp_f_N` numbering, since one new function renumbers every later
     one.
   - **Equality functions.** The functions that differ belong to types that
     used derived opaque equality, which after landing 0 includes the 29
     identity types. Each commit lists them.
5. **Landing 5: delete the conversions.** The two keywords, their syntax, the formatter's
   printing of them, the inference path and the errors (about 480 lines).
   Conversions refer to declarations, so they go first.
6. **Landing 6: delete the declarations.** This also runs `test_bootstrap.sh`, because
   `FORMAT_EXCLUDED` changes. It removes about 800 lines:
   - `ParsedOpaque` and the `opaque` keyword;
   - the ids, heads and tables;
   - representation equality and recursion;
   - the name uses and rendering;
   - specialize's opaque arms;
   - the formatter's declaration printing.

   The resource authority narrows from `NominalId` to unions. `resource type`
   goes with the production, so `resource union` must already be in use
   everywhere.
7. **Landing 7: destructuring of the other single-variant unions** (decision 2). This
   covers multi-payload unions, and single-payload unions that cannot be
   erased. own models a standalone payload read the way it models a
   record-field read, verify proves the single variant, and both get phase
   tests. Nothing before needs it, so it can land any time after landing 2.
   It waits until the migration is done, to keep the critical path short.
8. **Landing 8, optional: the `NominalId` collapse,** as a mechanical rename.

No second rotation is needed. The seed still accepts opaque types, and after
landing 4 no source uses them.

**Costs.** See [Ceilings](#ceilings).

**Other traps.**
- **Bootstrap subset.** Compiler source starts using private variants,
  destructuring and `resource union` in landing 4, so each brief names that
  extension.
- **`fixed` identity types.** An identity type in a `fixed record` field or a
  `fixed union` payload must be migrated as a `fixed union`, or
  `fixed_storage` rejects it, correctly but surprisingly.

## Ceilings

Upper bounds, measured with `blorp/scripts/self-compile-cost PARENT CANDIDATE
--rounds 3` against each landing's parent:

- **The cost ceilings bind the fixed-input row,** where both compilers compile
  the parent's source. The own-source row is reported but not held, as in
  `IMPURE_TRAIT_METHODS_PLAN.md`.
- **The line ceilings are net production and test lines.** They come from the
  survey's estimates, not from compiled code, so exceeding one stops the
  landing for a growth audit (root `AGENTS.md`).
- **Corrections.** The coordinator makes routine ones and records each here,
  with the old and new figures and the reason. Anything larger is Keith's.

| Landing | Instructions | Allocations | Peak heap | Production lines | Test lines |
| --- | --- | --- | --- | --- | --- |
| 0 | `EQUALITY_PLAN.md`, landing 3 | | | | |
| 1 | +0.1% | +0.05% | +0.1% | +655 | +1,310 |
| 2 | +0.18% | +0.1% | +0.1% | +750 | +1,900 |
| 3 | reported | reported | reported | 0 | 0 |
| 4 | +0.1% | +0.01% | +0.1% | +320 | +230 |
| 5 | +0.05% | +0.0% | +0.05% | −380 | 0 |
| 6 | +0.05% | +0.0% | +0.05% | −640 | 0 |
| 7 | +0.1% | +0.05% | +0.1% | +140 | +320 |
| 8 | +0.05% | +0.0% | +0.05% | −20 | 0 |

**The stack.** Landings 1 to 7 no longer promise to shrink the compiler or
to leave it the same size: Keith dropped the promise of 0 or fewer on
2026-11-24, when he accepted landing 2 at about +680. After landing 2 the
estimate is about +400: landing 1's +651, landing 2's +747, landings 4 and 7
at +395 by their estimates, and landings 5 and 6 removing about −1,395 if
landing 6 reaches its −915. Additions have run 1.5 to 2.6 times their
estimates, and the deferred fixes below count against it.
The estimates predate main's body spacing rule, which lengthens the code
landings 5 and 6 delete as well as the code the others add, so landing 5
re-surveys them before it starts.

**Corrections.** On 2026-11-23, before implementation, the rule-2 review
re-estimated rule 2 at about 150 lines, not 45. The coordinator raised
landing 1's production ceiling from +300 to +420 and its test ceiling from
+500 to +550, and moved the stack's from −225 to −130. After decision 5
saved about 20 lines, it moved the stack's from −130 to −150. The per-landing
ceilings carry margins that would add up to growth, so this one keeps the
promise.

Landing 1 then stopped at its ceiling with +566 production lines. Rule 2's
shared spellings came to about 220 lines (estimate 130), and rule 3's
messages to about 240 (estimate 130). The later corrections:
- **Keith accepted +566 as is** on 2026-11-23, with no wording cuts. The
  coordinator set landing 1's production ceiling to +580, a margin of 14
  for review fixes.
- **The test ceiling** went from +550 to +700, a routine correction for
  necessary test growth: a test per diagnostics row and the completion tests.
- **The rebase onto `f9423ade5`,** which added LSP completion, needed the
  three completion functions adapted to the `variants` table. The
  coordinator raised the production ceiling to +600, a routine correction for
  integrating with a concurrent landing.
- **The stack's ceiling** moved from −150 to 0 when Keith accepted +566. It
  no longer promises a line reduction, only no growth.
- **The review fixes** reached about +747 as first written. The coordinator
  deferred three help refinements of its own (below) and dropped a fourth
  that needed a data-model change, then raised the production ceiling from
  +600 to +615 for the fixes the review asked for: one error for an outside
  `match` missing public and private variants, one reader of the value
  space, a dead field, two helps, docstrings and the parser's mark.
- **The test ceiling** went from +700 to +1,250 (measured +1,244), a
  routine correction for necessary test growth under the root `AGENTS.md`.
  The review asked for the tests the implementer had compressed to fit the
  ceiling to be restored: aligned multiline programs, one behaviour per test,
  the completion test split in four, and the dropped parser and payload
  tests back. The two new suites, one test per diagnostics row and per scope
  case, are 788 of the lines.
- **Main's body spacing rule** (`ddb348dd5`) and its reformat of the tree
  landed while landing 1 was in CI. The merge added 39 blank production
  lines and 59 blank test lines to landing 1's code, and no other line. The
  coordinator raised the production ceiling from +615 to +655 and the test
  ceiling from +1,250 to +1,310, a routine correction for integrating with
  a concurrent landing.

**Landing 2, before implementation.** On 2026-11-24 the coordinator raised
landing 2's test ceiling from +450 to +900, a routine correction from
landing 1's measurement: its tests came to 2.4 times their estimate, with one
test per diagnostics row and per behaviour, aligned multiline programs, and
the body spacing rule. The production ceiling stays at +480, which stops the
landing for a growth audit. The coordinator also moved the resource shape
rule from check to the parser, which has every fact it needs, as rules 4 and
6 are there.

**Landing 2, after its growth audit.** Rules 7 and 8 came to +550 production
lines, after cuts of about 45 and a cost fix of 21, so destructuring ran
about +365 against its estimate of 140. With rule 9 and the `Dict` head, about
+113, the landing projects about +660. On 2026-11-24 Keith accepted about
+680, and dropped the stack's promise (above). The later corrections:
- **+690 and +700,** routine: the first for an index of erased unions, which
  removed a cost regression, and the second for the review fixes as
  estimated.
- **Keith accepted about +735** when the review fixes came to +58, not about
  13. The coordinator then set +740 for the reviewer's short
  `declares_resources` and +750 for the two cost simplifications below, both
  routine.
- **The test ceiling** went from +900 to +1,900 (measured +1,872), a routine
  correction for necessary test growth: four new suites of 869 lines, the
  rule 9 and `Dict` tests, and the fixture review.
- **The instruction ceiling** went from +0.15% to +0.18%.
  - Callgrind showed the regression was real, at +0.175%, and that about 80%
    of it was already in rules 7 and 8, whose macOS reading had been noise.
  - Keith chose to apply two simplifications first and correct only by what
    remained. Specialize now publishes each union's erasure once (−2.4M), and
    `declared_resource` is one direct match (−1.3M). Together they brought
    it to +0.144%.
  - Narrowing the type translation's parameters back to `opaques`
    (CODE_STYLE rule 1) then cost +4.1M, through a list drop the base pays
    too. The coordinator kept it, because the root `AGENTS.md` does not bend
    a design to a cost the compiler imposes. The remaining +0.18% is the
    correction.

**Deferred review fixes.** These refine landing 1's and landing 2's helps,
which match the plan's table as they stand, and add one missing form. They
are one follow-up with its own ceiling of +140, counted against the stack:

- **A private variant in an outside pattern** (`Email.Checked(_)`) gets
  "cover it with _, which matches the variants private to ./email" instead
  of the build help. About +35.
- **A public spelling several unions share, through an alias**
  (`mail.Unchecked`) gets "write Email.Unchecked or Letter.Unchecked",
  instead of help that repeats the selection. About +50.
- **A private spelling several unions share** (`mail.Init`) gets the generic
  "use the functions ./email exports" instead of naming the first union.
  About +25.
- **A private variant destructured from another module** gets the build
  help, where it should say to read the value through the functions the
  module exports. About +10, beside the pattern help above.
- **Destructuring through an import alias** (`ids.Len(v) = m`) has no
  accepted form, and gets the generic value-line error. Construction and
  patterns accept `alias.Variant`, so destructuring should too. About +20.

A fourth, dropped: the namespace would carry whether a variant is private by
its mark or through its union, so render need not read `UnionRow.visibility`.
That is a data-model change, and the wording it buys is the same.

The estimates behind the line ceilings:

- **Landing 1:** +330, for rules 1, 2, 3 and 5 and the declaration-local
  rules; rule 2 alone is about 130. Tests, about +450: the 34 renames, one
  test per diagnostics row for rules 1 to 6, and the new scope cases. Its cost is a privacy read per variant resolution, the
  spellings that hold several variants, and the hidden head in an outside
  `match`.
- **Landing 2:** +395: rule 7 for erased unions 140, rule 8 195, rule 9 60.
  The opaque arms stay until landing 6, so the erasure arms are new code
  here. Tests, about +350, with the 52-file layout review. Its cost is the
  storage walk, once per union.
- **Landing 4:** +285, for 66 declarations one line longer and 219 reads that
  become bindings, less what landing 0 removes. Tests, about +180. Its C
  oracle leaves only the equality functions to cost anything.
- **Landings 5 and 6:** −480 and −800. The survey's machinery total is about
  115 lines more than their sum, so landing 6 may reach about −915. Each
  ceiling asks for 80% of its estimate. No source uses opaque types after
  landing 4, so their fixed-input C is identical.
- **Landing 7:** +110. Tests, about +250: the own and verify phase tests for a
  standalone payload read.
- **Landing 8:** −30.

**Stress fixtures.** Allocation counts are deterministic, so they catch a
disabled fast path that behaviour tests miss. Two e2e fixtures get ceilings
of their measured cost plus 15%:

- **Landing 1:** a module of 64 unions with private variants, matched from
  another module, for the access check and the hidden head.
- **Landing 2:** 200 independent erased unions, for the storage walk and the
  erasure index. Doubling them must no more than double their allocations.

  The plan first asked for a chain of 200 unions, each over the next. Erasure
  makes a chain's compile allocations superlinear in its depth: 1.03M at 200
  and 3.53M at 400, against 305k at 200 before erasure. Specialize expands the
  chain again each time one of its types is made concrete. Opaque types already
  behave this way, at 2.8 times for double the depth, and real types nest two
  or three deep, so the self-compile is flat. On 2026-11-24 Keith accepted
  parity with opaque types for now. Memoized erasure is a follow-up, best after
  landing 6, where it can replace the `opaques` threading
  ([Simplifications](#simplifications-this-enables), item 3): the sealed
  tables publish each erased key's concrete type, and storage is classified
  by cycles in the declaration graph. It is about +60 to +90 lines.

**Cost follow-ups from landing 2.** Its callgrind attribution named these.
Each needs its own measurement:
- **Cache translated types** per type and substitution in specialize, with
  memoized erasure.
- **Memoize the resource walk** per type in check, or have the declarations
  publish which types are resources.
- **Emit compiled functions as `static`,** so the C compiler can inline small
  accessors such as `union_number`, `List.get` and the `from_opaque`
  readers. This is compiler-wide.
- **Inline the fast path of list drops,** which the narrowed type translation
  pays on every call.
- **Add a callgrind mode to `self-compile-cost`.** On macOS, nine rounds
  spread by 14M to 30M per side and cannot resolve a 0.1% change. Callgrind
  in the Linux Docker image is deterministic, at about 6 minutes per side.
- **Repair `blorp/scripts/attribution/run`.** Its markers stage patches an
  anchor in `emit.brp` that no longer exists.

## Review, probes and gates

Each landing gets these (root `AGENTS.md`, rule 12):

- **A code review** by a reviewer who did not review the plan, with an
  explicit verdict on simplicity.
- **A test-runner run** of the gates on the final commit.
- **An adversarial probe pass** for landings 1, 2 and 7, which change
  behaviour. The probes are small programs that combine the new forms with
  generics, closures, `List` and `Dict` payloads, `fixed` types, resources,
  and imports through aliases. They run through C with sanitizers and
  `BLORP_LEAK_CHECK=strict`.

The gates follow `blorp/AGENTS.md` ("Which gates a change runs"):

- `make -C blorp test INSTRUCTION_CHECK=on` for every landing;
- a dispatched Seed job for every landing that touches `blorp/src` or the
  library;
- all three gates for landing 3;
- `test_bootstrap.sh` for landing 6, which changes `blorp/Makefile`.

## Acceptance criteria

- [x] **Landing 0:** as `EQUALITY_PLAN.md`, landing 3.
- [x] **Landing 1:**
  - the `UserId` and `Email` examples compile and run;
  - every diagnostics row for rules 1 to 6 has a test of its message, help
    and span, which fails when its rule is removed;
  - another module's `hidden.Secret`, an unmarked variant of a private
    union, is rejected;
  - in a module where two unions have an `Init`, a bare use reports the
    ambiguity, and `UserId.Init` resolves;
  - the fixed-input C is byte-identical;
  - the ceilings hold, and the gates pass.
- [x] **Landing 2:**
  - a `resource union` fixture reads its handle by destructuring;
  - a union-headed `Dict` literal compiles;
  - each of the 52 layout fixtures has a second variant, or is labelled an
    erasure test;
  - the rows for rules 7 to 9 are tested as in landing 1;
  - the stress fixture's allocations grow no worse than linearly;
  - the fixed-input C is byte-identical;
  - the ceilings hold, and the gates pass.
- [x] **Landing 3:**
  - `bootstrap.env` pins a seed built from landing 2;
  - all three gates and the Seed job pass.
- [ ] **Landing 4:**
  - `grep -rn -E 'into_opaque|from_opaque|opaque type|resource type'
    blorp/src blorp/standard_library` finds nothing;
  - the fixed-input C is byte-identical;
  - the own-source C differs only in the equality functions each commit
    lists, under a diff that ignores `blorp_f_N`;
  - the ceilings hold, and the gates pass.
- [ ] **Landing 5:**
  - `grep -rn -E 'into_opaque|from_opaque|OpaqueWrap|OpaqueUnwrap|ConstructOpaque|ProjectOpaque'
    blorp/src blorp/test` finds nothing;
  - the ceilings hold, and the gates pass.
- [ ] **Landing 6:**
  - `grep -rn -i opaque blorp/src blorp/standard_library blorp/grammar.ebnf`
    finds nothing;
  - the README keeps one line saying that opaque types are gone;
  - the ceilings hold, and the gates pass, `test_bootstrap.sh` among them.
- [ ] **Landing 7:**
  - a union with two payloads, and a single-payload union that cannot be
    erased, destructure;
  - the own and verify phase tests cover the standalone payload read;
  - the probes run clean under sanitizers and the strict leak check;
  - the ceilings hold, and the gates pass.
- [ ] **Landing 8:**
  - `NominalId` is gone;
  - the fixed-input C is byte-identical.

## Handback

Each landing returns:

- its commit and gate logs;
- the `self-compile-cost` table and the C identity evidence;
- its production and test lines against the ceilings.

Stop and ask when:

- a ceiling fails beyond a routine correction;
- an oracle fails;
- a rule turns out to need a second enforcement site.

## Reviews

**Parser and soundness review (Opus): sound with the listed changes.**

Its two blockers, now resolved:
- **Rule 5 was missing from the seed list.** It admits programs as well as
  rejecting them. It is now in landing 3.
- **Rule 7 on an unerased union reads a payload outside a selection.** own and
  verify do not support that today (`own.brp:134, 896-901, 1644`;
  `verify.brp:1918-2085`). It is now landing 7, with real ownership modelling
  and phase tests.

Its other findings, folded in:
- the resource match rejection and the one-payload rule;
- the access checks in three error paths;
- the module stored once;
- the missing diagnostics;
- splitting the first landing in two;
- the parser approach to destructuring;
- equality from `ReadPayload`s;
- the oracle details;
- one home for declaration-local rules;
- the inventory additions.

It confirmed:
- `TestVariant` is unreachable on an erased union;
- the hidden head is sound;
- every generic build has an expected type;
- `Dict` is the only head-found foundation type;
- the walk is sound;
- the resource rules can be re-keyed;
- the deletion order is right;
- no type loses equality.

Its finding on rule 4 is answered by decisions 3 and 4.

**Ergonomics review (Sonnet): good with the listed changes.** Folded in:
- the diagnostic wordings, including a concrete example function and the
  "did you mean" form, which rule 2's ambiguity message has since replaced;
- the README outline;
- the rule-6 help that says why;
- `Init` as a stated convention;
- the generic and resource diagnostics;
- the field-access idea recorded as rejected for now.

It judged the extra line per read worth it, on real sites in `ids.brp`,
`names.brp`, `line_map.brp` and `dict.brp`.

**Rule-2 review (Opus): sound with the listed changes.** Rule 2 changed
after both reviews, so it was reviewed alone. Folded in:
- **Its blocker.** A variant's effective privacy had no producer, so an
  unmarked variant of a private union would have been offered to other
  modules. `VariantRow` now produces it (rule 1).
- **Where rule 2 is enforced.** Detection is in `named_value`, reporting in
  one check helper, and the candidates live in a per-module `variants` table.
- **New cases.** The ambiguous `email.Unchecked`, and the exhaustiveness
  witness as a fourth path that could name a private variant.
- **Wording.**
  - "variant in scope", not "union in scope";
  - the existing `UnimportedVariantValue` message;
  - a resource help that follows the union's visibility.
- **The estimate.** Rule 2 is about 150 lines, not 45.

It confirmed:
- a pattern's name is classified by its spelling before any lookup, so a
  variant cannot become a binding;
- no desugaring refers to a prelude variant by spelling;
- the parser can enforce rule 4.

Keith settled its question about where conflicts are reported as decision 5.

## How we got here

The same discussion considered and dropped these designs:

| Design | Why it was dropped |
| --- | --- |
| Keep the keyword form, and require parentheses before a postfix | It adds noise, and the redundant name stays. |
| `from_opaque(x)` and `into_opaque(x)` as calls, typed by operand and expected type | Building took its type from context, which is ambiguous with several opaque types in a module (Keith). |
| An `Opaque[Repr]` container, and `conceal`/`reveal` or `as_opaque`/`as_underlying` | `as_underlying` could not be an ordinary function: no signature fits, and the prelude rule misses library modules. It became a reserved word, and the marker types read as aliases. |
| A private variant always written through its union, as `UserId.Init` | Keith wanted `Init` usable on its own in its module. |
| A bare variant resolved by its expected type | A reader would need the types to know which `Init` is meant, and resolution would move into check. |
| `UserId(position)`: the type's own name as the constructor | Keith found it weird, and preferred a named variant, `UserId.Init`. |
| A variant sharing its union's name | Same reason, and in a multi-variant union it reads as "any value of the type". |
| Opaque types as their representation inside the module, as in Scala 3 | The seven `Int` ids in `ids.brp` would mix inside the one module whose job is to keep them apart. |
| Public generic conversions | Any module could forge or open any opaque type, including `Reader` and `Writer`. |

Elm showed the way. An opaque type there is a custom type whose constructor
the module does not export. That needs no special machinery, and the same
mechanism gives any union constructors that only its module can use.
