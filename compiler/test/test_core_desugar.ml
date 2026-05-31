(** Tests for Core_desugar — sugar elimination passes. *)

open Blorp.Ast
open Blorp.Core

let loc =
  { line = 1; column = 1; end_line = 1; end_column = 1; loc_file = None }

let ty_int = TyNamed ("Int", [])
let ty_string = TyNamed ("String", [])
let mk d t = { desc = d; ty = t; loc }
let cint n = mk (CLit (LitInt (Int64.of_int n))) ty_int
let cvar n t = mk (CVar (Var.named n)) t

(* ============================================================================
   CRecordUpdate desugaring
   ============================================================================ *)

let point_ty = TyNamed ("Point", [])

let point_decl : record_decl =
  {
    record_name = "Point";
    record_type_params = [];
    record_fields =
      [
        { field_name = "x"; field_type = ty_int; field_loc = loc };
        { field_name = "y"; field_type = ty_int; field_loc = loc };
      ];
    record_is_value = true;
    record_is_builtin = false;
  }

let triple_ty = TyNamed ("Triple", [])

let triple_decl : record_decl =
  {
    record_name = "Triple";
    record_type_params = [];
    record_fields =
      [
        { field_name = "a"; field_type = ty_int; field_loc = loc };
        { field_name = "b"; field_type = ty_int; field_loc = loc };
        { field_name = "c"; field_type = ty_int; field_loc = loc };
      ];
    record_is_value = true;
    record_is_builtin = false;
  }

let wrap_in_func body =
  let func : core_func =
    {
      cf_name = "test";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None }

(** Extract the function body from a desugared program. *)
let get_body (prog : core_program) : core =
  match prog with
  | { cd_desc = CDFunc { cf_body = Some body; _ }; _ } :: _ -> body
  | _ -> failwith "expected func with body"

(** Skip the leading CDRecord declarations and find the CDFunc. *)
let get_func_body (prog : core_program) : core =
  let rec find = function
    | { cd_desc = CDFunc { cf_body = Some body; _ }; _ } :: _ -> body
    | _ :: rest -> find rest
    | [] -> failwith "no func found"
  in
  find prog

(** { p | x = 10 } with Point{x, y} → let __upd_0 = p in Point_make(10, __upd_0.y) *)
let test_desugar_single_field_update () =
  let update =
    mk (CRecordUpdate (cvar "p" point_ty, [ ("x", cint 10) ])) point_ty
  in
  let prog =
    [
      { cd_desc = CDRecord point_decl; cd_loc = loc; cd_doc = None };
      wrap_in_func update;
    ]
  in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_func_body result in
  match body.desc with
  | CLet (b, { desc = CRecord fields; _ }) -> (
      Alcotest.(check string) "tmp var" "__upd_0" b.bind_var.vname;
      Alcotest.(check string)
        "rhs is p" "p"
        (match b.bind_rhs.desc with CVar v -> v.vname | _ -> "not a var");
      Alcotest.(check int) "all fields present" 2 (List.length fields);
      (* x should be the literal 10, y should be a field read *)
      let _, x_val = List.nth fields 0 in
      let _, y_val = List.nth fields 1 in
      (match x_val.desc with
      | CLit (LitInt 10L) -> ()
      | _ -> Alcotest.fail "x should be literal 10");
      match y_val.desc with
      | CField ({ desc = CVar v; _ }, "y") ->
          Alcotest.(check string) "reads from tmp" "__upd_0" v.vname
      | _ -> Alcotest.fail "y should be CField read from __upd_0")
  | _ -> Alcotest.fail "expected CLet wrapping CRecord"

(** { t | a = 1, c = 3 } with Triple{a, b, c} → reads b from base *)
let test_desugar_multi_field_update () =
  let update =
    mk
      (CRecordUpdate (cvar "t" triple_ty, [ ("a", cint 1); ("c", cint 3) ]))
      triple_ty
  in
  let prog =
    [
      { cd_desc = CDRecord triple_decl; cd_loc = loc; cd_doc = None };
      wrap_in_func update;
    ]
  in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_func_body result in
  match body.desc with
  | CLet (_, { desc = CRecord fields; _ }) -> (
      Alcotest.(check int) "3 fields" 3 (List.length fields);
      let names = List.map fst fields in
      Alcotest.(check (list string)) "field order" [ "a"; "b"; "c" ] names;
      (* a and c are updated, b is read *)
      (match (List.assoc "a" fields).desc with
      | CLit (LitInt 1L) -> ()
      | _ -> Alcotest.fail "a should be 1");
      (match (List.assoc "b" fields).desc with
      | CField (_, "b") -> ()
      | _ -> Alcotest.fail "b should be field read");
      match (List.assoc "c" fields).desc with
      | CLit (LitInt 3L) -> ()
      | _ -> Alcotest.fail "c should be 3")
  | _ -> Alcotest.fail "expected CLet + CRecord"

