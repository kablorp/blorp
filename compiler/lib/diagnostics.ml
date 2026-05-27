(** Diagnostics — centralized error formatting for blorp.

    All error messages should flow through this module to produce
    consistent, Rust-inspired diagnostic output.

    Output format (with color when stderr is a terminal):
      error: Expected ':' after if condition
       --> file.brp:5:12
        |
      5 |     if x > 0
        |              ^
*)

open Ast

type severity = Error | Warning | Note

(** Label style for source annotations *)
type label_style = Primary | Secondary

type label = {
  label_loc : loc;
  label_file : string;
  label_message : string;
  label_style : label_style;
}
(** A labeled source span *)

type diagnostic = {
  diag_severity : severity;
  diag_message : string;
  diag_labels : label list;
  diag_notes : string list;
  diag_help : string option;
}
(** Structured diagnostic *)

(* --- ANSI color helpers --- *)

let use_color = try Unix.isatty Unix.stderr with _ -> false
let red s = if use_color then "\027[1;31m" ^ s ^ "\027[0m" else s
let yellow s = if use_color then "\027[1;33m" ^ s ^ "\027[0m" else s
let cyan s = if use_color then "\027[36m" ^ s ^ "\027[0m" else s
let cyan_bold s = if use_color then "\027[1;36m" ^ s ^ "\027[0m" else s

let severity_text = function
  | Error -> red "error"
  | Warning -> yellow "warning"
  | Note -> cyan_bold "note"

let label_file ~default_file loc =
  match loc.loc_file with Some file -> file | None -> default_file

let primary_label labels =
  List.find_opt (fun label -> label.label_style = Primary) labels

let max_label_line labels =
  List.fold_left
    (fun acc label ->
      max acc (max label.label_loc.line label.label_loc.end_line))
    0 labels

let group_labels_by_line labels =
  let groups =
    List.fold_left
      (fun acc label ->
        if label.label_loc.line <= 0 then acc
        else
          let line = label.label_loc.line in
          let existing = Option.value (List.assoc_opt line acc) ~default:[] in
          (line, label :: existing) :: List.remove_assoc line acc)
      [] labels
  in
  groups
  |> List.map (fun (line, line_labels) -> (line, List.rev line_labels))
  |> List.sort (fun (a, _) (b, _) -> compare a b)

let underline_width loc =
  if loc.end_line = loc.line && loc.end_column > loc.column then
    loc.end_column - loc.column
  else 1

let underline_padding ~column source_line =
  let col = max 1 column in
  let buf = Buffer.create col in
  for j = 0 to min (col - 2) (String.length source_line - 1) do
    Buffer.add_char buf (if source_line.[j] = '\t' then '\t' else ' ')
  done;
  let remaining = col - 1 - Buffer.length buf in
  if remaining > 0 then Buffer.add_string buf (String.make remaining ' ');
  Buffer.contents buf

let underline_for_label label =
  let underline_char, color =
    match label.label_style with
    | Primary -> ('^', red)
    | Secondary -> ('-', cyan)
  in
  color (String.make (underline_width label.label_loc) underline_char)

(** Read a specific line from a file (1-based). Returns None on failure. *)
let read_source_line ~file ~line =
  if line <= 0 then None
  else
    try
      let ic = open_in file in
      Fun.protect
        ~finally:(fun () -> close_in ic)
        (fun () ->
          let rec skip n =
            if n <= 1 then Some (input_line ic)
            else begin
              ignore (input_line ic);
              skip (n - 1)
            end
          in
          skip line)
    with _ -> None

(** Create a diagnostic from a compiler_error. The label's file comes from
    [err.loc.loc_file] when present (so cross-file references cite the
    right source), falling back to the [~file] parameter (the current
    compilation unit) when the loc is synthetic / dummy. *)
let diagnostic_of_error ~file (err : compiler_error) : diagnostic =
  let message =
    match err.phase with
    | Codegen -> "(codegen) " ^ err.message
    | _ -> err.message
  in
  let label_file = label_file ~default_file:file err.loc in
  {
    diag_severity = Error;
    diag_message = message;
    diag_labels =
      [
        {
          label_loc = err.loc;
          label_file;
          label_message = "";
          label_style = Primary;
        };
      ];
    diag_notes = err.notes;
    diag_help = err.help;
  }

