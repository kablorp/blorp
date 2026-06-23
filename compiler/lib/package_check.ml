type error = Package_manifest.error = {
  path : string option;
  line : int option;
  message : string;
}

type result = { manifest : Package_manifest.t; source_files : string list }

let make_error = Package_manifest.make_error
let render_error = Package_manifest.render_error
let render_errors errors = String.concat "\n" (List.map render_error errors)

let has_prefix prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let with_brp_ext module_path = module_path ^ ".brp"
let normalize_path path = String.map (function '\\' -> '/' | c -> c) path

let is_directory path =
  try Sys.file_exists path && Sys.is_directory path with _ -> false

let is_file path =
  try Sys.file_exists path && not (Sys.is_directory path) with _ -> false

let canonical_dir path = try Unix.realpath path with _ -> path

let module_file source_dir module_path =
  Filename.concat source_dir (with_brp_ext (normalize_path module_path))

let std_module_exists module_name =
  if has_prefix "std/" module_name then
    Option.is_some (Embedded_std.find module_name)
  else Option.is_some (Embedded_std.find ("std/" ^ module_name))

let own_module_exists ~manifest ~source_dir module_name =
  (module_name = manifest.Package_manifest.name
  || has_prefix (manifest.Package_manifest.name ^ "/") module_name)
  && is_file (module_file source_dir module_name)

let relative_import_target ~source_dir ~file_path module_name =
  let candidate =
    Filename.concat (Filename.dirname file_path) (with_brp_ext module_name)
  in
  if is_file candidate && Modules.is_path_under_dir ~dir:source_dir candidate
  then Some candidate
  else None

let collect_source_files source_dir =
  let rec walk path =
    if is_directory path then
      Sys.readdir path |> Array.to_list |> List.sort String.compare
      |> List.concat_map (fun name -> walk (Filename.concat path name))
    else if Filename.check_suffix path ".brp" then [ path ]
    else []
  in
  walk source_dir

let export_errors ~manifest ~source_dir =
  List.filter_map
    (fun module_name ->
      let path = module_file source_dir module_name in
      if is_file path then None
      else
        Some
          (make_error ~path
             (Printf.sprintf "exported module %S does not exist" module_name)))
    manifest.Package_manifest.exports

let check_import ~manifest ~source_dir ~file_path module_name =
  if std_module_exists module_name then None
  else if own_module_exists ~manifest ~source_dir module_name then None
  else if has_prefix "./" module_name || has_prefix "../" module_name then
    match relative_import_target ~source_dir ~file_path module_name with
    | Some _ -> None
    | None ->
        Some
          (make_error ~path:file_path
             (Printf.sprintf
                "package relative import %S must resolve to a source file \
                 under src/"
                module_name))
  else
    Some
      (make_error ~path:file_path
         (Printf.sprintf
            "source packages may import only std modules or modules inside \
             package %S; found import %S"
            manifest.Package_manifest.name module_name))

let rec expr_uses_builtin expr =
  match expr.Ast.expr_desc with
  | Ast.EBuiltin _ -> Some expr.Ast.expr_loc
  | _ -> List.find_map expr_uses_builtin (Ast.expr_children expr)

let check_func_body ~file_path func =
  match func.Ast.func_body with
  | Ast.FuncBuiltinBody _ ->
      [
        make_error ~path:file_path
          "'builtin' function bodies are not allowed in source packages";
      ]
  | Ast.FuncForeign _ ->
      [
        make_error ~path:file_path
          "'foreign' declarations are not allowed in source packages";
      ]
  | Ast.FuncBodyExpr body -> (
      match expr_uses_builtin body with
      | Some loc ->
          [
            make_error ~path:file_path ~line:loc.Ast.line
              "'builtin' expressions are not allowed in source packages";
          ]
      | None -> [])
  | Ast.FuncNoBody -> []

