(** Tests for synthesized Core IR bodies in [Core_intrinsics]. *)

open Blorp.Ast
open Blorp.Core

let ty_int = TyNamed ("Int", [])
let ty_bool = TyNamed ("Bool", [])
let ty_char = TyNamed ("Char", [])
let ty_float = TyNamed ("Float", [])
let ty_string = TyNamed ("String", [])
let ty_var_t = TyVar "T"
let ty_color = TyNamed ("Color", [])
let ty_count = TyNamed ("Count", [])
let ty_list elem = TyNamed ("List", [ elem ])
let ty_set elem = TyNamed ("Set", [ elem ])
let ty_dict key value = TyNamed ("Dict", [ key; value ])
let ty_option elem = TyNamed ("Option", [ elem ])
let ty_result ok err = TyNamed ("Result", [ ok; err ])
let ty_concurrency_error = TyNamed ("ConcurrencyError", [])
let ty_void = TyNamed ("Void", [])
let ty_func params return = TyFunc { params; return; is_pure = true }
let ty_vector elem n = TyArray (elem, [ TyConstInt n ])
let param name ty = { cp_name = Var.named name; cp_ty = ty; cp_loc = dummy_loc }

let enum_variant name tag =
  {
    variant_name = name;
    variant_fields = [];
    variant_tag = tag;
    variant_loc = dummy_loc;
    variant_def_id = None;
  }

let enum_registry name variant_names =
  let reg = Blorp.Codegen_types.create_registry () in
  let variants =
    List.mapi (fun tag name -> enum_variant name tag) variant_names
  in
  Blorp.Codegen_types.register_enum_type reg name variants;
  reg

let color_enum_registry () = enum_registry "Color" [ "Red"; "Blue"; "Green" ]

let int_alias_registry () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Count" ([], ty_int);
  reg

let count_intrinsic name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKIntrinsic got, _, _) when got = name -> acc + 1
      | _ -> acc)
    0 body

let count_drop body =
  fold_tree
    (fun acc node -> match node.desc with CDrop _ -> acc + 1 | _ -> acc)
    0 body

let count_let_named name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CLet (binding, _) when binding.bind_var.vname = name -> acc + 1
      | _ -> acc)
    0 body

let count_break body =
  fold_tree
    (fun acc node -> match node.desc with CBreak -> acc + 1 | _ -> acc)
    0 body

let count_binop op body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CBin (got, _, _) when got = op -> acc + 1
      | _ -> acc)
    0 body

let count_closure_call body =
  fold_tree
    (fun acc node ->
      match node.desc with CCall (CKClosure, _, _) -> acc + 1 | _ -> acc)
    0 body

let count_builtin_call name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKBuiltin got, _, _) when got = name -> acc + 1
      | _ -> acc)
    0 body

let count_builtin_call_with_arg_count name arg_count body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKBuiltin got, _, args)
        when got = name && List.length args = arg_count ->
          acc + 1
      | _ -> acc)
    0 body

let count_collection_call name body =
  count_intrinsic name body + count_builtin_call name body

let count_cbox body =
  fold_tree
    (fun acc node -> match node.desc with CBox _ -> acc + 1 | _ -> acc)
    0 body

let count_tuple body =
  fold_tree
    (fun acc node -> match node.desc with CTuple _ -> acc + 1 | _ -> acc)
    0 body

let count_ccast body =
  fold_tree
    (fun acc node -> match node.desc with CCast _ -> acc + 1 | _ -> acc)
    0 body

let count_unknown_call name body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CCall (CKUnknown, { desc = CVar v; _ }, _) when v.vname = name ->
          acc + 1
      | _ -> acc)
    0 body

let count_tensor_raw_view_let kind body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CTensorRawViewLet ({ trv_kind; _ }, _) when trv_kind = kind -> acc + 1
      | _ -> acc)
    0 body

let count_tensor_raw_read kind body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CTensorRawRead { trr_kind; _ } when trr_kind = kind -> acc + 1
      | _ -> acc)
    0 body

let count_tensor_raw_read_result kind result_ty body =
  fold_tree
    (fun acc node ->
      match node.desc with
      | CTensorRawRead { trr_kind; _ }
        when trr_kind = kind && Blorp.Types.types_equal node.ty result_ty ->
          acc + 1
      | _ -> acc)
    0 body

let rec managed_type_for_intrinsic_test = function
  | TyNamed
      ( ( "Int" | "Bool" | "Float" | "Float32" | "Float16" | "Char" | "Void"
        | "Ptr" ),
        _ ) ->
      false
  | TyNamed
      (("List" | "Dict" | "Set" | "Option" | "Result" | "String" | "Bytes"), _)
    ->
      true
  | TyTuple tys -> List.exists managed_type_for_intrinsic_test tys
  | TyFunc _ -> true
  | TyVar _ | TyBoundVar _ | TyNamed _ -> true
  | TyArray _ -> true
  | TySelf | TyMeta _ -> true
  | TyConstInt _ | TyVarDims _ | TyRange _ | TyDimOp _ -> false

let call_returns_borrowed_alias kind arg_count =
  match Blorp.Core_ownership.contract_for_call_kind kind ~arg_count with
  | Some { result = ReturnAliasOfArg _ | ReturnBorrowed; _ } -> true
  | _ -> false

let list_remove_name name names = List.filter (fun n -> n <> name) names

let rec pattern_bound_names = function
  | PatVar name -> [ name ]
  | PatConstructor (_, pats)
  | PatQualified (_, _, pats)
  | PatTuple pats
  | PatOr pats ->
      List.concat_map pattern_bound_names pats
  | PatList (pats, spread) -> (
      List.concat_map pattern_bound_names pats
      @ match spread with Some pat -> pattern_bound_names pat | None -> [])
  | PatWildcard | PatLiteral _ -> []

let rec expr_returns_borrowed_alias borrowed expr =
  match expr.desc with
  | CVar v -> List.exists (( = ) v.vname) borrowed
  | CCall (kind, _, args) -> call_returns_borrowed_alias kind (List.length args)
  | CUnbox (inner, _) | CCast (inner, _) ->
      expr_returns_borrowed_alias borrowed inner
  | CField (owner, _) -> expr_returns_borrowed_alias borrowed owner
  | _ -> false

let borrowed_managed_alias_bindings body =
  let rec collect borrowed acc node =
    let collect_children borrowed acc node =
      fold_immediate_children (collect borrowed) acc node
    in
    match node.desc with
    | CLet (binding, body) ->
        let acc = collect borrowed acc binding.bind_rhs in
        let rhs_alias = expr_returns_borrowed_alias borrowed binding.bind_rhs in
        let acc =
          if managed_type_for_intrinsic_test binding.bind_ty && rhs_alias then
            binding.bind_var.vname :: acc
          else acc
        in
        let borrowed = list_remove_name binding.bind_var.vname borrowed in
        let borrowed =
          if rhs_alias then binding.bind_var.vname :: borrowed else borrowed
        in
        collect borrowed acc body
    | CFor (binder, iter, body) ->
        let acc = collect borrowed acc iter in
        collect (list_remove_name binder.loop_var.vname borrowed) acc body
    | CLambda lam ->
        let bound = List.map (fun (v, _) -> v.vname) lam.lam_params in
        let borrowed =
          List.fold_left
            (fun acc name -> list_remove_name name acc)
            borrowed bound
        in
        collect borrowed acc lam.lam_body
    | CMatchArms (scrut, arms) ->
        let acc = collect borrowed acc scrut in
        List.fold_left
          (fun acc (pat, arm) ->
            let borrowed =
              List.fold_left
                (fun acc name -> list_remove_name name acc)
                borrowed (pattern_bound_names pat)
            in
            collect borrowed acc arm)
          acc arms
    | _ -> collect_children borrowed acc node
  in
  List.rev (collect [] [] body)

let assert_no_borrowed_managed_alias_lets func_name body =
  let bindings = borrowed_managed_alias_bindings body in
  if bindings <> [] then
    Alcotest.failf "%s binds borrowed managed aliases as owned locals: %s"
      func_name
      (String.concat ", " bindings)

let synth_list_body func_name params return_ty =
  Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path:"std/list"
    ~params ~return_ty

let expect_no_synthesis ~module_path func_name params return_ty =
  match
    Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path ~params
      ~return_ty
  with
  | None -> ()
  | Some _ ->
      Alcotest.failf "%s.%s should not synthesize for this signature"
        module_path func_name
  | exception exn ->
      Alcotest.failf "%s.%s should return None, not raise %s" module_path
        func_name (Printexc.to_string exn)

let expect_no_list_synthesis func_name params return_ty =
  expect_no_synthesis ~module_path:"std/list" func_name params return_ty

let expect_builtin_synthesis ?arg_count ~module_path func_name params return_ty
    c_name =
  match
    Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path ~params
      ~return_ty
  with
  | None ->
      Alcotest.failf "%s.%s should synthesize from its spec entry" module_path
        func_name
  | Some body -> (
      Alcotest.(check int)
        (Printf.sprintf "%s.%s forwards to %s" module_path func_name c_name)
        1
        (count_builtin_call c_name body);
      match arg_count with
      | None -> ()
      | Some expected ->
          Alcotest.(check int)
            (Printf.sprintf "%s.%s forwards %d args" module_path func_name
               expected)
            1
            (count_builtin_call_with_arg_count c_name expected body))

let expect_intrinsic_synthesis ~module_path func_name params return_ty
    intrinsic_name =
  match
    Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path ~params
      ~return_ty
  with
  | None ->
      Alcotest.failf "%s.%s should synthesize an intrinsic body" module_path
        func_name
  | Some body ->
      Alcotest.(check int)
        (Printf.sprintf "%s.%s synthesizes %s" module_path func_name
           intrinsic_name)
        1
        (count_intrinsic intrinsic_name body)

let test_std_float_round_synthesizes_math_round () =
  expect_intrinsic_synthesis ~module_path:"std/float" "round"
    [ param "x" ty_float ] ty_float "math_round"

let test_list_synthesis_rejects_malformed_signatures () =
  let list_int = ty_list ty_int in
  let stream_int = TyNamed ("Stream", [ ty_int ]) in
  let f_int_to_int = ty_func [ ty_int ] ty_int in
  let pred_int = ty_func [ ty_int ] ty_bool in
  expect_no_list_synthesis "length"
    [ param "items" list_int; param "extra" ty_int ]
    ty_int;
  expect_no_list_synthesis "length" [ param "s" ty_string ] ty_int;
  expect_no_list_synthesis "append" [ param "items" list_int ] list_int;
  expect_no_list_synthesis "append"
    [ param "items" list_int; param "elem" ty_string ]
    list_int;
  expect_no_list_synthesis "get"
    [ param "items" list_int; param "idx" ty_string ]
    (ty_option ty_int);
  expect_no_list_synthesis "get_or"
    [ param "items" list_int; param "idx" ty_int; param "default" ty_string ]
    ty_int;
  expect_no_list_synthesis "get_or"
    [ param "items" list_int; param "idx" ty_int ]
    ty_int;
  expect_no_list_synthesis "map" [ param "items" list_int ] list_int;
  expect_no_list_synthesis "map"
    [ param "items" list_int; param "f" ty_int ]
    list_int;
  expect_no_list_synthesis "map"
    [ param "items" (ty_set ty_int); param "f" f_int_to_int ]
    (ty_set ty_int);
  expect_no_list_synthesis "take"
    [ param "items" list_int; param "n" ty_string ]
    list_int;
  expect_no_list_synthesis "concat"
    [ param "items" list_int; param "other" ty_string ]
    list_int;
  expect_no_list_synthesis "concat"
    [ param "items" list_int; param "other" (ty_list ty_string) ]
    list_int;
  expect_no_list_synthesis "find"
    [ param "items" stream_int; param "pred" pred_int ]
    (ty_option ty_int);
  expect_no_list_synthesis "find"
    [ param "items" list_int; param "pred" ty_bool ]
    (ty_option ty_int);
  expect_no_list_synthesis "zip_with"
    [ param "left" list_int; param "right" list_int; param "f" ty_int ]
    list_int;
  expect_no_list_synthesis "binary_search"
    [ param "items" list_int; param "target" ty_string ]
    (ty_option ty_int);
  expect_no_list_synthesis "range"
    [ param "start" ty_string; param "stop" ty_int ]
    list_int;
  expect_no_list_synthesis "string_append"
    [ param "items" list_int; param "other" ty_string ]
    ty_string;
  expect_no_list_synthesis "fold_left"
    [
      param "items" list_int;
      param "init" ty_int;
      param "f" f_int_to_int;
      param "extra" ty_int;
    ]
    ty_int