(** Unknown record type → structured Desugar error.

    Post-desugar invariants reject surviving [CRecordUpdate], so silently
    passing this through just defers the failure to a worse phase. *)
let test_desugar_unknown_record_type_raises () =
  let unknown_ty = TyNamed ("UnknownRec", []) in
  let update =
    mk (CRecordUpdate (cvar "u" unknown_ty, [ ("x", cint 1) ])) unknown_ty
  in
  let prog = [ wrap_in_func update ] in
  Blorp.Core_error.check_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Desugar)
    ~msg_contains:"record update for unknown record type" (fun () ->
      ignore (Blorp.Core_desugar.desugar_program prog))

let test_desugar_non_named_record_update_type_raises () =
  let tuple_ty = TyTuple [ ty_int; ty_int ] in
  let update =
    mk (CRecordUpdate (cvar "u" tuple_ty, [ ("x", cint 1) ])) tuple_ty
  in
  let prog = [ wrap_in_func update ] in
  Blorp.Core_error.check_raises
    ~phase:(Blorp.Core_error.Stage Blorp.Core_stage.Desugar)
    ~msg_contains:"record update target has non-record type" (fun () ->
      ignore (Blorp.Core_desugar.desugar_program prog))

(** All fields updated → no field reads, just CLet + CRecord *)
let test_desugar_all_fields_updated () =
  let update =
    mk
      (CRecordUpdate (cvar "p" point_ty, [ ("x", cint 10); ("y", cint 20) ]))
      point_ty
  in
  let prog =
    [
      { cd_desc = CDRecord point_decl; cd_loc = loc; cd_doc = None };
      wrap_in_func update;
    ]
  in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_func_body result in
  match body.desc with
  | CLet (_, { desc = CRecord fields; _ }) ->
      List.iter
        (fun (name, v) ->
          match v.desc with
          | CLit _ -> ()
          | _ -> Alcotest.failf "field %s should be a literal" name)
        fields
  | _ -> Alcotest.fail "expected CLet + CRecord"

(** Nested: { { p | x = 1 } | y = 2 } — inner desugars first *)
let test_desugar_nested () =
  let inner =
    mk (CRecordUpdate (cvar "p" point_ty, [ ("x", cint 1) ])) point_ty
  in
  let outer = mk (CRecordUpdate (inner, [ ("y", cint 2) ])) point_ty in
  let prog =
    [
      { cd_desc = CDRecord point_decl; cd_loc = loc; cd_doc = None };
      wrap_in_func outer;
    ]
  in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_func_body result in
  (* Outer should be CLet + CRecord *)
  match body.desc with
  | CLet (outer_b, { desc = CRecord _; _ }) -> (
      (* The rhs of the outer let should be a CLet (the desugared inner) *)
      match outer_b.bind_rhs.desc with
      | CLet (_, { desc = CRecord _; _ }) -> ()
      | _ -> Alcotest.fail "inner should be desugared to CLet + CRecord")
  | _ -> Alcotest.fail "outer should be CLet + CRecord"

(** Counter resets between desugar_program calls. After T1.4 the
    counter lives on [Session.t]; the test explicitly resets it to
    mirror what [Core_pipeline] does at every compile entry. *)
let test_desugar_counter_resets () =
  let update =
    mk (CRecordUpdate (cvar "p" point_ty, [ ("x", cint 1) ])) point_ty
  in
  let prog =
    [
      { cd_desc = CDRecord point_decl; cd_loc = loc; cd_doc = None };
      wrap_in_func update;
    ]
  in
  Blorp.Session.(reset_core_counters (current ()));
  let _ = Blorp.Core_desugar.desugar_program prog in
  Blorp.Session.(reset_core_counters (current ()));
  let result2 = Blorp.Core_desugar.desugar_program prog in
  let body = get_func_body result2 in
  match body.desc with
  | CLet (b, _) ->
      Alcotest.(check string) "counter reset" "__upd_0" b.bind_var.vname
  | _ -> Alcotest.fail "expected CLet"

(* ============================================================================
   CStringInterp desugaring
   ============================================================================ *)

let str_flags = { sf_multiline = false; sf_raw = false }
let cstr s = mk (CLit (LitString (s, str_flags))) ty_string

(** "hello" → just a string literal *)
let test_desugar_interp_single_lit () =
  let e = mk (CStringInterp ([ IPLit "hello" ], false)) ty_string in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CLit (LitString ("hello", _)) -> ()
  | _ -> Alcotest.fail "single lit should be a string literal"

(** "${x}" where x: String → just x *)
let test_desugar_interp_single_string_expr () =
  let e =
    mk (CStringInterp ([ IPExpr (cvar "x" ty_string) ], false)) ty_string
  in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CVar v -> Alcotest.(check string) "identity" "x" v.vname
  | _ -> Alcotest.fail "single string expr should be identity"

