# Independent dictionary reader fail-before report

Exact base `2ee201fb5cb74e8a7b4f3d068a143d8d71dd2bad`, parent checkout. FRESH O2 before and after; repository `bin/blorp` SHA256 `151ef0ac264ffeab97a521c39d02f96a7b627ba0019979ff21c97557db5b2cd8` unchanged. Production/stdlib/allowlist diff empty. Corrected owning test file `f694c647ec8d1bfb9e8493418bce4059c4124f92feab7369ed9ed8922ffa4480`; tests-only patch `3b046f9061b77a2b7cdaa721e3a311eb4a1ed686fdd89647467e6bb42737c7f9`. The build stamp accurately says dirty because unrelated docs and tests exist; compiler-source authority is exact base.

| Command/boundary | Actual result |
| --- | --- |
| Owning collection suite | 35 total: 32 pass, exactly 3 intended new failures; exit 1 |
| `dict_get_or_fast_path.brp` C capture | exit 0; 14,555 bytes; SHA256 `9a563e6059251d228f301d4239360e53b22c6b21a8f458e8d9bfa3f3ae1d126b` |
| `dict_opaque_alias_key.brp` C capture | exit 0; 14,946 bytes; SHA256 `16b0e9781c195dcefdfa144044e67988bbb25e4016422a6fe62538e8080121d5` |
| Retained dictionary getter layouts scratch C | exit 0; 72,170 bytes; SHA256 `a18e191a0703084c8031259be124d424537efff564824d73ff5bd702c09b1559` |

| Test failure | First error | Classification |
| --- | --- | --- |
| unknown dict get suffix stays unboxed | returned False | intended new admission regression, exact base |
| dict get suffix requires matching Option payload | returned False | intended new admission regression, exact base |
| typed dict get wrong arity stays unboxed | returned False | intended new admission regression, exact base |

The existing already-specialized getter/primitive-key and nullable managed Option controls pass, as do the new Int128 map-evaluation/fresh-key-ownership control and primitive/alias/generic positive controls. No compile or setup failure occurred in the successful TDD attempt. All four command packets report `source_changed_during_run=false`; batch source and binary guards match before/after.

The initial attempt had 31 passes and 4 failures because the new positive control incorrectly used nonallocating FloatBox while expecting a fresh-box owner. The worker corrected only that test premise to Int128Box, consistent with `specialize_layout.brp:473–478`; this was not a compiler fix. Original raw packet/pins are retained in the parent scratch directory. `FIRST_ATTEMPT_PRESERVATION.json` records an exact-hash original-content source sidecar reconstructed afterward by reversing that bounded correction, not a pre-edit-copy claim.

The C captures used `compile --no-format --no-embed-runtime -o <scratch> <input>` and did not execute runtime behavior. The layouts oracle copies 12 retained dictionary tests into runnable main: primitive widths/Option alias, managed String, and Int128/range/enum/record payloads. Generated C inspected: typed Int/Float/Bool/Char/Int32/UInt8 getters; nullable managed getter; generic raw lookup for Int128 and enum; get-or uses the direct probe. The opaque-key fixture is a hash/key-layout control, not getter coverage. Full input/C hashes and exact arguments are in `tdd-results.json`, `tdd-commands.json` and packet metadata. Before/after FRESH logs are retained.

Invocation: owned foreground `native_slot_serial.py --wait-seconds 600 -- python3 .../retry-int128/tdd_batch.py`; native session29747 completed exit0. Owned slot released explicitly; no jobs remain. No baseline full gates, candidate gates, resource measurements, source edits, commits or speed claims. Candidate correctness/resource acceptance remains pending.