let test_std_synthesis_rejects_malformed_signatures () =
  let bytes_ty = TyNamed ("Bytes", []) in
  let fixed_ty = TyNamed ("Fixed", []) in
  let slice_ty = TyNamed ("StringSlice", []) in
  let stream_int = TyNamed ("Stream", [ ty_int ]) in
  let vector_int = ty_vector ty_int 4 in
  let matrix_int = TyArray (ty_int, [ TyConstInt 2; TyConstInt 2 ]) in
  expect_no_synthesis ~module_path:"std/string" "substring"
    [ param "s" ty_string; param "start" ty_int ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "reverse"
    [ param "s" ty_string; param "extra" ty_int ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "reverse"
    [ param "items" (ty_list ty_int) ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "string_with_capacity" []
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "string"
    [ param "s" ty_string ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "append_char"
    [ param "s" ty_string; param "c" ty_string ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "length"
    [ param "items" (ty_list ty_int) ]
    ty_int;
  expect_no_synthesis ~module_path:"std/string" "substring"
    [ param "s" ty_string; param "start" ty_string; param "len" ty_int ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "count"
    [
      param "items" (ty_list ty_int); param "pred" (ty_func [ ty_int ] ty_bool);
    ]
    ty_int;
  expect_no_synthesis ~module_path:"std/string" "replace"
    [ param "s" ty_string; param "old" ty_string; param "new" ty_int ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "pad_left"
    [ param "s" ty_string; param "width" ty_int; param "fill" ty_string ]
    ty_string;
  expect_no_synthesis ~module_path:"std/string" "split"
    [ param "s" ty_string ]
    (ty_list ty_string);
  expect_no_synthesis ~module_path:"std/bytes" "bytes" [] bytes_ty;
  expect_no_synthesis ~module_path:"std/bytes" "length"
    [ param "b" bytes_ty; param "extra" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/bytes" "length"
    [ param "s" ty_string ]
    ty_int;
  expect_no_synthesis ~module_path:"std/bytes" "get"
    [ param "b" bytes_ty ]
    (ty_option ty_int);
  expect_no_synthesis ~module_path:"std/bytes" "to_string"
    [ param "s" ty_string ]
    ty_string;
  expect_no_synthesis ~module_path:"std/bytes" "from_hex"
    [ param "b" bytes_ty ]
    (ty_option bytes_ty);
  expect_no_synthesis ~module_path:"std/bytes" "encode_utf8"
    [ param "chars" (ty_list ty_int); param "extra" ty_int ]
    bytes_ty;
  expect_no_synthesis ~module_path:"std/bytes" "append"
    [ param "items" (ty_list ty_int); param "value" ty_int ]
    (ty_list ty_int);
  expect_no_synthesis ~module_path:"std/bytes" "append"
    [ param "a" bytes_ty; param "b" ty_string ]
    bytes_ty;
  expect_no_synthesis ~module_path:"std/bytes" "blit"
    [
      param "dst" bytes_ty;
      param "dst_offset" ty_int;
      param "src" bytes_ty;
      param "src_offset" ty_int;
    ]
    bytes_ty;
  expect_no_synthesis ~module_path:"std/bytes" "blit"
    [
      param "dst" bytes_ty;
      param "dst_offset" ty_int;
      param "src" ty_string;
      param "src_offset" ty_int;
      param "len" ty_int;
    ]
    bytes_ty;
  expect_no_synthesis ~module_path:"std/bytes" "index_of"
    [ param "s" ty_string; param "value" ty_int; param "start" ty_int ]
    (ty_option ty_int);
  expect_no_synthesis ~module_path:"std/set" "length"
    [ param "items" (ty_set ty_int); param "extra" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/set" "contains"
    [ param "items" (ty_set ty_int) ]
    ty_bool;
  expect_no_synthesis ~module_path:"std/set" "contains"
    [ param "items" (ty_set ty_int); param "elem" ty_string ]
    ty_bool;
  expect_no_synthesis ~module_path:"std/set" "add"
    [ param "items" (ty_set ty_int); param "elem" ty_string ]
    (ty_set ty_int);
  expect_no_synthesis ~module_path:"std/set" "map"
    [ param "items" (ty_list ty_int); param "f" (ty_func [ ty_int ] ty_int) ]
    (ty_list ty_int);
  expect_no_synthesis ~module_path:"std/set" "map"
    [ param "items" (ty_set ty_int); param "f" ty_int ]
    (ty_set ty_int);
  expect_no_synthesis ~module_path:"std/set" "combine"
    [ param "items" (ty_set ty_int); param "other" (ty_list ty_int) ]
    (ty_set ty_int);
  expect_no_synthesis ~module_path:"std/set" "combine"
    [ param "items" (ty_set ty_int); param "other" (ty_set ty_string) ]
    (ty_set ty_int);
  expect_no_synthesis ~module_path:"std/set" "fold"
    [ param "items" (ty_set ty_int); param "init" ty_int; param "f" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/set" "to_list"
    [ param "items" (ty_set ty_int); param "extra" ty_int ]
    (ty_list ty_int);
  expect_no_synthesis ~module_path:"std/dict" "length"
    [ param "items" (ty_list ty_int) ]
    ty_int;
  expect_no_synthesis ~module_path:"std/dict" "contains"
    [ param "items" (ty_dict ty_string ty_int) ]
    ty_bool;
  expect_no_synthesis ~module_path:"std/dict" "contains"
    [ param "items" (ty_dict ty_string ty_int); param "key" ty_int ]
    ty_bool;
  expect_no_synthesis ~module_path:"std/dict" "get_or"
    [ param "items" (ty_dict ty_string ty_int); param "key" ty_string ]
    ty_int;
  expect_no_synthesis ~module_path:"std/dict" "get_or"
    [
      param "items" (ty_dict ty_string ty_int);
      param "key" ty_string;
      param "default" ty_string;
    ]
    ty_int;
  expect_no_synthesis ~module_path:"std/dict" "set"
    [ param "items" (ty_list ty_int); param "idx" ty_int; param "value" ty_int ]
    (ty_list ty_int);
  expect_no_synthesis ~module_path:"std/dict" "set"
    [
      param "items" (ty_dict ty_string ty_int);
      param "key" ty_string;
      param "value" ty_string;
    ]
    (ty_dict ty_string ty_int);
  expect_no_synthesis ~module_path:"std/dict" "entries"
    [ param "items" (ty_dict ty_string ty_int); param "extra" ty_int ]
    (ty_list (TyTuple [ ty_string; ty_int ]));
  expect_no_synthesis ~module_path:"std/fixed" "get_scale"
    [ param "f" fixed_ty; param "extra" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/fixed" "get_precision"
    [ param "s" ty_string ]
    ty_int;
  expect_no_synthesis ~module_path:"std/fixed" "to_int"
    [ param "f" fixed_ty; param "extra" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/fixed" "neg"
    [ param "f" fixed_ty ]
    ty_int;
  expect_no_synthesis ~module_path:"std/fixed" "round_to"
    [ param "f" fixed_ty ]
    fixed_ty;
  expect_no_synthesis ~module_path:"std/fixed" "fixed"
    [ param "value" ty_int; param "scale" ty_int ]
    fixed_ty;
  expect_no_synthesis ~module_path:"std/fixed" "to_string"
    [ param "s" ty_string ]
    ty_string;
  expect_no_synthesis ~module_path:"std/slice" "from_string"
    [ param "s" ty_string; param "extra" ty_int ]
    slice_ty;
  expect_no_synthesis ~module_path:"std/slice" "length"
    [ param "slice" slice_ty ]
    ty_string;
  expect_no_synthesis ~module_path:"std/slice" "substring"
    [ param "slice" slice_ty; param "start" ty_int ]
    slice_ty;
  expect_no_synthesis ~module_path:"std/slice" "starts_with"
    [ param "slice" slice_ty; param "prefix" slice_ty ]
    ty_bool;
  expect_no_synthesis ~module_path:"std/slice" "get"
    [ param "slice" slice_ty; param "index" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/slice" "get"
    [ param "s" ty_string; param "index" ty_int ]
    (ty_option ty_char);
  expect_no_synthesis ~module_path:"std/math" "fma"
    [ param "a" ty_float; param "b" ty_float ]
    ty_float;
  expect_no_synthesis ~module_path:"std/math" "fma"
    [ param "a" ty_int; param "b" ty_float; param "c" ty_float ]
    ty_float;
  expect_no_synthesis ~module_path:"std/math" "sin"
    [ param "x" ty_float ]
    ty_int;
  expect_no_synthesis ~module_path:"std/math" "pow"
    [ param "base" ty_float; param "exponent" ty_string ]
    ty_float;
  expect_no_synthesis ~module_path:"std/math" "is_nan"
    [ param "x" ty_float ]
    ty_int;
  expect_no_synthesis ~module_path:"std/math" "infinity"
    [ param "extra" ty_int ]
    ty_float;
  expect_no_synthesis ~module_path:"std/time" "from_parts"
    [
      param "year" ty_int;
      param "month" ty_int;
      param "day" ty_int;
      param "hour" ty_int;
      param "minute" ty_int;
      param "second" ty_int;
      param "extra" ty_int;
    ]
    ty_int;
  expect_no_synthesis ~module_path:"std/time" "from_parts"
    [
      param "year" ty_int;
      param "month" ty_string;
      param "day" ty_int;
      param "hour" ty_int;
      param "minute" ty_int;
      param "second" ty_int;
    ]
    ty_int;
  expect_no_synthesis ~module_path:"std/time" "format_time"
    [ param "microseconds" ty_int; param "fmt" ty_int ]
    ty_string;
  expect_no_synthesis ~module_path:"std/time" "to_year"
    [ param "microseconds" ty_string ]
    ty_int;
  expect_no_synthesis ~module_path:"std/system" "now_microseconds"
    [ param "extra" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/system" "now_microseconds" [] ty_string;
  expect_no_synthesis ~module_path:"std/stream" "from_range"
    [ param "start" ty_int; param "stop" ty_string ]
    stream_int;
  expect_no_synthesis ~module_path:"std/stream" "map"
    [ param "items" (ty_list ty_int); param "f" (ty_func [ ty_int ] ty_int) ]
    (ty_list ty_int);
  expect_no_synthesis ~module_path:"std/stream" "map"
    [ param "items" stream_int; param "f" ty_int ]
    stream_int;
  expect_no_synthesis ~module_path:"std/stream" "take"
    [ param "items" stream_int; param "n" ty_string ]
    stream_int;
  expect_no_synthesis ~module_path:"std/stream" "fold"
    [ param "items" stream_int; param "init" ty_int; param "f" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/stream" "unfold"
    [ param "state" ty_int; param "next" ty_int ]
    stream_int;
  expect_no_synthesis ~module_path:"std/stream" "empty"
    [ param "extra" ty_int ]
    stream_int;
  expect_no_synthesis ~module_path:"std/tensor" "length"
    [ param "items" (ty_list ty_int) ]
    ty_int;
  expect_no_synthesis ~module_path:"std/tensor" "checked_get"
    [ param "items" (ty_list ty_int); param "idx" ty_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/vector" "sum"
    [ param "items" (ty_list ty_int) ]
    ty_int;
  expect_no_synthesis ~module_path:"std/vector" "dot"
    [ param "a" vector_int ]
    ty_int;
  expect_no_synthesis ~module_path:"std/vector" "dot"
    [ param "a" vector_int; param "b" (ty_list ty_int) ]
    ty_int;
  expect_no_synthesis ~module_path:"std/matrix" "multiply"
    [ param "a" (ty_list ty_int); param "b" matrix_int ]
    matrix_int;
  expect_no_synthesis ~module_path:"std/matrix" "multiply"
    [ param "a" matrix_int; param "b" (ty_list ty_int) ]
    matrix_int;
  expect_no_synthesis ~module_path:"std/hash" "sha256"
    [ param "b" bytes_ty ]
    ty_string;
  expect_no_synthesis ~module_path:"std/hash" "sha256_bytes"
    [ param "s" ty_string ]
    ty_string;
  expect_no_synthesis ~module_path:"std/hash" "hmac_sha256"
    [ param "key" ty_string; param "msg" bytes_ty ]
    ty_string

let test_hash_wrappers_synthesize_from_specs () =
  let bytes_ty = TyNamed ("Bytes", []) in
  [
    ("hash", [ param "s" ty_string ], ty_int, "blorp_hash");
    ("hash_bytes", [ param "b" bytes_ty ], ty_int, "blorp_hash_bytes");
    ("sha256", [ param "s" ty_string ], ty_string, "blorp_sha256");
    ( "hmac_sha256",
      [ param "key" ty_string; param "msg" ty_string ],
      ty_string,
      "blorp_hmac_sha256" );
  ]
  |> List.iter (fun (func_name, params, return_ty, c_name) ->
      expect_builtin_synthesis ~module_path:"std/hash" func_name params
        return_ty c_name)

let test_time_and_system_wrappers_synthesize_from_specs () =
  let time_cases =
    [
      ("now", [], ty_int, "blorp_time_now");
      ("to_year", [ param "microseconds" ty_int ], ty_int, "blorp_time_to_year");
      ( "from_parts",
        [
          param "year" ty_int;
          param "month" ty_int;
          param "day" ty_int;
          param "hour" ty_int;
          param "minute" ty_int;
          param "second" ty_int;
        ],
        ty_int,
        "blorp_time_from_parts" );
      ( "format_time",
        [ param "microseconds" ty_int; param "fmt" ty_string ],
        ty_string,
        "blorp_time_format" );
      ( "parse_time",
        [ param "input" ty_string; param "fmt" ty_string ],
        ty_option ty_int,
        "blorp_time_parse" );
      ( "from_iso",
        [ param "input" ty_string ],
        ty_option ty_int,
        "blorp_time_from_iso" );
    ]
  in
  List.iter
    (fun (func_name, params, return_ty, c_name) ->
      expect_builtin_synthesis ~module_path:"std/time" func_name params
        return_ty c_name)
    time_cases;
  expect_builtin_synthesis ~module_path:"std/system" "now_microseconds" []
    ty_int "blorp_now_us"

let test_bytes_c_wrappers_synthesize_from_specs () =
  let bytes_ty = TyNamed ("Bytes", []) in
  [
    ("to_string", [ param "bytes" bytes_ty ], ty_string, "blorp_bytes_to_string");
    ( "from_hex",
      [ param "hex" ty_string ],
      ty_option bytes_ty,
      "blorp_bytes_from_hex" );
    ( "encode_utf8",
      [ param "chars" (ty_list ty_int) ],
      bytes_ty,
      "blorp_encode_utf8" );
    ( "decode_utf8",
      [ param "bytes" bytes_ty ],
      ty_option (ty_list ty_int),
      "blorp_decode_utf8" );
  ]
  |> List.iter (fun (func_name, params, return_ty, c_name) ->
      expect_builtin_synthesis ~module_path:"std/bytes" func_name params
        return_ty c_name)

let test_fixed_c_wrappers_synthesize_from_specs () =
  let fixed_ty = TyNamed ("Fixed", []) in
  [
    ( "fixed",
      [ param "value" ty_float; param "scale" ty_int ],
      fixed_ty,
      "blorp_fixed_new",
      3 );
    ( "with_precision",
      [ param "value" ty_float; param "scale" ty_int; param "precision" ty_int ],
      fixed_ty,
      "blorp_fixed_new",
      3 );
    ( "from_int",
      [ param "value" ty_int; param "scale" ty_int ],
      fixed_ty,
      "blorp_fixed_from_int",
      3 );
    ( "to_string",
      [ param "value" fixed_ty ],
      ty_string,
      "blorp_fixed_to_string",
      1 );
    ("to_float", [ param "value" fixed_ty ], ty_float, "blorp_fixed_to_float", 1);
  ]
  |> List.iter (fun (func_name, params, return_ty, c_name, arg_count) ->
      expect_builtin_synthesis ~arg_count ~module_path:"std/fixed" func_name
        params return_ty c_name)

let test_tensor_c_wrappers_synthesize_from_specs () =
  let vector_int = ty_vector ty_int 4 in
  let matrix_int = TyArray (ty_int, [ TyConstInt 2; TyConstInt 3 ]) in
  let tensor3_int =
    TyArray (ty_int, [ TyConstInt 2; TyConstInt 3; TyConstInt 4 ])
  in
  let tensor4_int =
    TyArray (ty_int, [ TyConstInt 2; TyConstInt 3; TyConstInt 4; TyConstInt 5 ])
  in
  let tensor5_int =
    TyArray
      ( ty_int,
        [ TyConstInt 2; TyConstInt 3; TyConstInt 4; TyConstInt 5; TyConstInt 6 ]
      )
  in
  let cases =
    [
      ( "vector",
        [ param "value" ty_int; param "size" ty_int ],
        vector_int,
        "blorp_vector_new_fill",
        2 );
      ( "matrix",
        [ param "value" ty_int; param "rows" ty_int; param "cols" ty_int ],
        matrix_int,
        "blorp_matrix_new_fill",
        3 );
      ( "tensor3",
        [
          param "value" ty_int;
          param "x" ty_int;
          param "y" ty_int;
          param "z" ty_int;
        ],
        tensor3_int,
        "blorp_tensor3_new",
        4 );
      ( "tensor4",
        [
          param "value" ty_int;
          param "d1" ty_int;
          param "d2" ty_int;
          param "d3" ty_int;
          param "d4" ty_int;
        ],
        tensor4_int,
        "blorp_tensor4_new",
        5 );
      ( "tensor5",
        [
          param "value" ty_int;
          param "d1" ty_int;
          param "d2" ty_int;
          param "d3" ty_int;
          param "d4" ty_int;
          param "d5" ty_int;
        ],
        tensor5_int,
        "blorp_tensor5_new",
        6 );
      ( "checked_get",
        [ param "items" vector_int; param "idx" ty_int ],
        ty_int,
        "blorp_checked_get",
        2 );
      ( "checked_set",
        [ param "items" vector_int; param "idx" ty_int; param "value" ty_int ],
        vector_int,
        "blorp_checked_set",
        3 );
      ( "checked_slice",
        [
          param "items" vector_int; param "start" ty_int; param "end_idx" ty_int;
        ],
        vector_int,
        "blorp_checked_slice",
        3 );
      ( "matrix_checked_get",
        [ param "items" matrix_int; param "row" ty_int; param "col" ty_int ],
        ty_int,
        "blorp_matrix_checked_get",
        3 );
      ( "matrix_checked_set",
        [
          param "items" matrix_int;
          param "row" ty_int;
          param "col" ty_int;
          param "value" ty_int;
        ],
        matrix_int,
        "blorp_matrix_checked_set",
        4 );
      ( "tensor3_checked_get",
        [
          param "items" tensor3_int;
          param "i" ty_int;
          param "j" ty_int;
          param "k" ty_int;
        ],
        ty_int,
        "blorp_tensor3_checked_get",
        4 );
      ( "tensor3_checked_set",
        [
          param "items" tensor3_int;
          param "i" ty_int;
          param "j" ty_int;
          param "k" ty_int;
          param "value" ty_int;
        ],
        tensor3_int,
        "blorp_tensor3_checked_set",
        5 );
      ( "tensor4_checked_get",
        [
          param "items" tensor4_int;
          param "i" ty_int;
          param "j" ty_int;
          param "k" ty_int;
          param "l" ty_int;
        ],
        ty_int,
        "blorp_tensor4_checked_get",
        5 );
      ( "tensor4_checked_set",
        [
          param "items" tensor4_int;
          param "i" ty_int;
          param "j" ty_int;
          param "k" ty_int;
          param "l" ty_int;
          param "value" ty_int;
        ],
        tensor4_int,
        "blorp_tensor4_checked_set",
        6 );
      ( "tensor5_checked_get",
        [
          param "items" tensor5_int;
          param "i" ty_int;
          param "j" ty_int;
          param "k" ty_int;
          param "l" ty_int;
          param "m" ty_int;
        ],
        ty_int,
        "blorp_tensor5_checked_get",
        6 );
      ( "tensor5_checked_set",
        [
          param "items" tensor5_int;
          param "i" ty_int;
          param "j" ty_int;
          param "k" ty_int;
          param "l" ty_int;
          param "m" ty_int;
          param "value" ty_int;
        ],
        tensor5_int,
        "blorp_tensor5_checked_set",
        7 );
      ( "tensor_peel",
        [ param "items" matrix_int; param "row" ty_int ],
        vector_int,
        "blorp_tensor_peel",
        2 );
    ]
  in
  cases
  |> List.iter (fun (func_name, params, return_ty, c_name, arg_count) ->
      expect_builtin_synthesis ~arg_count ~module_path:"std/tensor" func_name
        params return_ty c_name)

let test_tensor_length_synthesizes_from_specs () =
  let vector_int = ty_vector ty_int 4 in
  [ ("std/tensor", "length"); ("std/vector", "length") ]
  |> List.iter (fun (module_path, func_name) ->
      match
        Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path
          ~params:[ param "items" vector_int ]
          ~return_ty:ty_int
      with
      | Some body ->
          Alcotest.(check int)
            (module_path ^ "." ^ func_name ^ " emits tensor_len")
            1
            (count_intrinsic "tensor_len" body)
      | None ->
          Alcotest.failf "%s.%s should synthesize through its spec" module_path
            func_name)

let test_matrix_c_wrappers_synthesize_from_specs () =
  let left_matrix = TyArray (ty_int, [ TyConstInt 2; TyConstInt 3 ]) in
  let right_matrix = TyArray (ty_int, [ TyConstInt 3; TyConstInt 4 ]) in
  let matrix_multiply_result =
    TyArray (ty_int, [ TyConstInt 2; TyConstInt 4 ])
  in
  let transposed = TyArray (ty_int, [ TyConstInt 3; TyConstInt 2 ]) in
  let vector2 = ty_vector ty_int 2 in
  let vector3 = ty_vector ty_int 3 in
  let outer_result = TyArray (ty_int, [ TyConstInt 2; TyConstInt 3 ]) in
  [
    ( "multiply",
      [ param "a" left_matrix; param "b" right_matrix ],
      matrix_multiply_result,
      "blorp_tensor_matrix_multiply",
      2 );
    ( "transpose",
      [ param "m" left_matrix ],
      transposed,
      "blorp_tensor_transpose",
      1 );
    ( "multiply_vector",
      [ param "m" left_matrix; param "v" vector3 ],
      vector2,
      "blorp_tensor_matrix_vector_multiply",
      2 );
    ( "multiply_transposed_vector",
      [ param "m" left_matrix; param "v" vector2 ],
      vector3,
      "blorp_tensor_transposed_matrix_vector_multiply",
      2 );
    ( "outer",
      [ param "a" vector2; param "b" vector3 ],
      outer_result,
      "blorp_tensor_outer",
      2 );
  ]
  |> List.iter (fun (func_name, params, return_ty, c_name, arg_count) ->
      expect_builtin_synthesis ~arg_count ~module_path:"std/matrix" func_name
        params return_ty c_name)

let test_stream_wrappers_synthesize_from_specs () =
  let stream_int = TyNamed ("Stream", [ ty_int ]) in
  let stream_cases =
    [
      ( "from_list",
        [ param "items" (ty_list ty_int) ],
        stream_int,
        "blorp_stream_from_list" );
      ( "from_range",
        [ param "start" ty_int; param "stop" ty_int ],
        stream_int,
        "blorp_stream_from_range" );
      ("repeat", [ param "value" ty_int ], stream_int, "blorp_stream_repeat");
      ( "unfold",
        [ param "state" ty_int; param "next" (ty_func [ ty_int ] stream_int) ],
        stream_int,
        "blorp_stream_unfold" );
      ("empty", [], stream_int, "blorp_stream_empty");
      ( "map",
        [ param "items" stream_int; param "f" (ty_func [ ty_int ] ty_int) ],
        stream_int,
        "blorp_stream_map" );
      ( "take",
        [ param "items" stream_int; param "n" ty_int ],
        stream_int,
        "blorp_stream_take" );
      ( "collect",
        [ param "items" stream_int ],
        ty_list ty_int,
        "blorp_stream_collect" );
      ( "fold",
        [
          param "items" stream_int;
          param "init" ty_int;
          param "f" (ty_func [ ty_int; ty_int ] ty_int);
        ],
        ty_int,
        "blorp_stream_fold" );
      ( "for_each",
        [ param "items" stream_int; param "f" (ty_func [ ty_int ] ty_void) ],
        ty_void,
        "blorp_stream_for_each" );
      ( "find",
        [ param "items" stream_int; param "pred" (ty_func [ ty_int ] ty_bool) ],
        ty_option ty_int,
        "blorp_stream_find" );
    ]
  in
  List.iter
    (fun (func_name, params, return_ty, c_name) ->
      expect_builtin_synthesis ~module_path:"std/stream" func_name params
        return_ty c_name)
    stream_cases

let assert_list_strategy_shape func_name params return_ty =
  let strategy =
    match
      Blorp.Core_ownership.collection_strategy ~module_path:"std/list"
        ~func_name
    with
    | Some s -> s
    | None -> Alcotest.failf "missing list strategy for %s" func_name
  in
  let body =
    match synth_list_body func_name params return_ty with
    | Some body -> body
    | None ->
        Alcotest.failf "List.%s should synthesize a Core IR body" func_name
  in
  (match strategy.result_collection with
  | Blorp.Core_ownership.ReuseReceiver { cow_boundary; reserve_for_len } ->
      Alcotest.(check int)
        (func_name ^ " has one COW/reuse boundary")
        1
        (count_intrinsic cow_boundary body);
      Alcotest.(check int)
        (func_name ^ " does not allocate fresh result")
        0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        (func_name ^ " reserve boundary count")
        0
        (match reserve_for_len with
        | Some name -> count_intrinsic name body
        | None -> count_intrinsic "set_reserve_for_len" body)
  | AllocateFresh { alloc; growth; reserve_for_len } ->
      Alcotest.(check bool)
        (func_name ^ " allocates fresh result")
        true
        (count_intrinsic alloc body > 0);
      let expected_growth = match growth with Some _ -> 1 | None -> 0 in
      let actual_growth =
        match growth with
        | Some name -> count_intrinsic name body
        | None -> count_intrinsic "list_ensure_capacity" body
      in
      Alcotest.(check int)
        (func_name ^ " growth boundary count")
        expected_growth actual_growth;
      Alcotest.(check int)
        (func_name ^ " reserve boundary count")
        0
        (match reserve_for_len with
        | Some name -> count_intrinsic name body
        | None -> count_intrinsic "set_reserve_for_len" body)
  | NoCollectionResult ->
      Alcotest.(check int)
        (func_name ^ " has no fresh list allocation")
        0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        (func_name ^ " has no list growth boundary")
        0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        (func_name ^ " has no list uniqueness boundary")
        0
        (count_intrinsic "list_ensure_unique" body));
  (match strategy.element_storage with
  | RetainInputElement | RetainBorrowedElement | RetainInputAndBorrowedElements
    ->
      Alcotest.(check bool)
        (func_name ^ " retains stored input")
        true
        (count_intrinsic "list_retain_for" body > 0)
  | TransferProducedElement ->
      Alcotest.(check bool)
        (func_name ^ " transfers produced elements")
        true
        (count_intrinsic "list_set_owned" body > 0)
  | NoElementStorage -> ());
  body

let test_list_strategy_contract_matches_synthesized_ir () =
  ignore
    (assert_list_strategy_shape "append"
       [ param "self" (ty_list ty_string); param "elem" ty_string ]
       (ty_list ty_string));
  ignore
    (assert_list_strategy_shape "set"
       [
         param "self" (ty_list ty_string);
         param "index" ty_int;
         param "elem" ty_string;
       ]
       (ty_list ty_string));
  ignore
    (assert_list_strategy_shape "map"
       [
         param "self" (ty_list ty_int); param "f" (ty_func [ ty_int ] ty_string);
       ]
       (ty_list ty_string));
  ignore
    (assert_list_strategy_shape "filter"
       [
         param "self" (ty_list ty_string);
         param "pred" (ty_func [ ty_string ] ty_bool);
       ]
       (ty_list ty_string));
  ignore
    (assert_list_strategy_shape "flat_map"
       [
         param "self" (ty_list ty_int);
         param "f" (ty_func [ ty_int ] (ty_list ty_string));
       ]
       (ty_list ty_string));
  ignore
    (assert_list_strategy_shape "fold_left"
       [
         param "self" (ty_list ty_int);
         param "init" ty_string;
         param "f" (ty_func [ ty_string; ty_int ] ty_string);
       ]
       ty_string)

let test_list_synthesized_ir_does_not_own_borrowed_aliases () =
  let list_string = ty_list ty_string in
  let list_int = ty_list ty_int in
  let option_string = ty_option ty_string in
  let option_int = ty_option ty_int in
  let list_list_string = ty_list list_string in
  let tuple_string_int = TyTuple [ ty_string; ty_int ] in
  let list_tuple_string_int = ty_list tuple_string_int in
  let tuple_int_string = TyTuple [ ty_int; ty_string ] in
  let list_tuple_int_string = ty_list tuple_int_string in
  let cases =
    [
      ("concat", [ param "a" list_string; param "b" list_string ], list_string);
      ("take", [ param "self" list_string; param "n" ty_int ], list_string);
      ("drop", [ param "self" list_string; param "n" ty_int ], list_string);
      ( "get_or",
        [
          param "self" list_string;
          param "index" ty_int;
          param "default" ty_string;
        ],
        ty_string );
      ( "intersperse",
        [ param "self" list_string; param "sep" ty_string ],
        list_string );
      ( "windows",
        [ param "self" list_string; param "size" ty_int ],
        list_list_string );
      ( "chunks",
        [ param "self" list_string; param "size" ty_int ],
        list_list_string );
      ( "map",
        [ param "self" list_string; param "f" (ty_func [ ty_string ] ty_int) ],
        list_int );
      ( "map_indexed",
        [
          param "self" list_string;
          param "f" (ty_func [ ty_int; ty_string ] ty_int);
        ],
        list_int );
      ( "filter",
        [
          param "self" list_string;
          param "predicate" (ty_func [ ty_string ] ty_bool);
        ],
        list_string );
      ( "filter_map",
        [
          param "self" list_string; param "f" (ty_func [ ty_string ] option_int);
        ],
        list_int );
      ( "fold_left",
        [
          param "self" list_string;
          param "init" ty_int;
          param "f" (ty_func [ ty_int; ty_string ] ty_int);
        ],
        ty_int );
      ( "fold_right",
        [
          param "self" list_string;
          param "init" ty_int;
          param "f" (ty_func [ ty_string; ty_int ] ty_int);
        ],
        ty_int );
      ( "for_each",
        [ param "self" list_string; param "f" (ty_func [ ty_string ] ty_void) ],
        ty_void );
      ( "all",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        ty_bool );
      ( "any",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        ty_bool );
      ( "find",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        option_string );
      ( "find_index",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        option_int );
      ( "count",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        ty_int );
      ( "take_while",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        list_string );
      ( "drop_while",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        list_string );
      ( "partition",
        [
          param "self" list_string; param "pred" (ty_func [ ty_string ] ty_bool);
        ],
        TyTuple [ list_string; list_string ] );
      ( "flat_map",
        [ param "self" list_string; param "f" (ty_func [ ty_string ] list_int) ],
        list_int );
      ( "binary_search_by",
        [
          param "sorted" list_string;
          param "target" ty_string;
          param "compare" (ty_func [ ty_string; ty_string ] ty_int);
        ],
        option_int );
      ( "min_by",
        [ param "self" list_string; param "f" (ty_func [ ty_string ] ty_int) ],
        option_string );
      ( "max_by",
        [ param "self" list_string; param "f" (ty_func [ ty_string ] ty_int) ],
        option_string );
      ( "scan",
        [
          param "self" list_string;
          param "init" ty_int;
          param "f" (ty_func [ ty_int; ty_string ] ty_int);
        ],
        list_int );
      ( "sort_by",
        [
          param "self" list_string;
          param "key_fn" (ty_func [ ty_string ] ty_int);
        ],
        list_string );
      ( "sort_desc_by",
        [
          param "self" list_string;
          param "key_fn" (ty_func [ ty_string ] ty_int);
        ],
        list_string );
      ("sort", [ param "self" list_string ], list_string);
      ("enumerate", [ param "self" list_string ], list_tuple_int_string);
      ( "zip",
        [ param "list_a" list_string; param "list_b" list_int ],
        list_tuple_string_int );
      ( "zip_with",
        [
          param "list_a" list_string;
          param "list_b" list_int;
          param "f" (ty_func [ ty_string; ty_int ] ty_string);
        ],
        list_string );
      ( "unzip",
        [ param "self" list_tuple_string_int ],
        TyTuple [ list_string; list_int ] );
      ("flatten", [ param "lists" list_list_string ], list_string);
      ("unique", [ param "self" list_string ], list_string);
    ]
  in
  List.iter
    (fun (func_name, params, return_ty) ->
      match synth_list_body func_name params return_ty with
      | Some body -> assert_no_borrowed_managed_alias_lets func_name body
      | None ->
          Alcotest.failf "List.%s should synthesize a Core IR body" func_name)
    cases

let assert_collection_result_strategy_shape ~module_path ~func_name params
    return_ty =
  let strategy =
    match Blorp.Core_ownership.collection_strategy ~module_path ~func_name with
    | Some s -> s
    | None ->
        Alcotest.failf "missing collection strategy for %s.%s" module_path
          func_name
  in
  let body =
    match
      Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path ~params
        ~return_ty
    with
    | Some body -> body
    | None ->
        Alcotest.failf "%s.%s should synthesize a Core IR body" module_path
          func_name
  in
  (match strategy.result_collection with
  | Blorp.Core_ownership.ReuseReceiver { cow_boundary; reserve_for_len } -> (
      Alcotest.(check bool)
        (func_name ^ " uses its COW-consuming mutator")
        true
        (count_collection_call cow_boundary body > 0);
      match reserve_for_len with
      | Some name ->
          Alcotest.(check bool)
            (func_name ^ " uses reserve strategy")
            true
            (count_collection_call name body > 0)
      | None -> ())
  | Blorp.Core_ownership.AllocateFresh { alloc; growth; reserve_for_len } -> (
      Alcotest.(check bool)
        (func_name ^ " allocates through strategy")
        true
        (count_collection_call alloc body > 0);
      (match growth with
      | Some name ->
          Alcotest.(check bool)
            (func_name ^ " uses growth strategy")
            true
            (count_collection_call name body > 0)
      | None -> ());
      match reserve_for_len with
      | Some name ->
          Alcotest.(check bool)
            (func_name ^ " uses reserve strategy")
            true
            (count_collection_call name body > 0)
      | None -> ())
  | Blorp.Core_ownership.NoCollectionResult ->
      Alcotest.(check int)
        (func_name ^ " has no list allocation")
        0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        (func_name ^ " has no set allocation")
        0
        (count_builtin_call "blorp_set_new" body));
  body

let test_set_dict_strategy_contract_matches_synthesized_ir () =
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/set"
       ~func_name:"combine"
       [ param "a" (ty_set ty_int); param "b" (ty_set ty_int) ]
       (ty_set ty_int));
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/set"
       ~func_name:"map"
       [
         param "self" (ty_set ty_int); param "f" (ty_func [ ty_int ] ty_string);
       ]
       (ty_set ty_string));
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/set"
       ~func_name:"filter"
       [
         param "self" (ty_set ty_int); param "pred" (ty_func [ ty_int ] ty_bool);
       ]
       (ty_set ty_int));
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/set"
       ~func_name:"fold"
       [
         param "self" (ty_set ty_int);
         param "init" ty_string;
         param "f" (ty_func [ ty_string; ty_int ] ty_string);
       ]
       ty_string);
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/set"
       ~func_name:"to_list"
       [ param "self" (ty_set ty_string) ]
       (ty_list ty_string));
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/dict"
       ~func_name:"keys"
       [ param "self" (ty_dict ty_string ty_int) ]
       (ty_list ty_string));
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/dict"
       ~func_name:"values"
       [ param "self" (ty_dict ty_string ty_int) ]
       (ty_list ty_int));
  ignore
    (assert_collection_result_strategy_shape ~module_path:"std/dict"
       ~func_name:"entries"
       [ param "self" (ty_dict ty_string ty_int) ]
       (ty_list (TyTuple [ ty_string; ty_int ])))

let test_dict_set_synthesizes_direct_cow_insert () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"set"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_string ty_string);
          param "key" ty_string;
          param "value" ty_string;
        ]
      ~return_ty:(ty_dict ty_string ty_string)
  in
  match body with
  | None -> Alcotest.fail "Dict.set should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "COWs receiver once" 1
        (count_intrinsic "dict_cow" body);
      Alcotest.(check int)
        "does not delegate to runtime dict_insert" 0
        (count_builtin_call "blorp_dict_insert" body);
      Alcotest.(check int)
        "hashes key once" 1
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "compares occupied keys" 1
        (count_intrinsic "dict_eq" body);
      Alcotest.(check int)
        "retains new keys before slot transfer" 1
        (count_intrinsic "dict_retain_key_for" body);
      Alcotest.(check int)
        "retains stored values before slot transfer" 2
        (count_intrinsic "dict_retain_value_for" body);
      Alcotest.(check int)
        "releases overwritten values on update" 1
        (count_intrinsic "dict_release_value_for" body);
      Alcotest.(check int)
        "writes key slots directly" 1
        (count_intrinsic "dict_set_key_at" body);
      Alcotest.(check int)
        "writes value slots directly" 2
        (count_intrinsic "dict_set_value_at" body);
      Alcotest.(check int)
        "resizes after insert threshold" 1
        (count_intrinsic "dict_resize" body);
      Alcotest.(check int)
        "uses non-owning casts for String key/value" 2 (count_ccast body);
      Alcotest.(check int)
        "does not owning-box String key/value" 0 (count_cbox body)

let test_dict_set_int_key_uses_immediate_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"set"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_int ty_int);
          param "key" ty_int;
          param "value" ty_int;
        ]
      ~return_ty:(ty_dict ty_int ty_int)
  in
  match body with
  | None -> Alcotest.fail "Dict.set[Int, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate key hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate key equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "does not dispatch through dict equality function pointer" 0
        (count_intrinsic "dict_eq" body)

let test_dict_set_enum_key_uses_registered_immediate_probe () =
  let reg = color_enum_registry () in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"set"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_color ty_string);
          param "key" ty_color;
          param "value" ty_string;
        ]
      ~return_ty:(ty_dict ty_color ty_string)
  in
  match body with
  | None ->
      Alcotest.fail "Dict.set[Color, String] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate enum key hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate enum key equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "does not dispatch through dict equality function pointer" 0
        (count_intrinsic "dict_eq" body);
      Alcotest.(check int)
        "boxes enum key as immediate table storage" 1 (count_cbox body);
      Alcotest.(check int)
        "borrows managed string value through cast" 1 (count_ccast body)

let test_dict_contains_int_uses_direct_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/dict"
      ~params:[ param "self" (ty_dict ty_int ty_int); param "key" ty_int ]
      ~return_ty:ty_bool
  in
  match body with
  | None ->
      Alcotest.fail "Dict.contains[Int, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate key hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate key equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "does not allocate an Option through dict_get" 0
        (count_builtin_call "blorp_dict_get" body);
      Alcotest.(check int)
        "does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "does not dispatch through dict equality function pointer" 0
        (count_intrinsic "dict_eq" body)

let test_dict_contains_enum_uses_registered_immediate_probe () =
  let reg = color_enum_registry () in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"contains"
      ~module_path:"std/dict"
      ~params:[ param "self" (ty_dict ty_color ty_int); param "key" ty_color ]
      ~return_ty:ty_bool
  in
  match body with
  | None ->
      Alcotest.fail "Dict.contains[Color, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate enum key hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate enum key equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "does not dispatch through dict equality function pointer" 0
        (count_intrinsic "dict_eq" body);
      Alcotest.(check int)
        "boxes enum lookup key as immediate table storage" 1 (count_cbox body)

let test_dict_contains_string_uses_dispatched_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/dict"
      ~params:[ param "self" (ty_dict ty_string ty_int); param "key" ty_string ]
      ~return_ty:ty_bool
  in
  match body with
  | None ->
      Alcotest.fail
        "Dict.contains[String, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses dict key hash callback" 1
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "uses dict key equality callback" 1
        (count_intrinsic "dict_eq" body);
      Alcotest.(check int)
        "does not allocate an Option through dict_get" 0
        (count_builtin_call "blorp_dict_get" body);
      Alcotest.(check int)
        "uses non-owning cast for String key" 1 (count_ccast body);
      Alcotest.(check int) "does not owning-box String key" 0 (count_cbox body)

let test_dict_get_or_synthesizes_option_free_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"get_or"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_string ty_string);
          param "key" ty_string;
          param "default" ty_string;
        ]
      ~return_ty:ty_string
  in
  match body with
  | None -> Alcotest.fail "Dict.get_or should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "hashes key once" 1
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "reads stored value directly" 1
        (count_intrinsic "dict_value_at" body);
      Alcotest.(check int)
        "retains borrowed value before return" 1
        (count_intrinsic "dict_retain_value_for" body);
      Alcotest.(check int)
        "does not allocate Option via dict_get" 0
        (count_builtin_call "blorp_dict_get" body);
      Alcotest.(check int)
        "does not construct Some" 0
        (count_unknown_call "Some" body)

let test_dict_get_or_int_key_uses_direct_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"get_or"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_int ty_int);
          param "key" ty_int;
          param "default" ty_int;
        ]
      ~return_ty:ty_int
  in
  match body with
  | None ->
      Alcotest.fail "Dict.get_or[Int, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate key hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate key equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "does not dispatch through dict equality function pointer" 0
        (count_intrinsic "dict_eq" body);
      Alcotest.(check int)
        "boxes immediate key for table probing" 1 (count_cbox body)

