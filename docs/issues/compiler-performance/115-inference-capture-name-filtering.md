# Remove Redundant Inference Capture-Name Deduplication

**Status:** Proposed; caller-contract proof required before implementation

**Current state:** Five capture/resource filters call `name_list_add_unique`
or `contains` while iterating inputs that current private callers appear to
supply in ordered-unique form: `mutable_capture_names`,
`resource_capability_capture_names`, `scoped_resource_capture_names`,
`scoped_resource_derived_capture_names`, and `unavailable_parent_resource_names`.
**Next action:** Prove and test the ordered-unique producer contract at every
caller, then replace redundant admission with direct append.
**Read first:** The functions and call sites in
`blorp/src/compiler/stage_06_typecheck/infer.brp` and the capture/resource cases
in `blorp/test/compiler/stage_06_typecheck/test_infer.brp`.
**Fast loop:** Run the inference suite and a proposed capture-filter fixture
that deliberately includes aliases, globals, and repeated dependency paths.
**Decision:** Ask for guidance if any caller can supply duplicates; do not rely
on an undocumented assumption or silently change that producer.

## Objective

Make these filters linear by appending qualifying names directly, while
representing the input uniqueness contract explicitly in tests or a precise
private type/boundary.

## Context And Proposed Change

Current shape:

```blorp
for name in refs:
	if qualifies(name):
		result = name_list_add_unique(result, name)
```

Candidate after proving `refs` is ordered unique:

```blorp
for name in refs:
	if qualifies(name):
		result = result.append(name)
```

Prefer a named private producer/helper that documents ordered uniqueness over
a comment at five consumers. If a producer can emit duplicates, fix or
explicitly normalize that owner first and retain consumer safety until then.

## Invariants And Scope

- Preserve free-reference order and the first diagnostic name.
- Preserve local/global lookup precedence and mutable-variable detection.
- A name may appear in both capability result lists when its type has both
  capabilities.
- Preserve scoped resource owner/unavailable behavior.
- Cover two syntax paths that reach the same dependency, shadowed locals,
  accepted globals, aliases, and empty inputs.
- Do not redesign free-variable analysis, resource typing, or diagnostics.

## Feedback Loop And Tests

Add counters around the production filters: input names, qualifying names,
duplicate inputs, membership comparisons, and output checksum. The proof test
must fail if a producer emits a duplicate. A proposed wide fixture should vary
references and qualifying ratio with setup outside the window.

```bash
bin/blorp test --timeout 180 blorp/test/compiler/stage_06_typecheck/test_infer.brp
scripts/compiler-check --stage typecheck
scripts/test compiler-blorp
```

## Acceptance And Rejection

Accept only when every caller is proven ordered-unique, redundant comparisons
fall to zero, a wide production-path filter improves instructions or
allocations by at least 10%, and the small path remains within 2%. Exact
capture/resource name lists and diagnostics must match.

Reject or narrow the issue if even one caller legitimately supplies
duplicates, if enforcing uniqueness merely moves equal work upstream, or if
direct append makes an illegal duplicate observable.
