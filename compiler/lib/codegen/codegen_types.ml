(** Type-related utilities shared by the core-emit pipeline.

    Provides:
    - C reserved-identifier escaping
    - Type-alias expansion and substitution
    - AST type → C type mapping ([type_to_c])
    - Per-compilation registry type ([registry]) bundling the type metadata
      that [type_to_c]/[expand_alias] and ownership classification consult:
      value-record names, enum union names, managed user type names, and
      type-alias definitions

    The registry is owned by [Core_emit_context] and created fresh per
    compilation (and per pipeline invocation). No module-global mutable
    state — callers always pass a registry explicitly.

    Population order: the core pipeline registers type aliases eagerly
    before monomorphization (see [Core_pipeline.compile_typed_with_modules]);
    [Core_emit.emit_program] registers value-record names and enum types
    as it walks declarations. [collect_subst] in [Core_mono] consults
    aliases via [expand_alias ~reg]. *)

open Ast

(* ============================================================================
   Type-variable predicate and substitution
   ============================================================================ *)

(** Normalize type aliases to canonical names for codegen.
    Vector/Matrix are aliases for Tensor; LiteralString is a String refinement. *)
let normalize_type ty =
  Types.map_type_expr
    (function
      | TyNamed (("Vector" | "Matrix"), args) -> Some (TyNamed ("Tensor", args))
      | TyNamed ("Tensor", [ elem ]) -> Some elem (* 0D tensor = scalar *)
      | TyNamed ("LiteralString", []) -> Some (TyNamed ("String", []))
      | _ -> None)
    ty

(** Apply a type-variable substitution to a type expression. *)
let apply_codegen_subst = Types.apply_type_param_subst

(** Peel a type to the outermost concrete name suitable as an impl
    lookup key. [TyTuple] gets a synthetic [Tuple<N>] name so impls can
    dispatch on arity; function types, ranges, meta/type vars return
    [None] — they have no stable lookup key for trait registration. *)
let type_name_for_impl (ty : type_expr) : string option =
  match normalize_type ty with
  | TyArray _ -> Some Types.array_head_name
  | TyNamed (n, _) -> Some n
  | TyTuple ts -> Some (Printf.sprintf "Tuple%d" (List.length ts))
  | _ -> None

(** Produce a fully concrete impl lookup key. Unlike [type_name_for_impl],
    this includes type arguments so [Stringable for (Int, Int)] and
    [Stringable for (String, String)] do not collide under the same
    [Tuple2] head. Non-parameterized named types intentionally keep their
    historic key (e.g. [Int], [String]) so existing primitive impl names
    remain stable. *)
let rec type_key_for_impl (ty : type_expr) : string option =
  match normalize_type ty with
  | TyArray (elem, dims) ->
      let encoded = List.filter_map type_key_for_impl (elem :: dims) in
      if List.length encoded = 1 + List.length dims then
        Some (String.concat "_" (Types.array_head_name :: encoded))
      else None
  | TyNamed (n, []) when not (Types.is_type_param_name n) -> Some n
  | TyNamed (n, args) when not (Types.is_type_param_name n) ->
      let encoded = List.filter_map type_key_for_impl args in
      if List.length encoded = List.length args then
        Some (String.concat "_" (n :: encoded))
      else None
  | TyTuple elems ->
      let encoded = List.filter_map type_key_for_impl elems in
      if List.length encoded = List.length elems then
        Some
          (Printf.sprintf "Tuple%d_%s" (List.length elems)
             (String.concat "_" encoded))
      else None
  | TyConstInt n -> Some (string_of_int n)
  | TyDimOp _ -> (
      match Types.Dim.normalize ty with
      | TyConstInt n -> Some (string_of_int n)
      | _ -> None)
  | _ -> None

