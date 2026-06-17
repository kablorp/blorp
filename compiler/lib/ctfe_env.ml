(** Lexical environment operations for compile-time evaluation. *)

open Ctfe_value

let ( >>= ) = Result.bind
let void_value loc = { ty = Ast.TyNamed ("Void", []); desc = VVoid; loc }

let bind_value ?(binding_scope = LocalBinding) ?(mutable_binding = false) name
    value env =
  if name = "_" then env
  else (name, { binding_scope; mutable_binding; cell = ref value }) :: env

let bind_global_value name value env =
  bind_value ~binding_scope:GlobalBinding name value env

let bind_values bindings env =
  List.fold_left
    (fun env (name, value) -> bind_value name value env)
    env bindings

let snapshot env =
  List.map
    (fun (name, binding) ->
      ( name,
        {
          mutable_binding = binding.mutable_binding;
          binding_scope = binding.binding_scope;
          cell = ref !(binding.cell);
        } ))
    env

let global_bindings env =
  List.filter (fun (_, binding) -> binding.binding_scope = GlobalBinding) env

let has_local_bindings env =
  List.exists (fun (_, binding) -> binding.binding_scope = LocalBinding) env

let lookup_binding env loc name =
  match List.assoc_opt name env with
  | Some binding -> Ok binding
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
  lookup_binding env loc name >>= fun binding -> Ok !(binding.cell)

let assign env loc name value =
  lookup_binding env loc name >>= fun binding ->
  if binding.mutable_binding then (
    binding.cell := value;
    Ok (void_value loc))
  else
    Error
      [
        Ctfe_error.error loc
          (Printf.sprintf "compile-time assignment target '%s' is immutable"
             name);
      ]
