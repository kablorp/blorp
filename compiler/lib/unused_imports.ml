(** Diagnostic pass for user-written imports that do not contribute any
    visible name usage in the same compilation unit. The pass intentionally consumes
    the original parsed program, not the post-prelude program: prelude imports
    are compiler-injected and may be merged into user import declarations, so
    treating the rewritten import list as user-authored would produce noisy
    false positives. *)

open Ast
module StringSet = Set.Make (String)

type import_item_kind = ModuleAlias of string | SelectiveNames of string list

type import_item = {
  item_kind : import_item_kind;
  item_display : string;
  item_module : string;
  item_loc : loc;
}

type refs = {
  terms : StringSet.t;
  types : StringSet.t;
  aliases : StringSet.t;
  methods : StringSet.t;
  constructors : StringSet.t;
}

type scope = {
  term_bindings : StringSet.t;
  type_bindings : StringSet.t;
  module_aliases : StringSet.t;
}

let empty_refs =
  {
    terms = StringSet.empty;
    types = StringSet.empty;
    aliases = StringSet.empty;
    methods = StringSet.empty;
    constructors = StringSet.empty;
  }

let add_term name refs = { refs with terms = StringSet.add name refs.terms }
let add_type name refs = { refs with types = StringSet.add name refs.types }

let add_alias name refs =
  { refs with aliases = StringSet.add name refs.aliases }

let add_method name refs =
  { refs with methods = StringSet.add name refs.methods }

let add_constructor name refs =
  { refs with constructors = StringSet.add name refs.constructors }

let add_term_binding name scope =
  { scope with term_bindings = StringSet.add name scope.term_bindings }

let add_type_binding name scope =
  { scope with type_bindings = StringSet.add name scope.type_bindings }

let is_dim_name name = String.length name > 0 && name.[0] = '#'

let local_symbol_name (sym : import_symbol) =
  Option.value sym.sym_alias ~default:sym.sym_name

let import_symbol_display (sym : import_symbol) =
  match (sym.sym_alias, sym.sym_ctors) with
  | Some alias, CtorNone -> Printf.sprintf "%s as %s" sym.sym_name alias
  | None, CtorNone -> sym.sym_name
  | Some alias, CtorSome _ ->
      (* Parser currently rejects aliases on Type(Ctor) imports; keep this
         branch explicit so future grammar changes do not silently mislabel
         diagnostics. *)
      Printf.sprintf "%s as %s" sym.sym_name alias
  | None, CtorSome ctors ->
      Printf.sprintf "%s(%s)" sym.sym_name (String.concat ", " ctors)

let module_alias_for_import (imp : import_decl) =
  Option.value imp.import_alias ~default:(Filename.basename imp.import_module)

let import_items (program : program) : import_item list =
  let rec collect_decl acc decl =
    match decl.decl_desc with
    | DPrivate inner -> collect_decl acc inner
    | DImport imp ->
        let symbol_items =
          match imp.import_symbols with
          | None -> []
          | Some symbols ->
              symbols
              |> List.filter (fun sym -> sym.sym_name <> "*")
              |> List.map (fun sym ->
                  let local_names =
                    match sym.sym_ctors with
                    | CtorNone -> [ local_symbol_name sym ]
                    | CtorSome ctors -> sym.sym_name :: ctors
                  in
                  {
                    item_kind = SelectiveNames local_names;
                    item_display = import_symbol_display sym;
                    item_module = imp.import_module;
                    item_loc = decl.decl_loc;
                  })
        in
        let alias_items =
          match imp.import_alias with
          | Some alias ->
              [
                {
                  item_kind = ModuleAlias alias;
                  item_display = alias;
                  item_module = imp.import_module;
                  item_loc = decl.decl_loc;
                };
              ]
          | None -> (
              match imp.import_symbols with
              | Some _ -> []
              | None ->
                  let alias = module_alias_for_import imp in
                  [
                    {
                      item_kind = ModuleAlias alias;
                      item_display = alias;
                      item_module = imp.import_module;
                      item_loc = decl.decl_loc;
                    };
                  ])
        in
        List.rev_append alias_items (List.rev_append symbol_items acc)
    | DFunc _ | DType _ | DRecord _ | DVar _ | DTrait _ | DImpl _ | DTypeAlias _
      ->
        acc
  in
  List.fold_left collect_decl [] program |> List.rev