(** Does this type still contain any unresolved type variables? *)
let rec has_type_vars = function
  | TyVar _ | TyBoundVar _ | TyVarDims _ | TyMeta _ -> true
  | TyNamed (name, []) when Types.is_type_param_name name -> true
  | TyNamed (_, args) -> List.exists has_type_vars args
  | TyArray (elem, dims) -> has_type_vars elem || List.exists has_type_vars dims
  | TyTuple elems -> List.exists has_type_vars elems
  | TyFunc { params; return; _ } ->
      List.exists has_type_vars params || has_type_vars return
  | TyRange inner -> has_type_vars inner
  | TyDimOp (_, a, b) -> has_type_vars a || has_type_vars b
  | _ -> false

(* ============================================================================
   C identifier escaping
   ============================================================================ *)

(** C reserved words that cannot be used as identifiers. Includes C keywords,
    standard-library macros (INT_MAX, INFINITY, NAN, M_PI, etc.), and types
    that collide with third-party headers. *)
let c_reserved_set =
  lazy
    (let words =
       [
         (* C keywords *)
         "auto";
         "break";
         "case";
         "char";
         "const";
         "continue";
         "default";
         "do";
         "double";
         "else";
         "enum";
         "extern";
         "float";
         "for";
         "goto";
         "if";
         "inline";
         "int";
         "long";
         "register";
         "restrict";
         "return";
         "short";
         "signed";
         "sizeof";
         "static";
         "struct";
         "switch";
         "typedef";
         "union";
         "unsigned";
         "void";
         "volatile";
         "while";
         "_Alignas";
         "_Alignof";
         "_Atomic";
         "_Bool";
         "_Complex";
         "_Generic";
         "_Imaginary";
         "_Noreturn";
         "_Static_assert";
         "_Thread_local";
         (* C11/C23 additions *)
         "alignas";
         "alignof";
         "bool";
         "false";
         "true";
         "nullptr";
         "static_assert";
         "thread_local";
         "typeof";
         "typeof_unqual";
         (* Common macros/types to avoid *)
         "NULL";
         "EOF";
         "stdin";
         "stdout";
         "stderr";
         "errno";
         "size_t";
         "ptrdiff_t";
         "intptr_t";
         "uintptr_t";
         "FILE";
         "fpos_t";
         "time_t";
         "clock_t";
         (* C standard library macros that user identifiers must not collide
         with — collisions break third-party headers (e.g. OpenSSL's
         [openssl/err.h] uses INT_MAX, math.h's INFINITY/NAN macros expand
         in unexpected places). *)
         "INT_MAX";
         "INT_MIN";
         "LONG_MAX";
         "LONG_MIN";
         "LLONG_MAX";
         "LLONG_MIN";
         "UINT_MAX";
         "ULONG_MAX";
         "ULLONG_MAX";
         "SIZE_MAX";
         "PTRDIFF_MAX";
         "INT8_MAX";
         "INT8_MIN";
         "INT16_MAX";
         "INT16_MIN";
         "INT32_MAX";
         "INT32_MIN";
         "INT64_MAX";
         "INT64_MIN";
         "UINT8_MAX";
         "UINT16_MAX";
         "UINT32_MAX";
         "UINT64_MAX";
         "INFINITY";
         "NAN";
         "HUGE_VAL";
         "HUGE_VALF";
         "HUGE_VALL";
         "M_PI";
         "M_E";
         "M_SQRT2";
         "M_LN2";
         "M_LN10";
         (* Common POSIX / stdlib function names a user could accidentally shadow.
         Runtime headers (unistd.h, stdio.h, stdlib.h) get transitively
         included via runtime.c, so a same-named user function with a
         different signature produces a "conflicting types" C error. *)
         "truncate";
         "open";
         "close";
         "read";
         "write";
         "link";
         "unlink";
         "rename";
         "stat";
         "fstat";
         "access";
         "chdir";
         "getcwd";
         "mkdir";
         "rmdir";
         "pipe";
         "dup";
         "dup2";
         "fork";
         "wait";
         "exit";
         "abort";
         "system";
         "malloc";
         "free";
         "calloc";
         "realloc";
         "memcpy";
         "memset";
         "memcmp";
         "memmove";
         "strlen";
         "strcpy";
         "strcmp";
         "strncmp";
         "strcat";
         "strchr";
         "strstr";
         "fopen";
         "fclose";
         "fread";
         "fwrite";
         "fprintf";
         "fscanf";
         "fseek";
         "ftell";
         "rewind";
         "printf";
         "scanf";
         "puts";
         "gets";
         "getchar";
         "putchar";
         "atoi";
         "atol";
         "atof";
         "strtol";
         "strtoul";
         "strtod";
         "time";
         "clock";
         "gmtime";
         "localtime";
         "mktime";
         "asctime";
         "ctime";
         "rand";
         "srand";
         "random";
         "srandom";
         "getpid";
         "getppid";
         "getuid";
         "geteuid";
         "signal";
         "raise";
         "sleep";
         "alarm";
         "setjmp";
         "longjmp";
       ]
     in
     let tbl = Hashtbl.create 64 in
     List.iter (fun w -> Hashtbl.replace tbl w ()) words;
     tbl)

