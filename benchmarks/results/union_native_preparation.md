# User union native adapter preparation

This fixture-only preparation separates user language values from external scalar
contracts. It implements no production ABI authority, union representation change,
foreign admission change, runtime layout change, or enum conversion.

## Scope and oracle

`foreign_default_enum_param.brp` now typechecks an exhaustive Color encoder at an
Int foreign parameter. `compiler_record_layout.brp` uses Int for its foreign state
field and identity call, with exhaustive LayoutState encode/decode adapters. The
native field assertion remains `sizeof(long)` and the native value check remains
`state == 1 && count == 42`. Existing packed language enum/record checks remain.

`user_union_wire_adapter.brp` deliberately declares managed WireBlue before
WireRed, while its explicit external contract is Red=0, Blue=1. Independent C
checks pin those numbers and C long argument widths. Source matches verify known
inbound constructors, reject -1 and 2 as None, and roundtrip a runtime-selected
value. LayoutState additionally rejects -1 and 3. No decoder manufactures an
invalid variant or substitutes a fallback language value.

The existing codegen-audit directory owner discovers the new companion fixture;
it is an input with a main function, not a new TestSuite requiring registration.

## Unchanged baseline

Source: `dde591ecd0ba7029f98ef6bfc6f3604b5451d2a5`, clean checkout. Compiler built
with `BLORP_CLI_C_OPTIMIZATION=-O2 make`, confirmed FRESH, CLI/runtime O2,
8-way split, Apple clang 21.0.0, aarch64-apple-darwin.
Compiler SHA-256: `70b25e74e68d7480190a0fdcef01085add1136c76b1d0fab56d65427517ca6b3`.

Commands:

```sh
bin/blorp check --no-format blorp/test/compiler/stage_06_typecheck/fixtures/typecheck/should_pass/foreign_default_enum_param.brp
BLORP_RECORD_LAYOUT_SKIP_BUILD=1 BLORP_RECORD_LAYOUT_KEEP_STAGE=1 benchmarks/compiler_record_layout
```

Both exit successfully. The retained layout oracle executes at O0 and O2. Both
report foreign state/count widths 8 bytes, foreign state record size 32 bytes,
and unchanged compact language state field widths 1 byte. Generated C contains
`long state`, `long count`, and a long foreign identity result. Its SHA-256 is
`19a55fca1207ee72e2bc437e362a3c262b5325b9b6dac74e349c75724a5c4ab0`.

Raw baseline logs: `/tmp/union-native-baseline-build.log`,
`/tmp/union-native-baseline-foreign.log`, `/tmp/union-native-baseline-layout.log`.
Retained C/Core/probes:
`$TMPDIR/blorp-record-layout.wYoEZL`.

## Candidate validation

The same compiler remains FRESH (fixture-only edits are outside compiler build
inputs), with the same SHA-256 and toolchain as baseline. The exact foreign
fixture check passes. The retained layout oracle passes at O0 and O2 with the
same eight record sizes/alignments/field widths as baseline. Candidate generated
C SHA-256 is `e1609b42cbf339bf93ffd5b3b459bf8219f5797da2e6dda9b03f105e1c702b92`;
C/Core/probes are retained at
`$TMPDIR/blorp-record-layout.s3EBIT`.

The companion runs at release O2 with `--leak-check` in both runtime-selected
branches: no args yields 3 allocations/3 releases/0 leaked; `-- blue` yields
4 allocations/4 releases/0 leaked. These are observed program totals, not an
allocation-free adapter claim. Its non-embedded generated C passes the audit's
warning sweep and shows a managed tagged union with long native inputs/results.
Companion C is `/tmp/union-native-companion.c`, SHA-256
`e1eb7bfbc085ac3d56778b343897fa1f524ebf14211e6a78152d25b7037896fd`.

Actual companion commands, run serially from the worktree root:

```sh
bin/blorp run --release --leak-check --no-format blorp/test/compiler/pipeline/codegen_audit/should_pass/user_union_wire_adapter.brp > /tmp/union-native-candidate-union-red-final.log 2>&1
bin/blorp run --release --leak-check --no-format blorp/test/compiler/pipeline/codegen_audit/should_pass/user_union_wire_adapter.brp -- blue > /tmp/union-native-candidate-union-blue.log 2>&1
bin/blorp compile --no-format --no-embed-runtime -o /tmp/union-native-companion.c blorp/test/compiler/pipeline/codegen_audit/should_pass/user_union_wire_adapter.brp > /tmp/union-native-companion-compile.log 2>&1 && clang -fsyntax-only -Werror=unsequenced -Werror=incompatible-pointer-types -Werror=implicitly-unsigned-literal -Wno-parentheses-equality -I blorp/test/compiler/pipeline/codegen_audit/should_pass -include blorp/src/lib/runtime/native/runtime_decl.c /tmp/union-native-companion.c > /tmp/union-native-companion-warning.log 2>&1
```

Final evidence logs:

