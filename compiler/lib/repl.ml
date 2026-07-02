(** Interactive REPL for blorp.

    Each iteration accumulates declarations, then constructs a synthetic
    source program and runs it through the standard compile pipeline
    (parse → typecheck → codegen → CC → execute). *)

(* ── State ────────────────────────────────────────────────────────── *)

type repl_state = {
  imports : string list;  (** accumulated import block text, reversed *)
  decls : string list;  (** accumulated declaration text, reversed *)
  iteration : int;
}

let empty_state = { imports = []; decls = []; iteration = 0 }

(* ── Input classification ─────────────────────────────────────────── *)

type input_kind =
  | Declarations of Ast.program * string
  | Expression of string
  | Command of string
  | Empty
  | ParseError of string

let classify_input text =
  let trimmed = String.trim text in
  if trimmed = "" then Empty
  else if String.length trimmed > 0 && (trimmed.[0] = ':' || trimmed.[0] = '/')
  then Command trimmed
  else
    match Modules.parse_source text with
    | Ok program when program <> [] -> Declarations (program, text)
    | Ok _ -> Empty
    | Error _ -> (
        let wrapped =
          "func __repl_detect(args: List[String]) -> Int:\n    "
          ^ String.concat "\n    " (String.split_on_char '\n' text)
          ^ "\n"
        in
        match Modules.parse_source wrapped with
        | Ok _ -> Expression text
        | Error err ->
            ParseError (Printf.sprintf "Parse error: %s" err.Ast.message))

(* ── Source construction ──────────────────────────────────────────── *)

let indent n text =
  let prefix = String.make n ' ' in
  text |> String.split_on_char '\n'
  |> List.map (fun line -> if String.trim line = "" then "" else prefix ^ line)
  |> String.concat "\n"

(** Build the synthetic source.  All decls at top level; [expr_wrap] in main. *)
let build_source state ~expr_wrap =
  let buf = Buffer.create 1024 in
  List.iter
    (fun imp ->
      Buffer.add_string buf imp;
      Buffer.add_char buf '\n')
    (List.rev state.imports);
  List.iter
    (fun decl ->
      Buffer.add_string buf decl;
      Buffer.add_char buf '\n')
    (List.rev state.decls);
  Buffer.add_string buf "func main(args: List[String]) -> Int:\n";
  (match expr_wrap with
  | Some wrapped ->
      Buffer.add_string buf (indent 4 wrapped);
      Buffer.add_char buf '\n'
  | None -> ());
  Buffer.add_string buf "    0\n";
  Buffer.contents buf

(* ── Compilation and execution ────────────────────────────────────── *)

let try_compile_and_run ~debug source =
  Test_runner.with_run_artifacts (fun () ->
      if debug then Printf.eprintf "[repl] source:\n%s\n%!" source;
      Modules.full_reset ();
      Modules.init_module_paths (Sys.getcwd ());
      let precompiled = Test_runner.precompile_runtime ~opt:"O2" () in
      let embed_runtime = precompiled = None in
      match
        Pipeline.compile ~debug ~embed_runtime ~filename:"<repl>" ~source ()
      with
      | Error errors -> Error (Diagnostics.format_errors ~file:"<repl>" errors)
      | Ok (Pipeline.Stopped_at _) ->
          (* Unreachable: REPL never supplies ~on_stage, so the pipeline has
         no stop trigger. If we ever get here, a callback was wired up
         without updating this branch — fail loud. *)
          assert false
      | Ok (Pipeline.Compiled { c_code; link_flags; include_dirs; _ }) ->
          let compilation_dir = Test_runner.run_compilation_dir () in
          let bin_file = Filename.concat compilation_dir "program.bin" in
          let header_file =
            Option.map (fun p -> p.Test_runner.header_file) precompiled
          in
          let pch_file =
            Option.bind precompiled (fun p -> p.Test_runner.pch_file)
          in
          let cc_args =
            [ "-O2"; "-fwrapv"; "-pipe"; "-w" ]
            @ List.concat_map (fun dir -> [ "-I"; dir ]) include_dirs
            @ (match pch_file with
              | Some pch_f ->
                  if Lazy.force Test_runner.cc_is_clang then
                    [ "-include-pch"; pch_f ]
                  else [ "-include"; pch_f ]
              | None -> (
                  match header_file with
                  | Some h -> [ "-include"; h ]
                  | None -> []))
            @ (match precompiled with
              | Some p -> [ p.Test_runner.runtime_obj ]
              | None -> [])
            @ [ "-lm"; "-lpthread" ]
            @ List.concat_map
                (fun s -> String.split_on_char ' ' (String.trim s))
                link_flags
          in
          let cc_result, cc_output =
            Test_runner.compile_c_from_stdin c_code bin_file cc_args
          in
          if cc_result <> 0 then
            if debug then
              Error
                ("Internal error: generated C code failed to compile.\n"
               ^ String.trim cc_output)
            else Error "Error: could not evaluate expression"
          else begin
            let result =
              Test_runner.run_process_timeout ~timeout:(Some 10) bin_file []
            in
            if result = 124 then Error "Evaluation timed out (10s)"
            else if result <> 0 then
              Error (Printf.sprintf "Runtime error (exit code %d)" result)
            else Ok ()
          end)