let module_aliases_of_items items =
  List.fold_left
    (fun acc item ->
      match item.item_kind with
      | ModuleAlias alias -> StringSet.add alias acc
      | SelectiveNames _ -> acc)
    StringSet.empty items

let rec collect_top_level_bindings scope decl =
  match decl.decl_desc with
  | DPrivate inner -> collect_top_level_bindings scope inner
  | DFunc f -> (
      match f.func_name with
      | Some name -> add_term_binding name scope
      | None -> scope)
  | DVar v -> (
      match v.var_name with
      | Some name -> add_term_binding name scope
      | None -> (
          match v.var_pattern with
          | Some pat ->
              List.fold_left
                (fun scope name -> add_term_binding name scope)
                scope
                (Ast.collect_pattern_vars pat)
          | None -> scope))
  | DType t -> add_type_binding t.type_name scope
  | DRecord r -> add_type_binding r.record_name scope
  | DTypeAlias a -> add_type_binding a.alias_name scope
  | DTrait t -> add_type_binding t.trait_name scope
  | DImport _ | DImpl _ -> scope

let initial_scope program module_aliases =
  List.fold_left collect_top_level_bindings
    {
      term_bindings = StringSet.empty;
      type_bindings = StringSet.empty;
      module_aliases;
    }
    program

let add_type_params params scope =
  List.fold_left
    (fun scope name ->
      add_type_binding (Types.strip_type_param_bounds name) scope)
    scope params

let scan_type_param_bounds refs params =
  List.fold_left
    (fun refs param ->
      List.fold_left
        (fun refs bound -> add_type (Generic_params.trait_ref_name bound) refs)
        refs param.param_bounds)
    refs params

let split_qualified name =
  match String.index_opt name '.' with
  | None -> None
  | Some i ->
      let lhs = String.sub name 0 i in
      let rhs = String.sub name (i + 1) (String.length name - i - 1) in
      Some (lhs, rhs)

let rec scan_type scope refs ty =
  match ty with
  | TyNamed (name, args) ->
      let refs =
        match split_qualified name with
        | Some (alias, _) when StringSet.mem alias scope.module_aliases ->
            add_alias alias refs
        | _ ->
            if is_dim_name name || StringSet.mem name scope.type_bindings then
              refs
            else add_type name refs
      in
      List.fold_left (scan_type scope) refs args
  | TyArray (elem, dims) ->
      List.fold_left (scan_type scope) (scan_type scope refs elem) dims
  | TyFunc f ->
      scan_type scope (List.fold_left (scan_type scope) refs f.params) f.return
  | TyTuple elems -> List.fold_left (scan_type scope) refs elems
  | TyRange inner -> scan_type scope refs inner
  | TyDimOp (_, lhs, rhs) -> scan_type scope (scan_type scope refs lhs) rhs
  | TyVar _ | TyBoundVar _ | TyConstInt _ | TySelf | TyVarDims _ | TyMeta _ ->
      refs

let scan_type_opt scope refs = function
  | Some ty -> scan_type scope refs ty
  | None -> refs

let rec scan_pattern scope refs pat =
  match pat with
  | PatWildcard | PatVar _ | PatLiteral _ -> refs
  | PatConstructor (name, args) ->
      List.fold_left (scan_pattern scope) (add_constructor name refs) args
  | PatQualified (alias, _ctor, args) ->
      let refs =
        if
          StringSet.mem alias scope.module_aliases
          && not (StringSet.mem alias scope.term_bindings)
        then add_alias alias refs
        else refs
      in
      List.fold_left (scan_pattern scope) refs args
  | PatTuple pats | PatList (pats, None) | PatOr pats ->
      List.fold_left (scan_pattern scope) refs pats
  | PatList (pats, Some spread) ->
      scan_pattern scope (List.fold_left (scan_pattern scope) refs pats) spread

