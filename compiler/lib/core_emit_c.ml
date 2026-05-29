(** C backend: the default [Backend.S] implementation for blorp.

    Thin wrapper around [Core_emit] + [Core_emit_context] that
    expresses the existing emit pipeline as the [Backend.S] contract.
    No behavior change — this file is structural so [Core_pipeline]
    can treat the backend as interchangeable with a future WASM /
    LLVM / interpreter implementation. *)

module Backend : sig
  include Backend.S

  val config_with_embed : embed_runtime:bool -> ?profile:bool -> unit -> config
end = struct
  type ctx = { inner : Core_emit_context.t; embed_runtime : bool }
  (** [ctx] bundles the underlying [Core_emit_context.t] with the
      per-compilation config. Config
      lives on the context instead of being threaded as a per-call
      parameter so the [Backend.S.emit_program] signature stays
      target-agnostic. *)

  type config = { embed_runtime : bool; profile : bool }
  (** Configuration for the C backend.

      [embed_runtime] controls whether the C runtime (runtime.c,
      runtime_decl.c, minicoro.h) is inlined into the generated
      output. Defaults to [false] — callers that use a precompiled
      runtime.o (e.g. [./blorp run]) leave it off; callers that ship
      a self-contained .c file (e.g. [./blorp compile]) set it.

      [profile] enables generated-program function profiling by emitting
      calls to the C runtime profiler around named user functions. *)

  let default_config = { embed_runtime = false; profile = false }
  let make_config ~embed_runtime ~profile = { embed_runtime; profile }

  let create_inner_context ~reg cfg =
    Core_emit_context.create ~profile:cfg.profile ~reg ()

  let create_ctx ~(reg : Codegen_types.registry) (cfg : config) : ctx =
    { inner = create_inner_context ~reg cfg; embed_runtime = cfg.embed_runtime }

  let emit_program (ctx : ctx) (prog : Core.core_program) : unit =
    Core_emit.emit_program ~embed_runtime:ctx.embed_runtime ctx.inner prog

  let finalize (ctx : ctx) : string = Buffer.contents ctx.inner.output

  (** Build a config from an explicit [embed_runtime] flag. Exposed
      so [Core_pipeline] can toggle the flag per compile without
      reaching into the opaque [config] type. *)
  let config_with_embed ~embed_runtime ?(profile = false) () : config =
    make_config ~embed_runtime ~profile
end