let test_dict_get_or_int_alias_key_uses_direct_probe () =
  let reg = int_alias_registry () in
  let dict_ty = ty_dict ty_count ty_int in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"get_or"
      ~module_path:"std/dict"
      ~params:
        [ param "self" dict_ty; param "key" ty_count; param "default" ty_int ]
      ~return_ty:ty_int
  in
  match body with
  | None ->
      Alcotest.fail "Dict.get_or[Count, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "alias key uses direct immediate hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "alias key uses direct immediate equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "alias key does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "alias key is boxed for immediate table probing" 1 (count_cbox body)

let test_dict_get_or_enum_key_uses_direct_probe () =
  let reg = color_enum_registry () in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"get_or"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_color ty_string);
          param "key" ty_color;
          param "default" ty_string;
        ]
      ~return_ty:ty_string
  in
  match body with
  | None ->
      Alcotest.fail
        "Dict.get_or[Color, String] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate enum hash" 1
        (count_intrinsic "dict_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate enum equality" 1
        (count_intrinsic "dict_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through dict hash function pointer" 0
        (count_intrinsic "dict_hash" body);
      Alcotest.(check int)
        "does not dispatch through dict equality function pointer" 0
        (count_intrinsic "dict_eq" body);
      Alcotest.(check int)
        "boxes enum lookup key as immediate table storage" 1 (count_cbox body)

let test_dict_entries_synthesizes_direct_tuple_list () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"entries"
      ~module_path:"std/dict"
      ~params:[ param "self" (ty_dict ty_string ty_int) ]
      ~return_ty:(ty_list (TyTuple [ ty_string; ty_int ]))
  in
  match body with
  | None -> Alcotest.fail "Dict.entries should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "allocates one result list" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "marks tuple list elements as ARC-managed" 1
        (count_intrinsic "list_set_elem_release" body);
      Alcotest.(check int)
        "scans insertion order directly" 1
        (count_intrinsic "dict_order_get" body);
      Alcotest.(check int)
        "reads keys directly" 1
        (count_intrinsic "dict_key_at" body);
      Alcotest.(check int)
        "reads values directly" 1
        (count_intrinsic "dict_value_at" body);
      Alcotest.(check int) "constructs tuple entries" 1 (count_tuple body);
      Alcotest.(check int)
        "transfers tuple owners into result list" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "does not delegate to runtime dict_entries" 0
        (count_builtin_call "blorp_dict_entries" body)

let test_generic_dict_contains_defers_to_post_mono_synthesis () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/dict"
      ~params:
        [ param "self" (ty_dict ty_var_t ty_var_t); param "key" ty_var_t ]
      ~return_ty:ty_bool
  in
  Alcotest.(check bool)
    "generic Dict.contains should defer" true (Option.is_none body)

let test_generic_dict_set_defers_to_post_mono_synthesis () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"set"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_var_t ty_var_t);
          param "key" ty_var_t;
          param "value" ty_var_t;
        ]
      ~return_ty:(ty_dict ty_var_t ty_var_t)
  in
  Alcotest.(check bool)
    "generic Dict.set should defer" true (Option.is_none body)

