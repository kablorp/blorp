# Callable-header index construction

Date: 2026-09-13. Former issue: callable-header index copies (#95).
Baseline source: `eb6893ea`. Accepted optimization: `b801b8ef` on its worker
branch (integrated on `main` as `cbd4129a`).

The old `append_callable_header` updated a dictionary and growing callable
list for every accepted header. The new builder accumulates accepted headers,
then constructs the definition-ID index once. The direct collection-copy
counters below were collected in a profile window around header-graph build,
with one module, no parameters, no dimension constraints, and no errors.

| Headers | Old dict copies | Old dict entries copied | New dict copies | New dict entries copied | Old list entries copied | New list entries copied |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 1,025 | 523,776 | 1 | 0 | 524,796 | 2,040 |
| 2,048 | 2,049 | 2,096,128 | 1 | 0 | 2,098,172 | 4,088 |
| 4,096 | 4,097 | 8,386,560 | 1 | 0 | 8,390,652 | 8,184 |

The old samples used the then-current profile driver, with a single internal
iteration:

```bash
bin/blorp run --profile \
  blorp/benchmark/compiler/compiler_callable_header_graph_profile.brp -- \
  1 1 <headers> 0 0 0
```

The final retained driver takes `modules headers_per_module
parameters_per_header dimension_constraints_per_header mixed_error_interval`;
its equivalent invocation is:

```bash
bin/blorp run --profile --timeout 60 --no-format \
  blorp/benchmark/compiler/compiler_callable_header_graph_profile.brp -- \
  1 <headers> 0 0 0
```

It builds the fixture through trait topology before timing, calls exactly one
production `callable_header_graph_build` inside the timed/profile window, and
validates counts, errors, ID lookups, and checksum afterward. Representative
new single-call elapsed samples for 1,024/2,048/4,096 headers were
14,344/28,697/57,695 microseconds; allocations were
28,696/57,370/114,716. All reported `workload_valid=True`. These are not
same-boundary old/new latency medians: old elapsed samples were taken before
the final benchmark-boundary cleanup. The directly observed elimination of
quadratic copied-entry work is the stronger comparison.

Verification on the worker branch included `make`, the callable-header and
profiling suites, artifact-writer and host-C suites, `scripts/compiler-check
--changed` (including leak), and `scripts/test compiler-blorp-sanitize`
(3,800/3,800). The final driver passed a typecheck and valid/mixed-error
profile smokes. The final simplification removed the internal iteration
control; no fresh 1,024/2,048/4,096 timing matrix was run afterward.
