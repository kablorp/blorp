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

New or substantively revised handoffs should lead with a short current-state
card so an agent assigned **one** issue can
start without reading the whole workstream or reconstructing history:

```text
Current state: what the production code and tests do now.
Next action: the one bounded experiment or implementation slice.
Read first: exact owner source, contract, and nearest test.
Fast loop: one runnable command and the result it must show.
Decision: acceptance, rejection, and when to ask for guidance.
```

Keep historical attempts in Git history and durable measurements in
`benchmarks/results/`; link them only when the next decision depends on them.
Label proposed commands as proposed so they are not mistaken for working
tooling. Prefer a link and a small task-specific example over repeating the
complete `scripts/test` or CLI reference in each issue.

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
- [Accepted semantic-type projection, measurement gated](compiler-performance/66-canonicalize-accepted-semantic-type-projection.md)
- [CTFE environment lookup, measurement gated](compiler-performance/67-index-remaining-ctfe-environment-lookup.md)
- [Step 2e visibility convergence](compiler-performance/94-step2e-visibility-convergence.md)
- [Step 2e width-probe resource gate](compiler-performance/97-bound-visibility-width-probe.md)
- [Accepted-alias cycle membership](compiler-performance/99-index-accepted-alias-cycle-membership.md)
- [Cancellation-plan child-result batching](compiler-performance/100-batch-cancellation-plan-child-results.md)
- [Variable-dimension list flattening](compiler-performance/101-flatten-var-dims-list-resolution.md)
- [Meta-resolution cycle membership](compiler-performance/102-index-meta-resolution-cycle-membership.md)
- [Environment symbol collection](compiler-performance/103-batch-environment-symbol-collection.md)
- [Resource-reference deduplication](compiler-performance/104-index-resource-reference-deduplication.md)
- [Consumed-argument membership](compiler-performance/105-index-consumed-argument-membership.md)
- [Parser-finalization diagnostics](compiler-performance/106-batch-parser-finalization-diagnostics.md)
- [Monomorphization type-parameter membership](compiler-performance/107-index-monomorphization-type-parameter-membership.md)
- [Implementation-obligation traversal](compiler-performance/108-bound-implementation-obligation-traversal.md)
- [Standard-inline rename copying](compiler-performance/109-reduce-std-inline-rename-copying.md)
- [Match-bound name deduplication](compiler-performance/110-deduplicate-match-bound-names-once.md)
- [Call-signature name allocation](compiler-performance/111-index-call-signature-name-allocation.md)
- [Normalized semantic compilation roadmap](compiler-performance/NORMALIZED_SEMANTIC_COMPILATION_ROADMAP.md)
- [Perceus ownership roadmap](compiler-performance/PERCEUS_OWNERSHIP_OPTIMIZATION_ROADMAP.md)
- [Nested record allocation folding prototype](compiler-performance/NESTED_RECORD_FOLDING_PROTOTYPE_ROADMAP.md)
- [Internal C-symbol projection follow-ups](compiler-performance/c-symbol-projection-followups.md)

### Typechecking

- [Inference profiling harness](typechecking/inference-performance-profiling.md)
- [Solver finalization](typechecking/phase-08-solver-finalization.md)
- [Semantic validation](typechecking/phase-09-semantic-validation.md)
- [Checked and codegen-ready graphs](typechecking/phase-10-checked-codegen-graphs.md)

### Tooling And Profiling

- [Profiling workstream](profiling/README.md)
- [Local profile aggregation and output](profiling/04-local-aggregation-and-output.md)
- [Native sampling and symbol maps](profiling/05-native-sampling-and-symbol-maps.md)
- [Unified profile command](profiling/06-unified-profile-command.md)
- [Definition and usage navigation](lsp/02-definition-usage-navigation.md)
- [Exact nonmember completion](lsp/03-exact-nonmember-completion.md)
- [Workspace rename](lsp/04-workspace-rename.md)
- [Typed member completion](lsp/05-typed-member-completion.md)
- [Compatibility and migration candidates](compatibility-candidates.md)
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
3. run `scripts/audit-issue-handoffs --scope docs/issues/<workstream>`;
4. check local Markdown links not covered by the audit when needed;
5. run `git diff --check`; and
6. use the focused validation described by the issue rather than a full suite
   until the change is ready.

See the [Developer Guide](../DEVELOPMENT.md) for the shared development and
measurement workflow.
