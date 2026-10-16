# Remaining quality work

This executes the decisions in [QUALITY_ROADMAP.md](QUALITY_ROADMAP.md) after
the namespace squash, `fb257c946`. The host compiler and bootstrap stay frozen.
The roadmap's deferred performance backlog and paused feature branches remain
deferred; they are not prerequisites for completing this quality queue.

## Ownership and order

Independent worktrees allow planning, inventories and implementation to overlap.
Integration follows the order below. A worker does not add an adjacent feature
to make a rule easier to implement.

1. Rewrite nested propagation in compiler source; then enforce the parser rule.
2. Apply the pattern and binding naming rules.
3. Reject private types exposed through public declarations.
4. Validate overlapping UFCS receivers using the existing inference solver.
5. Complete the three maintenance items, independently where their files permit.

The coordinator integrates changes and owns shared documentation. Compiler
specialists implement; a separate correctness reviewer and design-conformance
reviewer approve every code slice. A separate test-runner owns the final gate.
All compiled commands and measurements on this machine are serialized, with
an explicit coordinator-granted slot. Source editing and read-only review may
continue while another worktree owns that slot.

The owner subsequently requested parallel progress toward self-compilation.
A separate compiler worker plans M2.2 Boolean control flow against the accepted
join and designated-foundation contracts. Quality remains the integration
priority. Feature planning and isolated source work may overlap; no feature
depends on unreviewed quality output, and overlapping checker changes must be
rebased and revalidated before landing. This does not activate the deferred
performance backlog or any paused milestone branch automatically.

## Propagation delta plan

The landed baseline has 847 executable production propagation statements.
Of these, 343 are nested: 333 in blocks and ten in lambdas, across 19 files.
The earlier 349-plus-ten count is historical. The temporary target library has
none. Host-compiled tests are outside the mechanical source rewrite.

Use the three transformations already specified in the roadmap: match in place;
an explicitly annotated Result carrier for a value block; a helper only when
it names a real phase concept and avoids a deep continuation. Preserve branch
selection, operand evaluation, continuation and first-error ordering. Never
hoist an operand out of its branch. Do not add a rewrite framework.

Stage directories remain owning-test and full-corpus identity checkpoints:
lex, load, namespace, check, specialize, lower, own, verify, emit, shell, parse.
This updates the older per-directory commit proposal: commit the complete
mechanical rewrite after its aggregate gate, then the parser rule and its docs
as a separate slice. This retains incremental failure localization without
repeating the complete build and e2e gate at eleven intermediate commits.

The parser adds one `FunctionBlock` context. Convert `FunctionBody` when
entering an if or match block, preserve the existing loop/lambda contexts,
and restore the caller's context after the complete form. For an if chain,
retain the converted context through `consume_else_branch`, including else-if
recursion, before restoring it. For match, convert before `consume_arms` and
restore in the returned parser state. Header expressions retain the enclosing
context; a nested block expression inside a header applies its own conversion.

Tests separately cover then, else, else-if, tail and nested arms, inline arms,
bound-value if/match, blocks in while conditions and for iterables, and nested
lambda blocks. Pin exact message, help and operator span. Accepted propagation
before and after a block proves context restoration; break/continue after a
function-level block must still report outside-loop errors. Preserve the
existing loop-body, value-in-loop and lambda rejection precedence.

Pre-set ceilings for the rewrite plus parser rule:

| Metric | Ceiling |
| --- | --- |
| Physical production lines | +479 against the landed baseline |
| Lines with at least 14 tabs / maximum depth | 136 / 20 tabs |
| Allocations for each frozen successful fixture and retained stress input | No growth |
| Whole-corpus and individual stress-input retired instructions | +0.5% |
| Host compile of compiler source, allocations and instructions | +5% |

Report production, tests and docs separately. Cost measurements are matched
owned-input and host-build proxies, not self-compilation. Existing e2e cost
ceilings remain unchanged. Stop on a repeatable breach, a host fault, changed
evaluation/error ordering, or a necessary architectural expansion.

The parser rule's broader rejection audit found two increases outside the
successful-input allocation ceiling: two objects in the forwarding helper and
four in the alias-conflict helper. All accepted inputs remain below the frozen
baseline. The coordinator and independent test runner accept this minor cost:
the additional typed context entry/restoration copies the managed `ParserState`
carrier twice per completed match. That is source/count attribution, not an
allocator-stack profile. A later physical representation/update improvement
could combine existing advance/context construction or inline such fixed
carriers with managed children; no parser special case is justified for this
cost. Preserve these observations without describing them as a waived ceiling.

## Other rule deltas

