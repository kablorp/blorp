(** Blorp code formatter — orchestrates the formatting pipeline.

    Pipeline: source -> lex (collect comments) -> parse -> AST-to-doc -> layout -> post-process *)

(* ===== Format cache ===== *)

let fmt_cache_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let dir = Filename.concat home ".cache/blorp/format" in
  (* mkdir -p the cache directory chain *)
  let cache = Filename.concat home ".cache" in
  let blorp_cache = Filename.concat cache "blorp" in
  (try Unix.mkdir cache 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir blorp_cache 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir

(* Cache key includes the blorp binary's mtime so any rebuild invalidates all entries. *)
let binary_mtime =
  try (Unix.stat Sys.executable_name).Unix.st_mtime with _ -> 0.0

let fmt_cache_key source =
  Hashtbl.hash (Hashtbl.hash source, Hashtbl.hash binary_mtime)

let is_cached_formatted source =
  try
    let path =
      Filename.concat (fmt_cache_dir ())
        (Printf.sprintf "%d.fmt" (fmt_cache_key source))
    in
    Sys.file_exists path
  with _ -> false

let mark_cached_formatted source =
  try
    let path =
      Filename.concat (fmt_cache_dir ())
        (Printf.sprintf "%d.fmt" (fmt_cache_key source))
    in
    let oc = open_out path in
    close_out oc
  with _ -> ()

(* ===== Formatter ===== *)

let doc_for_source source =
  match Modules.parse_source ~hoist_nested:false source with
  | Error { message; loc; _ } ->
      Error
        (Printf.sprintf "%s at line %d, column %d" message loc.Ast.line
           loc.Ast.column)
  | Ok program -> (
      try
        let collected_comments = Lexer.get_comments () in
        (* Set up comment store for the printer *)
        Fmt_printer.comments := Fmt_comment.create collected_comments;
        (* Convert AST to document IR *)
        let doc = Fmt_printer.print_program program in
        Ok doc
      with
      | Failure msg -> Error (Printf.sprintf "Formatter error: %s" msg)
      | Invalid_argument msg -> Error (Printf.sprintf "Formatter error: %s" msg)
      | Not_found -> Error "Formatter error: internal lookup failed")

(** Format a source string. Returns the formatted source or an error. *)
let format_string source =
  match doc_for_source source with
  | Error msg -> Error msg
  | Ok doc ->
      (* Layout and post-process *)
      Ok (Fmt_layout.layout doc)

let format_doc_json_string source =
  match doc_for_source source with
  | Error msg -> Error msg
  | Ok doc -> Ok (Fmt_doc_json.to_json doc)

let format_doc_json_file filename =
  try
    let source = Modules.read_file filename in
    format_doc_json_string source
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)

let format_expr_cases_json_lines_string source =
  match Modules.parse_source ~hoist_nested:false source with
  | Error { message; loc; _ } ->
      Error
        (Printf.sprintf "%s at line %d, column %d" message loc.Ast.line
           loc.Ast.column)
  | Ok program -> (
      try Ok (Fmt_expr_json.cases_json_lines program) with
      | Failure msg -> Error (Printf.sprintf "Formatter error: %s" msg)
      | Invalid_argument msg -> Error (Printf.sprintf "Formatter error: %s" msg)
      | Not_found -> Error "Formatter error: internal lookup failed")

let format_expr_cases_json_lines_file filename =
  try
    let source = Modules.read_file filename in
    format_expr_cases_json_lines_string source
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)

let format_decl_cases_json_lines_string source =
  match Modules.parse_source ~hoist_nested:false source with
  | Error { message; loc; _ } ->
      Error
        (Printf.sprintf "%s at line %d, column %d" message loc.Ast.line
           loc.Ast.column)
  | Ok program -> (
      try Ok (Fmt_decl_json.cases_json_lines program) with
      | Failure msg -> Error (Printf.sprintf "Formatter error: %s" msg)
      | Invalid_argument msg -> Error (Printf.sprintf "Formatter error: %s" msg)
      | Not_found -> Error "Formatter error: internal lookup failed")

let format_decl_cases_json_lines_file filename =
  try
    let source = Modules.read_file filename in
    format_decl_cases_json_lines_string source
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)

(** Compute a simple line-level diff between two strings.
    Shows the first few changed lines. Since the formatter only rearranges/restylings
    lines (not arbitrary insertions), a simple parallel walk suffices. *)
let compute_diff source formatted =
  let src_lines = Array.of_list (String.split_on_char '\n' source) in
  let fmt_lines = Array.of_list (String.split_on_char '\n' formatted) in
  let buf = Buffer.create 256 in
  let max_diffs = 5 in
  let diffs_shown = ref 0 in
  let last_shown = ref (-10) in
  (* Track last shown line for context grouping *)
  let src_len = Array.length src_lines in
  let fmt_len = Array.length fmt_lines in
  let min_len = min src_len fmt_len in
  for i = 0 to min_len - 1 do
    if !diffs_shown < max_diffs && src_lines.(i) <> fmt_lines.(i) then begin
      (* Show one context line before if not contiguous with previous diff *)
      if i > 0 && i - 1 > !last_shown then
        Buffer.add_string buf
          (Printf.sprintf "  %4d |  %s\n" i src_lines.(i - 1));
      Buffer.add_string buf
        (Printf.sprintf "  %4d | -%s\n" (i + 1) src_lines.(i));
      Buffer.add_string buf
        (Printf.sprintf "  %4d | +%s\n" (i + 1) fmt_lines.(i));
      last_shown := i;
      incr diffs_shown
    end
  done;
  (* Show lines added/removed at end *)
  if !diffs_shown < max_diffs then begin
    for i = min_len to src_len - 1 do
      if !diffs_shown < max_diffs then begin
        Buffer.add_string buf
          (Printf.sprintf "  %4d | -%s\n" (i + 1) src_lines.(i));
        incr diffs_shown
      end
    done;
    for i = min_len to fmt_len - 1 do
      if !diffs_shown < max_diffs then begin
        Buffer.add_string buf
          (Printf.sprintf "  %4d | +%s\n" (i + 1) fmt_lines.(i));
        incr diffs_shown
      end
    done
  end;
  if !diffs_shown >= max_diffs then
    Buffer.add_string buf "  ... (more differences)\n";
  Buffer.contents buf

(** Format a file. *)
let format_file ?(use_cache = false) ~check filename =
  try
    let source = Modules.read_file filename in
    (* Check cache first — skip formatting if source is known-formatted *)
    if use_cache && is_cached_formatted source then Ok true
    else
      match format_string source with
      | Error msg -> Error msg
      | Ok formatted ->
          if source = formatted then begin
            (* Already formatted — cache it *)
            mark_cached_formatted source;
            Ok true
          end
          else if check then Ok false
          else begin
            let oc = open_out filename in
            Fun.protect
              ~finally:(fun () -> close_out oc)
              (fun () -> output_string oc formatted);
            (* Cache the formatted output *)
            mark_cached_formatted formatted;
            Ok true
          end
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)

(** Auto-format a file in place, silently skipping on any error.
    Uses the format cache to avoid re-formatting unchanged files.
    Intended for automatic formatting before compile/run/test. *)
let auto_format filename =
  try ignore (format_file ~use_cache:true ~check:false filename) with _ -> ()

(** Check formatting and optionally return diff. *)
let format_check_diff filename =
  try
    let source = Modules.read_file filename in
    match format_string source with
    | Error msg -> Error msg
    | Ok formatted ->
        if source = formatted then Ok None
        else Ok (Some (compute_diff source formatted))
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)
