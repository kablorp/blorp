# Compiler Complexity Candidates Ranked by Calls

## Measurement contract

This screen joins post-DCE structural complexity findings from
`scripts/complexity-check` with a call-count profile of the compiler compiling
`blorp/src/main.brp` through C emission. It ranks exposure; it does not measure
self time or prove that a flagged operation dominates its function.

- Revision: `cf0a8ff064a66eb679f51ce12e25f90d5beef043`
- Analyzer at that revision: `scripts/complexity-check`, SHA-256
  `de95b39c06847b4018b4cec07c8228b3adcc461f88f7b20939011eeb3eab276b`
- Static scope: modules under `blorp/src/compiler/`
- Static findings: 663 sites in 286 functions
- Dynamic workload: `compile --no-format -o OUTPUT blorp/src/main.brp`
- Candidate functions observed: 220; unobserved: 66
- Profiled modules: the 75 compiler modules containing a static finding
- Selected functions: 5,981; observed selected functions: 4,487
- Observed selected calls: 463,636,398
- Measured instrumented wall time: 52.15 seconds
- Emitted C: 92,264,744 bytes
- Instrumented compiler SHA-256:
  `eb81352f4259e8686d2e5a275230e72edaf1b0ffd1a292e93862f5c1e99395b6`
- Static report SHA-256:
  `a0d70d832993daaa2742a2099c338ff0a7e90b884bd523cadfbb45daec56f29a`
- Call report SHA-256:
  `129d81124044273baf3114a5e56ffb993b10fbeb443343d2449e16db6e3098f3`

The profiled compiler and repository compiler emitted byte-identical C with
SHA-256
`e1f95b491e7ce8eb1be1652b2281d29686dbde970811238333d0e1804b5edf0e`.
All invalid-ID, unmatched-end, out-of-order-end, metadata-failure,
stack-failure, and abandoned-frame counters were zero. The profiled compiler
was built at `-O0`, so its elapsed time must not be compared with the ordinary
compiler as an optimization result.

The reproducible static half is:

```bash
bin/blorp compile --no-format \
  --dump-core-after=dce \
  --stop-after=dce \
  --dump-core-file=/tmp/blorp-complexity-dce.core \
  blorp/src/main.brp

scripts/complexity-check \
  --core-file /tmp/blorp-complexity-dce.core \
  --module-prefix blorp/src/compiler/ \
  --json > /tmp/blorp-complexity-candidates.json
```

The exact dynamic half derives the 75 module selectors from that static report,
emits the instrumented compiler, builds it without host optimization, and
captures the call report from stderr:

```zsh
profile_args=()
while IFS= read -r module; do
  profile_args+=(--profile-module "$module")
done < <(
  jq -r '.findings[].module' /tmp/blorp-complexity-candidates.json |
    LC_ALL=C sort -u
)

bin/blorp compile --no-format --profile-mode calls \
  "${profile_args[@]}" \
  -o /tmp/blorp-profiled-compiler.c \
  blorp/src/main.brp

cc -O0 -fwrapv -pipe -w -DBLORP_COMPILER_RUNTIME_SOURCES=1 \
  -Iblorp/src/compiler/stage_01_generated_inputs \
  -Iblorp/src/compiler/stage_04_modules \
  -Iblorp/src/compiler/stage_06_typecheck/graph \
  -Iblorp/src -Iblorp/src/lib -Iblorp/src/lsp/server -Iblorp/src/test \
  /tmp/blorp-profiled-compiler.c \
  blorp/build/_build/blorp-cli/runtime_sources.c \
  blorp/src/lsp/server/native_runtime.c \
  -lm -lpthread \
  -o /tmp/blorp-profiled-compiler

/usr/bin/time -p /tmp/blorp-profiled-compiler compile --no-format \
  -o /tmp/blorp-self-emitted.c \
  blorp/src/main.brp \
  > /tmp/blorp-self-profile.stdout \
  2> /tmp/blorp-self-profile.calls
```

Do not shorten the module selectors to `compiler/...`: the current CLI expects
workspace-relative logical paths such as
`blorp/src/compiler/stage_06_typecheck/infer`. The raw inputs for this screen
were `/tmp/blorp-complexity-candidates.json` and
`/tmp/blorp-self-profile.calls`; their hashes are recorded above. Recreate
those files at the pinned revision before re-ranking because `/tmp` is not a
durable artifact store.

