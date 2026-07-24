(** Build the explicit import lookup tables consumed by middle-Core passes. *)

let table_of_bindings (bindings : Session.import_binding list) =
  let table = Hashtbl.create 16 in
  List.iter
    (fun (binding : Session.import_binding) ->
      Hashtbl.replace table binding.local_name
        (binding.module_path, Option.value binding.original_name ~default:""))
    bindings;
  table

let tables_of_bindings ~(main_import_bindings : Session.import_binding list)
    (module_bindings : (string * Session.import_binding list) list) =
  let module_imports = Hashtbl.create 32 in
  List.iter
    (fun (module_name, bindings) ->
      let table = table_of_bindings bindings in
      if Hashtbl.length table > 0 then Hashtbl.replace module_imports module_name table)
    module_bindings;
  (table_of_bindings main_import_bindings, module_imports)