let rec check_decl ~manifest ~source_dir ~file_path decl =
  match decl.Ast.decl_desc with
  | Ast.DImport imp -> (
      match
        check_import ~manifest ~source_dir ~file_path imp.Ast.import_module
      with
      | Some err -> [ err ]
      | None -> [])
  | Ast.DFunc func -> check_func_body ~file_path func
  | Ast.DType ty when ty.Ast.type_is_builtin ->
      [
        make_error ~path:file_path
          "'builtin' types are not allowed in source packages";
      ]
  | Ast.DRecord record when record.Ast.record_is_builtin ->
      [
        make_error ~path:file_path
          "'builtin' records are not allowed in source packages";
      ]
  | Ast.DVar var -> (
      match expr_uses_builtin var.Ast.var_value with
      | Some loc ->
          [
            make_error ~path:file_path ~line:loc.Ast.line
              "'builtin' expressions are not allowed in source packages";
          ]
      | None -> [])
  | Ast.DPrivate inner -> check_decl ~manifest ~source_dir ~file_path inner
  | Ast.DTrait trait_decl ->
      List.filter_map
        (fun method_decl ->
          Option.bind method_decl.Ast.method_default_body (fun body ->
              Option.map
                (fun loc ->
                  make_error ~path:file_path ~line:loc.Ast.line
                    "'builtin' expressions are not allowed in source packages")
                (expr_uses_builtin body)))
        trait_decl.Ast.trait_methods
  | Ast.DImpl impl ->
      List.concat_map (check_func_body ~file_path) impl.Ast.impl_methods
  | Ast.DType _ | Ast.DRecord _ | Ast.DTypeAlias _ -> []

let check_source_file ~manifest ~source_dir file_path =
  try
    let source = Modules.read_file file_path in
    match Modules.parse_source ~filename:file_path source with
    | Error err ->
        [
          make_error ~path:file_path ~line:err.Ast.loc.Ast.line err.Ast.message;
        ]
    | Ok program ->
        List.concat_map (check_decl ~manifest ~source_dir ~file_path) program
  with Sys_error msg -> [ make_error ~path:file_path msg ]

let compiler_error_to_package_error ~default_path (err : Ast.compiler_error) =
  let path = Option.value ~default:default_path err.Ast.loc.Ast.loc_file in
  let line =
    if err.Ast.loc.Ast.line > 0 then Some err.Ast.loc.Ast.line else None
  in
  let message =
    match err.Ast.help with
    | Some help -> err.Ast.message ^ "\n  help: " ^ help
    | None -> err.Ast.message
  in
  make_error ~path ?line message

let source_package ~manifest ~root ~source_dir : Session.source_package =
  {
    source_package_alias = manifest.Package_manifest.name;
    source_package_name = manifest.Package_manifest.name;
    source_package_root = canonical_dir root;
    source_package_source_dir = canonical_dir source_dir;
    source_package_exports = manifest.Package_manifest.exports;
  }

let typecheck_source_file ~source_package file_path =
  try
    let source = Modules.read_file file_path in
    match
      Pipeline.typecheck_source_package_module_only_typed ~source_package
        ~filename:file_path ~source
    with
    | Ok _ -> []
    | Error errors ->
        List.map
          (compiler_error_to_package_error ~default_path:file_path)
          errors
  with Sys_error msg -> [ make_error ~path:file_path msg ]

let check root =
  if not (is_directory root) then
    Error [ make_error ~path:root "package path must be a directory" ]
  else
    let manifest_path =
      Filename.concat root Package_manifest.manifest_filename
    in
    match Package_manifest.read manifest_path with
    | Error errors -> Error errors
    | Ok manifest -> (
        let source_dir = Filename.concat root "src" in
        let errors = ref [] in
        let add_error err = errors := err :: !errors in
        if
          manifest.Package_manifest.std_compat
          <> Package_manifest.current_std_compat
        then
          add_error
            (make_error ~path:manifest_path
               (Printf.sprintf
                  "package requires std compat %S, but this compiler supports \
                   %S"
                  manifest.Package_manifest.std_compat
                  Package_manifest.current_std_compat));
        if not (is_directory source_dir) then
          add_error
            (make_error ~path:source_dir
               "source package must contain a src/ directory");
        let source_files =
          if is_directory source_dir then collect_source_files source_dir
          else []
        in
        if is_directory source_dir && source_files = [] then
          add_error
            (make_error ~path:source_dir
               "source package must contain at least one .brp file");
        List.iter add_error (export_errors ~manifest ~source_dir);
        List.iter
          (fun file_path ->
            List.iter add_error
              (check_source_file ~manifest ~source_dir file_path))
          source_files;
        if !errors = [] then begin
          let source_package = source_package ~manifest ~root ~source_dir in
          List.iter
            (fun file_path ->
              List.iter add_error
                (typecheck_source_file ~source_package file_path))
            source_files
        end;
        match List.rev !errors with
        | [] -> Ok { manifest; source_files }
        | errors -> Error errors)
