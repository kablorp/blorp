# Mono pack kind: current87 landing test-runner report

Verdict: **PASS / APPROVE**, 0 current-attempt failures. The approved foreground batch completed once; no retries, bypasses or budget escalation occurred within this attempt.

## Authority and build

- HEAD `87e312047b4efa1eb320fff4fe22144ac575e66d`; reviewed staged tree `0ebd6d460195d6aff21fb5d58bfb6e53d5196142`; the 46-path feature slice remains frozen through the final guard.
- Source Mono SHA `9b092b9e8a0b93cdeca3f61a049f03a802e72dcb557ad60ce6034a954be67910`; owning-test SHA `087e2db7ed68ee5fc3706bb18fe04f9e169167f0dd55cd6c51ec97925c31965b`.
- Final host status **FRESH**, `87e312047b4e-dirty`, compiled by `dev-0e1598ed616e`, CLI/runtime `-O2`, Apple clang21.0.0, split8, memory diagnostics0. Installed compiler SHA `fc667f362349842bac8018e955c8144c33c704abf7850ddf1c60cb8147c28de0`.
- New bootstrap host executable digest `f0ddd748f51b2f449a46d5bfcf30aeb9c2f2f07468d761514dd408b40ca3ee91` and manifest `ccf4a77ab353a03e81e2868e0635facfb8967877e0974497a79d9d96607bb616` verified.

## Actual outcomes

| Boundary | Passed/failed |
| --- | --- |
| Package | 49/0 |
| Selected Mono + Core sanitizer aggregate | 2596/0 |
| Host full premerge normal corpus | 19291/0 |
| Host sanitizer printed case labels | 5512/0 |
| Host generated-C audit | 233/0 |
| Required Docker full CI normal corpus | 19291/0 |
| Docker generated-C audit | 233/0 |

Counts overlap across gates and are not summed as unique tests. Host sanitizer has 577 printed suite headers, zero failure labels and zero `runtime error:` diagnostics; its actual command exited0. Selected aggregate raw stdout is retained; successful child stdout was cleaned by compiler-check before capture, so no absent child logs are reconstructed or claimed.

| Normal gate | Host | Docker |
| --- | --- | --- |
| Compiler-Blorp | 7046/0 | 7046/0 |
| Compiler-Tools | 260/0 | 260/0 |
| Std-check | 1/0 | 1/0 |
| Runtime | 4781/0 | 4781/0 |
| Leak-check | 1221/0 | 1221/0 |
| Doctests | 1057/0 | 1057/0 |
| CLI-deep | 189/0 | 189/0 |
| LSP | 36/0 | 36/0 |
| Compiler-New | 1064/0 | 1064/0 |
| New-Parity | 3636/0 | 3636/0 |

Host configuration was explicitly `BLORP_TEST_TIMEOUT=60` from its first invocation, with codegen jobs1. Mandatory Docker was a separate `scripts/docker-gate --premerge-gate --platform linux/amd64 -- --no-sanitize` invocation with the host timeout variable absent. Actual SSH route: `blorp-gate`; snapshot `99f10b490df40fc6bb6e0d90a787d5cb5b758df8`, parent87, exact tree0ebd above. Container `10a92778f6c0` used workspace `XWAnYp`. Actual Linux stamp: snapshot `99f10b490df4`, clean, x86_64-unknown-linux-gnu, compiled by `dev-0e1598ed616e`, Ubuntu clang18.1.3, CLI/runtimeO2, split8, memory diagnostics0; split compile jobs2. Docker effective budgets were generic30/runtime60/leak60/compiler360, not host60.

All required host and Docker premerge steps passed. Host Docker was intentionally skipped because the required separate fullCI command followed; Docker nested Docker and sanitizer steps were intentionally skipped by configuration. Both skipped benchmark tooling because its input scope was untouched. Existing internal tooling test skips remain their reported qualification; this report does not claim every possible adjacent route was exercised.

## Resource bridge and final guards

The current new verified bootstrap generated baseline whole C over the unchanged sealed5e baseline payload; fresh Make supplied candidate whole C. Both byte comparisons passed: baseline `4523c2344651b2873d67ed77f3a105c98390afe58c15c17164ebffac0c3eed1f`, candidate `60cdcdd8dbe425e6a42bc012a4764967d1893882e2ee5014557ef83e6c7d2319`. Original matched cost records retain their exact5e revision and measured pairs. This bridge qualifies unchanged compiler body emissions across the new pin; it is **not** a new87 instruction/allocation/executable measurement.

Final post-gate authority reread all **523 sources, 10 headers and 19 auxiliary inputs**, including ignored generated inputs. Only bootstrap.env differs from original authority, at the verified digest above. Source/tests/docs, logical staged entries/tree, original sealed resource records and both original architecture drafts remained unchanged. Expected ignored build outputs were allowed only during declared build steps. Final FRESH and cached diff-check exited0.

[Final result](FINAL_RESULT.json), [commands and raw-log hashes](commands.json), [whole-C bridge](BOOTSTRAP_RESOURCE_BRIDGE.json), [post-gate input authority](POST_GATE_RESOURCE_BRIDGE_AUTHORITY.json), [foreground release](NATIVE_RELEASE.json).

| Recorded command | Exit |
| --- | --- |
| fresh-before | 0 |
| new-bootstrap-path | 0 |
| new-bootstrap-version | 0 |
| baseline-c-only | 0 |
| build-configuration | 0 |
| release-toolchain | 0 |
| package | 0 |
| selected-changed | 0 |
| fresh-after-selected | 0 |
| host-premerge | 0 |
| fresh-after-host | 0 |
| docker-ci | 0 |
| fresh-final | 0 |
| cached-diff-check | 0 |

## Preserved history and closure

The initial pre-gate artifact-path guard STOP, historical0e host PASS followed by the raw-index bookkeeping guard STOP, and historical0e Docker SSH255 infrastructure STOP remain preserved in their original packets. They are not rewritten as PASS. The successful current87 batch separately validates the current bootstrap, source, staged tree and required Docker snapshot.

Foreground session99314 was consumed with exit0. All 14 command children were waited; the owned serial lock was independently observed free after completion. The Docker subprocess returned0 after its remote premerge/docker PASS; no background job was launched by this runner. This guarded batch ended before any subsequent publication metadata integration.