Pattern/binding, private-type and UFCS delta plans have received independent
review. Their implementations remain separate review and integration slices;
approval of a plan is not approval of its resulting code or measurements.

Pattern/binding work first refreshes the rename and binding-site inventory.
Unknown whole-arm names cannot silently become bindings; `_` alone is the
catch-all. Constructor visibility has one enforcement site, and local binding
creation has one authority. Existing unsupported forms keep their staged
rejections. The historical production target is +21; the refreshed plan must
explain any change before implementation. The reviewed construction boundary
checks a new initializer before creating its complete binding. Thus an invalid
initializer wins over a collision for a new declaration; existing assignment
classification errors retain their earlier priority. A dedicated regression
pins this intentional ordering change. Scope remains a list of opaque accepted
bindings, with one constructor, and namespace occurrence projections retain
the actual declaration or import-selection span.

Private-type checking belongs in type annotation resolution, driven by the
public declaration's explicit access context and namespace-owned type origin.
It covers nested arguments and qualified heads without re-reading declaration
visibility downstream. Its reviewed delta plan must account for every TypeScope
construction and the existing source visibility fallout. The production
target remains +66.

Use `PrivateTypeUse | PublicTypeUse(NameId)` as the mandatory annotation-access
context, and project `{ head, origin }` once from the namespace's existing type
entry. Atomic and applied unqualified heads share one privacy check; qualified
heads reuse the provider's already-public offer contract. Recursion through
type arguments preserves the enclosing access. Errors carry the private type
and public declaration NameIds; rendering alone looks up spellings. A private
head is rejected before its arity, while public/unknown heads retain their
existing error ordering. Only the three inventoried source visibility
promotions are allowed; these establish future-bootstrap consistency, not a
claim that the pilot can check its entire source.

UFCS requires a reviewed cost-reduction plan before implementation. Reuse one
solver for receiver selection and overlap; no second matching algorithm or
global pair cache. A scope checks unordered new/new and inherited/new pairs;
it may skip inherited/inherited pairs only where provider validation proves
that exact inherited set was already checked. Different import subsets must
not conceal a clash. The roadmap's +102 production and +0.5% small/corpus
instruction limits still apply, as does the 31,000-allocation 32-module stress
ceiling. Additional workload and allocation ceilings are set in delta review.

The first bounded UFCS prototype passed 13 focused callbacks but added 276
allocations (3.27%) and 1.09 million instructions (2.58%) on `return/zero`.
It was held out of integration and stopped before stress/corpus validation.
The owner then clarified that ordinary lookup costs imposed by current data
structures may be accepted for now, with the inefficiency recorded for later
replacement. Attribute the work before making that tradeoff: this is not a
general cost waiver, permission for redundant scans, or permission to add a
cache or a second matcher to force the original numbers. Retain the original
ceilings and measured breach in the evidence, alongside the eventual decision.

## Maintenance and boundaries

The emitter needs meaningful invariant diagnostics carrying the relevant
identity and available occurrence, rather than one union error for every
failure. Keyword recognition and diagnostic spelling need one authoritative
mapping with measured lookup costs. Escaped long test programs become multiline
strings while preserving asserted bytes and spans. Each gets its own small
reviewed plan and explicit ceilings before code; none authorizes broader
emitter, lexer or testing infrastructure.

Shared documentation includes the input-program rule references, removed GUIDE
examples, roadmap join/recursion corrections and CF-031/032 reproductions.
Document divergence from the frozen host explicitly.

## Validation and evidence

Before implementation, freeze the baseline pilot/C, source and toolchain hashes,
and every fixture's outcome, diagnostic and C. The initial inventory has 429
files: 349 accept and 80 reject, each with a balanced zero-leak report.
Store raw samples under ignored build directories; retain designs and decisions
in repository documentation so no scratch plan is required to resume work.

Mechanical checkpoints require owning TestSuites and exact baseline outcome/C
identity. Semantic slices enumerate their intended acceptance/diagnostic changes
and preserve C for unchanged accepted programs. New tests must fail with the
protected behavior removed. Rejections assert typed errors and exact rendered
message/help/span; use normal fixture entrypoints and unmodified emitted C.

At each completed commit boundary, use a fresh matching host, the complete
`make -C blorp_2 test` gate, the parse frontier and strict fixture leak checks.
The frozen frontier is 32/34, not a bootstrap proof. New source modules must
parse too; report the new numerator and denominator rather than pinning a
hand-kept file count. Existing unsupported forms must not expand. Do not weaken counters,
limits or timeouts. Every review states its simplicity verdict and any evidence
it could not verify. Integration stops until should-fixes and required gates
are resolved; nits become bounded follow-ups.
