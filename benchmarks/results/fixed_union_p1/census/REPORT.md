# P0 migration census — review packet

Read-only candidate audit against `133eaf73a63830522b659ab6a2da65f9f2963711`.
Candidate: `<worktree:fixed-union-frontend>`.
No source conversion, compiled job, roadmap/packet edit, or commit performed.

## Reproduce and coverage

This is the pre-documentation-copy snapshot, not a fresh census of subsequent
docs/evidence additions; the recorded source-content hash belongs to that snapshot.
The script is a snapshot helper, not a supported repository tool. Run
`python3 census.py /path/to/blorp` from a scratch copy of this census directory;
it regenerates inventories there against the recorded baseline. Its default
assumes this directory remains under `benchmarks/results/fixed_union_p1/census`.
The file universe is `git ls-files --cached --others --exclude-standard`; staged
and untracked candidate fixtures are included. Baseline uses `git archive`.
The script excludes ignored outputs, binary/non-UTF8 files, and historical
`benchmarks/results/` evidence. Blorp comments/docstrings and quoted/pipe source
strings are separated from code; this is lexical inventory, not a typechecked
dependency graph. Interpolation expressions are not separately parsed.

Full path/line/name/owner/action inventory: `declarations.tsv`; all retained
references and structured inventory/controls: `inventory.json`. Reproduction also
emits inventory.tsv and summary JSON; these duplicates are not retained here.
The retained declarations.tsv projects all 499 declaration records onto every
field except multiline `text`; full text remains in unchanged inventory.json.
Decoded TSV fields are checked against the corresponding JSON records exactly.
Owner/action labels are migration-review routing, not proof of safe conversion.

## Counts

| Boundary | Baseline | Candidate |
| --- | ---: | ---: |
| Exact lexical `.brp` source declarations, entire inventory | 425 | 429 |
| Raw anchored enum lines, same inventory | 426 | 430 |
| Exact declarations, prior packet roots (`blorp/src`, all `standard_library`, `pkg`, `examples`) | 365 | 368 |
| Raw anchored lines, those roots | 366 | 369 |

The raw-line excess is prose at
`blorp/src/compiler/stage_06_typecheck/type_system/builtins.brp:1110`:
“enum match makes every installed trait choose a layer…”. Do not label it a
declaration. The packet-root count includes one standard-library test enum;
strict `blorp/src` + `standard_library/src` is 364 → 367.
Candidate source declarations: compiler/library/tool sources 358,
Blorp tests 50, Blorp benchmarks 10, standard-library sources 9,
standard-library tests 1, editor coverage 1. Existing declarations are retained;
the additions are three source-form metadata enums and one formatter fixture enum.

Embedded Blorp declaration headers: 50 (32 positive, 16 intentional
rejected/unsupported inputs, one source-scanner header, one formatter output).
Documentation enum examples: 20. Native constructs, excluded from source
migration: 84 C enum constructs, one Python Enum, one embedded native-C enum
in Python. Native mirrored headers are counted individually, not deduplicated.
Another 201 embedded enum text/wire rows retain generator fragments or protocol
strings that are not complete anchored declarations. All classifications and
owner totals are retained in JSON rather than inferred from these headline counts.

## Native/manual exceptions — must not mechanically assume union ABI

| Declaration/contract | Authority | Migration requirement |
| --- | --- | --- |
| Bool | `standard_library/src/bool.brp:8`; runtime C Boolean bridge | C `int`, True=1, False=0; preserve or explicitly adapt |
| MemoryCounter | `standard_library/src/memory.brp:58`; `blorp/src/lib/runtime/native/runtime.c:39308` | long selector tags 0..15 |
| DirectoryEntryKind / DirectoryEntry.kind | `standard_library/src/fs.brp:55,68`; runtime directory-entry code | long field tags 0..4 |
| IpFamily | `standard_library/src/net/tcp.brp:29,336`; `runtime.c:14887,14912,15001` | long family, IPv4=0 / IPv6=1, direct builtin arguments |
| User enum foreign record field | `blorp/test/compiler/pipeline/codegen_audit/should_pass/compiler_record_layout.brp` and its `_ffi.h` | existing sizeof(long) and tag=1 contract |

