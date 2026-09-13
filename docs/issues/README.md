# Active Engineering Issues

This directory contains implementation handoffs that are still actionable.
Git history is the archive: delete an issue document when its work is
implemented, rejected, superseded, or no longer planned.

Current language and compiler behavior belongs in the reference documents
under `docs/`. Durable raw measurements belong in `benchmarks/results/`.

## Retention Rules

Keep a document here only when it is active, ready, proposed with a credible
admission gate, or blocked on a named prerequisite. Before deleting a resolved
issue, move any still-current contract to the owning reference document and
any reusable measurement to `benchmarks/results/`.

Do not create an archive directory, retain completed checklists as history, or
copy logs and command output into an issue. Git already preserves that record.

Issue documents should be narrowly executable:

- state the problem, scope, current owner, and exact invariants;
- name the smallest fast feedback loop;
- use deterministic work, allocation, instruction, or memory measures where
  latency alone is noisy;
- define admission, acceptance, rejection, and rollback criteria;
- link shared development commands instead of copying them; and
- avoid progress diaries, completed sub-issue catalogs, and speculative
  architecture unrelated to the next implementation boundary.

Aim for no more than roughly 300 lines. Longer documents are justified only
for a genuinely multi-phase architecture and should begin with a concise
current-state and next-action summary.

## Active Workstreams

### Compiler Performance

- [Callable header registration](compiler-performance/05-callable-header-registration.md)
- [Core traversal and declaration-query reduction](compiler-performance/14-reduce-core-program-traversal-work.md)
- [Token and token-kind storage](compiler-performance/30-fuse-token-and-token-kind-storage.md)
- [Shared match continuations](compiler-performance/52-share-match-continuations.md)
- [Cancellation cleanup ABI](compiler-performance/53-minimize-and-compact-cancellation-cleanup.md)
- [Stage 06 latency roadmap](compiler-performance/STAGE06_LATENCY_REDUCTION_ROADMAP.md)
- [Normalized semantic compilation roadmap](compiler-performance/NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md)
- [Normalized compilation database direction](compiler-performance/NORMALIZED_COMPILATION_DATABASE_ROADMAP.md)
- [Perceus ownership roadmap](compiler-performance/PERCEUS_OWNERSHIP_OPTIMIZATION_ROADMAP.md)
- [Nested record allocation folding prototype](compiler-performance/NESTED_RECORD_FOLDING_PROTOTYPE_ROADMAP.md)

### Typechecking

- [Inference profiling harness](typechecking/inference-performance-profiling.md)
- [Solver finalization](typechecking/phase-08-solver-finalization.md)
- [Semantic validation](typechecking/phase-09-semantic-validation.md)
- [Checked and codegen-ready graphs](typechecking/phase-10-checked-codegen-graphs.md)

### Tooling And Profiling

- [Profiling workstream](profiling/README.md)
- [Definition and usage navigation](lsp/02-definition-usage-navigation.md)
- [Exact nonmember completion](lsp/03-exact-nonmember-completion.md)
- [Workspace rename](lsp/04-workspace-rename.md)
- [Typed member completion](lsp/05-typed-member-completion.md)
- [Layout compatibility follow-ups](blorp-layout/COMPATIBILITY_FOLLOW_UPS.md)
- [Formatter interpolation diagnostics](formatter-interpolation-projection-errors.md)

### Runtime, Core, And Focused Cleanup

- [COW-capable list concatenation](cow-capable-list-concat.md)
- [Flat ordered set storage](runtime-performance/02-flat-ordered-set-storage.md)
- [Core-preparation declaration indexes](late-core-latency/02-index-core-preparation-declarations.md)
- [Consume-specialization candidate index](late-core-latency/03-index-consume-specialization-candidates.md)
- [First-match loop cleanup](compiler-first-match-loop-cleanup.md)
- [Global constant materialization limitations](compiler-global-constant-materialization.md)

## Maintenance Check

When touching this directory:

1. remove resolved or superseded documents;
2. update this index only for workstream-level additions or removals;
3. check local Markdown links;
4. run `git diff --check`; and
5. use the focused validation described by the issue rather than a full suite
   until the change is ready.

See the [Developer Guide](../DEVELOPMENT.md) for the shared development and
measurement workflow.