let add_pattern_bindings scope pat =
  List.fold_left
    (fun scope name -> add_term_binding name scope)
    scope
    (Ast.collect_pattern_vars pat)

let rec field_access_module_alias scope expr =
  match expr.expr_desc with
  | EIdent name
    when StringSet.mem name scope.module_aliases
         && not (StringSet.mem name scope.term_bindings) ->
      Some name
  | EFieldAccess (base, _) -> field_access_module_alias scope base
  | _ -> None

let rec scan_expr scope refs expr =
  match expr.expr_desc with
  | EIdent name ->
      if StringSet.mem name scope.term_bindings then refs
      else add_term name refs
  | ELiteral _ | EVoid | EBreak | EContinue -> refs
  | EUnary (_, e) -> scan_expr scope refs e
  | EAscription (e, ty) -> scan_type scope (scan_expr scope refs e) ty
  | EBinary (_, a, b) | ELogical (_, a, b) | ERange (a, b) ->
      scan_expr scope (scan_expr scope refs a) b
  | ECall (({ expr_desc = EFieldAccess (recv, method_name); _ } as callee), args)
    -> (
      match field_access_module_alias scope callee with
      | Some alias ->
          List.fold_left (scan_expr scope) (add_alias alias refs) args
      | None ->
          let refs = scan_expr scope refs recv |> add_method method_name in
          List.fold_left (scan_expr scope) refs args)
  | ECall (callee, args) ->
      List.fold_left (scan_expr scope) (scan_expr scope refs callee) args
  | EIf (cond, then_, else_) ->
      let refs = scan_expr scope (scan_expr scope refs cond) then_ in
      Option.fold ~none:refs ~some:(scan_expr scope refs) else_
  | EMatch (scrutinee, cases) ->
      List.fold_left
        (fun refs case ->
          let refs = scan_pattern scope refs case.case_pattern in
          let case_scope = add_pattern_bindings scope case.case_pattern in
          scan_expr case_scope refs case.case_body)
        (scan_expr scope refs scrutinee)
        cases
  | ESelect arms ->
      List.fold_left
        (fun refs arm ->
          match arm.select_arm_kind with
          | SelectRecv { select_bind; select_channel } ->
              let refs = scan_expr scope refs select_channel in
              scan_expr
                (add_term_binding select_bind scope)
                refs arm.select_arm_body
          | SelectAfter timeout ->
              scan_expr scope (scan_expr scope refs timeout) arm.select_arm_body
          | SelectSealed channel ->
              scan_expr scope (scan_expr scope refs channel) arm.select_arm_body)
        refs arms
  | EBlock exprs -> scan_block scope refs exprs
  | ETuple elems | EVector elems | EList elems ->
      List.fold_left (scan_expr scope) refs elems
  | ERecord fields ->
      List.fold_left
        (fun refs (_, value) -> scan_expr scope refs value)
        refs fields
  | ERecordUpdate (base, fields) ->
      List.fold_left
        (fun refs (_, value) -> scan_expr scope refs value)
        (scan_expr scope refs base)
        fields
  | EFieldAccess (base, _) -> (
      match field_access_module_alias scope expr with
      | Some alias -> add_alias alias refs
      | None -> scan_expr scope refs base)
  | ELambda f -> scan_func scope refs f
  | EWhile (cond, body) -> scan_expr scope (scan_expr scope refs cond) body
  | EFor (name, iterable, body) ->
      let refs = scan_expr scope refs iterable in
      scan_expr (add_term_binding name scope) refs body
  | EForTuple (names, iterable, body) ->
      let refs = scan_expr scope refs iterable in
      let scope =
        List.fold_left (fun s n -> add_term_binding n s) scope names
      in
      scan_expr scope refs body
  | ELoopView view ->
      let refs = scan_expr scope refs view.loop_view_source in
      let refs = scan_type scope refs view.loop_view_elem_type in
      Option.fold ~none:refs ~some:(scan_expr scope refs)
        view.loop_view_size_arg
  | EAssign (name, value) ->
      let refs =
        if StringSet.mem name scope.term_bindings then refs
        else add_term name refs
      in
      scan_expr scope refs value
  | ECompoundAssign (name, _, value) ->
      let refs =
        if StringSet.mem name scope.term_bindings then refs
        else add_term name refs
      in
      scan_expr scope refs value
  | EVarDecl (_name, ty, init, _) ->
      scan_type_opt scope (scan_expr scope refs init) ty
  | ETupleDestruct (_names, init) -> scan_expr scope refs init
  | ESubscript (base, index) ->
      scan_expr scope (scan_expr scope refs base) index
  | ESubscriptMulti (base, indices) ->
      List.fold_left (scan_expr scope) (scan_expr scope refs base) indices
  | ESubscriptAssign (base, indices, value) ->
      scan_expr scope
        (List.fold_left (scan_expr scope) (scan_expr scope refs base) indices)
        value
  | EStringInterp (parts, _) ->
      List.fold_left
        (fun refs part ->
          match part with
          | InterpLit _ -> refs
          | InterpExpr e -> scan_expr scope refs e)
        refs parts
  | EStringInterpRaw _ -> refs
  | EQuestionBind (_name, ty, rhs) ->
      scan_type_opt scope (scan_expr scope refs rhs) ty
  | EWith (binding, body) ->
      let refs =
        scan_type_opt scope
          (scan_expr scope refs binding.with_value)
          binding.with_type
      in
      scan_expr (add_term_binding binding.with_name scope) refs body
  | EDebugBlock exprs | EConcurrent (exprs, None, _) ->
      scan_block scope refs exprs
  | EConcurrent (exprs, Some timeout, _) ->
      scan_expr scope (scan_block scope refs exprs) timeout
  | EConcurrentBind (_name, ty, rhs) ->
      scan_type_opt scope (scan_expr scope refs rhs) ty
  | EConcurrentFor (name, iterable, body, timeout, _) ->
      let refs = scan_expr scope refs iterable in
      let refs = scan_expr (add_term_binding name scope) refs body in
      Option.fold ~none:refs ~some:(scan_expr scope refs) timeout
  | EDetach e -> scan_expr scope refs e
  | EDict entries ->
      List.fold_left
        (fun refs (key, value) ->
          scan_expr scope (scan_expr scope refs key) value)
        refs entries
  | EBuiltin _ -> refs
  | EFuncDecl f -> scan_func scope refs f

