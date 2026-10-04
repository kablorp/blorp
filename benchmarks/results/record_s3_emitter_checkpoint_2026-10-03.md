# Managed-record emitter checkpoint

The focused emitter suite passed **361/361**, exit 0:

```sh
bin/blorp test --timeout 240 blorp/test/compiler/stage_10_backend/test_core_emit.brp
```

Evidence directory: `/tmp/blorp-record-through-s4.5K6t2p/`.

- Final gate: `s3-emitter-final.log`.
- Original 15 failures: `integrated-emitter-3.log`.
- Complete generated C before fixture corrections: `s3-emitter-diagnostic-artifacts.log`.
- Type-coherent intermediate C: `s3-emitter-diagnostic-managed-artifacts.log`.
- Supported pointer-read C: `s3-emitter-diagnostic-valid-artifacts.log`.

Test-only corrections made Point tensor element types coherent; matrix reads
use rank-two dimensions and the four-element fill has a matching result shape.
Managed reads use the production-supported checked-get pointer cast, not the
scalar-only unchecked intrinsic. Exact C assertions cover returned-child
retains, pointer closure captures and release masks, owned list insertion,
constructor temporary cleanup, and one release per direct fill/set function.
Nullable managed Options retain their erased pointer ABI. The live scalar
Option[Int] mode/element-size guard, memcpy/sizeof, zero initialization and
boxed fallback remain covered; scalar Option/Result and unchecked controls
were not converted to managed records. Temporary diagnostic code was removed
before the final gate. No production changes were made for these repairs.

Provenance remained frozen in the shared integration checkout:

- Checkout: `/Users/keithphilpott/.codex/worktrees/r2-ownership-questions/blorp`.
- Branch: `codex/record-s2-internal-migrations`.
- HEAD: `d29b264e1a74d73a1c0c02f437437947660c3ff3` with integrated working-tree changes.
- Bootstrap pin unchanged: `dev-0322140767b0`.
- Integrated compiler: existing fresh `-O2` build; no rebuild or pin change in this gate.
- Compiler SHA256: `36b5baf3787e35b0b91fb0673fe133bb2d1f29c318837b7230eb991dc72e4ee0`.
- Emitter test SHA256: `d6a5aa124ba8e3767638467bbcb30f22740f5172832fc4f5785118ec0e64ebc2`.

This is a focused checkpoint, not broad acceptance or a compiler fixpoint.
Broad compiler/runtime/leak/sanitizer/codegen gates and fixpoint validation
remain open. Main's separately advanced bootstrap is not this gate's compiler.

Benchmark work remains incomplete: the managed-object row/direct-allocation
size migration has only shell syntax and diff checks. The new bounded
`benchmarks/support/compiler_record_layout_symbols.brp` authority consumer is
unvalidated; runner naming transport and its happy/absent/duplicate input
tests are not implemented. No benchmark compiled gate was run.