let test_generic_dict_get_or_defers_to_post_mono_synthesis () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"get_or"
      ~module_path:"std/dict"
      ~params:
        [
          param "self" (ty_dict ty_var_t ty_var_t);
          param "key" ty_var_t;
          param "default" ty_var_t;
        ]
      ~return_ty:ty_var_t
  in
  Alcotest.(check bool)
    "generic Dict.get_or should defer" true (Option.is_none body)

let test_list_map_synthesizes_presized_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"map"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "f" (ty_func [ ty_int ] ty_string);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.map should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "single list_set_owned in loop body" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_concurrent_synthesizes_concurrently_loop () =
  let return_ty = ty_list (ty_result ty_string ty_concurrency_error) in
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"concurrent"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "limit" ty_int;
          param "f" (ty_func [ ty_int ] ty_string);
        ]
      ~return_ty
  in
  match body with
  | None -> Alcotest.fail "List.concurrent should synthesize Core"
  | Some { desc = CConcurrentlyLoop cf; ty; _ } -> (
      Alcotest.(check string)
        "result type"
        (Blorp.Types.type_to_string return_ty)
        (Blorp.Types.type_to_string ty);
      Alcotest.(check string)
        "task body return" "String"
        (Blorp.Types.type_to_string cf.cf_body.ty);
      Alcotest.(check bool)
        "concurrent collects results" true
        (match cf.cf_output with
        | ConcurrentlyLoopCollect -> true
        | ConcurrentlyLoopDiscard -> false);
      match cf.cf_width with
      | ConcurrentlyLoopLimit limit ->
          Alcotest.(check string)
            "limit type" "Int"
            (Blorp.Types.type_to_string limit.ty))
  | Some _ -> Alcotest.fail "expected synthesized CConcurrentlyLoop"