(** Prefix reserved C identifiers with [_blorp_] so user names can't collide
    with keywords or standard-library macros. *)
let escape_c_ident name =
  if Hashtbl.mem (Lazy.force c_reserved_set) name then "_blorp_" ^ name
  else name

(* ============================================================================
   Type registries
   ============================================================================ *)

type managed_type_kind =
  | ManagedHeapRecord
  | ManagedUnion
  | ManagedRuntimeBuiltin

type union_payload_storage =
  | ErasedUnionPayloadStorage
  | TypedUnionPayloadStorage

type managed_destructor =
  | ArcReleaseOnly
      (** The value has a blorp ARC header, but no type-specific nested
          destructor is needed. [blorp_release] is still the release path. *)
  | GeneratedDestructor of string
      (** The C backend emits and installs this type-specific destructor. *)
  | RuntimeDestructor of string
      (** Runtime-owned managed type whose destructor is implemented in C. *)

type managed_type_info = {
  managed_kind : managed_type_kind;
  destructor : managed_destructor;
}

type enum_info = { enum_variant_count : int; enum_max_tag : int }

type registry = {
  value_records : (string, unit) Hashtbl.t;
      (** Declared struct types ([record_is_value = true]) — [type_to_c] emits
        these by-value (no trailing [*]). *)
  enum_types : (string, enum_info) Hashtbl.t;
      (** All-nullary union types — [type_to_c] emits these as [long] since
        they live at runtime as integer tags. The metadata also drives packed
        list/tensor storage decisions. *)
  union_variants : (string, (string, variant) Hashtbl.t) Hashtbl.t;
      (** Union variant metadata keyed by type name, then constructor name.
        This is intentionally separate from [managed_types]: enum and managed
        unions both have constructors, but only managed unions allocate ARC
        objects. Earlier Core passes use this table to recognize constructor
        calls without guessing from source names. *)
  union_payload_storage : (string, union_payload_storage) Hashtbl.t;
      (** C storage policy for non-enum union payload fields. Source unions
        default to erased [void*] payload slots. Monomorphized concrete generic
        unions can opt into typed payload slots once their variant field types
        are fully concrete. *)
  managed_types : (string, managed_type_info) Hashtbl.t;
      (** Heap-allocated user types with ARC headers: records and non-enum
        unions. The value records the type's release/destructor policy, so
        source-declared custom managed types cannot enter ownership analysis as
        a bare "known managed" bit. Runtime builtins are classified by name in
        [Core_type_layout]. *)
  type_aliases : (string, string list * type_expr) Hashtbl.t;
      (** Type aliases: alias-name → (type_params, target_type). [expand_alias]
        substitutes these before codegen so downstream passes see canonical
        types. *)
}
(** Per-compilation registries consulted by [type_to_c], [expand_alias], and
    ownership classification. Bundled into a single record so the tables share
    a lifetime:
    created together (in the emission context), populated together by
    pipeline / emission walks, and never referenced in isolation. *)

