# Dimension kind reader fail-before qualification

PASS: exact baseline demonstrates the seven intended functional failures. No production changes, build or retry were performed.

- Base revision: `8fe717e28d461088258f7744db77f2d9c8d02a0f`; compiler production diff empty before and after.
- Repository binary: `e31954fb25891ad7f6eea758a58ce8352ec3acf5cea836d3361cd6a13f241ad2`. Build status FRESH before/after, CLI and runtime `-O2`; stamp `8fe717e28d46-dirty` accurately includes tests-only checkout changes.
- Test SHA256: `746b60e7407aaee75ffa327be6fa21f9112e722b5979b39256e6ebcaa1cd5fb2`; frozen actual source is `test_dim_solver.frozen.brp`.
- Production inventory SHA256: `d29814ca1dec4e11568b898162c54c6b08b12d71310637cd9eec24a401a350d0` (tracked `blorp/src` and `standard_library/src`, individual hashes in before/after JSON).
- Result: **26 total, 19 PASS, 7 FAIL**, suite exit1. Existing18 controls and one new opaque-factor positive control pass.
- Source/test/binary fingerprints unchanged (`source_changed=false`); production diffs empty. No compile or setup failure occurred.
- Foreground session10309 consumed with runner exit0; the recorded suite exit is1. The wrapper returned, native slot is released, and no owned child remains.

Exact command:

```sh
python3 /tmp/blorp-identity-wave-7ab679600/native_slot_serial.py --cwd <worktree:reader-cuts> --wait-seconds 600 -- bin/blorp test --timeout 180 blorp/test/test_compiler/test_stage_06_typecheck/test_type_system/test_dim_solver.brp
```

The runner reports failed Bool controls without more granular assertion diagnostics. These are functional regression results, not inferred compilation failures. The test line is in the owning suite.

| Test | Line | First actual failure | Classification | Repeat |
| --- | --- | --- | --- | --- |
| dimension kind solves without sigil | 480 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |
| ordinary kind does not solve from sigil | 490 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |
| same spelling kinds bind without cancelling | 501 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |
| meta binding preserves no-sigil dimension kind | 522 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |
| meta binding preserves sigil-looking ordinary kind | 539 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |
| named isolation keeps ordinary remainder | 556 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |
| mixed candidates prefer meta and preserve kinds | 573 | Bool control returned false; no compile/setup diagnostic | Intended new regression fails on base | Not repeated |

The owning suite ran once as authorized. Final candidate types-stage integration and broad compiler validation remain pending separate GO; no baseline broad gates were repeated. Raw output is `raw.log`; exact command/timestamps, FRESH logs, production diffs and before/after individual hashes are retained beside this report.