(** Render a structured diagnostic in Rust-style format.

    Example output:
      error: Type mismatch in variable 'x'
       --> file.brp:2:14
        |
      2 |     x: Int = "hello"
        |              ^^^^^^^ expected Int, found String
        |
        = help: Remove the quotes to use an integer literal
*)
let render_diagnostic (diag : diagnostic) : string =
  let buf = Buffer.create 256 in
  let add s = Buffer.add_string buf s in
  let addln s =
    Buffer.add_string buf s;
    Buffer.add_char buf '\n'
  in
  (* Severity header *)
  let sev_str = severity_text diag.diag_severity in
  (* Handle multi-line messages: first line on header, rest indented *)
  let message_lines = String.split_on_char '\n' diag.diag_message in
  (match message_lines with
  | [] -> addln (Printf.sprintf "%s:" sev_str)
  | [ msg ] -> addln (Printf.sprintf "%s: %s" sev_str msg)
  | first :: rest ->
      addln (Printf.sprintf "%s: %s" sev_str first);
      List.iter (fun line -> addln (Printf.sprintf "    %s" line)) rest);
  (* Primary label determines location arrow *)
  let primary = primary_label diag.diag_labels in
  (* Compute gutter width from max line number across all labels *)
  let max_line = max_label_line diag.diag_labels in
  let gutter_width = max 1 (String.length (string_of_int max_line)) in
  let gutter_pad = String.make gutter_width ' ' in
  let gutter_bar = Printf.sprintf " %s %s" gutter_pad (cyan "|") in
  (* Location arrow *)
  (match primary with
  | Some lbl when lbl.label_loc.line > 0 ->
      addln
        (Printf.sprintf " %s %s:%d:%d"
           (cyan (Printf.sprintf "%s-->" gutter_pad))
           lbl.label_file lbl.label_loc.line lbl.label_loc.column)
  | Some lbl ->
      addln
        (Printf.sprintf " %s %s"
           (cyan (Printf.sprintf "%s-->" gutter_pad))
           lbl.label_file)
  | None -> ());
  (* Group labels by line, sort by line number *)
  let labels_by_line = group_labels_by_line diag.diag_labels in
  if labels_by_line <> [] then begin
    addln gutter_bar;
    let prev_line = ref 0 in
    List.iter
      (fun (line_no, labels) ->
        match labels with
        | [] -> ()
        | first_lbl :: _ -> (
            (* Show ellipsis between non-adjacent lines *)
            if !prev_line > 0 && line_no > !prev_line + 1 then
              addln (cyan (Printf.sprintf " %s..." gutter_pad));
            prev_line := line_no;
            (* Source line *)
            let line_num_str = Printf.sprintf "%*d" gutter_width line_no in
            match read_source_line ~file:first_lbl.label_file ~line:line_no with
            | Some src_line ->
                addln
                  (Printf.sprintf " %s %s %s" (cyan line_num_str) (cyan "|")
                     src_line);
                (* Underline each label on this line *)
                List.iter
                  (fun lbl ->
                    (* Preserve tabs from source line so underline aligns at any tab width *)
                    let pad =
                      underline_padding ~column:lbl.label_loc.column src_line
                    in
                    let colored = underline_for_label lbl in
                    let msg =
                      if lbl.label_message <> "" then " " ^ lbl.label_message
                      else ""
                    in
                    addln
                      (Printf.sprintf " %s %s%s%s%s" gutter_pad (cyan "|") pad
                         colored msg))
                  labels
            | None -> ()))
      labels_by_line;
    add gutter_bar
  end;
  (* Notes *)
  List.iter
    (fun note ->
      add
        (Printf.sprintf "\n %s %s %s" gutter_pad (cyan "=")
           (cyan_bold (Printf.sprintf "note: %s" note))))
    diag.diag_notes;
  (* Help *)
  (match diag.diag_help with
  | Some help ->
      add
        (Printf.sprintf "\n %s %s %s" gutter_pad (cyan "=")
           (cyan_bold (Printf.sprintf "help: %s" help)))
  | None -> ());
  Buffer.contents buf

(** Render a compiler_error as a structured diagnostic *)
let format_error ~file (e : compiler_error) =
  render_diagnostic (diagnostic_of_error ~file e)

(** Render a list of compiler_errors *)
let format_errors ~file errors =
  errors |> List.map (format_error ~file) |> String.concat "\n"

(** Legacy format_diagnostic — used by blorp.ml for direct formatting *)
let format_diagnostic ~file ~loc ~severity ~message =
  render_diagnostic
    {
      diag_severity = severity;
      diag_message = message;
      diag_labels =
        [
          {
            label_loc = loc;
            label_file = file;
            label_message = "";
            label_style = Primary;
          };
        ];
      diag_notes = [];
      diag_help = None;
    }