(** Create an empty registry. Tables are sized to match observed real
    programs (dozens of value records and aliases, handful of enums). *)
let create_registry () : registry =
  {
    value_records = Hashtbl.create 16;
    enum_types = Hashtbl.create 8;
    union_variants = Hashtbl.create 16;
    union_payload_storage = Hashtbl.create 16;
    managed_types = Hashtbl.create 32;
    type_aliases = Hashtbl.create 16;
  }

(** Clear all tables in [reg] so it can be reused for a fresh compilation. *)
let reset_registry (reg : registry) : unit =
  Hashtbl.clear reg.value_records;
  Hashtbl.clear reg.enum_types;
  Hashtbl.clear reg.union_variants;
  Hashtbl.clear reg.union_payload_storage;
  Hashtbl.clear reg.managed_types;
  Hashtbl.clear reg.type_aliases

let register_union_variants reg name variants =
  let by_name =
    match Hashtbl.find_opt reg.union_variants name with
    | Some tbl -> tbl
    | None ->
        let tbl = Hashtbl.create 8 in
        Hashtbl.add reg.union_variants name tbl;
        tbl
  in
  Hashtbl.clear by_name;
  List.iter (fun v -> Hashtbl.replace by_name v.variant_name v) variants

let register_managed_type reg name info =
  Hashtbl.replace reg.managed_types name info

let register_heap_record_type reg name ~destructor =
  register_managed_type reg name
    { managed_kind = ManagedHeapRecord; destructor }

let register_union_type ?payload_storage reg name ~destructor =
  let payload_storage =
    match payload_storage with
    | Some storage -> storage
    | None -> (
        match Hashtbl.find_opt reg.union_payload_storage name with
        | Some storage -> storage
        | None -> ErasedUnionPayloadStorage)
  in
  Hashtbl.replace reg.union_payload_storage name payload_storage;
  register_managed_type reg name { managed_kind = ManagedUnion; destructor }

let enum_info_of_variants variants =
  let max_tag =
    List.fold_left (fun acc (v : variant) -> max acc v.variant_tag) 0 variants
  in
  { enum_variant_count = List.length variants; enum_max_tag = max_tag }

let register_enum_type reg name variants =
  register_union_variants reg name variants;
  Hashtbl.replace reg.enum_types name (enum_info_of_variants variants)

let enum_info reg name = Hashtbl.find_opt reg.enum_types name
let is_enum_type reg name = Hashtbl.mem reg.enum_types name

let lookup_union_variant reg type_name variant_name =
  match Hashtbl.find_opt reg.union_variants type_name with
  | None -> None
  | Some variants -> Hashtbl.find_opt variants variant_name

let union_payload_storage reg name =
  match Hashtbl.find_opt reg.union_payload_storage name with
  | Some storage -> storage
  | None -> ErasedUnionPayloadStorage

let union_uses_typed_payload_storage reg name =
  match union_payload_storage reg name with
  | TypedUnionPayloadStorage -> true
  | ErasedUnionPayloadStorage -> false

let managed_type_info reg name = Hashtbl.find_opt reg.managed_types name
let is_managed_type reg name = Hashtbl.mem reg.managed_types name

let is_tcp_string_backed_builtin_name = function
  | "IpAddress" | "std/net/tcp::IpAddress" | "std_net_tcp__IpAddress"
  | "DnsName" | "std/net/tcp::DnsName" | "std_net_tcp__DnsName"
  | "InterfaceScope" | "std/net/tcp::InterfaceScope"
  | "std_net_tcp__InterfaceScope" ->
      true
  | _ -> false

let is_tcp_port_builtin_name = function
  | "Port" | "std/net/tcp::Port" | "std_net_tcp__Port" -> true
  | _ -> false

(* ============================================================================
   Type-to-C mapping
   ============================================================================ *)

