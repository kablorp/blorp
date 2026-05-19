(** Blorp code formatter orchestration.

    OCaml owns parsing/comment collection and emits formatter JSON. The Blorp
    formatter tool owns source rendering. *)

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

let parse_error_message { Ast.message; loc; _ } =
  Printf.sprintf "%s at line %d, column %d" message loc.Ast.line loc.Ast.column

let with_formatter_errors f =
  try f () with
  | Failure msg -> Error (Printf.sprintf "Formatter error: %s" msg)
  | Invalid_argument msg -> Error (Printf.sprintf "Formatter error: %s" msg)
  | Not_found -> Error "Formatter error: internal lookup failed"

let with_parsed_source source f =
  match Modules.parse_source ~hoist_nested:false source with
  | Error err -> Error (parse_error_message err)
  | Ok program -> with_formatter_errors (fun () -> f program)

let program_json_for_program ~comments program =
  with_formatter_errors (fun () ->
      match Fmt_decl_json.program_json ~comments program with
      | Some json -> Ok json
      | None -> Error "Formatter error: program contains unsupported syntax")

let format_expr_cases_json_lines_string source =
  with_parsed_source source (fun program ->
      Ok (Fmt_expr_json.cases_json_lines program))

let format_decl_cases_json_lines_string source =
  with_parsed_source source (fun program ->
      let collected_comments = Lexer.get_comments () in
      Ok (Fmt_decl_json.cases_json_lines ~comments:collected_comments program))

let format_program_json_string source =
  with_parsed_source source (fun program ->
      let collected_comments = Lexer.get_comments () in
      program_json_for_program ~comments:collected_comments program)

let format_program_json_file filename =
  try
    let source = Modules.read_file filename in
    format_program_json_string source
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)

type format_result =
  | Unchanged of string
  | WouldChange of { file : string; diff : string option }
  | Written of string

type format_mode = Write | Check of { show_diff : bool }

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

let write_file path content =
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc content)

let remove_file_noerr path = try Sys.remove path with _ -> ()

let cleanup_temp_dir dir =
  (try
     Sys.readdir dir
     |> Array.iter (fun name -> remove_file_noerr (Filename.concat dir name))
   with _ -> ());
  try Unix.rmdir dir with _ -> ()

let with_temp_dir prefix f =
  let marker = Filename.temp_file prefix ".tmp" in
  remove_file_noerr marker;
  Unix.mkdir marker 0o700;
  Fun.protect ~finally:(fun () -> cleanup_temp_dir marker) (fun () -> f marker)

let sleep_seconds seconds = ignore (Unix.select [] [] [] seconds)
let formatter_tool_name = "tools/formatter/formatter.brp"

let absolute_dir dir =
  if Filename.is_relative dir then Filename.concat (Sys.getcwd ()) dir else dir

let rec find_formatter_tool_from dir =
  let candidate = Filename.concat dir formatter_tool_name in
  if Sys.file_exists candidate then Some candidate
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else find_formatter_tool_from parent

let formatter_tool_path () =
  let search_roots =
    [ Sys.getcwd (); Filename.dirname Sys.executable_name ]
    |> List.map absolute_dir
  in
  match List.find_map find_formatter_tool_from search_roots with
  | Some path -> Ok path
  | None ->
      Error
        (Printf.sprintf "Formatter error: Blorp formatter tool not found at %s"
           (Filename.concat (Sys.getcwd ()) formatter_tool_name))

let formatter_source_files formatter_tool =
  let dir = Filename.dirname formatter_tool in
  Sys.readdir dir |> Array.to_list |> List.sort String.compare
  |> List.filter (fun name -> Filename.check_suffix name ".brp")
  |> List.map (Filename.concat dir)

let formatter_binary_cache_key formatter_tool =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf (Printf.sprintf "compiler-mtime:%f\n" binary_mtime);
  formatter_source_files formatter_tool
  |> List.iter (fun path ->
      Buffer.add_string buf (Filename.basename path);
      Buffer.add_char buf '\000';
      Buffer.add_string buf (Modules.read_file path);
      Buffer.add_char buf '\000');
  Digest.to_hex (Digest.string (Buffer.contents buf))

let status_message = function
  | Unix.WEXITED code -> Printf.sprintf "exited with status %d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "was killed by signal %d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "was stopped by signal %d" signal

let rec waitpid_retry pid =
  try snd (Unix.waitpid [] pid)
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retry pid

