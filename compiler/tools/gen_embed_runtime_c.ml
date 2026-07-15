let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let emit_escaped_char = function
  | '"' -> print_string "\\\""
  | '\\' -> print_string "\\\\"
  | '\n' -> print_string "\\n\"\n\""
  | '\r' -> print_string "\\r"
  | '\t' -> print_string "\\t"
  | character ->
      let code = Char.code character in
      if code >= 32 && code <= 126 then print_char character
      else Printf.printf "\\x%02x\"\"" code

let emit_string name value =
  Printf.printf "const char %s[] =\n\"" name;
  String.iter emit_escaped_char value;
  Printf.printf "\";\nconst size_t %s_len = sizeof(%s) - 1;\n\n" name name

let () =
  match Array.to_list Sys.argv with
  | [ _; minicoro_path; runtime_path; runtime_decl_path ] ->
      let minicoro = read_file minicoro_path in
      let runtime = read_file runtime_path in
      let runtime_decl = read_file runtime_decl_path in
      print_endline "#include <stddef.h>";
      emit_string "blorp_compiler_runtime_source_data"
        ("#define _GNU_SOURCE\n#define MINICORO_IMPL\n" ^ minicoro ^ "\n"
       ^ runtime);
      emit_string "blorp_compiler_runtime_decl_data"
        ("#define _GNU_SOURCE\n" ^ minicoro ^ "\n" ^ runtime_decl)
  | _ ->
      prerr_endline
        "usage: gen_embed_runtime_c <minicoro.h> <runtime.c> <runtime_decl.c>";
      exit 2