(** Expand type aliases by substituting type arguments for type parameters. *)
let rec expand_alias ~(reg : registry) ty =
  match ty with
  | TyNamed (name, args) -> (
      match Hashtbl.find_opt reg.type_aliases name with
      | Some (params, body) ->
          let args' = List.map (expand_alias ~reg) args in
          let subst =
            List.combine params (List.map (fun a -> (a : type_expr)) args')
          in
          let expanded =
            List.fold_left
              (fun acc (param, arg) -> apply_codegen_subst [ (param, arg) ] acc)
              body subst
          in
          expand_alias ~reg expanded
      | None -> TyNamed (name, List.map (expand_alias ~reg) args))
  | TyArray (elem, dims) ->
      TyArray (expand_alias ~reg elem, List.map (expand_alias ~reg) dims)
  | TyTuple elems -> TyTuple (List.map (expand_alias ~reg) elems)
  | TyFunc f ->
      TyFunc
        {
          f with
          params = List.map (expand_alias ~reg) f.params;
          return = expand_alias ~reg f.return;
        }
  | TyRange inner -> TyRange (expand_alias ~reg inner)
  | TyDimOp (op, a, b) -> TyDimOp (op, expand_alias ~reg a, expand_alias ~reg b)
  | _ -> ty

let primitive_stack_option_c_type_of_expanded_type = function
  | TyNamed ("Option", [ TyNamed ("Void", []) ]) ->
      Some "blorp_StackOption_Void"
  | TyNamed ("Option", [ TyNamed ("Int", []) ]) -> Some "blorp_StackOption_Int"
  | TyNamed ("Option", [ TyNamed ("Int8", []) ]) ->
      Some "blorp_StackOption_Int8"
  | TyNamed ("Option", [ TyNamed ("Int16", []) ]) ->
      Some "blorp_StackOption_Int16"
  | TyNamed ("Option", [ TyNamed ("Int32", []) ]) ->
      Some "blorp_StackOption_Int32"
  | TyNamed ("Option", [ TyNamed ("Int64", []) ]) ->
      Some "blorp_StackOption_Int64"
  | TyNamed ("Option", [ TyNamed ("UInt8", []) ]) ->
      Some "blorp_StackOption_UInt8"
  | TyNamed ("Option", [ TyNamed ("UInt16", []) ]) ->
      Some "blorp_StackOption_UInt16"
  | TyNamed ("Option", [ TyNamed ("UInt32", []) ]) ->
      Some "blorp_StackOption_UInt32"
  | TyNamed ("Option", [ TyNamed ("UInt64", []) ]) ->
      Some "blorp_StackOption_UInt64"
  | TyNamed ("Option", [ TyNamed ("Float", []) ]) ->
      Some "blorp_StackOption_Float"
  | TyNamed ("Option", [ TyNamed ("Bool", []) ]) ->
      Some "blorp_StackOption_Bool"
  | TyNamed ("Option", [ TyNamed ("Char", []) ]) ->
      Some "blorp_StackOption_Char"
  | TyNamed ("Option", [ TyNamed ("Float32", []) ]) ->
      Some "blorp_StackOption_Float32"
  | TyNamed ("Option", [ TyNamed ("Float16", []) ]) ->
      Some "blorp_StackOption_Float16"
  | _ -> None

let primitive_stack_option_c_type_of_payload payload =
  primitive_stack_option_c_type_of_expanded_type
    (TyNamed ("Option", [ payload ]))

let is_primitive_stack_option_payload payload =
  primitive_stack_option_c_type_of_payload payload <> None

let generated_stack_option_c_type_name payload_name =
  let payload_name =
    if payload_name = "Range" then "RangeValue" else payload_name
  in
  "blorp_StackOption_" ^ Codegen_names.sanitize_c_ident payload_name

let generated_stack_option_c_type_of_payload ~(reg : registry) = function
  | TyNamed ("Int128", []) -> Some "blorp_StackOption_Int128"
  | TyNamed ("UInt128", []) -> Some "blorp_StackOption_UInt128"
  | TyRange _ -> Some "blorp_StackOption_Range"
  | TyNamed (name, []) when Hashtbl.mem reg.enum_types name ->
      Some (generated_stack_option_c_type_name name)
  | TyNamed (name, []) when Hashtbl.mem reg.value_records name ->
      Some (generated_stack_option_c_type_name name)
  | _ -> None

let stack_option_c_type ~(reg : registry) ty =
  let ty = expand_alias ~reg ty in
  match primitive_stack_option_c_type_of_expanded_type ty with
  | Some c_ty -> Some c_ty
  | None -> (
      match ty with
      | TyNamed ("Option", [ payload ]) ->
          generated_stack_option_c_type_of_payload ~reg payload
      | _ -> None)

let result_layout_metadata reg =
  Core_result_layout.metadata
    ~is_enum_name:(fun name -> Hashtbl.mem reg.enum_types name)
    ~is_managed_name:(is_managed_type reg)
    ~is_value_record_name:(fun name -> Hashtbl.mem reg.value_records name)
    ~lookup_alias:(fun name -> Hashtbl.find_opt reg.type_aliases name)
    ()

let stack_result_layout ~(reg : registry) ty =
  match Core_result_layout.classify (result_layout_metadata reg) ty with
  | Core_result_layout.Known layout -> Some layout
  | Core_result_layout.BoxedUnion _ | Core_result_layout.Unknown_named _
  | Core_result_layout.Invalid_result_type _ ->
      None

let stack_result_c_type ~(reg : registry) ty =
  match stack_result_layout ~reg ty with
  | Some (Core_result_layout.StackErased | Core_result_layout.StackManaged) ->
      Some "blorp_StackResult"
  | None -> None

(** Map a blorp type expression to its C representation.

    [reg] is the per-compilation registry bundling value-record names,
    enum-type names, and type-alias definitions — passed in so [type_to_c]
    has no hidden global state. *)
let type_to_c ~(reg : registry) ty =
  let ty = expand_alias ~reg ty in
  match stack_option_c_type ~reg ty with
  | Some c_ty -> c_ty
  | None -> (
      match stack_result_c_type ~reg ty with
      | Some c_ty -> c_ty
      | None -> (
          match ty with
          | TyNamed (name, []) -> (
              match name with
              | "Int" -> "long"
              | "Float" -> "double"
              | "Bool" -> "bool"
              | "String" | "LiteralString" -> "blorp_String*"
              | name when is_tcp_string_backed_builtin_name name ->
                  "blorp_String*"
              | name when is_tcp_port_builtin_name name -> "long"
              | "ParallelList" -> "blorp_List*"
              | "ParallelVector" | "ParallelMatrix" -> "blorp_Vector*"
              | "Bytes" -> "blorp_Bytes*"
              | "Char" -> "int32_t"
              | "Void" -> "void"
              | "Fixed" -> "blorp_Fixed*"
              | "StringSlice" -> "blorp_StringSlice*"
              | "MemStats" -> "blorp_MemStats*"
              | "SchedulerStats" -> "blorp_SchedulerStats*"
              | "DirectoryEntry" | "std/fs::DirectoryEntry"
              | "std_fs__DirectoryEntry" ->
                  "blorp_DirectoryEntry*"
              | "Task" -> "blorp_Task*"
              | "Channel" -> "blorp_Channel*"
              | name when Type_name_metadata.is_stream_name name ->
                  "blorp_Stream*"
              | name when Type_name_metadata.is_fallible_stream_name name ->
                  "blorp_FallibleStream*"
              | name when Type_name_metadata.is_resource_source_name name ->
                  "blorp_ResourceSource*"
              | "TcpListener" | "std/net/tcp::TcpListener"
              | "std_net_tcp__TcpListener" ->
                  "blorp_TcpListener*"
              | "TcpStream" | "std/net/tcp::TcpStream"
              | "std_net_tcp__TcpStream" ->
                  "blorp_TcpStream*"
              | "TlsSession" | "std/net/tls::TlsSession"
              | "std_net_tls__TlsSession" ->
                  "blorp_TlsSession*"
              | "WebSocketSession" | "std/net/websocket::WebSocketSession"
              | "std_net_websocket__WebSocketSession" ->
                  "blorp_WebSocketSession*"
              | "UdpSocket" | "std/net/udp::UdpSocket"
              | "std_net_udp__UdpSocket" ->
                  "blorp_UdpSocket*"
              | "FileReader" | "std/fs::FileReader" | "std_fs__FileReader" ->
                  "blorp_FileReader*"
              | "FileWriter" | "std/fs::FileWriter" | "std_fs__FileWriter" ->
                  "blorp_FileWriter*"
              | "FileAppender" | "std/fs::FileAppender" | "std_fs__FileAppender"
                ->
                  "blorp_FileAppender*"
              | "FileReadWriter" | "std/fs::FileReadWriter"
              | "std_fs__FileReadWriter" ->
                  "blorp_FileReadWriter*"
              | "FileReadAppender" | "std/fs::FileReadAppender"
              | "std_fs__FileReadAppender" ->
                  "blorp_FileReadAppender*"
              | "Directory" | "std/fs::Directory" | "std_fs__Directory" ->
                  "blorp_Directory*"
              | "Ptr" -> "void*"
              | "ConcurrencyError" -> "blorp_ConcurrencyError*"
              | _ when List.mem name Types.all_int_type_names ->
                  Types.int_type_to_c name
              | _ when List.mem name Types.all_float_type_names ->
                  Types.float_type_to_c name
              | _ when Types.is_type_param_name name ->
                  "void*" (* Type variables type-erased as void* *)
              | _ when Hashtbl.mem reg.enum_types name ->
                  "long" (* Enum types are integer values *)
              | _ when Hashtbl.mem reg.value_records name ->
                  name (* Value types are by-value, no pointer *)
              | _ -> name ^ "*" (* Assume pointer for custom types *))
          | TyNamed (name, _args) -> (
              match name with
              | "Tensor" | "Vector" | "Matrix" | "ParallelVector"
              | "ParallelMatrix" ->
                  "blorp_Vector*"
              | "List" | "ParallelList" -> "blorp_List*"
              | "Dict" -> "blorp_Dict*"
              | "Set" -> "blorp_Set*"
              | "Fixed" ->
                  "blorp_Fixed*"
                  (* Fixed with any params still maps to blorp_Fixed* *)
              | name when is_tcp_string_backed_builtin_name name ->
                  "blorp_String*"
              | name when is_tcp_port_builtin_name name -> "long"
              | "Task" -> "blorp_Task*"
              | "Channel" -> "blorp_Channel*"
              | name when Type_name_metadata.is_stream_name name ->
                  "blorp_Stream*"
              | name when Type_name_metadata.is_fallible_stream_name name ->
                  "blorp_FallibleStream*"
              | name when Type_name_metadata.is_resource_source_name name ->
                  "blorp_ResourceSource*"
              | "TcpListener" | "std/net/tcp::TcpListener"
              | "std_net_tcp__TcpListener" ->
                  "blorp_TcpListener*"
              | "TcpStream" | "std/net/tcp::TcpStream"
              | "std_net_tcp__TcpStream" ->
                  "blorp_TcpStream*"
              | "TlsSession" | "std/net/tls::TlsSession"
              | "std_net_tls__TlsSession" ->
                  "blorp_TlsSession*"
              | "WebSocketSession" | "std/net/websocket::WebSocketSession"
              | "std_net_websocket__WebSocketSession" ->
                  "blorp_WebSocketSession*"
              | "UdpSocket" | "std/net/udp::UdpSocket"
              | "std_net_udp__UdpSocket" ->
                  "blorp_UdpSocket*"
              | "FileReader" | "std/fs::FileReader" | "std_fs__FileReader" ->
                  "blorp_FileReader*"
              | "FileWriter" | "std/fs::FileWriter" | "std_fs__FileWriter" ->
                  "blorp_FileWriter*"
              | "FileAppender" | "std/fs::FileAppender" | "std_fs__FileAppender"
                ->
                  "blorp_FileAppender*"
              | "FileReadWriter" | "std/fs::FileReadWriter"
              | "std_fs__FileReadWriter" ->
                  "blorp_FileReadWriter*"
              | "FileReadAppender" | "std/fs::FileReadAppender"
              | "std_fs__FileReadAppender" ->
                  "blorp_FileReadAppender*"
              | "Directory" | "std/fs::Directory" | "std_fs__Directory" ->
                  "blorp_Directory*"
              | "DirectoryEntry" | "std/fs::DirectoryEntry"
              | "std_fs__DirectoryEntry" ->
                  "blorp_DirectoryEntry*"
              | _ -> name ^ "*" (* Generic types are pointers *))
          | TyArray _ -> "blorp_Vector*"
          | TyFunc _ -> "blorp_Closure*"
          | TyVar name when Types.Dim.is_var_name name ->
              "long" (* Dim params erase to long *)
          | TyVar _ | TyBoundVar _ ->
              "void*" (* Type variables type-erased as void* *)
          | TySelf ->
              "void*"
              (* Self type erased as void* - resolved during type checking *)
          | TyConstInt _ -> "long" (* Dim constants erase to long *)
          | TyRange _ -> "long" (* Range types erase to plain long at runtime *)
          | TyTuple _ -> "blorp_Tuple*"
          | TyVarDims _ -> "void*"
          | TyDimOp _ ->
              "long" (* Dim expressions erase to long, matching TyConstInt *)
          | TyMeta _ -> failwith "TyMeta reached codegen — zonking bug"))

let inline_value_record_c_type ~(reg : registry) ty =
  let ty = expand_alias ~reg ty |> normalize_type in
  match ty with
  | TyNamed (name, []) when Hashtbl.mem reg.value_records name ->
      Some (type_to_c ~reg ty)
  | _ -> None

(** Is a normalized type represented as a heap pointer (not a scalar)?
    Callers decide whether to box a value before passing as [void*] or
    storing in a generic container. Agrees with [type_to_c]: anything
    that maps to [long], [double], [bool], [int32_t], [_Float16], [float],
    [__int128] / [unsigned __int128] is a scalar; enum-typed unions map to
    [long] and are scalars; value records are by-value but are not
    bit-boxable so they still need box helpers (caller's responsibility).

    Kept parallel to the rules in [type_to_c] above. *)
let is_pointer_type ~(reg : registry) ty =
  let ty = expand_alias ~reg ty |> normalize_type in
  match ty with
  | ty when stack_option_c_type ~reg ty <> None -> false
  | ty when stack_result_c_type ~reg ty <> None -> false
  | TyNamed ("Int", _)
  | TyNamed ("Bool", _)
  | TyNamed ("Char", _)
  | TyNamed ("Float", _)
  | TyNamed ("Float32", _)
  | TyNamed ("Float16", _)
  | TyNamed ("Int128", _)
  | TyNamed ("UInt128", _)
  | TyNamed ("Void", _) ->
      false
  | TyNamed (n, _) when Hashtbl.mem reg.enum_types n -> false
  (* Value records ([struct Foo { ... }]) emit as bare structs in C —
     no header, no refcount, no pointer indirection. Treating them as
     pointer types causes [emit_box_to_void] to fall through to the
     [blorp_retain] arm, which fails C compile with "operand of type
     'Foo' where arithmetic or pointer type is required". The
     dedicated value-record arm in [emit_box_to_void] handles boxing
     via [blorp_box_struct]. *)
  | TyNamed (n, _) when Hashtbl.mem reg.value_records n -> false
  | ty when Types.is_any_integer_type ty -> false
  | ty when Types.Dim.is_value_dim ty -> false
  | _ -> true