let test_list_concurrent_timeout_synthesizes_concurrently_loop () =
  let return_ty = ty_list (ty_result ty_string ty_concurrency_error) in
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"__concurrent_timeout_ms"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "limit" ty_int;
          param "timeout_ms" ty_int;
          param "f" (ty_func [ ty_int ] ty_string);
        ]
      ~return_ty
  in
  match body with
  | None -> Alcotest.fail "List.concurrent_with_timeout should synthesize Core"
  | Some { desc = CConcurrentlyLoop cf; _ } -> (
      Alcotest.(check bool)
        "timeout attached" true
        (Option.is_some cf.cf_timeout);
      match cf.cf_timeout with
      | Some timeout ->
          Alcotest.(check string)
            "timeout type" "Int"
            (Blorp.Types.type_to_string timeout.ty)
      | None -> Alcotest.fail "expected timeout expression")
  | Some _ -> Alcotest.fail "expected synthesized CConcurrentlyLoop"

let test_list_filter_synthesizes_retain_then_transfer_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"filter"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "pred" (ty_func [ ty_string ] (TyNamed ("Bool", [])));
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.filter should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "retains kept borrowed elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers retained elements into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_get_or_synthesizes_option_free_bounds_check () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"get_or"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "index" ty_int;
          param "default" ty_string;
        ]
      ~return_ty:ty_string
  in
  match body with
  | None -> Alcotest.fail "List.get_or should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "reads element after explicit bounds proof" 1
        (count_intrinsic "list_get_unchecked" body);
      Alcotest.(check int)
        "retains returned borrowed element" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "does not allocate a list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "does not use append growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "does not construct Some" 0
        (count_unknown_call "Some" body)

let test_list_get_synthesizes_checked_option () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"get"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string); param "index" ty_int ]
      ~return_ty:(ty_option ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.get should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "bounds check reads length" 1
        (count_intrinsic "list_len" body);
      Alcotest.(check int)
        "reads element after explicit bounds proof" 1
        (count_intrinsic "list_get_unchecked" body);
      Alcotest.(check int)
        "retains returned borrowed element" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "constructs Some on hit" 1
        (count_unknown_call "Some" body);
      assert_no_borrowed_managed_alias_lets "List.get" body

let test_list_set_synthesizes_option_free_cow_set () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"set"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "index" ty_int;
          param "elem" ty_string;
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.set should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses COW uniqueness before mutation" 1
        (count_intrinsic "list_ensure_unique" body);
      Alcotest.(check int)
        "releases overwritten slot" 1
        (count_intrinsic "list_release_elem" body);
      Alcotest.(check int)
        "retains inserted element" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "writes slot directly" 1
        (count_intrinsic "list_set" body);
      Alcotest.(check int)
        "does not use append growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "does not construct Some" 0
        (count_unknown_call "Some" body)

let test_list_filter_map_synthesizes_single_alloc_transfer_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"filter_map"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "f" (ty_func [ ty_string ] (ty_option ty_int));
        ]
      ~return_ty:(ty_list ty_int)
  in
  match body with
  | None -> Alcotest.fail "List.filter_map should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "transfers callback-produced values into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "shrinks result to kept count once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "leaves matched option wrapper to Perceus" 0 (count_drop body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let assert_fold_synthesizes_direct_loop name =
  let callback_ty =
    match name with
    | "fold_right" -> ty_func [ ty_int; ty_string ] ty_string
    | _ -> ty_func [ ty_string; ty_int ] ty_string
  in
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:name
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "init" ty_string;
          param "f" callback_ty;
        ]
      ~return_ty:ty_string
  in
  match body with
  | None -> Alcotest.failf "List.%s should synthesize a Core IR body" name
  | Some body ->
      Alcotest.(check int)
        "no output allocation" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads source elements directly" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "calls callback once in synthesized body" 1 (count_closure_call body);
      Alcotest.(check int)
        "leaves accumulator drops to Perceus" 0 (count_drop body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_fold_synthesizes_direct_loop () =
  assert_fold_synthesizes_direct_loop "fold_left";
  assert_fold_synthesizes_direct_loop "fold_right"

let test_list_map_indexed_synthesizes_presized_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"map_indexed"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "f" (ty_func [ ty_int; ty_int ] ty_string);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.map_indexed should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads input elements via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "transfers callback results into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_enumerate_synthesizes_presized_tuple_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"enumerate"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string) ]
      ~return_ty:(ty_list (TyTuple [ ty_int; ty_string ]))
  in
  match body with
  | None -> Alcotest.fail "List.enumerate should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads input elements via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "constructs tuple element once in loop body" 1 (count_tuple body);
      Alcotest.(check int)
        "transfers tuple results into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_zip_synthesizes_presized_tuple_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"zip"
      ~module_path:"std/list"
      ~params:
        [ param "list_a" (ty_list ty_int); param "list_b" (ty_list ty_string) ]
      ~return_ty:(ty_list (TyTuple [ ty_int; ty_string ]))
  in
  match body with
  | None -> Alcotest.fail "List.zip should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads both lists via list_get" 2
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "constructs tuple element once in loop body" 1 (count_tuple body);
      Alcotest.(check int)
        "transfers tuple results into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_zip_with_synthesizes_presized_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"zip_with"
      ~module_path:"std/list"
      ~params:
        [
          param "list_a" (ty_list ty_int);
          param "list_b" (ty_list ty_string);
          param "f" (ty_func [ ty_int; ty_string ] ty_string);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.zip_with should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads both lists via list_get" 2
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "transfers callback results into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_unzip_synthesizes_two_presized_outputs () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"unzip"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list (TyTuple [ ty_int; ty_string ])) ]
      ~return_ty:(TyTuple [ ty_list ty_int; ty_list ty_string ])
  in
  match body with
  | None -> Alcotest.fail "List.unzip should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "two exact output allocations" 2
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads source pairs via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains both borrowed tuple fields" 2
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "stores both retained fields without consuming" 2
        (count_intrinsic "list_set" body);
      Alcotest.(check int)
        "does not transfer direct tuple field aliases" 0
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "does not bind borrowed tuple as owned local" 0
        (count_let_named "__pair" body);
      Alcotest.(check int)
        "sets both final lengths" 2
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int) "returns tuple of output lists" 1 (count_tuple body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_concat_synthesizes_exact_copy () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"concat"
      ~module_path:"std/list"
      ~params:[ param "a" (ty_list ty_string); param "b" (ty_list ty_string) ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.concat should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single exact output allocation" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "bulk-copies both source spans" 2
        (count_intrinsic "list_copy_span_uninit" body);
      Alcotest.(check int)
        "does not copy through per-element reads" 0
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "does not retain one copied element at a time" 0
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "does not store one copied element at a time" 0
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_reverse_synthesizes_owned_bulk_reverse () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"reverse"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string) ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.reverse should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses one ownership-aware reverse primitive" 1
        (count_intrinsic "list_reverse_owned" body);
      Alcotest.(check int)
        "does not force generic COW before reversing" 0
        (count_intrinsic "list_ensure_unique" body);
      Alcotest.(check int)
        "does not reverse through per-element reads" 0
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "does not reverse through per-element stores" 0
        (count_intrinsic "list_set" body);
      Alcotest.(check int)
        "does not reverse through emitted slot swaps" 0
        (count_intrinsic "list_swap_slots" body)

let test_list_take_drop_synthesize_exact_slices () =
  let assert_slice func_name =
    let body =
      Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path:"std/list"
        ~params:[ param "self" (ty_list ty_string); param "n" ty_int ]
        ~return_ty:(ty_list ty_string)
    in
    match body with
    | None ->
        Alcotest.failf "List.%s should synthesize a Core IR body" func_name
    | Some body ->
        Alcotest.(check int)
          (func_name ^ " allocates exact output")
          1
          (count_intrinsic "list_alloc" body);
        Alcotest.(check int)
          (func_name ^ " reads copied elements")
          1
          (count_intrinsic "list_get" body);
        Alcotest.(check int)
          (func_name ^ " retains copied elements")
          1
          (count_intrinsic "list_retain_for" body);
        Alcotest.(check int)
          (func_name ^ " transfers copied elements")
          1
          (count_intrinsic "list_set_owned" body);
        Alcotest.(check int)
          (func_name ^ " sets final length once")
          1
          (count_intrinsic "list_set_len" body);
        Alcotest.(check int)
          (func_name ^ " avoids append growth")
          0
          (count_intrinsic "list_ensure_capacity" body)
  in
  assert_slice "take";
  assert_slice "drop"

let test_list_flatten_synthesizes_prescan_exact_copy () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"flatten"
      ~module_path:"std/list"
      ~params:[ param "lists" (ty_list (ty_list ty_string)) ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.flatten should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single exact output allocation" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check bool)
        "scans and copies through direct list reads" true
        (count_intrinsic "list_get" body >= 2);
      Alcotest.(check int)
        "retains copied inner elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers copied elements into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_repeat_range_synthesize_presized_builders () =
  let repeat_body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"repeat"
      ~module_path:"std/list"
      ~params:[ param "elem" ty_string; param "n" ty_int ]
      ~return_ty:(ty_list ty_string)
  in
  let range_body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"range"
      ~module_path:"std/list"
      ~params:[ param "start" ty_int; param "stop" ty_int ]
      ~return_ty:(ty_list ty_int)
  in
  (match repeat_body with
  | None -> Alcotest.fail "List.repeat should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "repeat allocates exact output" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "repeat retains input for each slot" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check bool)
        "repeat writes direct slots" true
        (count_intrinsic "list_set" body > 0);
      Alcotest.(check int)
        "repeat sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "repeat avoids append growth" 0
        (count_intrinsic "list_ensure_capacity" body));
  match range_body with
  | None -> Alcotest.fail "List.range should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "range allocates exact output" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check bool)
        "range writes direct slots" true
        (count_intrinsic "list_set" body > 0);
      Alcotest.(check int)
        "range does not retain primitive values" 0
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "range sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "range avoids append growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_intersperse_synthesizes_exact_retain_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"intersperse"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string); param "sep" ty_string ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.intersperse should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single exact output allocation" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "copies source elements through list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check bool)
        "retains separator and source elements" true
        (count_intrinsic "list_retain_for" body >= 2);
      Alcotest.(check int)
        "transfers retained source elements into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check bool)
        "stores retained separator without consuming it" true
        (count_intrinsic "list_set" body > 0);
      Alcotest.(check int)
        "sets final length once" 1
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_windows_synthesizes_nested_exact_builders () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"windows"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string); param "n" ty_int ]
      ~return_ty:(ty_list (ty_list ty_string))
  in
  match body with
  | None -> Alcotest.fail "List.windows should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "outer plus inner exact allocations" 2
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "copies source elements through list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains borrowed source elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "stores copied elements and produced windows" 2
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets inner and outer lengths" 2
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "does not call drop" 0
        (count_unknown_call "drop" body);
      Alcotest.(check int)
        "does not call take" 0
        (count_unknown_call "take" body)