(** "${n}" where n: Int → blorp_to_string(n) *)
let test_desugar_interp_single_int_expr () =
  let e = mk (CStringInterp ([ IPExpr (cvar "n" ty_int) ], false)) ty_string in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CCall (CKBuiltin "blorp_to_string", _, [ { desc = CVar v; _ } ]) ->
      Alcotest.(check string) "arg is n" "n" v.vname
  | _ -> Alcotest.fail "int expr should be blorp_to_string(n)"

(** "hi ${n}" → blorp_string_concat_consume(lit, to_string(n)) *)
let test_desugar_interp_two_parts () =
  let e =
    mk
      (CStringInterp ([ IPLit "hi "; IPExpr (cvar "n" ty_int) ], false))
      ty_string
  in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CCall (CKBuiltin "blorp_string_concat_consume", _, [ a; b ]) -> (
      (match a.desc with
      | CLit (LitString ("hi ", _)) -> ()
      | _ -> Alcotest.fail "first part should be literal");
      match b.desc with
      | CCall (CKBuiltin "blorp_to_string", _, _) -> ()
      | _ -> Alcotest.fail "second part should be to_string call")
  | _ -> Alcotest.fail "two parts should use concat_consume"

(** "${a} + ${b} = ${c}" → blorp_string_concat_many(5, ...) *)
let test_desugar_interp_many_parts () =
  let e =
    mk
      (CStringInterp
         ( [
             IPExpr (cvar "a" ty_int);
             IPLit " + ";
             IPExpr (cvar "b" ty_int);
             IPLit " = ";
             IPExpr (cvar "c" ty_int);
           ],
           false ))
      ty_string
  in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CCall (CKBuiltin "blorp_string_concat_many", _, count :: parts) ->
      (match count.desc with
      | CLit (LitInt 5L) -> ()
      | _ -> Alcotest.fail "count should be 5");
      Alcotest.(check int) "5 parts" 5 (List.length parts)
  | _ -> Alcotest.fail "many parts should use concat_many"

(** Float type dispatches to blorp_float_to_string *)
let test_desugar_interp_float () =
  let ty_float = TyNamed ("Float", []) in
  let e =
    mk (CStringInterp ([ IPExpr (cvar "f" ty_float) ], false)) ty_string
  in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CCall (CKBuiltin "blorp_float_to_string", _, _) -> ()
  | _ -> Alcotest.fail "float should use blorp_float_to_string"

(** Bool dispatches to blorp_bool_to_string *)
let test_desugar_interp_bool () =
  let e =
    mk
      (CStringInterp ([ IPExpr (cvar "b" (TyNamed ("Bool", []))) ], false))
      ty_string
  in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CCall (CKBuiltin "blorp_bool_to_string", _, _) -> ()
  | _ -> Alcotest.fail "bool should use blorp_bool_to_string"

(** Unknown type (List) → CStringInterp preserved *)
let test_desugar_interp_unknown_desugars () =
  (* Unknown types now desugar via blorp_to_string sentinel *)
  let list_ty = TyNamed ("List", [ ty_int ]) in
  let e =
    mk (CStringInterp ([ IPExpr (cvar "xs" list_ty) ], false)) ty_string
  in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CCall (CKBuiltin "blorp_to_string", _, _) -> ()
  | CStringInterp _ -> Alcotest.fail "should not remain as CStringInterp"
  | _ -> Alcotest.fail "expected CCall to blorp_to_string"

(** Empty interpolation → empty string *)
let test_desugar_interp_empty () =
  let e = mk (CStringInterp ([], false)) ty_string in
  let prog = [ wrap_in_func e ] in
  let result = Blorp.Core_desugar.desugar_program prog in
  let body = get_body result in
  match body.desc with
  | CLit (LitString ("", _)) -> ()
  | _ -> Alcotest.fail "empty interp should be empty string"

(* Direct [?=] propagation is lowered before [Core_desugar], so this suite only
   covers sugar nodes that can still exist in Core. *)

(* ============================================================================
   End-to-end: desugar + emit + cc + run
   ============================================================================ *)

let emit_program_to_string (prog : core_program) : string =
  (* A4.2: resolve populates [vdef_id] on [CVar] references to
     user-declared symbols, so the emit pass mangles call sites to
     match their decl sites. *)
  let resolved = Blorp.Core_resolve.resolve_program prog in
  let ctx = Blorp.Core_emit_context.create () in
  Blorp.Core_emit.emit_program ctx resolved;
  Buffer.contents ctx.output

