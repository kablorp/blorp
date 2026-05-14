(** Layout engine for the Blorp formatter.

    Wadler-Lindig algorithm: resolves Group nodes into flat or broken form,
    targeting a configurable line width. Also handles post-processing. *)

open Fmt_doc

(** Layout mode for group resolution *)
type mode = Flat | Break

type cmd = int * mode * doc
(** Layout command — a (indent, mode, doc) triple *)

(** Render a document to a string.
    Uses the Wadler-Lindig algorithm with a work stack. *)
let render ?(width = line_width) doc =
  let buf = Buffer.create 4096 in
  let col = ref 0 in
  (* line_suffix_queue collects trailing comments to emit at next newline *)
  let line_suffix_queue = Queue.create () in
  (* fits: does the flat-mode rendering of the work list fit in the remaining columns? *)
  let rec fits remaining = function
    | _ when remaining < 0 -> false
    | [] -> true
    | (_, _, Nil) :: rest -> fits remaining rest
    | (_, _, Text s) :: rest -> fits (remaining - String.length s) rest
    | (_, _, Hardline) :: _ -> true (* hardline always "fits" — forces break *)
    | (i, _, Softline) :: rest -> fits remaining ((i, Flat, Nil) :: rest)
    | (_, Flat, SoftlineSpace) :: rest -> fits (remaining - 1) rest
    | (_, Break, SoftlineSpace) :: _ -> true
    | (i, m, Indent (j, d)) :: rest -> fits remaining ((i + j, m, d) :: rest)
    | (i, _, Group d) :: rest -> fits remaining ((i, Flat, d) :: rest)
    | (i, m, Concat (a, b)) :: rest ->
        fits remaining ((i, m, a) :: (i, m, b) :: rest)
    | (i, Flat, IfBreak (_, flat_d)) :: rest ->
        fits remaining ((i, Flat, flat_d) :: rest)
    | (i, Break, IfBreak (broken_d, _)) :: rest ->
        fits remaining ((i, Break, broken_d) :: rest)
    | (_, _, LineSuffix _) :: rest -> fits remaining rest
  in
  let flush_line_suffixes () =
    while not (Queue.is_empty line_suffix_queue) do
      let s = Queue.pop line_suffix_queue in
      Buffer.add_string buf s
    done
  in
  let emit_newline indent =
    flush_line_suffixes ();
    Buffer.add_char buf '\n';
    col := 0;
    if indent > 0 then begin
      let tabs = indent / 4 in
      Buffer.add_string buf (String.make tabs '\t');
      col := indent
    end
  in
  let rec process = function
    | [] -> flush_line_suffixes ()
    | (_, _, Nil) :: rest -> process rest
    | (_, _, Text s) :: rest ->
        Buffer.add_string buf s;
        col := !col + String.length s;
        process rest
    | (i, _, Hardline) :: rest ->
        emit_newline i;
        process rest
    | (_, Flat, Softline) :: rest -> process rest
    | (i, Break, Softline) :: rest ->
        emit_newline i;
        process rest
    | (_, Flat, SoftlineSpace) :: rest ->
        Buffer.add_char buf ' ';
        col := !col + 1;
        process rest
    | (i, Break, SoftlineSpace) :: rest ->
        emit_newline i;
        process rest
    | (i, m, Indent (j, d)) :: rest -> process ((i + j, m, d) :: rest)
    | (i, _, Group d) :: rest ->
        (* Try flat first *)
        let flat_cmds = [ (i, Flat, d) ] in
        if fits (width - !col) (flat_cmds @ rest) then
          process ((i, Flat, d) :: rest)
        else process ((i, Break, d) :: rest)
    | (i, m, Concat (a, b)) :: rest -> process ((i, m, a) :: (i, m, b) :: rest)
    | (i, Flat, IfBreak (_, flat_d)) :: rest ->
        process ((i, Flat, flat_d) :: rest)
    | (i, Break, IfBreak (broken_d, _)) :: rest ->
        process ((i, Break, broken_d) :: rest)
    | (_, _, LineSuffix s) :: rest ->
        Queue.push (" " ^ s) line_suffix_queue;
        process rest
  in
  process [ (0, Break, doc) ];
  Buffer.contents buf

(** Post-process rendered output:
    - Remove trailing whitespace from all lines
    - Collapse 3+ consecutive newlines to 2 (within function bodies)
    - Ensure single trailing newline *)
let post_process s =
  let lines = String.split_on_char '\n' s in
  (* Remove trailing whitespace from each line *)
  let lines =
    List.map
      (fun line ->
        let len = String.length line in
        let rec find_end i =
          if i < 0 then 0
          else match line.[i] with ' ' | '\t' -> find_end (i - 1) | _ -> i + 1
        in
        let end_pos = find_end (len - 1) in
        if end_pos = len then line else String.sub line 0 end_pos)
      lines
  in
  (* Collapse 3+ consecutive blank lines to 2 *)
  let rec collapse acc blank_count = function
    | [] -> List.rev acc
    | line :: rest ->
        if line = "" then
          begin if blank_count < 2 then
            collapse (line :: acc) (blank_count + 1) rest
          else collapse acc blank_count rest (* Drop extra blank lines *)
          end
        else collapse (line :: acc) 0 rest
  in
  let lines = collapse [] 0 lines in
  (* Remove trailing blank lines, then add exactly one trailing newline *)
  let rec drop_trailing_blanks = function
    | [] -> []
    | [ "" ] -> []
    | x :: rest -> x :: drop_trailing_blanks rest
  in
  let lines = drop_trailing_blanks lines in
  String.concat "\n" lines ^ "\n"

(** Full pipeline: render + post-process *)
let layout ?(width = line_width) doc = post_process (render ~width doc)
