# Qualified constructor source-pattern pilot

**Status:** approved plan; source implementation and cost execution remain held.
No source migration or cost epoch is authorized by this document.

The qualified-flat-head prerequisite is now accepted on main/origin at
`462f115949ecdf801c5ebba9ac07bdb8c14ab97e`. The earlier f1458924a/db8
candidate and patch references remain historical planning evidence, not current
source authority. A static refresh pins the three accepted files and six regions
against this actual base; root and a peer must review the refreshed examples and
counts, reserve the regions, and authorize source implementation separately.
The prerequisite feature's cost evidence remains separate from this source pilot.

The coordinator and independent reviewers approved this plan and its production, test and
fixture ceilings. Implementation remains held until the prerequisites and gates below are
satisfied. This planning-documents-only change refreshes this plan and the
[roadmap](ROADMAP.md#m2b-pattern-compilation), including its generic SOURCE cost policy prose.
No SOURCE freeze, source-migration compiler, cost sample or source implementation has been
produced. Follow the [source plan](BOOTSTRAP_SOURCE_PLAN.md) and [development
instructions](AGENTS.md) when implementation is authorized.

## Purpose, authorities and boundary

After qualified-feature acceptance, use flat qualified heads on six real
checker producer/consumer paths. Replace nested constructor arm headers with successive matches while
retaining the exact existing branch actions. Qualification names the module that
DECLARES the constructor; it is not a spelling-based semantic lookup downstream.

- namespace/namespace.brp declares NamedValue, OfferedValue, Entity, TypeHead,
  SelectionProblem and Unoffered (lines173/181/55/39/129/120). Add `as Namespace`
  to its existing selected-import lines in constructors.brp and render.brp.
- utils/syntax.brp declares PatternHead, ParsedPattern and ParsedStatement
  (415/431/582). Add `as Syntax` to bodies.brp's existing selected import.
- Preserve the existing selected imports and existing Errors/Check aliases.
  Keep ordinary Ok/Err/Some/None from the designated foundation; do not qualify
  them through forwarding result/option modules that do not own the declarations.
- Existing full VariantId membership, occurrence_fields substitution, immutable
  VariantContract and resolve_variant_pattern remain the single authorities.
  No new helper, datatype, decision tree, registry, nested/list/literal feature,
  lower-stage name recovery or accepted-IR change is proposed.

## Accepted implementation base and region pins

The historical plan-review base `f1458924a` and old candidate anchors are descriptive;
they are not an implementation or cost freeze. Before any source edit:

1. Obtain the coordinator's actual accepted-main commit and a region lease,
   after the qualified feature and any accepted M2/M3/opaque prerequisites.
   Record that full commit and the accepted qualified-feature commit. Rebuild
   the proposed source refactor from this actual base; never transplant an old
   function body or apply an old whole-function replacement.
2. Pin all three complete files and all six function regions: constructors.brp
   `find_declared_variant`/`find_qualified_variant`, bodies.brp
   `resolve_pattern`/`resolve_statements`, render.brp
   `declaration_span`/`render_selection`. For each region record actual path,
   function name, start/end byte offsets and SHA256 of the exact UTF-8 bytes,
   from its declaration through the final nonblank body line including the
   final newline. Do not substitute db8 hashes. If a prerequisite function is
   absent or any accepted base/region changes, stop and refresh before edits.
3. Refresh every before/after example against those six pinned regions. Build
   only the header/dispatch transformations below, preserving each current arm
   action verbatim except the required indentation and explicit constructor
   qualification. Keep all current signatures, call arguments, result carriers,
   diagnostics, branch order and fallback coverage. Recompute gross/net counts
   and retain the approved160/+40 production ceiling.
4. Preserve the pinned base's accepted M2 join/carrier handling, local
   annotations and opaque type-head/note cases. At accepted `462f115949`,
   propagation, while and for remain rejected; break/continue retain their
   outside-loop invariant errors. Preserve those exact actions and all actual
   call arguments. Do not introduce `BooleanContext.boolean` or copy any old
   whole body. Only if Boolean, propagation or while support later lands may
   fresh accepted-region pins preserve that newer behavior instead.

All six actual region hashes are required before implementation. The qualified feature is
accepted; refresh against its actual integration rather than the old db8 candidate. No SOURCE
freeze or cost call is implied by static code pins. The independent review checks the refreshed
dispatch-only patch before implementation acceptance.

## Exact six sites and literate changes

### 1. constructors.brp:96, find_declared_variant

Before:
```blorp
match named_value(context.namespace, context.module, name.id):
    Some(NamedConstructor(variant)): declared_variant_contract(context, owner, variant, name.span)
    _: Ok(None)
```
After:
```blorp
match named_value(context.namespace, context.module, name.id):
    Some(named):
        match named:
            Namespace.NamedConstructor(variant): declared_variant_contract(context, owner, variant, name.span)
            _: Ok(None)
    None: Ok(None)
```

One namespace query, same visible declaration ID and same None result for a
nonconstructor. The existing find_variant fallback still owns the unimported-
constructor diagnostic; the full same_variant comparison is untouched.

### 2. constructors.brp:125, find_qualified_variant

Before:
```blorp
declared ?= match offered_value(context.namespace, aliased.target, qualified.name.id):
    Ok(OfferedConstructor(variant)):
        declared_variant_contract(context, occurrence.owner, variant, qualified.name.span)
    Ok(_): Ok(None)
    Err(reason):
        Err(qualified_error(qualified.name.span, QualifiedNotOffered(qualified.module.id, qualified.name.id, aliased.path, reason)))
```
After:
```blorp
declared ?= match offered_value(context.namespace, aliased.target, qualified.name.id):
    Ok(offered):
        match offered:
            Namespace.OfferedConstructor(variant):
                declared_variant_contract(context, occurrence.owner, variant, qualified.name.span)
            _: Ok(None)
    Err(reason):
        Err(qualified_error(qualified.name.span, QualifiedNotOffered(qualified.module.id, qualified.name.id, aliased.path, reason)))
```

Alias resolution still precedes the offer; private/non-reexport errors precede
membership/arity. Neither module alias nor constructor identity is reconstructed.
The existing instantiation and publication following this block are unchanged.

### 3. bodies.brp:186, resolve_pattern

The accepted base has three Result/Option dispatches: a whole-arm bare
name, bare constructor head and qualified constructor head. Refresh each from
the accepted base. In the qualified branch, preserve the actual query and arm
actions and change these headers only:

Before:
```blorp
QualifiedHead(qualified):
    -- same accepted lookup and context arguments
    match found_result:
        Ok(Some(contract)):
            -- existing accepted-contract action
        Ok(None):
            -- existing exact missing-constructor diagnostic
        Err(error):
            -- existing error propagation
```
After:
```blorp
Syntax.QualifiedHead(qualified):
    -- same accepted lookup and context arguments
    match found_result:
        Ok(found):
            match found:
                Some(contract):
                    -- same accepted-contract action
                None:
                    -- same exact missing-constructor diagnostic
        Err(error):
            -- same error propagation
```

`found_result` labels the existing matched expression in these fragments; it is
not a proposed extra binding or helper. Qualify the function's existing flat
ParsedPattern and BareHead/QualifiedHead arms with Syntax. Preserve current
binding allocation, field order, capture types/origins/spans and publication of
VariantCase. The existing allocator, scope and context carriers remain unchanged.
The pinned base forwards its existing context unchanged; no Boolean argument is
introduced. A later accepted context change requires fresh pins and examples.

### 4. bodies.brp:774, resolve_statements

Refresh from accepted current statement semantics. The transformation unwraps
the existing Option once, then dispatches its actual statement constructors.
Illustrative headers, with every accepted action retained:

Before:
```blorp
match selected_statement:
    None:
        -- current end-of-statements result/carrier
    Some(BindingStatement(binding)):
        -- current binding action
    Some(PropagatingBinding(propagation)):
        Err(unsupported_form(propagation.span, Propagation))
    Some(WhileLoop(loop)):
        Err(unsupported_form(loop.span, WhileStatement))
    -- current remaining statement arms
```
After:
```blorp
match selected_statement:
    None:
        -- same end-of-statements result/carrier
    Some(statement):
        match statement:
            Syntax.BindingStatement(binding):
                -- same binding action
            Syntax.PropagatingBinding(propagation):
                Err(unsupported_form(propagation.span, Propagation))
            Syntax.WhileLoop(loop):
                Err(unsupported_form(loop.span, WhileStatement))
            -- same remaining statement arms, qualified with Syntax
```

`selected_statement` labels the existing scrutinee, not a new binding. Retain the
current cursor/scrutinee, accepted M2 carriers, initializer/collision priority,
BindingIds and append order exactly. Preserve the pinned propagation/while/for
rejections and outside-loop break/continue errors. Reindent accepted actions;
never replace the function. Future admitted propagation/while or Boolean context
arguments belong only to their later accepted landing and a fresh region refresh.

### 5. render.brp:425, declaration_span

The reviewed candidate distinguishes Type(UnionHead(id)), Type(RecordHead(id))
and Type(candidate). Preserve every actual accepted type-head arm, including any
newer opaque head and its note lookup. Transform only outer/inner dispatch:

```blorp
Namespace.Type(candidate):
    match candidate:
        Namespace.UnionHead(id):
            -- same accepted union declaration-note action
        Namespace.RecordHead(id):
            -- same accepted record declaration-note action
        -- preserve any additional accepted type-head arms here
        _:
            -- same existing builtin/fallback action
```

Function/Constant/Constructor/Alias actions remain unchanged. Preserve nominal
IDs and existing inventory selection; no type spelling chooses the declaration
owner and no inventory is rebuilt.

### 6. render.brp:472, render_selection

The reviewed candidate has four nested NotOffered arms. Refresh their actual
set and actions, then match the existing reason once:

```blorp
Namespace.NotOffered(reason):
    match reason:
        Namespace.UnknownName:
            -- same selection-form-specific diagnostic
        Namespace.PrivateName:
            -- same private-declaration diagnostic
        Namespace.ImportedThere(entity):
            -- same help/type/declaration-note action
        Namespace.ProvidedThere(entity):
            -- same prelude diagnostic
```

Existing name/module spelling queries stay before this switch and run once.
Keep every current message/help/span/note and its first-error order. All other
SelectionProblem arms remain at the outer level. Strings here stay diagnostic
text without later-stage semantic meaning. Comments in these examples identify
unchanged accepted actions, not proposed helper calls or replacement bodies.

## Draft scope estimate and hard ceilings

A static dispatch-only preview on accepted `462f115949ecdf801c5ebba9ac07bdb8c14ab97e`,
including three same-line import aliases and readable indentation, gives:

| Production file | Added | Removed | Net |
| --- | ---: | ---: | ---: |
| check/constructors.brp | 11 | 6 | +5 |
| check/bodies.brp | 51 | 43 | +8 |
| check/render.brp | 59 | 55 | +4 |
| Total | 121 | 104 | +17 |

This is an uncompiled accepted-base preview, not an implemented/validated patch. The earlier db8
estimate was 108 ADD / 91 DEL / +17 and remains historical. Coordinator and independent design
review approved hard ceilings of160 gross added/+40 net production,240 added/+240 net tests and
zero new fixture lines. Refresh the estimate against the actual pinned base before
implementation; retain these caps if newer accepted arm actions increase the draft. Plan
approval does not authorize source edits. No compressed formatting, removed coverage or stacked
pilot allowances. The current preview removes 22 nested arm headers at these six functions; it
is not a full compiler-source census or a claim that nested/list/literal dependencies have all
been removed. The qualified feature and this source refactor remain separately
reviewable/measurable changes.

## Characterization, acceptance, dependencies and stop rules

Use existing owning Blorp TestSuites first: test_check/{test_qualified_patterns,
test_match,test_binding_names,test_scope,test_constructors,test_qualified_names,
test_render}.brp and test_namespace/test_namespace.brp. Add only missing exact
characterizations within 240 lines: accepted VariantId and BindingIds 0/1 with
field type/origin/span; unknown/private/non-reexport errors; local initializer
and collision order; every current statement admission/rejection; UnionHead/RecordHead/
builtin declaration notes; selection-form help and imported/prelude notes.

Before source edits, characterize the unchanged baseline; source refactoring
should begin green. Demonstrate sensitive oracles with bounded semantic mutants
of the protected identity/priority/span, then restore exact bytes. Do not fabricate
an initial red or accept a host setup error as proof. After implementation run
focused owning suites, one current complete component/e2e acceptance, exact shared
C and diagnostics, strict zero pilot counters and normal-main sanitizer checks.

The [dated SOURCE cost decision](BOOTSTRAP_SOURCE_PLAN.md#source-cost-acceptance)
supersedes this plan's older original-reset cumulative hold. Before any new setup
or sampling, root names one then-current accepted B and the complete C with the
exact dependency/composition boundary. Freeze source, full library, corpus,
physical paths, host and metric roles. Each unchanged owned input and the
original construction-checkpoint source-to-C proxy must independently pass
+3% allocations and normal minimum-of-three instructions against that fixed B.
No baseline or cost epoch is named by this static refresh. Never roll B after a
failure. Preserve historical R0 thresholds, failures and cumulative trends with
their original verdicts; those comparisons are no longer a remaining-SOURCE
landing gate. Absolute fixture limits, strict zero leaks, identity/diagnostic
oracles, LOC ceilings and independent reviews are unchanged. The prerequisite
qualified feature keeps its separately measured fixed-EA contract and its
140,000 allocation / 500,000,000 instruction fixture limits.

No measurements are authorized by this plan. The extra host control/capture
cost must be measured rather than assumed free; reject or rescope any hard
cost/LOC failure without deleting coverage or rolling the baseline.

Order after qualified-feature acceptance and the prerequisite accepted-source
alignment. Root must reserve these six regions in three checker files against
opaque/control writers and review the refreshed estimate before source edits. Stop on
source conflicts, unresolved ownership/diagnostic ordering, a new helper/model/
mechanism requirement, or a hard ceiling breach. No parse/namespace production,
specialization, lower/own/verify/emit or library change is part of this pilot.