let run_process_capture_files prog args stdout_path stderr_path =
  let stdout_fd =
    Unix.openfile stdout_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ]
      0o600
  in
  let stderr_fd =
    Unix.openfile stderr_path
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC; Unix.O_CLOEXEC ]
      0o600
  in
  let argv = Array.of_list (prog :: args) in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Unix.close stdout_fd;
        Unix.close stderr_fd)
      (fun () -> Unix.create_process prog argv Unix.stdin stdout_fd stderr_fd)
  in
  let status = waitpid_retry pid in
  let stdout = Modules.read_file stdout_path in
  let stderr = Modules.read_file stderr_path in
  match status with
  | Unix.WEXITED 0 -> Ok stdout
  | _ ->
      let detail =
        String.concat ""
          [
            "Formatter renderer ";
            status_message status;
            (if stderr = "" then "" else "\n" ^ stderr);
            (if stdout = "" then "" else "\n" ^ stdout);
          ]
      in
      Error detail

let formatter_cc_args include_dirs precompiled link_flags =
  let pch_file = Option.bind precompiled (fun p -> p.Test_runner.pch_file) in
  let header_file =
    Option.map (fun p -> p.Test_runner.header_file) precompiled
  in
  let stack_args =
    if Lazy.force Test_runner.cc_is_clang && Sys.os_type = "Unix" then
      [ "-Wl,-stack_size,0x1000000" ]
    else []
  in
  let header_args =
    match pch_file with
    | Some pch ->
        if Lazy.force Test_runner.cc_is_clang then [ "-include-pch"; pch ]
        else [ "-include"; pch ]
    | None -> (
        match header_file with Some h -> [ "-include"; h ] | None -> [])
  in
  let runtime_obj_args =
    match precompiled with
    | Some p -> [ p.Test_runner.runtime_obj ]
    | None -> []
  in
  [ "-O2"; "-fwrapv"; "-pipe" ]
  @ stack_args @ [ "-w" ]
  @ List.concat_map (fun dir -> [ "-I"; dir ]) include_dirs
  @ header_args @ runtime_obj_args @ [ "-lm"; "-lpthread" ]
  @ List.concat_map
      (fun s -> String.split_on_char ' ' (String.trim s))
      link_flags

let compile_formatter_binary formatter_tool bin_path =
  Test_runner.with_run_artifacts (fun () ->
      let temp_bin = Printf.sprintf "%s.%d.tmp" bin_path (Unix.getpid ()) in
      remove_file_noerr temp_bin;
      Fun.protect
        ~finally:(fun () -> remove_file_noerr temp_bin)
        (fun () ->
          let source = Modules.read_file formatter_tool in
          let precompiled = Test_runner.precompile_runtime ~opt:"O2" () in
          let embed_runtime = Option.is_none precompiled in
          match
            Pipeline.compile ~embed_runtime ~filename:formatter_tool ~source ()
          with
          | Error errors ->
              Error (Diagnostics.format_errors ~file:formatter_tool errors)
          | Ok (Pipeline.Stopped_at _) ->
              Error
                "Formatter error: formatter compilation stopped unexpectedly"
          | Ok (Pipeline.Compiled { c_code; link_flags; include_dirs; _ }) ->
              let cc_result, cc_output =
                Test_runner.compile_c_from_stdin c_code temp_bin
                  (formatter_cc_args include_dirs precompiled link_flags)
              in
              if cc_result <> 0 then
                Error
                  ("Formatter error: failed to compile Blorp formatter\n"
                 ^ String.trim cc_output)
              else begin
                Sys.rename temp_bin bin_path;
                Ok bin_path
              end))

let wait_for_formatter_binary bin_path =
  let rec loop attempts =
    if Sys.file_exists bin_path then Ok bin_path
    else if attempts <= 0 then
      Error
        (Printf.sprintf
           "Formatter error: timed out waiting for cached formatter binary %s"
           bin_path)
    else begin
      sleep_seconds 0.1;
      loop (attempts - 1)
    end
  in
  loop 600

let formatter_binary_path formatter_tool =
  try
    let key = formatter_binary_cache_key formatter_tool in
    let bin_path =
      Filename.concat (fmt_cache_dir ()) (Printf.sprintf "formatter-%s.bin" key)
    in
    if Sys.file_exists bin_path then Ok bin_path
    else
      let lock_dir = bin_path ^ ".lock" in
      try
        Unix.mkdir lock_dir 0o700;
        Fun.protect
          ~finally:(fun () -> try Unix.rmdir lock_dir with _ -> ())
          (fun () ->
            if Sys.file_exists bin_path then Ok bin_path
            else compile_formatter_binary formatter_tool bin_path)
      with Unix.Unix_error (Unix.EEXIST, _, _) ->
        wait_for_formatter_binary bin_path
  with Sys_error msg -> Error (Printf.sprintf "File error: %s" msg)