and scan_block scope refs exprs =
  let scope_after_expr scope expr =
    match expr.expr_desc with
    | EVarDecl (name, _, _, _) -> add_term_binding name scope
    | ETupleDestruct (names, _) ->
        List.fold_left (fun s n -> add_term_binding n s) scope names
    | EQuestionBind (name, _, _) -> add_term_binding name scope
    | EConcurrentBind (name, _, _) -> add_term_binding name scope
    | _ -> scope
  in
  let refs, _scope =
    List.fold_left
      (fun (refs, scope) expr ->
        let refs = scan_expr scope refs expr in
        (refs, scope_after_expr scope expr))
      (refs, scope) exprs
  in
  refs

and scan_param scope refs param =
  let refs = scan_type_opt scope refs param.param_type in
  let refs =
    match param.param_pattern with
    | Some pat -> scan_pattern scope refs pat
    | None -> refs
  in
  refs

and add_param_bindings scope param =
  let scope =
    match param.param_name with
    | Some name -> add_term_binding name scope
    | None -> scope
  in
  match param.param_pattern with
  | Some pat -> add_pattern_bindings scope pat
  | None -> scope

and scan_func scope refs func =
  let refs = scan_type_param_bounds refs func.func_type_params in
  let scope =
    add_type_params (Ast.type_param_names func.func_type_params) scope
  in
  let refs =
    List.fold_left (scan_param scope) refs func.func_params |> fun refs ->
    scan_type_opt scope refs func.func_return_type |> fun refs ->
    List.fold_left
      (fun refs (lhs, rhs) -> scan_type scope (scan_type scope refs lhs) rhs)
      refs func.func_dim_constraints
  in
  let body_scope = List.fold_left add_param_bindings scope func.func_params in
  match func.func_body with
  | FuncBodyExpr body -> scan_expr body_scope refs body
  | FuncBuiltinBody _ | FuncForeign _ | FuncNoBody -> refs

