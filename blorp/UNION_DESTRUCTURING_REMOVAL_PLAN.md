# Union destructuring removal plan

**Status: approved, 2026-11-26.** Keith asked for this plan on 2026-11-26 and
accepted its three decisions the same day ("Accept all three"). Each landing
waits for his word.

**The direction.** On 2026-11-26 Keith compared an accessor written both
ways, after the help fixes landed:

```blorp
ModuleStem.Init(text) = stem
text
```

```blorp
match id:
    ModuleStem.Init(text):
       text
```

He said the second "is what we already had available, and I think it's
clearer", and chose "Plan the removal" over a style rule that would keep both
forms.

The rule this plan reaches is that **a union is read only with `match`.**

- **Tuple destructuring stays.** `(left, right) = pair` has no variant to
  name.
- **This reverses `PRIVATE_VARIANTS_PLAN.md`'s:**
  - rule 7;
  - decision 2;
  - the destructuring half of decision 1;
  - landing 7;
  - the alias destructuring of its help follow-up (`5f52dc9c6`).

## What the language loses and keeps

On `34008c1cf`, 204 lines destructure a union: 162 in `blorp/src` and 42 in
`blorp/standard_library`. Each binds exactly one payload of a one-variant,
one-payload union, so every one of these unions is erased (rule 8).

**157 end the body: they become a `match`.**

- 31 return the binder.
- 89 end with a one-line expression.
- 37 end with a multi-line one.

For example:

```blorp
-- blorp/src/common/syntax/source.brp:115, today
pure func stem_text(stem: ModuleStem) -> String:
    ModuleStem.Init(text) = stem
    text

-- after
pure func stem_text(stem: ModuleStem) -> String:
    match stem:
        ModuleStem.Init(text): text
```

**47 keep going after the payload.** They bind it with a `match` expression,
one line longer than today. `Dict.set` (`blorp/standard_library/dict.brp:263`)
is one:

```blorp
-- today
pure func set[K: Hashable, V](self: Dict[K, V], key: K, value: V) -> Dict[K, V]:
    Dict.Init(contents) = self
    slot = contents.probe(key)
    ...

-- after
pure func set[K: Hashable, V](self: Dict[K, V], key: K, value: V) -> Dict[K, V]:
    contents = match self:
        Dict.Init(contents): contents
    slot = contents.probe(key)
    ...
```

The arm's binder may reuse the bound name: the outer `contents` comes into
scope only after the `match`, so nothing is shadowed. This compiles today,
and works as a `concurrent:` task.

**Rejected: nesting the rest of the body inside the arm.** It moves up to 40
lines one level right in `Dict` and `io/files`, and puts a statement body in
an arm, where every other arm in the source is short.

