(** Lexical environment operations for compile-time evaluation. *)

open Ctfe_value

let ( >>= ) = Result.bind
let void_value loc = { ty = Ast.TyNamed ("Void", []); desc = VVoid; loc }

let bind_value ?(binding_scope = LocalBinding) ?(mutable_binding = false) name
    value env =
  if name = "_" then env
  else
    ( name,
      {
        binding_scope;
        mutable_binding;
        binding_value = AvailableValue (ref value);
      } )
    :: env

let bind_global_value name value env =
  bind_value ~binding_scope:GlobalBinding name value env

let bind_unavailable_global reason name env =
  if name = "_" then env
  else
    ( name,
      {
        binding_scope = GlobalBinding;
        mutable_binding = false;
        binding_value = UnavailableGlobal reason;
      } )
    :: env

let bind_values bindings env =
  List.fold_left
    (fun env (name, value) -> bind_value name value env)
    env bindings

let snapshot env =
  List.map
    (fun (name, binding) ->
      let binding_value =
        match binding.binding_value with
        | AvailableValue cell -> AvailableValue (ref !cell)
        | UnavailableGlobal reason -> UnavailableGlobal reason
      in
      ( name,
        {
          mutable_binding = binding.mutable_binding;
          binding_scope = binding.binding_scope;
          binding_value;
        } ))
    env

let global_bindings env =
  List.filter (fun (_, binding) -> binding.binding_scope = GlobalBinding) env

let has_local_bindings env =
  List.exists (fun (_, binding) -> binding.binding_scope = LocalBinding) env

let unavailable_global_error loc name = function
  | CurrentGlobal ->
      [
        Ctfe_error.error
          ~help:
            "Global constants are evaluated in source order and cannot be \
             recursive. Move the repeated computation into a pure function \
             that takes explicit inputs, or move this computation back to \
             runtime code."
          loc
          (Printf.sprintf
             "global constant initializer cannot reference itself: '%s'" name);
      ]
  | LaterGlobal ->
      [
        Ctfe_error.error
          ~help:
            (Printf.sprintf
               "Move '%s' above this initializer, or move this computation \
                back to runtime code."
               name)
          loc
          (Printf.sprintf
             "global constant initializer cannot reference later global \
              constant '%s'"
             name);
      ]
  | RuntimeInitializedGlobal ->
      [
        Ctfe_error.error
          ~help:
            (Printf.sprintf
               "Only immutable global constants are available during \
                compile-time constant evaluation. Make '%s' immutable and \
                compile-time evaluable, or move this computation back to \
                runtime code."
               name)
          loc
          (Printf.sprintf
             "global constant initializer cannot reference global '%s' because \
              it is not a compile-time constant"
             name);
      ]
  | ImportedRuntimeInitializedGlobal { module_path; original_name } ->
      [
        Ctfe_error.error
          ~help:
            "Only imported values that were themselves evaluated as global \
             constants can be used during compile-time constant evaluation."
          loc
          (Printf.sprintf
             "global constant initializer cannot reference imported value \
              '%s.%s' because it is not a compile-time constant"
             module_path original_name);
      ]

let lookup_binding env loc name =
  match List.assoc_opt name env with
  | Some ({ binding_value = AvailableValue _; _ } as binding) -> Ok binding
  | Some { binding_value = UnavailableGlobal reason; _ } ->
      Error (unavailable_global_error loc name reason)
  | None ->
      Error
        [
          Ctfe_error.error
            ~help:
              "Only earlier global constants that have already been evaluated \
               are available during compile-time constant evaluation."
            loc
            (Printf.sprintf
               "global constant initializer cannot reference '%s' before it is \
                evaluated"
               name);
        ]

let lookup env loc name =
  lookup_binding env loc name >>= fun binding ->
  match binding.binding_value with
  | AvailableValue cell -> Ok !cell
  | UnavailableGlobal reason -> Error (unavailable_global_error loc name reason)

let assign env loc name value =
  lookup_binding env loc name >>= fun binding ->
  if binding.mutable_binding then
    match binding.binding_value with
    | AvailableValue cell ->
        cell := value;
        Ok (void_value loc)
    | UnavailableGlobal reason ->
        Error (unavailable_global_error loc name reason)
  else
    Error
      [
        Ctfe_error.error loc
          (Printf.sprintf "compile-time assignment target '%s' is immutable"
             name);
      ]