let scan_trait_method scope refs meth =
  let refs =
    List.fold_left (scan_param scope) refs meth.method_params |> fun refs ->
    scan_type_opt scope refs meth.method_return_type
  in
  match meth.method_default_body with
  | Some body ->
      let body_scope =
        List.fold_left add_param_bindings scope meth.method_params
      in
      scan_expr body_scope refs body
  | None -> refs

let rec scan_decl scope refs decl =
  match decl.decl_desc with
  | DImport _ -> refs
  | DPrivate inner -> scan_decl scope refs inner
  | DFunc f -> scan_func scope refs f
  | DVar v ->
      let refs = scan_type_opt scope refs v.var_type in
      let refs =
        match v.var_pattern with
        | Some pat -> scan_pattern scope refs pat
        | None -> refs
      in
      scan_expr scope refs v.var_value
  | DType t ->
      let refs = scan_type_param_bounds refs t.type_params in
      let scope = add_type_params (Ast.type_param_names t.type_params) scope in
      List.fold_left
        (fun refs variant ->
          List.fold_left (scan_type scope) refs variant.variant_fields)
        refs t.type_variants
  | DRecord r ->
      let refs = scan_type_param_bounds refs r.record_type_params in
      let scope =
        add_type_params (Ast.type_param_names r.record_type_params) scope
      in
      List.fold_left
        (fun refs field -> scan_type scope refs field.field_type)
        refs r.record_fields
  | DTypeAlias a ->
      let refs = scan_type_param_bounds refs a.alias_type_params in
      scan_type
        (add_type_params (Ast.type_param_names a.alias_type_params) scope)
        refs a.alias_target
  | DTrait t ->
      let refs = scan_type_param_bounds refs t.trait_type_params in
      let scope =
        add_type_params (Ast.type_param_names t.trait_type_params) scope
      in
      let refs =
        List.fold_left
          (fun refs name -> add_type name refs)
          refs t.trait_supertraits
      in
      List.fold_left (scan_trait_method scope) refs t.trait_methods
  | DImpl impl ->
      let refs = add_type impl.impl_trait refs in
      let refs = scan_type scope refs impl.impl_for_type in
      List.fold_left (scan_func scope) refs impl.impl_methods

let refs_of_program program items =
  let scope = initial_scope program (module_aliases_of_items items) in
  List.fold_left (scan_decl scope) empty_refs program

let selective_name_used refs name =
  StringSet.mem name refs.terms
  || StringSet.mem name refs.types
  || StringSet.mem name refs.methods
  || StringSet.mem name refs.constructors

let item_used refs item =
  match item.item_kind with
  | ModuleAlias alias -> StringSet.mem alias refs.aliases
  | SelectiveNames names -> List.exists (selective_name_used refs) names

let error_for_item item =
  let message =
    match item.item_kind with
    | ModuleAlias _ ->
        Printf.sprintf "unused module import '%s' from module '%s'"
          item.item_display item.item_module
    | SelectiveNames _ ->
        Printf.sprintf "unused import '%s' from module '%s'" item.item_display
          item.item_module
  in
  {
    message;
    loc = item.item_loc;
    phase = TypeCheck;
    kind = OtherError;
    notes = [];
    help = Some "Remove the import, or use it in this file.";
  }

let errors (program : program) : compiler_error list =
  let items = import_items program in
  if items = [] then []
  else
    let refs = refs_of_program program items in
    items
    |> List.filter (fun item -> not (item_used refs item))
    |> List.map error_for_item
