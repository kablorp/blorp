(** Emission context for Core → C.

    Deliberately separate from [Codegen_context.t] so that Core emission
    is insulated from old-codegen assumptions. Only the state Core_emit
    actually needs lives here: output buffer, indentation, a single
    temp-name counter, and the string-literal deduplication table.

    During migration, the old [Codegen_context.t] remains for the legacy
    codegen path. The two contexts are independent. *)

type collected_lambda = {
  cl_name : string;
  cl_profile_name : string;
  cl_params : (Core.var * Ast.type_expr) list;
  cl_captures : (string * Ast.type_expr) list;
  cl_moved_captures : string list;
  cl_body : Core.core;
  cl_return_ty : Ast.type_expr;
  cl_task_abi : bool;
}
(** A lambda collected during expression emission, to be emitted as
    a top-level C function after all declarations. *)

type string_literal_binding = { sl_var : string; sl_helper : string }

type t = {
  profile : bool;
  mutable output : Buffer.t;
  mutable indent : int;
  mutable temp_counter : int;
  string_literals : (string, string_literal_binding) Hashtbl.t;
  mutable string_literals_buffer : Buffer.t;
  mutable collected_lambdas : collected_lambda list;
  mutable lambda_counter : int;
  constructor_names : (string, unit) Hashtbl.t;
  constructor_c_names : (string, string) Hashtbl.t;
      (** Best-effort source constructor name → emitted C symbol map.
        Call sites with [Var.vdef_id] use DefId mangling directly; this
        table is only a fallback for legacy constructor references that
        still carry a source name but no def id. *)
  constructor_c_names_by_type : (string * string, string) Hashtbl.t;
      (** Parent type + source constructor name → emitted C symbol map.
        This disambiguates same-named nullary constructors from different
        enum/union types when legacy [CVar] nodes lack a [vdef_id]. *)
  ctor_parent_types : (string, string) Hashtbl.t;
      (** Maps constructor name → C type name of its parent union.
        E.g. "Some" → "Option", "VInt" → "Value".
        Used by [emit_pat_bindings] to cast void* intermediates. *)
  global_names : (string, unit) Hashtbl.t;
  global_def_ids : (int, unit) Hashtbl.t;
      (** DefIds for top-level functions/impl methods/foreign functions.
      Used by emit-time invariant backstops to identify raw function values
      that should have been made explicit by Core closure conversion. *)
  reg : Codegen_types.registry;
  record_decls : (string, Ast.record_decl) Hashtbl.t;
      (** Source record declarations keyed by record name. C emission uses
      this for generic record fields whose C storage is erased to
      [void*] even when the use site has a concrete instantiated type. *)
  trait_impl_def_ids : (string, int) Hashtbl.t;
      (** A4.2: trait-impl mangled name (e.g. [Hashable_hash_Widget])
      → [cf_def_id] of the emitted method. Populated by [emit_impl]
      when it walks [ci_methods]. Consumed by hardcoded trait-ptr
      emission sites (the [blorp_set_new_custom] / [blorp_dict_new_custom]
      fallbacks at [core_emit.ml:642]) that bypass the [CKUser]
      resolve path. A4.3 may collapse this into a unified trait
      method table; for now it's the minimal patch to keep
      user-hashable / user-equatable set + dict creation working
      after trait-impl method names gained a [__def_N_] prefix. *)
}

(** Create a fresh emission context with its own [Codegen_types.registry].
    The registry is shared with whatever pipeline invoked emission so that
    type aliases registered before mono remain visible at emit time. *)
let create ?(profile = false) ?(reg = Codegen_types.create_registry ()) () =
  {
    profile;
    output = Buffer.create 4096;
    indent = 0;
    temp_counter = 0;
    string_literals = Hashtbl.create 16;
    string_literals_buffer = Buffer.create 512;
    collected_lambdas = [];
    lambda_counter = 0;
    constructor_names = Hashtbl.create 32;
    constructor_c_names = Hashtbl.create 32;
    constructor_c_names_by_type = Hashtbl.create 64;
    ctor_parent_types = Hashtbl.create 32;
    global_names = Hashtbl.create 64;
    global_def_ids = Hashtbl.create 64;
    reg;
    record_decls = Hashtbl.create 32;
    trait_impl_def_ids = Hashtbl.create 16;
  }