let test_list_unique_synthesizes_single_alloc_eq_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"unique"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string) ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.unique should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single upper-bound output allocation" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads source and result scan elements" 2
        (count_intrinsic "list_get" body);
      Alcotest.(check bool)
        "compares candidate against prior kept elements" true
        (count_binop Eq body > 0);
      Alcotest.(check int)
        "retains kept borrowed elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers retained elements into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "keeps visible length current while scanning prior results" 2
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "does not allocate an any() closure call" 0
        (count_unknown_call "any" body);
      Alcotest.(check int)
        "does not call append" 0
        (count_unknown_call "append" body)

let test_list_chunks_synthesizes_nested_exact_builders () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"chunks"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string); param "n" ty_int ]
      ~return_ty:(ty_list (ty_list ty_string))
  in
  match body with
  | None -> Alcotest.fail "List.chunks should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "outer plus inner exact allocations" 2
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "copies source elements through list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains borrowed source elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "stores copied elements and produced chunks" 2
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets inner and outer lengths" 2
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "does not call drop" 0
        (count_unknown_call "drop" body);
      Alcotest.(check int)
        "does not call take" 0
        (count_unknown_call "take" body)

let test_list_take_while_synthesizes_retain_transfer_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"take_while"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "pred" (ty_func [ ty_string ] ty_bool);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.take_while should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads elements via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains kept borrowed elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers retained elements into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int) "short-circuits on first miss" 1 (count_break body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_drop_while_synthesizes_retain_transfer_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"drop_while"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "pred" (ty_func [ ty_string ] ty_bool);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.drop_while should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single list_alloc" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scan plus copy reads" 2
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains kept borrowed elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers retained elements into result" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int) "short-circuits on first miss" 1 (count_break body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_partition_synthesizes_two_retain_transfer_loops () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"partition"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "pred" (ty_func [ ty_string ] ty_bool);
        ]
      ~return_ty:(TyTuple [ ty_list ty_string; ty_list ty_string ])
  in
  match body with
  | None -> Alcotest.fail "List.partition should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "allocates two upper-bound result lists" 2
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads source elements once" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains for both output lists" 2
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers into both output lists" 2
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "shrinks both outputs" 2
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body)

let test_list_flat_map_synthesizes_single_callback_dynamic_fill () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"flat_map"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "f" (ty_func [ ty_int ] (ty_list ty_string));
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.flat_map should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "calls callback once in the synthesized body" 1
        (count_closure_call body);
      Alcotest.(check int)
        "allocates one result list" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads outer and inner elements" 2
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "grows once per inner list" 1
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "retains copied inner elements" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers copied inner elements" 1
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "sets final output length once" 1
        (count_intrinsic "list_set_len" body)

let test_list_predicate_queries_synthesize_direct_loops () =
  let assert_predicate_query ~func_name ~return_ty ~expected_breaks =
    let body =
      Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path:"std/list"
        ~params:
          [
            param "self" (ty_list ty_int);
            param "pred" (ty_func [ ty_int ] ty_bool);
          ]
        ~return_ty
    in
    match body with
    | None ->
        Alcotest.failf "List.%s should synthesize a Core IR body" func_name
    | Some body ->
        Alcotest.(check int)
          (func_name ^ " reads elements via list_get")
          1
          (count_intrinsic "list_get" body);
        Alcotest.(check int)
          (func_name ^ " does not allocate a list")
          0
          (count_intrinsic "list_alloc" body);
        Alcotest.(check int)
          (func_name ^ " break count")
          expected_breaks (count_break body)
  in
  assert_predicate_query ~func_name:"all" ~return_ty:ty_bool ~expected_breaks:1;
  assert_predicate_query ~func_name:"any" ~return_ty:ty_bool ~expected_breaks:1;
  assert_predicate_query ~func_name:"count" ~return_ty:ty_int ~expected_breaks:0

let test_list_for_each_synthesizes_direct_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"for_each"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int); param "f" (ty_func [ ty_int ] ty_void);
        ]
      ~return_ty:ty_void
  in
  match body with
  | None -> Alcotest.fail "List.for_each should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "reads elements via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "does not allocate a list" 0
        (count_intrinsic "list_alloc" body)

let test_list_find_index_synthesizes_direct_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"find_index"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "pred" (ty_func [ ty_int ] ty_bool);
        ]
      ~return_ty:(ty_option ty_int)
  in
  match body with
  | None -> Alcotest.fail "List.find_index should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "reads elements via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "does not allocate a list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int) "short-circuits on first match" 1 (count_break body)

let test_list_find_synthesizes_direct_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"find"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "pred" (ty_func [ ty_string ] ty_bool);
        ]
      ~return_ty:(ty_option ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.find should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "calls predicate once in the synthesized body" 1
        (count_closure_call body);
      Alcotest.(check int)
        "reads elements via list_get" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "retains returned borrowed element" 1
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "does not allocate a list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int) "short-circuits on first match" 1 (count_break body)

let test_list_binary_search_synthesizes_direct_probe_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"binary_search"
      ~module_path:"std/list"
      ~params:[ param "sorted" (ty_list ty_int); param "target" ty_int ]
      ~return_ty:(ty_option ty_int)
  in
  match body with
  | None -> Alcotest.fail "List.binary_search should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct list probe" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "does not call predicate/compare closure" 0 (count_closure_call body);
      Alcotest.(check int)
        "does not allocate probe Options" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "constructs Some only for successful match" 1
        (count_unknown_call "Some" body);
      Alcotest.(check int) "short-circuits once found" 1 (count_break body)

let test_list_binary_search_by_synthesizes_direct_probe_loop () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"binary_search_by"
      ~module_path:"std/list"
      ~params:
        [
          param "sorted" (ty_list ty_string);
          param "target" ty_string;
          param "compare" (ty_func [ ty_string; ty_string ] ty_int);
        ]
      ~return_ty:(ty_option ty_int)
  in
  match body with
  | None ->
      Alcotest.fail "List.binary_search_by should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct list probe" 1
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "calls compare closure once in loop body" 1 (count_closure_call body);
      Alcotest.(check int)
        "does not allocate probe Options" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "constructs Some only for successful match" 1
        (count_unknown_call "Some" body);
      Alcotest.(check int) "short-circuits once found" 1 (count_break body)

let test_list_min_max_by_synthesize_index_scan () =
  let assert_minmax_by func_name =
    let body =
      Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path:"std/list"
        ~params:
          [
            param "self" (ty_list ty_string);
            param "score" (ty_func [ ty_string ] ty_int);
          ]
        ~return_ty:(ty_option ty_string)
    in
    match body with
    | None ->
        Alcotest.failf "List.%s should synthesize a Core IR body" func_name
    | Some body ->
        Alcotest.(check int)
          (func_name ^ " scores first element and loop candidates")
          2 (count_closure_call body);
        Alcotest.(check int)
          (func_name ^ " initializes, scans, then returns by index")
          3
          (count_intrinsic "list_get" body);
        Alcotest.(check int)
          (func_name ^ " retains returned borrowed element")
          1
          (count_intrinsic "list_retain_for" body);
        Alcotest.(check int)
          (func_name ^ " does not allocate a list")
          0
          (count_intrinsic "list_alloc" body);
        Alcotest.(check int)
          (func_name ^ " does not need loop break")
          0 (count_break body)
  in
  assert_minmax_by "min_by";
  assert_minmax_by "max_by"

let test_list_scan_synthesizes_result_backed_accumulator () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"scan"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_int);
          param "init" ty_string;
          param "f" (ty_func [ ty_string; ty_int ] ty_string);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.scan should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "single output allocation" 1
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "reads input and prior accumulator" 2
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "transfers init plus callback results" 2
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check int)
        "advances visible result length before reading accumulated slots" 2
        (count_intrinsic "list_set_len" body);
      Alcotest.(check int)
        "calls callback once in synthesized body" 1 (count_closure_call body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check int)
        "no borrowed element retain" 0
        (count_intrinsic "list_retain_for" body)

let test_list_fold_left_leaves_accumulator_drop_to_perceus () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"fold_left"
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "init" ty_string;
          param "f" (ty_func [ ty_string; ty_string ] ty_string);
        ]
      ~return_ty:ty_string
  in
  match body with
  | None -> Alcotest.fail "List.fold_left should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "calls callback once in synthesized body" 1 (count_closure_call body);
      Alcotest.(check int)
        "intrinsic body should not pre-drop accumulator before Perceus" 0
        (count_drop body)

let assert_sort_by_synthesizes_index_merge name compare_op =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:name
      ~module_path:"std/list"
      ~params:
        [
          param "self" (ty_list ty_string);
          param "key_fn" (ty_func [ ty_string ] ty_int);
        ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.failf "List.%s should synthesize a Core IR body" name
  | Some body ->
      Alcotest.(check int)
        "allocates key/index buffers and result" 4
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "computes each key once in preload loop" 1 (count_closure_call body);
      Alcotest.(check int)
        "transfers key owners and branch-specific final result elements" 3
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check bool)
        "merge moves slots without append/COW growth" true
        (count_intrinsic "list_set" body > 0);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check bool)
        "uses stable ordering comparison" true
        (count_binop compare_op body > 0)

let test_list_sort_by_synthesizes_index_merge () =
  assert_sort_by_synthesizes_index_merge "sort_by" Le;
  assert_sort_by_synthesizes_index_merge "sort_desc_by" Ge

let test_list_sort_synthesizes_index_merge () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"sort"
      ~module_path:"std/list"
      ~params:[ param "self" (ty_list ty_string) ]
      ~return_ty:(ty_list ty_string)
  in
  match body with
  | None -> Alcotest.fail "List.sort should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "allocates index buffers and result" 3
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "does not call a key callback" 0 (count_closure_call body);
      Alcotest.(check int)
        "retains branch-specific final result elements" 2
        (count_intrinsic "list_retain_for" body);
      Alcotest.(check int)
        "transfers branch-specific final result elements" 2
        (count_intrinsic "list_set_owned" body);
      Alcotest.(check bool)
        "merge moves indexes without append/COW growth" true
        (count_intrinsic "list_set" body > 0);
      Alcotest.(check bool)
        "internal sort loads use unchecked proven accesses" true
        (count_intrinsic "list_get_unchecked" body > 0);
      Alcotest.(check int)
        "internal sort does not use checked list loads" 0
        (count_intrinsic "list_get" body);
      Alcotest.(check int)
        "no repeated append capacity growth" 0
        (count_intrinsic "list_ensure_capacity" body);
      Alcotest.(check bool)
        "uses stable ascending comparison" true
        (count_binop Le body > 0)

let test_set_is_subset_synthesizes_direct_entry_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"is_subset"
      ~module_path:"std/set"
      ~params:[ param "a" (ty_set ty_int); param "b" (ty_set ty_int) ]
      ~return_ty:ty_bool
  in
  match body with
  | None -> Alcotest.fail "Set.is_subset should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans set entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "uses direct immediate hash in rhs set" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body);
      Alcotest.(check int)
        "short-circuits on missing element" 1 (count_break body)

let test_set_contains_string_uses_borrowed_key_cast () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_string); param "elem" ty_string ]
      ~return_ty:ty_bool
  in
  match body with
  | None ->
      Alcotest.fail "Set.contains[String] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "hashes one borrowed key" 1
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "uses non-owning cast for String key" 1 (count_ccast body);
      Alcotest.(check int) "does not owning-box String key" 0 (count_cbox body)

let test_set_contains_int_uses_immediate_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_int); param "elem" ty_int ]
      ~return_ty:ty_bool
  in
  match body with
  | None -> Alcotest.fail "Set.contains[Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate hash" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body)

let test_set_contains_int_alias_uses_immediate_probe () =
  let reg = int_alias_registry () in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_count); param "elem" ty_count ]
      ~return_ty:ty_bool
  in
  match body with
  | None -> Alcotest.fail "Set.contains[Count] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "alias key uses direct immediate hash" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "alias key uses direct immediate equality" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "alias key does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "alias key is boxed for immediate table probing" 1 (count_cbox body)

let test_set_contains_enum_uses_registered_immediate_probe () =
  let reg = color_enum_registry () in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_color); param "elem" ty_color ]
      ~return_ty:ty_bool
  in
  match body with
  | None -> Alcotest.fail "Set.contains[Color] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate enum hash" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate enum equality" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body);
      Alcotest.(check int)
        "boxes enum key as immediate table storage" 1 (count_cbox body)

let test_set_contains_unregistered_named_key_stays_dispatched () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_color); param "elem" ty_color ]
      ~return_ty:ty_bool
  in
  match body with
  | None -> Alcotest.fail "Set.contains[Color] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses set hash callback for unregistered named key" 1
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "uses set equality callback for unregistered named key" 1
        (count_intrinsic "set_eq" body);
      Alcotest.(check int)
        "does not guess named key is immediate" 0
        (count_intrinsic "set_hash_immediate" body)

let test_set_contains_float_boxes_key () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_float); param "elem" ty_float ]
      ~return_ty:ty_bool
  in
  match body with
  | None -> Alcotest.fail "Set.contains[Float] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int) "boxes Float key for hash/eq" 1 (count_cbox body);
      Alcotest.(check int)
        "does not cast Float directly to Ptr" 0 (count_ccast body)

let test_generic_set_contains_defers_to_post_mono_synthesis () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"contains"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_var_t); param "elem" ty_var_t ]
      ~return_ty:ty_bool
  in
  Alcotest.(check bool)
    "generic Set.contains should defer" true (Option.is_none body)

let test_generic_set_add_defers_to_post_mono_synthesis () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"add"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_var_t); param "elem" ty_var_t ]
      ~return_ty:(ty_set ty_var_t)
  in
  Alcotest.(check bool)
    "generic Set.add should defer" true (Option.is_none body)