ProcessStream/ProcessGroup/Signal in `standard_library/src/process.brp` already
use explicit raw integer/platform signal adapters; retain these as adapter
precedent, not an automatic scalar-native admission rule. LogLevel/Waveform have
no observed direct native scalar boundary in this bounded audit. No exhaustive
foreign-call dependency closure was established; the inventory is not an ABI
acceptance gate.

Explicit enum Equatable implementations found with same-file declaration identity:
`standard_library/src/bool.brp:41` and
`blorp/src/lib/build_artifact.brp:78` (BuildNativeFeature). No explicit Hashable
implementation for either was found. Settled P2a policy: explicit Equatable without
explicit Hashable gets no automatic tag Hash; supplied trait laws remain the
implementation's responsibility. Bool needs real shared canonical hashing and
regressions; BuildNativeFeature removes redundant Eq or supplies matching Hash,
not a name exception. Name-only matching incorrectly joins a different
union Shape and was excluded; this audit does not resolve imports semantically.

## Other coordinated migration owners

- Scanner: `blorp/test/compiler_new/stage_01_discovery/parse/test_parser_fixtures.brp`
  PLAIN_CODES_HEADER must change together with diagnostic_code.brp; otherwise the
  fixture coverage census silently loses cases.
- Generators: `benchmarks/blorp/compiler_discovery_record_allocations.brp`,
  discovery allocation-budget/load-budget source strings, and
  `blorp/test/compiler_new/support/syntax_samples.brp` minted enum helpers.
  Update their schemas/assertions and `support/declarations_dump.brp` deliberately.
- Keyword/parser negatives: empty parentheses/payload enum rejection fixtures,
  reserved-name diagnostics, tree-parser/preview unsupported headers, both lexers.
  The 13 source enums under should_fail are not automatically removed-syntax
  tests: many are valid declarations in intentionally ill-typed programs.
- Formatter/JSON/editor: LegacyEnum form, legacy_enum wire values, retained enum
  golden fixture, keyword/scope expectations; migrate source form and expectations
  together, not native enum constructs or unrelated enumerate identifiers.
- Imports/CTFE/Eq/Hash: test_imports, type-header graph/canonical constructor
  identity, enum constructor collision, stage_07_ctfe and pipeline CTFE helpers,
  standard_library/test/dict/test_enum_keys, runtime union equality/hashable keys,
  and Core synthesized collection hashing all need behavior gates.

## Future-invalid fixed examples and stop boundary

Inventory records 32 source/embedded fixed headers, 18 with direct String text;
this includes positive synonym examples and intentionally malformed parser input.
Exact locations are `fixed_direct_string_locations` in inventory.json.
Runtime `test_fixed_union_synonym_ownership.brp` additionally instantiates
FixedGeneric[Label] where Label contains String and FixedGeneric[String] using
the empty variant: both become inadmissible under final P5, even unused payloads.
GUIDE's fixed Response and the coordinator roadmap's proposed String example also
require explicit future-invalid treatment. Current syntax synonym evidence is
not a checked fixed contract or no-allocation/unboxed/native-layout promise.

No existing enum migration script was found; compiler-identity-census is an
identity ratchet, not a converter. A bounded future tool should consume a reviewed
path/line/declaration manifest, replace lexical source headers and separately
decoded embedded sources, dry-run deterministic diffs, and exclude native/prose/
negative fixtures by explicit classification. Scanner strings, schemas, imports,
ABI adapters and Eq/Hash policy remain manual owner tasks with dedicated gates.
Dynamic generator fragments and imported trait identity remain unresolved for
automatic conversion; they are retained for manual review, not silently accepted.

This finishes a classified census artifact, not P0/P1 release acceptance.
