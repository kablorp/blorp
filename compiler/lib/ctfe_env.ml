(** Lexical environment operations for compile-time evaluation. *)

open Ctfe_value

let ( >>= ) = Result.bind
let void_value loc = { ty = Ast.TyNamed ("Void", []); desc = VVoid; loc }

let bind_value ?(mutable_binding = false) name value env =
  if name = "_" then env
  else (name, { mutable_binding; cell = ref value }) :: env

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
          cell = ref !(binding.cell);
        } ))
    env

let lookup_binding env loc name =
  match List.assoc_opt name env with
  | Some binding -> Ok binding
  | None ->
      Error
        [
          Ctfe_error.error
            ~help:
              "Only earlier bindings in the same compile_time block are \
               available during compile-time evaluation."
            loc
            (Printf.sprintf
               "compile_time initializer cannot reference '%s' before it is \
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
          (Printf.sprintf "compile_time assignment target '%s' is immutable"
             name);
      ]