let test_generic_set_bulk_defers_to_post_mono_synthesis () =
  let assert_defers func_name return_ty =
    let body =
      Blorp.Core_intrinsics.synthesize_body ~func_name ~module_path:"std/set"
        ~params:[ param "a" (ty_set ty_var_t); param "b" (ty_set ty_var_t) ]
        ~return_ty
    in
    Alcotest.(check bool)
      (Printf.sprintf "generic Set.%s should defer" func_name)
      true (Option.is_none body)
  in
  assert_defers "is_subset" ty_bool;
  assert_defers "difference" (ty_set ty_var_t);
  assert_defers "intersect" (ty_set ty_var_t);
  assert_defers "combine" (ty_set ty_var_t)

let test_generic_set_map_filter_defer_to_post_mono_synthesis () =
  let map_body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"map"
      ~module_path:"std/set"
      ~params:
        [
          param "self" (ty_set ty_var_t);
          param "f" (ty_func [ ty_var_t ] ty_var_t);
        ]
      ~return_ty:(ty_set ty_var_t)
  in
  let filter_body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"filter"
      ~module_path:"std/set"
      ~params:
        [
          param "self" (ty_set ty_var_t);
          param "pred" (ty_func [ ty_var_t ] ty_bool);
        ]
      ~return_ty:(ty_set ty_var_t)
  in
  Alcotest.(check bool)
    "generic Set.map should defer" true (Option.is_none map_body);
  Alcotest.(check bool)
    "generic Set.filter should defer" true
    (Option.is_none filter_body)

let test_registered_post_mono_synthesis_operations () =
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s is post-mono synthesized" name)
        true
        (Blorp.Core_intrinsics.has_post_mono_synthesis
           ~module_path:(Some "std/list") name))
    [
      "map";
      "filter";
      "drop";
      "any";
      "concat";
      "unique";
      "all";
      "flat_map";
    ];
  Alcotest.(check bool)
    "same name in unrelated module stays deferred" false
    (Blorp.Core_intrinsics.has_post_mono_synthesis
       ~module_path:(Some "std/string") "map");
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "dict %s is post-mono synthesized" name)
        true
        (Blorp.Core_intrinsics.has_post_mono_synthesis
           ~module_path:(Some "std/dict") name))
    [ "keys"; "values" ]

let test_set_difference_synthesizes_direct_entry_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"difference"
      ~module_path:"std/set"
      ~params:[ param "a" (ty_set ty_int); param "b" (ty_set ty_int) ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.difference should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans set entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "uses direct immediate hash lookups in rhs and result sets" 2
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality in rhs and result sets" 2
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body);
      Alcotest.(check int)
        "creates result via type-dispatched set new" 1
        (count_builtin_call "blorp_set_new" body);
      Alcotest.(check int)
        "reserves result capacity from lhs length" 1
        (count_intrinsic "set_reserve_for_len" body);
      Alcotest.(check int)
        "does not delegate inserts to runtime set_add" 0
        (count_builtin_call "blorp_set_add" body);
      Alcotest.(check int)
        "retains borrowed keys before entry transfer" 1
        (count_intrinsic "set_retain_key_for" body);
      Alcotest.(check int)
        "allocates set entries directly" 1
        (count_intrinsic "set_alloc_entry" body)

let test_set_intersect_synthesizes_direct_entry_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"intersect"
      ~module_path:"std/set"
      ~params:[ param "a" (ty_set ty_int); param "b" (ty_set ty_int) ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.intersect should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans set entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "uses direct immediate hash lookups in rhs and result sets" 2
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality in rhs and result sets" 2
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body);
      Alcotest.(check int)
        "creates result via type-dispatched set new" 1
        (count_builtin_call "blorp_set_new" body);
      Alcotest.(check int)
        "reserves result capacity from lhs length" 1
        (count_intrinsic "set_reserve_for_len" body);
      Alcotest.(check int)
        "does not delegate inserts to runtime set_add" 0
        (count_builtin_call "blorp_set_add" body);
      Alcotest.(check int)
        "retains borrowed keys before entry transfer" 1
        (count_intrinsic "set_retain_key_for" body);
      Alcotest.(check int)
        "allocates set entries directly" 1
        (count_intrinsic "set_alloc_entry" body)

let test_set_combine_synthesizes_direct_rhs_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"combine"
      ~module_path:"std/set"
      ~params:[ param "a" (ty_set ty_int); param "b" (ty_set ty_int) ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.combine should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans rhs entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "does not allocate a fresh output up front" 0
        (count_builtin_call "blorp_set_new" body);
      Alcotest.(check int)
        "COWs lhs once before direct insertion" 1
        (count_intrinsic "set_cow" body);
      Alcotest.(check int)
        "reserves result capacity for both inputs" 1
        (count_intrinsic "set_reserve_for_len" body);
      Alcotest.(check int)
        "does not delegate inserts to runtime set_add" 0
        (count_builtin_call "blorp_set_add" body);
      Alcotest.(check int)
        "retains borrowed keys before entry transfer" 1
        (count_intrinsic "set_retain_key_for" body);
      Alcotest.(check int)
        "allocates set entries directly" 1
        (count_intrinsic "set_alloc_entry" body)

let test_set_add_synthesizes_direct_cow_insert () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"add"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_string); param "elem" ty_string ]
      ~return_ty:(ty_set ty_string)
  in
  match body with
  | None -> Alcotest.fail "Set.add should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "COWs receiver once" 1
        (count_intrinsic "set_cow" body);
      Alcotest.(check int)
        "does not delegate to runtime set_add" 0
        (count_builtin_call "blorp_set_add" body);
      Alcotest.(check int)
        "retains input key before entry transfer" 1
        (count_intrinsic "set_retain_key_for" body);
      Alcotest.(check int)
        "allocates set entry directly" 1
        (count_intrinsic "set_alloc_entry" body);
      Alcotest.(check int)
        "uses non-owning cast for String key" 1 (count_ccast body);
      Alcotest.(check int) "does not owning-box String key" 0 (count_cbox body)

