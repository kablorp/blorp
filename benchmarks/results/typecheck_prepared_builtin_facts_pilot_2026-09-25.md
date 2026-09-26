# Prepared-module builtin facts pilot (2026-09-25)

## Change

`prepared_module_environments` previously called
`typecheck_state_for_prepared_module_scope` once per module. That constructor
rebuilt the same builtin `Env` every time before selecting the module's exact
reserved scope and definition frontier.

The pilot builds `env_with_builtins(ENV_EMPTY)` once within the preparation
operation and borrows it while constructing fresh per-module states. Each
state still owns a fresh inference context, diagnostics, module view, scope,
and definition frontier. Its first local update uses ordinary value semantics;
the shared builtin value is never mutated.

The focused regression first failed because the new constructor did not exist.
It then proved builtin type/function parity with the legacy constructor, exact
reserved scopes and definition frontiers, independent debug policy,
independent local updates and diagnostics, and an unchanged shared input.

## Matched measurement

The baseline is clean `acb64ab629b59b68b7a31edf162bb6427d082a97`.
The candidate is that revision plus the three-file production/test diff. Both
compilers were FRESH Apple clang 21 `-O2` builds made by
`dev-048a5864cd98`. Both workloads used frozen input
`d84db06c2b9432dd5354f0bdccac59ea4fb78fed` and three retired-instruction
samples. Wall time is intentionally not used as evidence.

| Workload and metric | Baseline | Candidate | Delta |
| --- | ---: | ---: | ---: |
| Self typed-frontend allocations | 32,060,276 | 31,182,129 | -878,147 (-2.74%) |
| Self total allocations | 211,857,673 | 210,979,526 | -878,147 (-0.41%) |
| Self minimum retired instructions | 170,129,413,806 | 169,237,783,422 | -0.52% |
| Self peak RSS bytes | 2,135,457,792 | 2,127,347,712 | -0.38% |
| Small typed-frontend allocations | 918,561 | 849,047 | -69,514 (-7.57%) |
| Small total allocations | 1,615,851 | 1,546,337 | -69,514 (-4.30%) |
| Small minimum retired instructions | 1,346,493,024 | 1,287,942,195 | -4.35% |
| Small peak RSS bytes | 37,126,144 | 35,553,280 | -4.24% |

Every candidate self-compile instruction sample was below every baseline
sample: baseline `[170129413806, 170181083155, 170264363446]`, candidate
`[169409932774, 169427970977, 169237783422]`. The small samples were baseline
`[1346493024, 1346754062, 1346530914]`, candidate
`[1288768706, 1287942195, 1288087110]`.

Generated C was byte-identical. Self output was 83,573,590 bytes with SHA-256
`85e32afe36bc34e910d8d26a6230862d03673671e75dc5dca8717d73bf3b8497`;
small output was 42,475 bytes with SHA-256
`b14e002cf83bd89ace4c862a0cf0137f36b21cde683a993671641f0c2e3b096a`.
The baseline compiler SHA-256 was
`442761fc66bbebc814f4d2564a599599d0ceef30005dff54aa3924eb237fb51e`;
the measured candidate was
`2d40dfc34794f91fd94934e6d7114f5d90f2da417c629f9d39ffd76b54b81c6e`.

Raw JSON is retained temporarily at
`/tmp/prepared-module-pilot-parent.json`,
`/tmp/prepared-module-pilot.json`,
`/tmp/prepared-module-pilot-parent-small.json`, and
`/tmp/prepared-module-pilot-small.json`; their SHA-256 values are
`e427904615a84cb0f879f693840d566c96bd489e95ee15f354e334ae82ba3520`,
`2698f2d6942756e508ebd0fc4675e6fb49c43ff789f935d0b33635484aac190f`,
`fbc7f6e2e06c335851028953b4beddae5c49ee40c0a9d48b11d919d1d66a5551`,
and `7336c5eba7b6cef052ac3187eee7f94c70489372ab3ce53d11ea6d1dae4d164d`.

## Validation

The owning global-header suite passed 30/30. The selected compiler check
passed 294/294 across eleven suites and the typecheck-body-metrics contract.
The independent FRESH `-O2` `compiler-blorp` gate passed 5,115/5,115; its log
is `/tmp/blorp-prepared-module-pilot-gates/compiler-blorp.log`.
The result demonstrates that immutable graph-wide facts can be constructed
once and borrowed by per-module builders without changing semantics, and that
this boundary is large enough to matter on self-compilation.