(** Reset the context to an empty state — useful between independent
    emit runs within a single test or when reusing a context across
    passes. Also clears the registry so value-record/enum/alias tables
    don't leak across runs. *)
let reset ctx =
  Buffer.clear ctx.output;
  ctx.indent <- 0;
  ctx.temp_counter <- 0;
  Hashtbl.clear ctx.string_literals;
  Buffer.clear ctx.string_literals_buffer;
  ctx.collected_lambdas <- [];
  ctx.lambda_counter <- 0;
  Hashtbl.clear ctx.constructor_names;
  Hashtbl.clear ctx.constructor_c_names;
  Hashtbl.clear ctx.constructor_c_names_by_type;
  Hashtbl.clear ctx.ctor_parent_types;
  Hashtbl.clear ctx.global_names;
  Hashtbl.clear ctx.global_def_ids;
  Codegen_types.reset_registry ctx.reg;
  Hashtbl.clear ctx.record_decls;
  Hashtbl.clear ctx.trait_impl_def_ids

(* ============================================================================
   Output primitives
   ============================================================================ *)

(** Append a raw string to the output buffer. *)
let emit ctx s = Buffer.add_string ctx.output s

(** Append a string followed by a newline. *)
let emitln ctx s =
  Buffer.add_string ctx.output s;
  Buffer.add_char ctx.output '\n'

(** Append indentation (4 spaces per level) to the output buffer. *)
let emit_indent ctx =
  for _ = 1 to ctx.indent do
    Buffer.add_string ctx.output "    "
  done

(** Emit an indented line: [indent] + [s] + newline. *)
let emit_line ctx s =
  emit_indent ctx;
  emitln ctx s

(** Fresh numeric counter. Increments and returns the previous value. *)
let fresh_temp ctx =
  let n = ctx.temp_counter in
  ctx.temp_counter <- n + 1;
  n

(* ============================================================================
   Literal emission

   Originally a deliberate copy of the legacy [Codegen_emit.gen_literal]
   kept in sync during the Core-emit migration. The legacy codegen was
   deleted in the 2026-04-14 cutover (see memory/legacy_codegen_cutover.md),
   so this is now the sole definition.
   ============================================================================ *)

(** Escape a string for C string literals. Use fixed-width octal for
    non-ASCII bytes because C hex escapes greedily consume following
    hex digits (for example [\xa9fac]). *)
let c_escape_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c ->
      let code = Char.code c in
      match c with
      | '\\' -> Buffer.add_string buf "\\\\"
      | '"' -> Buffer.add_string buf "\\\""
      | '\n' -> Buffer.add_string buf "\\n"
      | '\r' -> Buffer.add_string buf "\\r"
      | '\t' -> Buffer.add_string buf "\\t"
      | _ when code >= 32 && code < 127 -> Buffer.add_char buf c
      | _ -> Buffer.add_string buf (Printf.sprintf "\\%03o" code))
    s;
  Buffer.contents buf

(** Emit a deduplicated string literal. Each literal has a static [__sl_N]
    pointer and a helper that lazily initializes it. Calls to the helper are
    safe to repeat inside one C expression; the old inline assignment
    expression could read/write the same [__sl_N] multiple times with
    unspecified argument evaluation order. *)
let emit_string_literal ctx s =
  let escaped = c_escape_string s in
  let binding =
    match Hashtbl.find_opt ctx.string_literals escaped with
    | Some binding -> binding
    | None ->
        let slot =
          Printf.sprintf "sl_%d" (Hashtbl.length ctx.string_literals)
        in
        let binding =
          { sl_var = "__" ^ slot; sl_helper = "__blorp_get_" ^ slot }
        in
        Hashtbl.replace ctx.string_literals escaped binding;
        Buffer.add_string ctx.string_literals_buffer
          (Printf.sprintf
             "static blorp_String* %s;\n\
              static blorp_String* %s(void) {\n\
             \    if (!%s) %s = blorp_string_literal_len(\"%s\", %dL);\n\
             \    return %s;\n\
              }\n"
             binding.sl_var binding.sl_helper binding.sl_var binding.sl_var
             escaped (String.length s) binding.sl_var);
        binding
  in
  emit ctx (binding.sl_helper ^ "()")

(** Emit a blorp literal as a C expression. Byte-identical to the
    legacy [Codegen_emit.gen_literal] — duplicated here to keep
    Core_emit self-contained. *)
let gen_literal ctx = function
  | Ast.LitInt n -> emit ctx (Printf.sprintf "%LdL" n)
  | Ast.LitInt128 digits ->
      let base = "1000000000000000000" in
      let len = String.length digits in
      let rec chunks acc end_idx =
        if end_idx <= 0 then acc
        else
          let start = max 0 (end_idx - 18) in
          let chunk = String.sub digits start (end_idx - start) in
          chunks (chunk :: acc) start
      in
      let expr =
        match chunks [] len with
        | [] -> "((__int128)0)"
        | first :: rest ->
            List.fold_left
              (fun acc chunk ->
                Printf.sprintf "((%s) * (__int128)%s + (__int128)%s)" acc base
                  chunk)
              (Printf.sprintf "(__int128)%s" first)
              rest
      in
      emit ctx expr
  | Ast.LitFloat f ->
      let s = Printf.sprintf "%.17g" f in
      emit ctx s;
      (* Ensure C sees a floating-point literal, not an integer *)
      if
        not
          (String.contains s '.' || String.contains s 'e'
         || String.contains s 'E')
      then emit ctx ".0"
  | Ast.LitString (s, _) -> emit_string_literal ctx s
  | Ast.LitBool true -> emit ctx "true"
  | Ast.LitBool false -> emit ctx "false"
  | Ast.LitChar c -> emit ctx (Printf.sprintf "%d" c)