let test_set_add_int_uses_immediate_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"add"
      ~module_path:"std/set"
      ~params:[ param "self" (ty_set ty_int); param "elem" ty_int ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.add[Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate hash" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body)

let test_set_map_synthesizes_direct_entry_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"map"
      ~module_path:"std/set"
      ~params:
        [
          param "self" (ty_set ty_int); param "f" (ty_func [ ty_int ] ty_string);
        ]
      ~return_ty:(ty_set ty_string)
  in
  match body with
  | None -> Alcotest.fail "Set.map should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans set entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "calls mapper once in synthesized body" 1 (count_closure_call body);
      Alcotest.(check int)
        "creates result via type-dispatched set new" 1
        (count_builtin_call "blorp_set_new" body);
      Alcotest.(check int)
        "reserves result capacity from source length" 1
        (count_intrinsic "set_reserve_for_len" body);
      Alcotest.(check int)
        "does not delegate inserts to runtime set_add" 0
        (count_builtin_call "blorp_set_add" body);
      Alcotest.(check int)
        "retains mapped key before entry transfer" 1
        (count_intrinsic "set_retain_key_for" body);
      Alcotest.(check int)
        "allocates set entries directly" 1
        (count_intrinsic "set_alloc_entry" body)

let test_set_map_int_result_uses_immediate_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"map"
      ~module_path:"std/set"
      ~params:
        [ param "self" (ty_set ty_int); param "f" (ty_func [ ty_int ] ty_int) ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.map[Int, Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate hash for mapped keys" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality for mapped keys" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body)

let test_set_filter_synthesizes_direct_entry_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"filter"
      ~module_path:"std/set"
      ~params:
        [
          param "self" (ty_set ty_int);
          param "pred" (ty_func [ ty_int ] ty_bool);
        ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.filter should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans set entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "calls predicate once in synthesized body" 1 (count_closure_call body);
      Alcotest.(check int)
        "creates result via type-dispatched set new" 1
        (count_builtin_call "blorp_set_new" body);
      Alcotest.(check int)
        "reserves result capacity from source length" 1
        (count_intrinsic "set_reserve_for_len" body);
      Alcotest.(check int)
        "does not delegate inserts to runtime set_add" 0
        (count_builtin_call "blorp_set_add" body);
      Alcotest.(check int)
        "retains kept keys before entry transfer" 1
        (count_intrinsic "set_retain_key_for" body);
      Alcotest.(check int)
        "allocates set entries directly" 1
        (count_intrinsic "set_alloc_entry" body)

let test_set_filter_int_uses_immediate_probe () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"filter"
      ~module_path:"std/set"
      ~params:
        [
          param "self" (ty_set ty_int);
          param "pred" (ty_func [ ty_int ] ty_bool);
        ]
      ~return_ty:(ty_set ty_int)
  in
  match body with
  | None -> Alcotest.fail "Set.filter[Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "uses direct immediate hash for kept keys" 1
        (count_intrinsic "set_hash_immediate" body);
      Alcotest.(check int)
        "uses direct immediate equality for kept keys" 1
        (count_intrinsic "set_eq_immediate" body);
      Alcotest.(check int)
        "does not dispatch through set hash function pointer" 0
        (count_intrinsic "set_hash" body);
      Alcotest.(check int)
        "does not dispatch through set equality function pointer" 0
        (count_intrinsic "set_eq" body)

let test_set_fold_synthesizes_direct_entry_scan () =
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"fold"
      ~module_path:"std/set"
      ~params:
        [
          param "self" (ty_set ty_int);
          param "init" ty_string;
          param "f" (ty_func [ ty_string; ty_int ] ty_string);
        ]
      ~return_ty:ty_string
  in
  match body with
  | None -> Alcotest.fail "Set.fold should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not allocate via to_list" 0
        (count_intrinsic "list_alloc" body);
      Alcotest.(check int)
        "scans set entries directly" 1
        (count_intrinsic "set_first" body);
      Alcotest.(check int)
        "calls folder once in synthesized body" 1 (count_closure_call body);
      Alcotest.(check int)
        "drops prior managed accumulator after callback" 1 (count_drop body);
      Alcotest.(check int)
        "does not allocate an output set" 0
        (count_builtin_call "blorp_set_new" body)

let test_tensor_sum_synthesizes_typed_raw_view () =
  let vec_ty = ty_vector ty_float 256 in
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"sum"
      ~module_path:"std/vector"
      ~params:[ param "items" vec_ty ]
      ~return_ty:ty_float
  in
  match body with
  | None -> Alcotest.fail "Vector.sum[Float] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not emit raw unchecked get intrinsic" 0
        (count_intrinsic "tensor_get_f64_raw_unchecked" body);
      Alcotest.(check int)
        "binds one typed raw tensor view" 1
        (count_tensor_raw_view_let TensorFloat64Elements body);
      Alcotest.(check int)
        "reads through typed raw tensor view" 1
        (count_tensor_raw_read TensorFloat64Elements body)

let test_tensor_sum_alias_synthesizes_typed_raw_view () =
  let reg = Blorp.Codegen_types.create_registry () in
  Hashtbl.replace reg.type_aliases "Meters" ([], ty_float);
  Hashtbl.replace reg.type_aliases "Positions"
    ([], TyNamed ("Vector", [ TyNamed ("Meters", []); TyConstInt 256 ]));
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"sum"
      ~module_path:"std/vector"
      ~params:[ param "items" (TyNamed ("Positions", [])) ]
      ~return_ty:ty_float
  in
  match body with
  | None ->
      Alcotest.fail
        "Vector.sum should synthesize when the tensor type is provided through \
         aliases"
  | Some body ->
      Alcotest.(check int)
        "binds one typed raw tensor view" 1
        (count_tensor_raw_view_let TensorFloat64Elements body);
      Alcotest.(check int)
        "reads through typed raw tensor view" 1
        (count_tensor_raw_read TensorFloat64Elements body)

let test_tensor_sum_element_alias_synthesizes_typed_raw_view () =
  let reg = int_alias_registry () in
  let vec_ty = ty_vector ty_count 256 in
  let body =
    Blorp.Core_intrinsics.synthesize_body_with_reg ~reg ~func_name:"sum"
      ~module_path:"std/vector"
      ~params:[ param "items" vec_ty ]
      ~return_ty:ty_int
  in
  match body with
  | None ->
      Alcotest.fail
        "Vector.sum should synthesize when only the tensor element type is an \
         alias"
  | Some body ->
      Alcotest.(check int)
        "does not emit raw unchecked get intrinsic" 0
        (count_intrinsic "tensor_get_i64_raw_unchecked" body);
      Alcotest.(check int)
        "binds one typed raw tensor view" 1
        (count_tensor_raw_view_let TensorInt64Elements body);
      Alcotest.(check int)
        "reads through typed raw tensor view" 1
        (count_tensor_raw_read_result TensorInt64Elements ty_int body)

let test_tensor_dot_synthesizes_typed_raw_views () =
  let vec_ty = ty_vector ty_float 256 in
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"dot"
      ~module_path:"std/vector"
      ~params:[ param "a" vec_ty; param "b" vec_ty ]
      ~return_ty:ty_float
  in
  match body with
  | None -> Alcotest.fail "Vector.dot[Float] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not emit raw unchecked get intrinsic" 0
        (count_intrinsic "tensor_get_f64_raw_unchecked" body);
      Alcotest.(check int)
        "binds typed raw tensor views for both inputs" 2
        (count_tensor_raw_view_let TensorFloat64Elements body);
      Alcotest.(check int)
        "reads both inputs through typed raw tensor views" 2
        (count_tensor_raw_read TensorFloat64Elements body)

let test_tensor_mean_int_reads_int_and_casts_to_float () =
  let vec_ty = ty_vector ty_int 256 in
  let body =
    Blorp.Core_intrinsics.synthesize_body ~func_name:"mean"
      ~module_path:"std/vector"
      ~params:[ param "items" vec_ty ]
      ~return_ty:ty_float
  in
  match body with
  | None -> Alcotest.fail "Vector.mean[Int] should synthesize a Core IR body"
  | Some body ->
      Alcotest.(check int)
        "does not emit raw unchecked get intrinsic" 0
        (count_intrinsic "tensor_get_i64_raw_unchecked" body);
      Alcotest.(check int)
        "binds one typed int raw tensor view" 1
        (count_tensor_raw_view_let TensorInt64Elements body);
      Alcotest.(check int)
        "raw int view reads produce Int values before numeric conversion" 1
        (count_tensor_raw_read_result TensorInt64Elements ty_int body);
      Alcotest.(check bool)
        "casts element sum and length to Float" true
        (count_ccast body >= 2)

let suite =
  [
    ( "synthesis",
      [
        Alcotest.test_case "list_synthesis_rejects_malformed_signatures" `Quick
          test_list_synthesis_rejects_malformed_signatures;
        Alcotest.test_case "std_synthesis_rejects_malformed_signatures" `Quick
          test_std_synthesis_rejects_malformed_signatures;
        Alcotest.test_case "std_float_round_synthesizes_math_round" `Quick
          test_std_float_round_synthesizes_math_round;
        Alcotest.test_case "hash_wrappers_synthesize_from_specs" `Quick
          test_hash_wrappers_synthesize_from_specs;
        Alcotest.test_case "time_and_system_wrappers_synthesize_from_specs"
          `Quick test_time_and_system_wrappers_synthesize_from_specs;
        Alcotest.test_case "bytes_c_wrappers_synthesize_from_specs" `Quick
          test_bytes_c_wrappers_synthesize_from_specs;
        Alcotest.test_case "fixed_c_wrappers_synthesize_from_specs" `Quick
          test_fixed_c_wrappers_synthesize_from_specs;
        Alcotest.test_case "tensor_c_wrappers_synthesize_from_specs" `Quick
          test_tensor_c_wrappers_synthesize_from_specs;
        Alcotest.test_case "tensor_length_synthesizes_from_specs" `Quick
          test_tensor_length_synthesizes_from_specs;
        Alcotest.test_case "matrix_c_wrappers_synthesize_from_specs" `Quick
          test_matrix_c_wrappers_synthesize_from_specs;
        Alcotest.test_case "stream_wrappers_synthesize_from_specs" `Quick
          test_stream_wrappers_synthesize_from_specs;
        Alcotest.test_case "list_strategy_contract_matches_synthesized_ir"
          `Quick test_list_strategy_contract_matches_synthesized_ir;
        Alcotest.test_case "list_synthesized_ir_does_not_own_borrowed_aliases"
          `Quick test_list_synthesized_ir_does_not_own_borrowed_aliases;
        Alcotest.test_case "set_dict_strategy_contract_matches_synthesized_ir"
          `Quick test_set_dict_strategy_contract_matches_synthesized_ir;
        Alcotest.test_case "dict_set_synthesizes_direct_cow_insert" `Quick
          test_dict_set_synthesizes_direct_cow_insert;
        Alcotest.test_case "dict_set_int_key_uses_immediate_probe" `Quick
          test_dict_set_int_key_uses_immediate_probe;
        Alcotest.test_case "dict_set_enum_key_uses_registered_immediate_probe"
          `Quick test_dict_set_enum_key_uses_registered_immediate_probe;
        Alcotest.test_case "dict_contains_int_uses_direct_probe" `Quick
          test_dict_contains_int_uses_direct_probe;
        Alcotest.test_case "dict_contains_enum_uses_registered_immediate_probe"
          `Quick test_dict_contains_enum_uses_registered_immediate_probe;
        Alcotest.test_case "dict_contains_string_uses_dispatched_probe" `Quick
          test_dict_contains_string_uses_dispatched_probe;
        Alcotest.test_case "generic_dict_contains_defers_to_post_mono_synthesis"
          `Quick test_generic_dict_contains_defers_to_post_mono_synthesis;
        Alcotest.test_case "dict_get_or_synthesizes_option_free_probe" `Quick
          test_dict_get_or_synthesizes_option_free_probe;
        Alcotest.test_case "dict_get_or_int_key_uses_direct_probe" `Quick
          test_dict_get_or_int_key_uses_direct_probe;
        Alcotest.test_case "dict_get_or_int_alias_key_uses_direct_probe" `Quick
          test_dict_get_or_int_alias_key_uses_direct_probe;
        Alcotest.test_case "dict_get_or_enum_key_uses_direct_probe" `Quick
          test_dict_get_or_enum_key_uses_direct_probe;
        Alcotest.test_case "dict_entries_synthesizes_direct_tuple_list" `Quick
          test_dict_entries_synthesizes_direct_tuple_list;
        Alcotest.test_case "generic_dict_set_defers_to_post_mono_synthesis"
          `Quick test_generic_dict_set_defers_to_post_mono_synthesis;
        Alcotest.test_case "generic_dict_get_or_defers_to_post_mono_synthesis"
          `Quick test_generic_dict_get_or_defers_to_post_mono_synthesis;
        Alcotest.test_case "tensor_sum_synthesizes_typed_raw_view" `Quick
          test_tensor_sum_synthesizes_typed_raw_view;
        Alcotest.test_case "tensor_sum_alias_synthesizes_typed_raw_view" `Quick
          test_tensor_sum_alias_synthesizes_typed_raw_view;
        Alcotest.test_case "tensor_sum_element_alias_synthesizes_typed_raw_view"
          `Quick test_tensor_sum_element_alias_synthesizes_typed_raw_view;
        Alcotest.test_case "tensor_dot_synthesizes_typed_raw_views" `Quick
          test_tensor_dot_synthesizes_typed_raw_views;
        Alcotest.test_case "tensor_mean_int_reads_int_and_casts_to_float" `Quick
          test_tensor_mean_int_reads_int_and_casts_to_float;
        Alcotest.test_case "list_map_synthesizes_presized_loop" `Quick
          test_list_map_synthesizes_presized_loop;
        Alcotest.test_case "list_concurrent_synthesizes_concurrently_loop"
          `Quick test_list_concurrent_synthesizes_concurrently_loop;
        Alcotest.test_case
          "list_concurrent_timeout_synthesizes_concurrently_loop" `Quick
          test_list_concurrent_timeout_synthesizes_concurrently_loop;
        Alcotest.test_case "list_filter_synthesizes_retain_then_transfer_loop"
          `Quick test_list_filter_synthesizes_retain_then_transfer_loop;
        Alcotest.test_case "list_get_or_synthesizes_option_free_bounds_check"
          `Quick test_list_get_or_synthesizes_option_free_bounds_check;
        Alcotest.test_case "list_get_synthesizes_checked_option" `Quick
          test_list_get_synthesizes_checked_option;
        Alcotest.test_case "list_set_synthesizes_option_free_cow_set" `Quick
          test_list_set_synthesizes_option_free_cow_set;
        Alcotest.test_case
          "list_filter_map_synthesizes_single_alloc_transfer_loop" `Quick
          test_list_filter_map_synthesizes_single_alloc_transfer_loop;
        Alcotest.test_case "list_fold_synthesizes_direct_loop" `Quick
          test_list_fold_synthesizes_direct_loop;
        Alcotest.test_case "list_map_indexed_synthesizes_presized_loop" `Quick
          test_list_map_indexed_synthesizes_presized_loop;
        Alcotest.test_case "list_enumerate_synthesizes_presized_tuple_loop"
          `Quick test_list_enumerate_synthesizes_presized_tuple_loop;
        Alcotest.test_case "list_zip_synthesizes_presized_tuple_loop" `Quick
          test_list_zip_synthesizes_presized_tuple_loop;
        Alcotest.test_case "list_zip_with_synthesizes_presized_loop" `Quick
          test_list_zip_with_synthesizes_presized_loop;
        Alcotest.test_case "list_unzip_synthesizes_two_presized_outputs" `Quick
          test_list_unzip_synthesizes_two_presized_outputs;
        Alcotest.test_case "list_concat_synthesizes_exact_copy" `Quick
          test_list_concat_synthesizes_exact_copy;
        Alcotest.test_case "list_reverse_synthesizes_owned_bulk_reverse" `Quick
          test_list_reverse_synthesizes_owned_bulk_reverse;
        Alcotest.test_case "list_take_drop_synthesize_exact_slices" `Quick
          test_list_take_drop_synthesize_exact_slices;
        Alcotest.test_case "list_flatten_synthesizes_prescan_exact_copy" `Quick
          test_list_flatten_synthesizes_prescan_exact_copy;
        Alcotest.test_case "list_repeat_range_synthesize_presized_builders"
          `Quick test_list_repeat_range_synthesize_presized_builders;
        Alcotest.test_case "list_intersperse_synthesizes_exact_retain_loop"
          `Quick test_list_intersperse_synthesizes_exact_retain_loop;
        Alcotest.test_case "list_windows_synthesizes_nested_exact_builders"
          `Quick test_list_windows_synthesizes_nested_exact_builders;
        Alcotest.test_case "list_unique_synthesizes_single_alloc_eq_scan" `Quick
          test_list_unique_synthesizes_single_alloc_eq_scan;
        Alcotest.test_case "list_chunks_synthesizes_nested_exact_builders"
          `Quick test_list_chunks_synthesizes_nested_exact_builders;
        Alcotest.test_case "list_take_while_synthesizes_retain_transfer_loop"
          `Quick test_list_take_while_synthesizes_retain_transfer_loop;
        Alcotest.test_case "list_drop_while_synthesizes_retain_transfer_loop"
          `Quick test_list_drop_while_synthesizes_retain_transfer_loop;
        Alcotest.test_case
          "list_partition_synthesizes_two_retain_transfer_loops" `Quick
          test_list_partition_synthesizes_two_retain_transfer_loops;
        Alcotest.test_case
          "list_flat_map_synthesizes_single_callback_dynamic_fill" `Quick
          test_list_flat_map_synthesizes_single_callback_dynamic_fill;
        Alcotest.test_case "list_predicate_queries_synthesize_direct_loops"
          `Quick test_list_predicate_queries_synthesize_direct_loops;
        Alcotest.test_case "list_for_each_synthesizes_direct_loop" `Quick
          test_list_for_each_synthesizes_direct_loop;
        Alcotest.test_case "list_find_index_synthesizes_direct_loop" `Quick
          test_list_find_index_synthesizes_direct_loop;
        Alcotest.test_case "list_find_synthesizes_direct_loop" `Quick
          test_list_find_synthesizes_direct_loop;
        Alcotest.test_case "list_binary_search_synthesizes_direct_probe_loop"
          `Quick test_list_binary_search_synthesizes_direct_probe_loop;
        Alcotest.test_case "list_binary_search_by_synthesizes_direct_probe_loop"
          `Quick test_list_binary_search_by_synthesizes_direct_probe_loop;
        Alcotest.test_case "list_min_max_by_synthesize_index_scan" `Quick
          test_list_min_max_by_synthesize_index_scan;
        Alcotest.test_case "list_scan_synthesizes_result_backed_accumulator"
          `Quick test_list_scan_synthesizes_result_backed_accumulator;
        Alcotest.test_case "list_fold_left_leaves_accumulator_drop_to_perceus"
          `Quick test_list_fold_left_leaves_accumulator_drop_to_perceus;
        Alcotest.test_case "list_sort_synthesizes_index_merge" `Quick
          test_list_sort_synthesizes_index_merge;
        Alcotest.test_case "list_sort_by_synthesizes_index_merge" `Quick
          test_list_sort_by_synthesizes_index_merge;
        Alcotest.test_case "set_is_subset_synthesizes_direct_entry_scan" `Quick
          test_set_is_subset_synthesizes_direct_entry_scan;
        Alcotest.test_case "set_contains_string_uses_borrowed_key_cast" `Quick
          test_set_contains_string_uses_borrowed_key_cast;
        Alcotest.test_case "set_contains_int_uses_immediate_probe" `Quick
          test_set_contains_int_uses_immediate_probe;
        Alcotest.test_case "set_contains_int_alias_uses_immediate_probe" `Quick
          test_set_contains_int_alias_uses_immediate_probe;
        Alcotest.test_case "set_contains_enum_uses_registered_immediate_probe"
          `Quick test_set_contains_enum_uses_registered_immediate_probe;
        Alcotest.test_case
          "set_contains_unregistered_named_key_stays_dispatched" `Quick
          test_set_contains_unregistered_named_key_stays_dispatched;
        Alcotest.test_case "set_contains_float_boxes_key" `Quick
          test_set_contains_float_boxes_key;
        Alcotest.test_case "generic_set_contains_defers_to_post_mono_synthesis"
          `Quick test_generic_set_contains_defers_to_post_mono_synthesis;
        Alcotest.test_case "generic_set_add_defers_to_post_mono_synthesis"
          `Quick test_generic_set_add_defers_to_post_mono_synthesis;
        Alcotest.test_case "generic_set_bulk_defers_to_post_mono_synthesis"
          `Quick test_generic_set_bulk_defers_to_post_mono_synthesis;
        Alcotest.test_case "generic_set_map_filter_defer_to_post_mono_synthesis"
          `Quick test_generic_set_map_filter_defer_to_post_mono_synthesis;
        Alcotest.test_case "registered_post_mono_synthesis_operations" `Quick
          test_registered_post_mono_synthesis_operations;
        Alcotest.test_case "set_difference_synthesizes_direct_entry_scan" `Quick
          test_set_difference_synthesizes_direct_entry_scan;
        Alcotest.test_case "set_intersect_synthesizes_direct_entry_scan" `Quick
          test_set_intersect_synthesizes_direct_entry_scan;
        Alcotest.test_case "set_combine_synthesizes_direct_rhs_scan" `Quick
          test_set_combine_synthesizes_direct_rhs_scan;
        Alcotest.test_case "set_add_synthesizes_direct_cow_insert" `Quick
          test_set_add_synthesizes_direct_cow_insert;
        Alcotest.test_case "set_add_int_uses_immediate_probe" `Quick
          test_set_add_int_uses_immediate_probe;
        Alcotest.test_case "set_map_synthesizes_direct_entry_scan" `Quick
          test_set_map_synthesizes_direct_entry_scan;
        Alcotest.test_case "set_map_int_result_uses_immediate_probe" `Quick
          test_set_map_int_result_uses_immediate_probe;
        Alcotest.test_case "set_filter_synthesizes_direct_entry_scan" `Quick
          test_set_filter_synthesizes_direct_entry_scan;
        Alcotest.test_case "set_filter_int_uses_immediate_probe" `Quick
          test_set_filter_int_uses_immediate_probe;
        Alcotest.test_case "set_fold_synthesizes_direct_entry_scan" `Quick
          test_set_fold_synthesizes_direct_entry_scan;
      ] );
  ]