let test_e2e_record_update () =
  (* struct Pair { a: Int, b: Int }
     func compute() -> Int:
       let p = Pair_make(10, 32)
       let q = { p | a = 40 }
       q.a + q.b   -- should be 40 + 32 = 72  (exit code 72) *)
  let pair_ty = TyNamed ("Pair", []) in
  let pair_decl : record_decl =
    {
      record_name = "Pair";
      record_type_params = [];
      record_fields =
        [
          { field_name = "a"; field_type = ty_int; field_loc = loc };
          { field_name = "b"; field_type = ty_int; field_loc = loc };
        ];
      record_is_value = true;
      record_is_builtin = false;
    }
  in
  let mk_pair = mk (CRecord [ ("a", cint 10); ("b", cint 32) ]) pair_ty in
  let update =
    mk (CRecordUpdate (cvar "p" pair_ty, [ ("a", cint 40) ])) pair_ty
  in
  let body =
    mk
      (CLet
         ( {
             bind_var = Var.named "p";
             bind_mut = false;
             bind_ty = pair_ty;
             bind_rhs = mk_pair;
           },
           mk
             (CLet
                ( {
                    bind_var = Var.named "q";
                    bind_mut = false;
                    bind_ty = pair_ty;
                    bind_rhs = update;
                  },
                  mk
                    (CBin
                       ( Add,
                         mk (CField (cvar "q" pair_ty, "a")) ty_int,
                         mk (CField (cvar "q" pair_ty, "b")) ty_int ))
                    ty_int ))
             ty_int ))
      ty_int
  in
  let func : core_func =
    {
      cf_name = "compute";
      cf_type_params = [];
      cf_params = [];
      cf_module = None;
      cf_return_ty = ty_int;
      cf_body = Some body;
      cf_is_pure = true;
      cf_kind = CFUser;
      cf_def_id = 0;
    }
  in
  let prog =
    [
      { cd_desc = CDRecord pair_decl; cd_loc = loc; cd_doc = None };
      { cd_desc = CDFunc func; cd_loc = loc; cd_doc = None };
    ]
  in
  let desugared = Blorp.Core_desugar.desugar_program prog in
  let c_body = emit_program_to_string desugared in
  (* A4.2: entry symbol is mangled __def_0_compute (cf_def_id = 0). *)
  let c_program =
    Printf.sprintf "%s\nint main(void) { return (int)__def_0_compute(); }\n"
      c_body
  in
  let base = Filename.temp_file "blorp_desugar_e2e" "" in
  let src = base ^ ".c" in
  let bin = base ^ ".out" in
  (try Sys.remove base with _ -> ());
  let oc = open_out src in
  output_string oc c_program;
  close_out oc;
  let cc_cmd = Printf.sprintf "cc -std=c99 -o %s %s 2>/dev/null" bin src in
  let cc_status = Sys.command cc_cmd in
  (try Sys.remove src with _ -> ());
  if cc_status <> 0 then begin
    (try Sys.remove bin with _ -> ());
    Alcotest.failf "cc failed (exit %d) on:\n%s" cc_status c_program
  end;
  let run_status = Sys.command (bin ^ " > /dev/null 2>&1") in
  (try Sys.remove bin with _ -> ());
  Alcotest.(check int) "40 + 32 = 72" 72 run_status

(* ============================================================================
   Test suite
   ============================================================================ *)

let suite =
  [
    ( "record_update",
      [
        Alcotest.test_case "single_field" `Quick
          test_desugar_single_field_update;
        Alcotest.test_case "multi_field" `Quick test_desugar_multi_field_update;
        Alcotest.test_case "unknown_record_type_raises" `Quick
          test_desugar_unknown_record_type_raises;
        Alcotest.test_case "non_named_record_update_type_raises" `Quick
          test_desugar_non_named_record_update_type_raises;
        Alcotest.test_case "all_fields" `Quick test_desugar_all_fields_updated;
        Alcotest.test_case "nested" `Quick test_desugar_nested;
        Alcotest.test_case "counter_resets" `Quick test_desugar_counter_resets;
      ] );
    ( "string_interp",
      [
        Alcotest.test_case "single_lit" `Quick test_desugar_interp_single_lit;
        Alcotest.test_case "single_string" `Quick
          test_desugar_interp_single_string_expr;
        Alcotest.test_case "single_int" `Quick
          test_desugar_interp_single_int_expr;
        Alcotest.test_case "two_parts" `Quick test_desugar_interp_two_parts;
        Alcotest.test_case "many_parts" `Quick test_desugar_interp_many_parts;
        Alcotest.test_case "float" `Quick test_desugar_interp_float;
        Alcotest.test_case "bool" `Quick test_desugar_interp_bool;
        Alcotest.test_case "unknown_desugars" `Quick
          test_desugar_interp_unknown_desugars;
        Alcotest.test_case "empty" `Quick test_desugar_interp_empty;
      ] );
    ("e2e", [ Alcotest.test_case "record_update" `Quick test_e2e_record_update ]);
  ]
