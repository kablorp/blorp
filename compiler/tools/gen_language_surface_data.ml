(* Build-time script that emits static OCaml data from the Blorp-owned
   language surface manifest.

   The parser is intentionally narrow: it reads the two manifest lists that are
   authoritative for the temporary OCaml facade while typecheck/LSP are still
   OCaml-owned. If the manifest shape changes, this script fails instead of
   silently drifting. *)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

let find_from source start pattern =
  let source_len = String.length source in
  let pattern_len = String.length pattern in
  let rec loop i =
    if i + pattern_len > source_len then None
    else if String.sub source i pattern_len = pattern then Some i
    else loop (i + 1)
  in
  loop start

let require msg = function Some value -> value | None -> failwith msg

let find_char_from source start wanted =
  let rec loop i =
    if i >= String.length source then None
    else if source.[i] = wanted then Some i
    else loop (i + 1)
  in
  loop start

let extract_bracket_list source name =
  let marker = name ^ ":" in
  let marker_index =
    require ("missing language surface manifest binding: " ^ name)
      (find_from source 0 marker)
  in
  let value_index =
    require ("missing value assignment for language surface binding: " ^ name)
      (find_char_from source marker_index '=')
  in
  let open_index =
    require ("missing list opener for language surface binding: " ^ name)
      (find_char_from source value_index '[')
  in
  let rec loop i depth in_string escaped =
    if i >= String.length source then
      failwith ("unterminated language surface list: " ^ name)
    else
      let ch = source.[i] in
      if in_string then
        let escaped = (not escaped) && ch = '\\' in
        let in_string = if escaped then true else ch <> '"' in
        loop (i + 1) depth in_string escaped
      else
        match ch with
        | '"' -> loop (i + 1) depth true false
        | '[' -> loop (i + 1) (depth + 1) false false
        | ']' ->
            if depth = 1 then
              String.sub source open_index (i - open_index + 1)
            else loop (i + 1) (depth - 1) false false
        | _ -> loop (i + 1) depth false false
  in
  loop open_index 0 false false

let strip_line_comments text =
  let len = String.length text in
  let out = Buffer.create len in
  let rec loop i in_string escaped =
    if i >= len then ()
    else
      let ch = text.[i] in
      if in_string then begin
        Buffer.add_char out ch;
        let escaped = (not escaped) && ch = '\\' in
        let in_string = if escaped then true else ch <> '"' in
        loop (i + 1) in_string escaped
      end
      else if ch = '"' then begin
        Buffer.add_char out ch;
        loop (i + 1) true false
      end
      else if ch = '-' && i + 1 < len && text.[i + 1] = '-' then
        let rec skip j =
          if j >= len then j
          else if text.[j] = '\n' then j
          else skip (j + 1)
        in
        loop (skip (i + 2)) false false
      else begin
        Buffer.add_char out ch;
        loop (i + 1) false false
      end
  in
  loop 0 false false;
  Buffer.contents out

let parse_string_literals text =
  let text = strip_line_comments text in
  let len = String.length text in
  let rec scan i acc =
    if i >= len then List.rev acc
    else if text.[i] <> '"' then scan (i + 1) acc
    else
      let buf = Buffer.create 16 in
      let rec string_loop j escaped =
        if j >= len then failwith "unterminated string in language surface list"
        else
          let ch = text.[j] in
          if escaped then begin
            let decoded =
              match ch with
              | 'n' -> '\n'
              | 'r' -> '\r'
              | 't' -> '\t'
              | '\\' -> '\\'
              | '"' -> '"'
              | other -> other
            in
            Buffer.add_char buf decoded;
            string_loop (j + 1) false
          end
          else if ch = '\\' then string_loop (j + 1) true
          else if ch = '"' then (j + 1, Buffer.contents buf)
          else begin
            Buffer.add_char buf ch;
            string_loop (j + 1) false
          end
      in
      let next, value = string_loop (i + 1) false in
      scan next (value :: acc)
  in
  scan 0 []

let rec pair_strings = function
  | [] -> []
  | a :: b :: rest -> (a, b) :: pair_strings rest
  | [ _ ] -> failwith "expected even number of strings for prelude import pairs"

let unique_preserving_order values =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | value :: rest ->
        if List.mem value seen then loop seen acc rest
        else loop (value :: seen) (value :: acc) rest
  in
  loop [] [] values

let emit_string_list_binding name values =
  Printf.printf "let %s : string list = [\n" name;
  List.iter (fun value -> Printf.printf "  %S;\n" value) values;
  Printf.printf "]\n\n"

let emit_string_pair_list_binding name values =
  Printf.printf "let %s : (string * string) list = [\n" name;
  List.iter
    (fun (left, right) -> Printf.printf "  (%S, %S);\n" left right)
    values;
  Printf.printf "]\n\n"

let emit_rows completion_keywords prelude_imports prelude_ufcs_modules =
  let completion_text = String.concat ";" completion_keywords in
  let import_rows =
    List.map (fun (module_name, type_name) -> module_name ^ ":" ^ type_name)
      prelude_imports
  in
  let imports_text = String.concat ";" import_rows in
  let ufcs_text = String.concat ";" prelude_ufcs_modules in
  Printf.printf "let rows : (string * string) list = [\n";
  Printf.printf "  (%S, %S);\n" "language_lsp_completion_keywords"
    completion_text;
  Printf.printf "  (%S, %S);\n" "language_prelude_method_type_imports"
    imports_text;
  Printf.printf "  (%S, %S);\n" "language_prelude_ufcs_modules" ufcs_text;
  Printf.printf "]\n\n";
  Printf.printf "let find name = List.assoc_opt name rows\n"

let () =
  let manifest_path =
    match Array.to_list Sys.argv with
    | _ :: path :: _ -> path
    | _ ->
        Printf.eprintf
          "Usage: gen_language_surface_data.ml <language_surface_manifest.brp>\n";
        exit 1
  in
  let source = read_file manifest_path in
  let completion_keywords =
    extract_bracket_list source "COMPLETION_KEYWORDS" |> parse_string_literals
  in
  let prelude_imports =
    extract_bracket_list source "PRELUDE_METHOD_TYPE_IMPORTS"
    |> parse_string_literals |> pair_strings
  in
  let prelude_ufcs_modules =
    prelude_imports |> List.map fst |> unique_preserving_order
  in
  Printf.printf "(* Generated by gen_language_surface_data.ml - do not edit *)\n\n";
  emit_string_list_binding "lsp_completion_keywords" completion_keywords;
  emit_string_pair_list_binding "prelude_method_type_imports" prelude_imports;
  emit_string_list_binding "prelude_ufcs_modules" prelude_ufcs_modules;
  emit_rows completion_keywords prelude_imports prelude_ufcs_modules