Some functions destructure twice in a row (`bytes.brp:64`, `:83`, `:91`;
`path.brp`'s left and right). They nest two matches or bind twice, so they
cost more lines than the rest.

**Three sites are resources:**

- `Reader.Init(handle) = reader`, twice in `io/files/read.brp`;
- `Writer.Init(handle) = writer`, once in `io/files/write.brp`.

Today a resource union cannot be matched at all (`MatchedResource`,
`bodies.brp:296`), so this plan must open one form for them (rule 2).

## Rules

1. **A union is read with `match`.** The parser rejects:

   - `Variant(binders) = value`;
   - `Union.Variant(binders) = value`;
   - `alias.Variant(binders) = value`;
   - each of those with `?=` (`parse.brp:4246`).

   `at_variant_binding` already finds the shape, so the lookahead stays and
   feeds the rejection. Someone coming from Rust or Elm will write exactly
   this line, so the error teaches the replacement (principle 7).

   | Case | Message | Help |
   | --- | --- | --- |
   | value is a plain name: `Pair.Init(left, right) = pair` | `a union is read with match, not destructured` | `use match pair: with an arm such as Pair.Init(left, right): on the next line` |
   | any other value | the same | `use match with an arm such as Pair.Init(left, right): on the next line` |

   The help never suggests a one-line `match`, which the parser rejects, and
   never repeats a long initializer. It says "an arm such as", because the
   variant may have siblings: `Some(x) = maybe` needs a `None` arm too, and
   the exhaustiveness check names it.

2. **A resource union is matched only in its declaring module.**

   - **In that module,** the `match` is accepted. It binds the handle as
     destructuring does today. Its subject is the scrutinee itself:
     `start_match` stores the scrutinee as a `CheckedExpr` and makes no
     binding (`bodies.brp:279-305`). So no binding holds a resource.
   - **Elsewhere,** it is rejected as today, with the help `use the functions
     ${module} exports`.
   - **Arms:** the union has one variant, but literal patterns on the handle
     may add arms. They are allowed, as any `match` allows them.
   - **Decision 1 holds.** Its "only the declaring module wraps or unwraps a
     resource" is unchanged.

3. **Nothing else changes.**

   - Erased layout, the private-variant rules (1 to 6) and bare names stay.
   - Of the help fixes' uses, `Built` and `Matched` stay. `Destructured`
     goes, with its read help.

## Cost

**Every arm binder is retained when its arm is entered** (`own.brp:2358`):
"Only newly acquired occurrences cross the successful edge". Destructuring
an erased union retains nothing, because `ReadPayload` of an erased payload
is the root itself. The reviewer's probes show both:

```c
/* size_destructured: Stem.Init(text) = stem; text.length() */
int64_t blorp_f_1(struct blorp_string* blorp_p_0){ ... blorp_f_9(blorp_vl_0) ... return blorp_vl_1;}

/* size_matched: match stem: Stem.Init(text): text.length() */
int64_t blorp_f_4(struct blorp_string* blorp_p_0){ ... blorp_string_retain(blorp_vl_0) ... blorp_f_9(blorp_vl_2) ... blorp_string_release ... }
```

So moving to `match` pays a retain and a release at every site, unless the
binder is returned (31 sites), and this holds in the arm form and the binding
form alike. `Some(x):` arms in the compiler pay the same today.

**The self-compile spike.** `spike/destructuring-as-match` (`fea5918e4`,
never lands) rewrote the 201 non-resource sites into the binding form.
Against `34008c1cf`:

| Metric | `34008c1cf` | spike | Change |
| --- | ---: | ---: | ---: |
| fixed-input allocations | 13,507,896 | 13,507,896 | +0.0000% |
| fixed-input peak heap, bytes | 192,302,629 | 192,302,629 | +0.0000% |
| fixed-input instructions, median of 5 | 13,747,803,217 | 13,838,754,494 | **+0.6616%** |
| own-source allocations | 13,507,896 | 13,583,805 | +0.5620% |
| own-source instructions, median of 5 | 13,744,791,691 | 13,886,558,021 | +1.0314% |

- **The C is the same.** Fixed-input C is identical, so the compiler's
  behaviour is unchanged.
- **Where the +0.66% comes from.** The migrated compiler runs its own
  `match`es, paying the same allocations plus the arm-entry retains.
  `Dict`'s methods, on the hot path, dominate.
- **Landing 4 would pay about the same in the arm form.** For scale, landing
  2's +0.18% needed Keith's acceptance.

The raw output is in `build/destructuring-removal/spike-cost.log`.

**Removing the cost first.**

- **The rule in root `AGENTS.md`.** It does not let a design bend around a
  cost the compiler imposes, and it does not accept a significant instruction
  regression because the language got simpler. So landing 2 removes the cost
  in the compiler first.
- **Why lower can do it.** A one-variant `match` has a selection with no test:
  its entry node is `EnterArm`, which is an explicit property of the
  selection, not of its source shape. Such a selection always enters its one
  arm.
- **The fix.** Lower compiles it as straight-line code: the arm's inputs are
  its arguments, and its statements and value join the enclosing block.
- **The result for an erased union.** Specialize maps the payload place to
  the root (`specialize.brp:5877`), and lower makes the input the scrutinee
  value (`lower.brp:1918`). The flattened block is then destructuring's exact
  IR, with no new form in own or verify.
- **Precedent.** OCaml compiles a one-constructor match to field reads, and
  Lean 4 turns a single-constructor `cases` into projections.
- **Why it must reach the seed.** The compiler binary is the seed's output
  (`Makefile:66`), so the compiler's own code gets the flattening only after
  a rotation.

## Landings

1. **Landing 1: a resource union matched in its module** (rule 2).
   - **Check:**
     - `bodies.brp:296` rejects a resource scrutinee only outside its
       declaring module.
     - `admit_match_root` (`resource_scopes.brp:404-414`) raises the checker
       invariant `LoanInMatchRoot` for any root that mentions a resource. It
       must admit the in-module `match`, or relaxing `bodies.brp:296` turns a
       user error into exit 4.
     - Update the comment at `resource_scopes.brp:400` and
       `PRIVATE_VARIANTS_PLAN.md`'s invariant rows with it.
   - **No rotation needed.** Library bodies are checked only when reached
     (`model.brp:1196`, `bodies.brp:3320`). `src` reaches `read_text`
     (`load.brp:5`) and `write_text` (`compile_command.brp:6`), neither of
     which touches `Reader` or `Writer`. The reviewer compiled `src/main.brp`
     and `embed_library.brp` with today's compiler, which rejects resource
     matches as the seed does, against a library whose `read_chunk`,
     `fold_reader` and `write_all` use `match`. Both exited 0.
   - **Tests:**
     - an in-module `match` that binds the handle;
     - one with a literal arm;
     - an `implements` method that matches `self`, after
       `resources/token.brp`;
     - an outside `match`, rejected with the new help;
     - a test that reads a file through a matched `Reader`.
   - **Estimate:** +30 production, +100 tests. **Ceiling:** +45 production,
     +150 tests. Fixed-input C identical.
   - **Results (`ac72cd96a`, base `4f9260e16`):**
     - `self-compile-cost`: fixed-input C identical; fixed-input allocations
       13,507,896 and peak heap 192,303,197 bytes unchanged; fixed-input
       instructions -0.0504%.
     - Production +71/-19 (net +52); tests +136/-8 (net +128, ceiling
       +150). Production ceiling +45 -> +55, routine (coordinator): one check
       function and one render function for the outside-module error. The
       error carries a `UnionId`; check narrows the `AggregateId` once and
       keeps one invariant for a record, which is never a resource.
     - Lower, own, verify and emit needed no change. The C of an in-module
       `match` is a selection on the handle, where destructuring is a copy.
2. **Landing 2: lower flattens a selection with no test.**
   - **Scope:** erased unions first. Flattening a non-erased union puts a
     `PayloadValue` in a block.
     - Own borrows a `PayloadValue` unconditionally (`own.brp:896`).
     - `borrowed_extents` follows only record fields (`own.brp:1718`).
     - So flattening a non-erased union is unsound until own's `Projection`
       plan covers `PayloadValue`.

     Either limit flattening to selections whose inputs are the scrutinee
     itself, or extend `Projection` in the same landing. The spike decides
     which.
   - **Handle:** carried vars and a tail `RecurWith` in the flattened arm.
   - **Spike first, one to two hours, in a scratch branch.**
     - Flatten `size_matched`, `text_of` and `size_of` from
       `build/destructuring-removal/spike/` and the reviewer's p1 probes.
     - Decide between the two scopes above.
     - Set this landing's line ceiling from the spike.
     - Stop and report if flattening needs own to learn a new output kind.
   - **Oracle:**
     - The `match` forms of those probes emit the destructured bodies' C,
       identical apart from the numbering of C temporaries.
     - Fixed-input allocations are identical. Fixed-input C may differ only
       in flattened selections.
     - A uniquely owned `Dict.set` still updates in place.
   - **Pre-rotation measurements.** `self-compile-cost` builds both sides with
     the seed, so it cannot show this landing's effect. Build every compiler
     below by itself (stage 2) and give each the same fixed input.
     - **The stop condition** mirrors landing 4's real base. Build landing 2's
       source, and landing 2 plus a landing-4-shaped migration from the spike
       branch, both with landing 2's compiler. The migration's instructions
       must be within +0.10%, or stop before rotating.
     - **This landing's own cost, reported separately:** landing 2 against its
       base, both built by themselves.
   - **Tests:**
     - lower tests for flattening;
     - own and verify tests for the flattened bindings;
     - memory tests under `BLORP_LEAK_CHECK=strict`, as `b8b198dde` added for
       borrowed projections (83 production and 707 test lines).
   - **Estimate:** +60 to +120 production, +300 to +600 tests. The ceiling is
     set from the spike before implementation.
   - **Ceilings:** +125 / +700, coordinator, set from the spike (+106
     measured in the draft). Tests +700 -> +860, routine (coordinator):
     independent verifier tests.
   - **Model:** use Opus. This is the plan's subtle ownership work.
   - **Spike (`spike/flatten-selection`, never lands):** scope (a). Every one
     of the 204 sites is an erased union; scope (b) flattens only 2 more
     selections in `src` and needs a new verify rule, so it is a follow-up
     (below). `lower_match` serves only `@tail_recursive` functions, whose
     final one-arm match must be the self call and never ends, so it keeps
     its selection.
   - **Results (`4fb81b64f..`, measured at `fa50eb082`):**
     - Lower only. Own, verify and emit need no change: a straight-line arm's
       inputs are the scrutinee's own value, which is destructuring's IR.
       Lower checks the arm's input count, which verify checks on an edge.
     - Patterns that bind nothing flatten too: `_`, `(_, _)`, `Unit.Only` and
       all-wildcard patterns on tagged unions.
     - **A known small difference, accepted:** a flattened statement match
       still defines its arm's Void value, so its C keeps a constant that
       nothing reads (`const uint8_t ...=0;`), which -O2 removes.
     - The repro's `size_matched` and `m/`'s binding form emit their
       destructured counterparts' C, temporaries included.
     - With flattening disabled, exactly the flattening tests fail (8 lower,
       3 own, 2 verify, 2 emit); the guards for a tagged one-variant union and
       a self-tail final match pass either way.
     - **Measurement 1, the stop condition.** Landing 2's stage-1 compiler
       built landing 2 and landing 2 plus `build/destructuring-removal/migrate.py`
       (157 arm form, 47 binding form, 0 skipped), each at -O2, given landing
       2's source:

       | Metric | landing 2 | + migration | Change |
       | --- | ---: | ---: | ---: |
       | allocations | 13,538,155 | 13,538,155 | 0 |
       | peak heap, bytes | 192,458,904 | 192,458,922 | +18 |
       | instructions, macOS median of 11 | 13,764,930,042 | 13,771,790,324 | +0.0498% |
       | instructions, callgrind (Linux arm64) | 12,291,921,880 | 12,291,922,051 | +0.0000% |

       The macOS reading sat at the edge of the 0.05% band, so callgrind
       settled it: +171 instructions. The fixed-input C is identical.
     - **Measurement 2, this landing's own cost.** Each side built by itself
       (stage 2), given the base's source:

       | Metric | `4fb81b64f` | landing 2 | Change |
       | --- | ---: | ---: | ---: |
       | allocations | 13,515,368 | 13,514,539 | -0.0061% |
       | peak heap, bytes | 192,360,289 | 192,263,408 | -0.0504% |
       | instructions, macOS median of 5 | 13,760,289,611 | 13,749,885,211 | -0.0756% |

     - **`self-compile-cost 4fb81b64f fa50eb082 --rounds 3`:** fixed input
       allocations -0.0061%, peak heap -0.0504%, instructions -0.0855%; own
       source allocations +0.1686%, instructions +0.0642%. The fixed-input C
       differs only in the 27 derived equalities of erased id types
       (`ModuleId`, `ValueId` and the rest), whose 54 one-arm selections are
       flattened.
     - **Lines** (against `04a7ceff7`, the origin/main merged as
       `abed4171e`): production +137/-14 (net +123, ceiling +125); tests +816
       (ceiling +860). The growth audit cut a two-variant guard that
       `test_match_arms` covers, a generic verifier rejection and the
       destructured e2e twin (+923 before); the review then dropped the e2e
       store case, which allocated 2 either way, and added the arity check
       (+15 production) and a wildcard assertion. README +4/-1.
     - Raw evidence: `build/destructuring-removal/landing2/` (`stage2/`,
       `callgrind/`, `self-compile-cost/`, `gate.log`).
3. **Landing 3: rotate the seed** to landing 2's commit, as
   `PRIVATE_VARIANTS_PLAN.md`'s landing 3 did. It runs the fixpoint and
   `test_bootstrap.sh`.
4. **Landing 4: migrate every union destructuring to `match`.**
   - **What changes:** `src`, the library, the test programs that destructure
     a union only incidentally, and the README's examples.
     - The 157 sites that end the body take the arm form.
     - The 47 that keep going take the binding form.
     - The 3 resources take either.
     - The destructuring tests themselves stay for landing 5.
   - **Formatting:** run `blorp format` on every changed file.
   - **Oracle:** the fixed-input C is identical.
   - **Estimate:** about +105 production lines:
     - +1 at each binding site and each multi-line arm;
     - more at the double destructurings;
     - +1 where a `match` line would pass 100 columns.

     **Ceiling:** +130 production, and the cost ceiling below.
5. **Landing 5: delete union destructuring** (rule 1).
   - **Deleted from syntax and parse:**
     - `ParsedVariantBinding` and `VariantBinding`;
     - `consume_variant_binding`, `consume_variant_head`,
       `consume_payload_binder` and `VARIANT_BINDER_*` (`parse.brp:4186`,
       `:4262`).
   - **Deleted from check:**
     - `resolve_variant_binding`, `bind_erased_payload` and
       `bind_payload_matches`;
     - `destructured_variant`, `aliased_destructured_variant`,
       `union_destructured_variant` and `bare_destructured_variant`
       (`constructors.brp:425`, `:442`);
     - the concurrent `task_names` arm for a variant binding
       (`bodies.brp:1875`);
     - `DestructuringRejected` and `DestructuringProblem`, with their render
       arms;
     - `VariantUse.Destructured`;
     - `QualifiedVariantNotOffered`'s destructuring site.
   - **Deleted from later phases:**
     - `ReadPayload` in check's model, specialize (two sites) and resource
       scopes. Its only producer is `bodies.brp:1643`.
     - The formatter's `VariantBinding` case.
   - **Kept:** `at_variant_binding`, which now feeds rule 1's rejection.
   - **Tests:**
     - `test_destructuring.brp`'s union cases become rule 1's rejection
       tests, or are deleted;
     - delete `test_variant_bindings.brp` and its `COMPONENT_SOURCES` entry in
       `driver.brp`;
     - delete the `test_conformance.brp` arms, the formatter fixtures, the e2e
       alias case and `concurrency/tuple_task.brp:39`'s variant task;
     - tuple destructuring tests stay.
   - **Docs:**
     - `blorp/README.md`: the union destructuring paragraph, the
       private-variant and resource paragraphs, and `:965`;
     - `blorp/grammar.ebnf`: `variant_binding` leaves the statement rule, and
       a comment records the rejection;
     - `blorp/NEXT.md:230`.
   - **Oracle:** fixed-input C identical, since landing 4's source has no
     destructuring.
   - **Estimate:** about −330 production lines. The reviewer counts about
     430 lines including comments.

     | Area | Lines |
     | --- | ---: |
     | check's destructuring | −200 |
     | parse, net of the new rejection | −40 |
     | errors and render | −50 |
     | `ReadPayload` across phases | −25 |
     | syntax and formatter | −15 |

     **Ceiling:** at most −265, which is 80% of the estimate, as
     `PRIVATE_VARIANTS_PLAN.md` set its deletions.

**Net:** about −135 to −75 production lines across the five landings (+30,
+60 to +120, 0, +105, −330). The language has one way to read a union. A
one-variant `match` costs nothing more than the destructuring it replaces,
in the compiler and in users' programs.

**Review and probes.** Every landing gets a code review, a test-runner run on
its final commit, and Seed CI. Landings 1, 2 and 5 also get an adversarial
probe pass:

- **Landing 1:** resources matched in and outside their module.
- **Landing 2:** flattened selections under reassignment, in loops and
  closures, with carried vars and a tail `RecurWith`, run through C with
  sanitizers and `BLORP_LEAK_CHECK=strict`.
- **Landing 5:** each removed form, with and without aliases, generics,
  resources and `?=`, to show the rejection and its span.

## Cost ceiling

Landing 4 is measured against its base, whose seed already has landing 2's
flattening:

- fixed-input C identical;
- fixed-input allocations and peak heap identical;
- fixed-input instructions within +0.10%.

Callgrind in the Linux image settles a reading within 0.05% of the ceiling.
Without landing 2, the expected cost is the spike's +0.66%. Taking that cost
would be Keith's decision, not a routine correction.

## Out of scope

- **Flattening an edge that projects (landing 2's scope (b)).** The spike
  (`spike/flatten-selection-b`, never lands) flattened edges with definitions
  too: +45 lower, +2 own (`PayloadDefinition` on the `Projection` plan, and
  `borrowed_extents` following `PayloadValue`) and +96 verify (a payload read
  of a one-variant union in an ordinary block). `[...rest]` (`CopyListSuffix`)
  also becomes straight-line and fails verify's `value_place` outside a
  selection, so it needs a second rule or an exclusion. It flattens 2 more
  selections in `src` (`declarations.resolved_uses` and
  `resolved_value_type`), and in users' programs tagged one-variant unions,
  tuple patterns and the per-binder selections of a tagged destructuring.
  The codegen suites passed with it; the full gate was not run.

- Tuple destructuring.
- **Lending an arm input whose root is a borrowed parameter.** It would
  remove the arm-entry retain from every `Some(x):` arm in the compiler, not
  only one-variant ones. `projection_lasts` already answers `True` for
  `(None, _)` (`own.brp:1795`), which is Lean's borrowed-projection rule. It
  needs its own plan and measurement.
- Memoized erasure, and `PRIVATE_VARIANTS_PLAN.md`'s cost follow-ups.
- The `declares no public Point` wording, which `PRIVATE_VARIANTS_PLAN.md`
  records.

## Decisions

Keith accepted all three on 2026-11-26.

1. **The binding form for the 47 sites that keep going**
   (`contents = match self: Dict.Init(contents): contents`), rather than
   nesting the rest of the body.
2. **A parser rejection with a migration help,** rather than leaving the line
   to today's generic "expected a newline after the return expression".
3. **Landing 2's flattening, and a rotation, before the migration,** so that
   the migration costs nothing. The alternative was to take about +0.66%
   instructions on the self-compile and flatten later.