type pending_render = {
  source_file : string;
  source : string;
  json_file : string;
  output_file : string;
}

let prepare_render_file temp_dir index filename =
  try
    let source = Modules.read_file filename in
    match format_program_json_string source with
    | Error msg -> Error (Printf.sprintf "%s: %s" filename msg)
    | Ok json ->
        let json_file =
          Filename.concat temp_dir (Printf.sprintf "%04d.json" index)
        in
        let output_file =
          Filename.concat temp_dir (Printf.sprintf "%04d.out" index)
        in
        write_file json_file json;
        Ok { source_file = filename; source; json_file; output_file }
  with Sys_error msg ->
    Error (Printf.sprintf "%s: File error: %s" filename msg)

let rec prepare_render_files temp_dir index files =
  match files with
  | [] -> Ok []
  | filename :: rest -> (
      match prepare_render_file temp_dir index filename with
      | Error msg -> Error msg
      | Ok pending -> (
          match prepare_render_files temp_dir (index + 1) rest with
          | Error msg -> Error msg
          | Ok pending_rest -> Ok (pending :: pending_rest)))

let program_batch_args pending_files =
  "program-batch"
  :: List.concat_map
       (fun pending -> [ pending.json_file; pending.output_file ])
       pending_files

let run_formatter_tool temp_dir formatter_tool args =
  let stdout_path = Filename.concat temp_dir "formatter.stdout" in
  let stderr_path = Filename.concat temp_dir "formatter.stderr" in
  match formatter_binary_path formatter_tool with
  | Error msg -> Error msg
  | Ok formatter_binary ->
      run_process_capture_files formatter_binary args stdout_path stderr_path

let render_pending_files temp_dir formatter_tool pending_files =
  run_formatter_tool temp_dir formatter_tool (program_batch_args pending_files)

let render_program_json_with_blorp_renderer json =
  match formatter_tool_path () with
  | Error msg -> Error msg
  | Ok formatter_tool ->
      with_temp_dir "blorp-format-source-" (fun temp_dir ->
          let json_file = Filename.concat temp_dir "program.json" in
          write_file json_file json;
          run_formatter_tool temp_dir formatter_tool [ "program"; json_file ])

(** Format a source string. Returns the formatted source or an error. *)
let format_string source =
  match format_program_json_string source with
  | Error msg -> Error msg
  | Ok json -> render_program_json_with_blorp_renderer json

let format_program_with_comments ~comments program =
  match program_json_for_program ~comments program with
  | Error msg -> Error msg
  | Ok json -> render_program_json_with_blorp_renderer json

let finish_render_file ~mode pending =
  try
    let rendered = Modules.read_file pending.output_file in
    if pending.source = rendered then Ok (Unchanged pending.source_file)
    else
      match mode with
      | Check { show_diff } ->
          Ok
            (WouldChange
               {
                 file = pending.source_file;
                 diff =
                   (if show_diff then
                      Some (compute_diff pending.source rendered)
                    else None);
               })
      | Write ->
          write_file pending.source_file rendered;
          Ok (Written pending.source_file)
  with Sys_error msg ->
    Error (Printf.sprintf "%s: File error: %s" pending.source_file msg)

let rec finish_render_files ~mode pending_files =
  match pending_files with
  | [] -> Ok []
  | pending :: rest -> (
      match finish_render_file ~mode pending with
      | Error msg -> Error msg
      | Ok result -> (
          match finish_render_files ~mode rest with
          | Error msg -> Error msg
          | Ok results -> Ok (result :: results)))

let format_files_with_blorp_renderer ~mode files =
  match formatter_tool_path () with
  | Error msg -> Error msg
  | Ok formatter_tool ->
      with_temp_dir "blorp-format-" (fun temp_dir ->
          match prepare_render_files temp_dir 0 files with
          | Error msg -> Error msg
          | Ok pending_files -> (
              match
                render_pending_files temp_dir formatter_tool pending_files
              with
              | Error msg -> Error msg
              | Ok _ -> finish_render_files ~mode pending_files))

(** Auto-format a file in place, silently skipping on any error.
    Uses the format cache to avoid re-formatting unchanged files.
    Intended for automatic formatting before compile/run/test. *)
let auto_format filename =
  try
    let source = Modules.read_file filename in
    if not (is_cached_formatted source) then
      match format_files_with_blorp_renderer ~mode:Write [ filename ] with
      | Error _ -> ()
      | Ok _ -> (
          try mark_cached_formatted (Modules.read_file filename) with _ -> ())
  with _ -> ()
