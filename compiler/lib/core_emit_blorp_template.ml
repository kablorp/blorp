(** Shared bridge for Blorp-authored C emission templates.

    Blorp source owns the template bodies. OCaml uses this module only at the
    compiler boundary: parse the checked-in manifest, render child Core
    expressions, and substitute already-rendered arguments into placeholders. *)

type template = { name : string; arity : int; body : string }

type t = {
  label : string;
  templates : template list Lazy.t;
  table : (string, template) Hashtbl.t Lazy.t;
}

let strip_trailing_cr line =
  let len = String.length line in
  if len > 0 && line.[len - 1] = '\r' then String.sub line 0 (len - 1) else line

let parse_manifest_line ~label line_no line =
  let line = strip_trailing_cr line in
  if String.trim line = "" || line.[0] = '#' then None
  else
    match String.split_on_char '\t' line with
    | [ name; arity_text; body ] -> (
        match int_of_string_opt arity_text with
        | Some arity when arity >= 0 -> Some { name; arity; body }
        | _ ->
            invalid_arg
              (Printf.sprintf "invalid %s template arity on line %d: %S" label
                 line_no arity_text))
    | fields ->
        invalid_arg
          (Printf.sprintf
             "invalid %s template line %d: expected 3 TSV fields, got %d" label
             line_no (List.length fields))

let create ?(initial_size = 8) ~label manifest_tsv =
  let templates =
    lazy
      (manifest_tsv |> String.split_on_char '\n'
      |> List.mapi (fun i line -> parse_manifest_line ~label (i + 1) line)
      |> List.filter_map Fun.id)
  in
  let table =
    lazy
      (let tbl = Hashtbl.create initial_size in
       List.iter
         (fun template ->
           if Hashtbl.mem tbl template.name then
             invalid_arg
               (Printf.sprintf "duplicate %s template for %S" label
                  template.name);
           Hashtbl.add tbl template.name template)
         (Lazy.force templates);
       tbl)
  in
  { label; templates; table }

let names manifest =
  Lazy.force manifest.templates
  |> List.map (fun template -> template.name)
  |> List.sort_uniq String.compare

let find manifest name = Hashtbl.find_opt (Lazy.force manifest.table) name

let render_arg ~emit_expr (ctx : Core_emit_context.t) arg =
  let original_output = ctx.output in
  let arg_output = Buffer.create 128 in
  ctx.output <- arg_output;
  Fun.protect
    ~finally:(fun () -> ctx.output <- original_output)
    (fun () ->
      emit_expr ctx arg;
      Buffer.contents arg_output)

let render_args ~emit_expr ctx args =
  let rec go acc = function
    | [] -> List.rev acc
    | arg :: rest ->
        let rendered = render_arg ~emit_expr ctx arg in
        go (rendered :: acc) rest
  in
  go [] args

let substitute template args =
  if List.length args <> template.arity then
    invalid_arg
      (Printf.sprintf "template %S expected %d args, got %d" template.name
         template.arity (List.length args));
  let rendered_args = Array.of_list args in
  let body = template.body in
  let len = String.length body in
  let buf = Buffer.create (len + 32) in
  let is_digit c = c >= '0' && c <= '9' in
  let parse_placeholder start =
    if body.[start] <> '@' then None
    else
      let rec scan_digits i =
        if i < len && is_digit body.[i] then scan_digits (i + 1) else i
      in
      let digit_start = start + 1 in
      let digit_end = scan_digits digit_start in
      if digit_end = digit_start || digit_end >= len || body.[digit_end] <> '@'
      then None
      else
        let digit_text =
          String.sub body digit_start (digit_end - digit_start)
        in
        match int_of_string_opt digit_text with
        | Some arg_index -> Some (arg_index, digit_end + 1)
        | None ->
            invalid_arg
              (Printf.sprintf "template %S has invalid placeholder @%s@"
                 template.name digit_text)
  in
  let rec go i =
    if i >= len then ()
    else
      match parse_placeholder i with
      | Some (arg_index, next_i) ->
          if arg_index >= Array.length rendered_args then
            invalid_arg
              (Printf.sprintf
                 "template %S references arg %d but only %d args are available"
                 template.name arg_index
                 (Array.length rendered_args));
          Buffer.add_string buf rendered_args.(arg_index);
          go next_i
      | None ->
          Buffer.add_char buf body.[i];
          go (i + 1)
  in
  go 0;
  Buffer.contents buf

let render_exn manifest name args =
  match find manifest name with
  | Some template -> substitute template args
  | None ->
      invalid_arg (Printf.sprintf "missing %s template %S" manifest.label name)