(* ── Declaration helpers ──────────────────────────────────────────── *)

let is_all_imports program =
  List.for_all
    (fun (d : Ast.decl) ->
      match d.decl_desc with Ast.DImport _ -> true | _ -> false)
    program

let describe_decl (d : Ast.decl) =
  match d.decl_desc with
  | Ast.DFunc f ->
      let name =
        match f.Ast.func_name with Some n -> n | None -> "<lambda>"
      in
      let params =
        List.map
          (fun (p : Ast.param) ->
            match p.Ast.param_type with
            | Some t -> Types.type_to_string t
            | None -> "?")
          f.Ast.func_params
      in
      let ret =
        match f.Ast.func_return_type with
        | Some t -> Types.type_to_string t
        | None -> "?"
      in
      Printf.sprintf "func %s : (%s) -> %s" name (String.concat ", " params) ret
  | Ast.DType t -> Printf.sprintf "union %s" t.Ast.type_name
  | Ast.DRecord r ->
      let kw = if r.Ast.record_is_value then "struct" else "record" in
      Printf.sprintf "%s %s" kw r.Ast.record_name
  | Ast.DVar v ->
      let name = match v.Ast.var_name with Some n -> n | None -> "_" in
      Printf.sprintf "%s defined" name
  | Ast.DImport i -> Printf.sprintf "import %s" i.Ast.import_module
  | Ast.DTrait t -> Printf.sprintf "trait %s" t.Ast.trait_name
  | Ast.DImpl i ->
      Printf.sprintf "impl %s for %s" i.Ast.impl_trait
        (Types.type_to_string i.Ast.impl_for_type)
  | Ast.DTypeAlias a -> Printf.sprintf "type %s" a.Ast.alias_name
  | Ast.DPrivate _ -> "private"

(* ── Module index for slash commands ──────────────────────────────── *)

(** Cached module index: short_name -> (relative_path, category) list.
    e.g. "option" -> [("types/option", "types")] *)
let cached_module_index : (string, (string * string) list) Hashtbl.t option ref
    =
  ref None

let build_module_index () =
  match !cached_module_index with
  | Some idx -> idx
  | None ->
      let idx = Hashtbl.create 64 in
      Modules.init_module_paths (Sys.getcwd ());
      (match Modules.std_source_dir () with
      | None -> ()
      | Some std_dir ->
          let rec scan dir category =
            let entries = try Sys.readdir dir with Sys_error _ -> [||] in
            Array.iter
              (fun entry ->
                let path = Filename.concat dir entry in
                if try Sys.is_directory path with Sys_error _ -> false then
                  scan path entry
                else if Filename.check_suffix entry ".brp" then begin
                  let name = Filename.chop_suffix entry ".brp" in
                  let rel =
                    if category = "" then name else category ^ "/" ^ name
                  in
                  let existing =
                    try Hashtbl.find idx name with Not_found -> []
                  in
                  Hashtbl.replace idx name ((rel, category) :: existing)
                end)
              entries
          in
          scan std_dir "");
      cached_module_index := Some idx;
      idx

