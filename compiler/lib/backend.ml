(** Backend interface — the contract between the Core IR pipeline and
    any target-code emitter.

    A backend reads a fully-processed [Core.core_program] (post-
    monomorphization, post-match-compilation, post-trait-resolution,
    post-specialization, post-Perceus, post-closure-conversion) and
    emits target-specific output. The default C backend is
    [Core_emit_c]; hypothetical future backends (WASM, LLVM,
    interpreter) implement the same signature.

    {1 Design philosophy}

    The interface is deliberately thin. Earlier drafts proposed
    exposing individual emission primitives ([emit_intrinsic],
    [emit_box], [emit_func], etc.) — that style bakes C-specific
    assumptions into the contract and forces every new backend to
    match the C backend's internal structure. This thinner surface
    (emit the whole program, finalize to get output) lets each
    backend organize its internals freely.

    {1 How to add a backend}

    1. Create [compiler/lib/my_backend.ml] with a module matching [S].
    2. Supply a [ctx] that holds whatever mutable state your emitter
       needs (output buffer, label counter, type caches, …).
    3. [create_ctx] allocates one; [emit_program] drives emission
       into it; [finalize] reads the finished output out.
    4. Wire into [Core_pipeline.compile_typed_with_modules] via the
       [?backend] parameter — which takes a first-class [(module S)].

    {1 Known leak: [reg] in [create_ctx]}

    [create_ctx] takes a [Codegen_types.registry] — C-specific
    vocabulary (value records, enum-types, type aliases) bleeding
    through a supposedly target-agnostic interface. The registry is
    currently how Core passes (mono, specialize) share type decisions
    with the emit phase, so a non-C backend would need to either
    re-populate its own parallel registry or reuse this one.

    The right long-term shape (not urgent — no second backend exists
    to force it): hoist type-decision metadata into a neutral
    [Core_register] stage that runs before backend dispatch, give
    backends a read-only view, and remove the registry from this
    signature. *)
module type S = sig
  type ctx
  (** Per-emission mutable state. Opaque to callers. *)

  type config
  (** Backend-specific configuration (e.g. "embed the runtime in the
      output" for the C backend, or "optimization level" for future
      native code generators). *)

  val default_config : config
  (** Sensible defaults — used by [Core_pipeline] when no explicit
      config is passed. *)

  val create_ctx : reg:Codegen_types.registry -> config -> ctx
  (** Allocate a fresh emission context. *)

  val emit_program : ctx -> Core.core_program -> unit
  (** Emit a fully-processed Core program into [ctx]. Idempotent in
      the sense that a caller may invoke it multiple times on the
      same [ctx] to accumulate output, but downstream passes today
      call it exactly once per compile. *)

  val finalize : ctx -> string
  (** Extract the finished output as a string. After calling this,
      the [ctx] is typically not used further. *)
end