This aggregation joins each static candidate's unmangled function name to the
sum of its selected module-local profile symbols and orders by calls:

```bash
python3 - <<'PY'
import collections
import json
import re

with open("/tmp/blorp-complexity-candidates.json") as source:
    findings = json.load(source)["findings"]

calls = collections.Counter()
with open("/tmp/blorp-self-profile.calls") as source:
    for line in source:
        match = re.match(r"^(\S+)\s+(\S+)\s+(\d+)\s*$", line)
        if match and match.group(1).startswith("blorp_src_"):
            calls[match.group(1)] += int(match.group(3))

candidate_sites = collections.defaultdict(list)
for finding in findings:
    candidate_sites[finding["function"]].append(finding)

for qualified_name, sites in sorted(
    candidate_sites.items(), key=lambda item: (-calls[item[0]], item[0])
):
    short_name = qualified_name.rsplit("__", 1)[-1]
    print(f"{calls[qualified_name]}\t{len(sites)}\t{qualified_name}\t{short_name}")
PY
```

Verify output identity against the ordinary compiler separately:

```bash
/usr/bin/time -p bin/blorp compile --no-format \
  -o /tmp/blorp-self-control.c \
  blorp/src/main.brp
cmp /tmp/blorp-self-emitted.c /tmp/blorp-self-control.c
sha256sum /tmp/blorp-self-emitted.c /tmp/blorp-self-control.c
```

## Screened candidates

These are ordered by invocation count in the one self-compile. Functions with
the same count were both measured, not inferred from one another.

| Rank | Calls | Function | Static signal |
| ---: | ---: | --- | --- |
| 1 | 2,510,797 | `resolve_types` | `O(types * seen_aliases)` |
| 2 | 1,397,874 | `resolve_alias_list` | `O(types * seen)` |
| 3 | 985,345 | `analyze_current_behavior_expr` | repeated result-list concatenation while visiting children |
| 6 | 331,640 | `resolve_var_dims_type_list` | growing result plus concatenation inside `types` traversal |
| 9 | 228,771 | `resolve_type_meta_list` | `O(types * seen)` |
| 10 | 224,557 | `env_symbols_named` | repeated result concatenation across scopes |
| 11 | 210,048 | `append_resource_refs` | membership scan of a growing ordered result |
| 12 | 160,378 | `call_args_transfer_cleanup_pop_statements` | `O(args * consumed_args)` |
| 13 | 156,548 | `finalize_exprs` | repeated diagnostic-list concatenation |
| 14 | 107,722 | `types_contain_parameter` | `O(types * type_params)` |
| 15 | 101,735 | `implementation_pattern_matches_with` | nested bound and obligation traversal |
| 16 | 101,279 | `clone_expr` | rename-list growth across nested binders |
| 17 | 87,211 | `rewrite_raw_match_case` | `concat(...).unique()` |
| 18 | 87,020 | `consumed_call_vars_before_suspension` | `O(args * indices)` |
| 19 | 87,020 | `direct_consumed_call_vars` | `O(args * indices)` |
| 20 | 86,692 | `call_signature` | membership scans of outer and growing used-name lists |

Ranks 4, 5, 7, and 8 were removed from the compiler-refactor shortlist.
`c_local_name`, `split_canonical_module_type_name`, `split_var_callable_id`,
and `strip_mono_suffix` search for named constant strings. Their actual cost is
linear in the input name. Propagating fixed-size global constants is a future
analyzer precision improvement, not a reason to refactor those four compiler
functions.

## Interpretation rules

- Recount after any earlier issue changes a shared caller or representation.
- A large call count is an admission signal, not an acceptance result.
- Before replacing a short list with `Set` or `Dict`, measure cardinality,
  allocations, and retired instructions. COW updates can cost more than a small
  linear scan.
- Preserve source order, first-match behavior, shadowing, diagnostic order,
  cycle detection, and generated-C identity where applicable.
- Prefer deterministic visits, comparisons, copied elements, allocations, and
  semantic checksums over one elapsed-time sample.
- A negative experiment is a valid close: record the rejected representation
  and remove the issue when the evidence is durable.