(** Get export names from a module's parsed exports, including union variant constructors. *)
let get_export_names (exports : (string * Ast.decl) list) =
  List.concat_map
    (fun (name, decl) ->
      match decl.Ast.decl_desc with
      | Ast.DType t ->
          name
          :: List.map
               (fun (v : Ast.variant) -> v.Ast.variant_name)
               t.Ast.type_variants
      | _ -> [ name ])
    exports

(* ── Slash command handlers ──────────────────────────────────────── *)

let handle_help () =
  print_endline "Commands:";
  print_endline "  :quit, :q       Exit the REPL";
  print_endline "  :reset          Clear accumulated state";
  print_endline "  :state          Show current imports and declarations";
  print_endline "  :type <expr>    Type-check an expression";
  print_endline "";
  print_endline "  /help           Show this help";
  print_endline "  /modules [cat]  List available std library modules";
  print_endline "  /import <name>  Auto-import a module with its exports";
  print_endline "  /func           Show function definition syntax";
  print_endline "  /match          Show match expression syntax";
  print_endline "  /record         Show record/struct/union syntax"

let handle_modules filter =
  let idx = build_module_index () in
  (* Group all entries by category *)
  let categories : (string, string list) Hashtbl.t = Hashtbl.create 16 in
  Hashtbl.iter
    (fun name entries ->
      List.iter
        (fun (_rel, cat) ->
          let cat_key = if cat = "" then "(root)" else cat in
          let existing =
            try Hashtbl.find categories cat_key with Not_found -> []
          in
          Hashtbl.replace categories cat_key (name :: existing))
        entries)
    idx;
  (* Sort categories *)
  let cat_order =
    [ "types"; "text"; "numeric"; "sys"; "json"; "net"; "database"; "(root)" ]
  in
  let all_cats = Hashtbl.fold (fun k _ acc -> k :: acc) categories [] in
  let sorted_cats =
    let in_order = List.filter (fun c -> List.mem c all_cats) cat_order in
    let extra = List.filter (fun c -> not (List.mem c cat_order)) all_cats in
    let extra_sorted = List.sort String.compare extra in
    in_order @ extra_sorted
  in
  let should_show cat =
    match filter with None -> true | Some f -> cat = f || cat = "(" ^ f ^ ")"
  in
  let shown = ref false in
  print_endline "std/ modules:";
  print_newline ();
  List.iter
    (fun cat ->
      if should_show cat then begin
        shown := true;
        let names = try Hashtbl.find categories cat with Not_found -> [] in
        let sorted = List.sort_uniq String.compare names in
        Printf.printf "  %-10s%s\n" cat (String.concat ", " sorted)
      end)
    sorted_cats;
  if not !shown then
    Printf.printf "  No modules found for category '%s'.\n"
      (match filter with Some f -> f | None -> "");
  print_newline ();
  print_endline "Use /import <name> to import a module."

let handle_import state name =
  let idx = build_module_index () in
  (* Accept both "option" and "types/option" *)
  let matches =
    if String.contains name '/' then
      (* Full path like "types/option" — find the short name and filter *)
      let short = Filename.basename name in
      let entries = try Hashtbl.find idx short with Not_found -> [] in
      List.filter (fun (rel, _) -> rel = name) entries
    else try Hashtbl.find idx name with Not_found -> []
  in
  match matches with
  | [] ->
      Printf.printf
        "Module '%s' not found. Use /modules to list available modules.\n" name;
      state
  | [ (rel, _cat) ] -> (
      let module_path = "std/" ^ rel in
      (* Load the module to get exports *)
      Modules.full_reset ();
      Modules.init_module_paths (Sys.getcwd ());
      match Modules.load_module module_path (Sys.getcwd ()) with
      | None ->
          Printf.printf "Failed to load module '%s'.\n" module_path;
          state
      | Some m ->
          let export_names = get_export_names m.exports in
          let import_text =
            if export_names = [] then
              (* No exports — use qualified import *)
              let alias = String.capitalize_ascii (Filename.basename rel) in
              Printf.sprintf "import:\n    %s as %s" module_path alias
            else
              Printf.sprintf "import:\n    %s { %s }" module_path
                (String.concat ", " export_names)
          in
          Printf.printf "Imported %s { %s }\n" module_path
            (String.concat ", " export_names);
          { state with imports = import_text :: state.imports })
  | ambiguous ->
      Printf.printf "'%s' matches multiple modules:\n" name;
      List.iter (fun (rel, _) -> Printf.printf "  std/%s\n" rel) ambiguous;
      Printf.printf "Use the full path: /import %s\n"
        (let first_rel, _ = List.hd ambiguous in
         first_rel);
      state

let handle_func () =
  print_endline "Function syntax:";
  print_endline "  func name(x: Int, y: Int) -> Int:";
  print_endline "      x + y";
  print_endline "";
  print_endline "  pure func name(x: Int) -> Int:";
  print_endline "      x * 2";
  print_endline "";
  print_endline "  -- Lambda";
  print_endline "  func(x: Int): x + 1";
  print_endline "";
  print_endline "  -- Generic";
  print_endline "  func identity(x: T) -> T:";
  print_endline "      x"

let handle_match () =
  print_endline "Match syntax:";
  print_endline "  match value:";
  print_endline "      Some(x): x";
  print_endline "      None: default";
  print_endline "";
  print_endline "  -- Or-patterns";
  print_endline "  match color:";
  print_endline "      Red | Blue: \"cool\"";
  print_endline "      Green: \"warm\"";
  print_endline "";
  print_endline "  -- List patterns";
  print_endline "  match items:";
  print_endline "      []: \"empty\"";
  print_endline "      [x, ...rest]: \"has items\""

let handle_record () =
  print_endline "Record (heap, ARC-managed):";
  print_endline "  record Point {x: Int, y: Int}";
  print_endline "  p: Point = {x = 1, y = 2}";
  print_endline "  q: Point = { p | x = 10 }";
  print_endline "";
  print_endline "Struct (stack, value type):";
  print_endline "  struct Vec2 {x: Float, y: Float}";
  print_endline "";
  print_endline "Union (algebraic data type):";
  print_endline "  union Shape:";
  print_endline "      Circle(Float)";
  print_endline "      Rect(Float, Float)"

let handle_slash_command state cmd =
  let parts = String.split_on_char ' ' (String.trim cmd) in
  match parts with
  | [ "/help" ] ->
      handle_help ();
      Some state
  | "/modules" :: rest ->
      let filter =
        match rest with [] -> None | [ cat ] -> Some cat | _ -> None
      in
      handle_modules filter;
      Some state
  | "/import" :: rest when rest <> [] ->
      let name = String.concat " " rest in
      Some (handle_import state name)
  | [ "/import" ] ->
      print_endline "Usage: /import <module_name>";
      print_endline
        "Examples: /import option, /import types/option, /import list";
      Some state
  | [ "/func" ] ->
      handle_func ();
      Some state
  | [ "/match" ] ->
      handle_match ();
      Some state
  | [ "/record" ] ->
      handle_record ();
      Some state
  | _ ->
      Printf.printf "Unknown command: %s\n" cmd;
      print_endline "Type /help for available commands.";
      Some state

(* ── Type inference for expressions ───────────────────────────────── *)

(** Infer the type of an expression in the current REPL state.
    Returns Some type_string or None if typechecking fails. *)
let infer_expr_type state expr_text =
  let source =
    let buf = Buffer.create 512 in
    List.iter
      (fun imp ->
        Buffer.add_string buf imp;
        Buffer.add_char buf '\n')
      (List.rev state.imports);
    List.iter
      (fun decl ->
        Buffer.add_string buf decl;
        Buffer.add_char buf '\n')
      (List.rev state.decls);
    Buffer.add_string buf ("__repl_ty__ = " ^ expr_text ^ "\n");
    Buffer.add_string buf "func main(args: List[String]) -> Int:\n    0\n";
    Buffer.contents buf
  in
  Modules.full_reset ();
  Modules.init_module_paths (Sys.getcwd ());
  match Pipeline.typecheck_module_only ~filename:"<repl>" ~source with
  | Ok (state_result, _) -> (
      let env = Typecheck.get_state_env state_result in
      match Env.lookup env "__repl_ty__" with
      | Some { kind = VarSymbol { var_type; _ }; _ } ->
          Some (Types.type_to_string var_type)
      | Some { kind = FuncSymbol { func_type; _ }; _ } ->
          Some (Types.type_to_string func_type)
      | _ -> Some "?")
  | Error _ -> None

(* ── Special commands ─────────────────────────────────────────────── *)

let handle_command state cmd =
  let parts = String.split_on_char ' ' (String.trim cmd) in
  match parts with
  | [ ":quit" ] | [ ":q" ] -> None
  | [ ":reset" ] ->
      print_endline "State cleared.";
      Some empty_state
  | [ ":state" ] ->
      Printf.printf "Imports: %d, Declarations: %d, Iteration: %d\n"
        (List.length state.imports)
        (List.length state.decls) state.iteration;
      if state.imports <> [] then begin
        print_endline "--- Imports ---";
        List.iter print_endline (List.rev state.imports)
      end;
      if state.decls <> [] then begin
        print_endline "--- Declarations ---";
        List.iter print_endline (List.rev state.decls)
      end;
      Some state
  | ":type" :: rest when rest <> [] ->
      let expr_text = String.concat " " rest in
      (match infer_expr_type state expr_text with
      | Some ty_str -> Printf.printf "%s\n" ty_str
      | None -> prerr_endline "Could not determine type");
      Some state
  | _ when String.length cmd > 0 && cmd.[0] = '/' ->
      handle_slash_command state cmd
  | _ ->
      Printf.printf "Unknown command: %s\n" cmd;
      print_endline "Type /help for available commands.";
      Some state

(* ── Expression evaluation ────────────────────────────────────────── *)

(** Try to evaluate an expression with output.
    Typechecks first to determine the expression type, then wraps appropriately.
    Single compile cycle instead of trial-and-error cascade. *)
let eval_expression ~debug state expr_text =
  let ty = infer_expr_type state expr_text in
  let wrap =
    match ty with
    | Some "String" -> Printf.sprintf "print(%s)" expr_text
    | Some "Void" -> expr_text
    | Some _ -> Printf.sprintf "print(to_string(%s))" expr_text
    | None -> expr_text
  in
  let source = build_source state ~expr_wrap:(Some wrap) in
  match try_compile_and_run ~debug source with
  | Ok () -> true
  | Error _ when ty <> None && ty <> Some "String" && ty <> Some "Void" -> (
      (* to_string wrapper failed — fall back to bare expression *)
      let source2 = build_source state ~expr_wrap:(Some expr_text) in
      match try_compile_and_run ~debug source2 with
      | Ok () -> true
      | Error msg ->
          prerr_endline msg;
          false)
  | Error msg ->
      prerr_endline msg;
      false

(* ── Command hint registry ────────────────────────────────────────── *)

let repl_commands =
  [
    ("/help", "Show available commands");
    ("/modules", "List std library modules");
    ("/import", "Auto-import a module");
    ("/func", "Function definition syntax");
    ("/match", "Match expression syntax");
    ("/record", "Record/struct/union syntax");
    (":quit", "Exit the REPL");
    (":q", "Exit the REPL");
    (":reset", "Clear accumulated state");
    (":state", "Show current imports/declarations");
    (":type", "Type-check an expression");
  ]

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let hint_for_text text =
  let trimmed = String.trim text in
  if trimmed = "" || (trimmed.[0] <> '/' && trimmed.[0] <> ':') then None
  else
    let matches =
      List.filter
        (fun (cmd, _) ->
          String.length cmd > String.length trimmed
          && starts_with ~prefix:trimmed cmd)
        repl_commands
    in
    match matches with
    | [ (cmd, _) ] ->
        Some
          (String.sub cmd (String.length trimmed)
             (String.length cmd - String.length trimmed))
    | _ -> None

let completions_for_text text =
  let trimmed = String.trim text in
  if trimmed = "" then
    (* Show all slash commands when just "/" hasn't been typed yet *)
    []
  else if trimmed.[0] = '/' || trimmed.[0] = ':' then
    List.filter (fun (cmd, _) -> starts_with ~prefix:trimmed cmd) repl_commands
  else []

(* ── Main REPL loop ───────────────────────────────────────────────── *)

let run ~debug =
  let editor = Line_editor.create () in
  Line_editor.set_hint_fn editor hint_for_text;
  Line_editor.set_completions_fn editor completions_for_text;
  Line_editor.enter_raw_mode editor;
  Line_editor.install_cleanup_handlers editor;
  Printf.printf "blorp REPL (type :quit to exit, Tab for hints)\n%!";
  let state = ref empty_state in
  let running = ref true in
  while !running do
    (* Temporarily restore terminal for program output *)
    Line_editor.restore_mode editor;
    flush stdout;
    flush stderr;
    Line_editor.enter_raw_mode editor;
    match Line_editor.read_input editor with
    | Line_editor.Eof -> running := false
    | Line_editor.Interrupted -> () (* Ctrl-C: just re-prompt *)
    | Line_editor.Input text ->
        if String.trim text = "" then ()
        else begin
          Line_editor.add_history editor text;
          (* Restore terminal for compilation/execution output *)
          Line_editor.restore_mode editor;
          (match classify_input text with
          | Empty -> ()
          | Command cmd -> (
              match handle_command !state cmd with
              | None -> running := false
              | Some s -> state := s)
          | ParseError msg -> prerr_endline msg
          | Declarations (program, raw_text) -> (
              let candidate =
                if is_all_imports program then
                  { !state with imports = raw_text :: !state.imports }
                else { !state with decls = raw_text :: !state.decls }
              in
              let source = build_source candidate ~expr_wrap:None in
              match try_compile_and_run ~debug source with
              | Ok () ->
                  state :=
                    { candidate with iteration = candidate.iteration + 1 };
                  List.iter
                    (fun d -> Printf.printf "%s\n" (describe_decl d))
                    program
              | Error msg -> prerr_endline msg)
          | Expression expr_text ->
              if eval_expression ~debug !state expr_text then
                state := { !state with iteration = !state.iteration + 1 });
          (* Re-enter raw mode for next input *)
          Line_editor.enter_raw_mode editor
        end
  done;
  Line_editor.restore_mode editor