- `/tmp/union-native-candidate-foreign.log`
- `/tmp/union-native-candidate-layout.log`
- `/tmp/union-native-candidate-union-red-final.log`
- `/tmp/union-native-candidate-union-blue.log`
- `/tmp/union-native-companion-compile.log`
- `/tmp/union-native-companion-warning.log`
- `/tmp/union-native-candidate-full-audit-attempt1.log`

Full serial codegen audit (`run_codegen_audit.sh bin/blorp --jobs 1`) passes:
229 passed, 0 failed. Independent code review is complete: zero blockers and zero
should-fixes; the one nit was fixed. Independent runner artifacts at
`/tmp/union-native-independent.gIPE6O` retain one passing foreign fixture check,
passing O0/O2 layout oracles, two runtime branches with zero leaks, passing
generated-C warning checks, and the full codegen audit (229 passed, 0 failed).
The six-file preparation is accepted locally as `66944f3e9`; its integration
status is recorded in the [progress checkpoint](union_progress_checkpoint.md).
These independent results retain their original `dde591ecd` fixture epoch;
they are not new measurements of the later integration commit. No performance or
allocation reduction is claimed; these source adapters are preparation. Stage 2
is not required for this fixture-only slice; no emitter or runtime source changed.

### Oracle/setup repairs and evidence limitation

The initial retained-layout attempt exposed stale `__t9` temporary-name
expectations. The fixture now pins a long result specifically at the native wire
identity call, while retaining the independent argument and field assertions.
The next attempt exposed an over-strict expression-width oracle: bare C int
literals can legitimately convert at a declared long parameter, but the macro's
`sizeof(value)` assertion runs before that conversion. The assertions remain
unchanged; layout tests use encoder-produced long values, and the companion
decodes independently supplied native long values for known and unknown tags.
Neither failure establishes a compiler ABI defect.

The original layout failure log was overwritten during iteration. The failed
generated C remains untouched at
`$TMPDIR/blorp-record-layout.xL918Y/compiler_record_layout.c`,
SHA-256 `a5ddac56d2d237b38aeadff2f41991a67c0ab03c8b4aa97a13cd9e2ac47e2b60`.
`/tmp/union-native-macro-oracle-supplementary.log` is a new syntax-check
reproduction, not recovery of the original log. It uses current header SHA-256
`7bba842f0e7d7c88cf3da5da161fd6419c3601352de064133fa3e41e3d575d77` and
`/usr/bin/clang` SHA-256
`5b1ddb7e9c11b87a034fc88b212e8ac243cfe2b4db696d767aa44c79595fc09a`.
The companion's initial inline-if parser error is separately retained at
`/tmp/union-native-candidate-union-red.log`; its source now uses indented blocks.

## Remaining canonical ABI readiness

This read-only matrix describes source at the baseline revision, not implemented
behavior for the proposed common union model.

| Boundary | Current authority and contract | Remaining conversion obligation |
| --- | --- | --- |
| Bool | Exact standard-library `DeclaredAbiBool` identity; C int; True=1, False=0 | Preserve identity, widths, and explicit constructor mapping through common union lowering and emission; declaration order cannot grant ABI. |
| MemoryCounter | Exhaustive Int adapter already landed; native long selectors 0..15 | Preserve existing allocation/ownership oracle; this task does not redo it. |
| DirectoryEntry.kind | Native pointee field is long, File=0, Directory=1, Symlink=2, Other=3, Unknown=4; destructor releases only managed name | Atomic field/layout/destructor proof and single-entry Option, batch List, and stream ownership gates before a managed kind conversion. Outer DeclaredAbiDirectoryEntry alone does not validate the nested kind. |
| IpFamily | Five builtins receive long family; IPv4=0, IPv6=1, returning TcpListener/TcpStream resources | Explicit declared scalar authority or another reviewed atomic design. Ordinary resource-returning source wrappers are rejected by validate_resource_signature_boundary; preserve that rule and its negative fixture. |
| Recursive foreign fields | Foreign carrier admission must agree with actual native pointee layout | Validate every nested field and transfer direction before conversion; the scalar adapter fixture proves only its explicit Int field. |
| Callbacks | Callable signature, context, lifetime, and ownership are distinct contracts | Validate argument/result representations and captures explicitly; shape or tag count does not establish a callback ABI. |
| Option/container positions | Existing scalar admission does not prove every nullable/tag encoding | Inventory actual native encodings and ownership before accepting a migrated managed union at these positions. |
| Borrowed managed positions | Validated managed pointers can retain their pointer ABI | Prove recursive layout and borrow duration. Borrowing neither grants scalar ABI nor warrants blanket pointer rejection. |

Source boundaries: `type_system/language_surface_manifest.brp`,
`stage_09_core/c_type_layout.brp`, `stage_06_typecheck/foreign_validation.brp`,
`stage_06_typecheck/decl.brp` (`validate_resource_signature_boundary`),
`standard_library/src/fs.brp`, `standard_library/src/net/tcp.brp`, and native
`runtime.c`/`runtime_decl.c`. The
`tcp_resource_return_carrier.brp` negative fixture pins the source wrapper rule.
P2a canonical authority and foreign admission remain open.
