(** Pure OCaml raw terminal line editor for the REPL. *)

(* ── Types ───────────────────────────────────────────────────────── *)

type line_buf = {
  mutable text : string;
  mutable cursor : int; (* byte offset *)
}

type input_state = SingleLine | MultiLine
type read_result = Input of string | Eof | Interrupted

type key =
  | Char of char
  | Up
  | Down
  | Left
  | Right
  | Home
  | End
  | Delete
  | Backspace
  | Enter
  | Tab
  | CtrlA
  | CtrlC
  | CtrlD
  | CtrlE
  | CtrlK
  | CtrlL
  | CtrlU
  | CtrlW
  | Unknown

type t = {
  mutable history : string list;
  mutable history_pos : int;
  mutable history_stash : string;
  max_history : int;
  mutable lines : string list; (* completed lines, reversed *)
  mutable current : line_buf;
  mutable mode : input_state;
  mutable orig_termios : Unix.terminal_io option;
  is_tty : bool;
  mutable hint_fn : (string -> string option) option;
  mutable completions_fn : (string -> (string * string) list) option;
}

let create ?(max_history = 500) () =
  {
    history = [];
    history_pos = -1;
    history_stash = "";
    max_history;
    lines = [];
    current = { text = ""; cursor = 0 };
    mode = SingleLine;
    orig_termios = None;
    is_tty = Unix.isatty Unix.stdin;
    hint_fn = None;
    completions_fn = None;
  }

let set_hint_fn t f = t.hint_fn <- Some f
let set_completions_fn t f = t.completions_fn <- Some f

(* ── Raw mode ────────────────────────────────────────────────────── *)

let enter_raw_mode t =
  if not t.is_tty then ()
  else
    let orig = Unix.tcgetattr Unix.stdin in
    t.orig_termios <- Some orig;
    Unix.tcsetattr Unix.stdin TCSAFLUSH
      {
        orig with
        c_icanon = false;
        c_echo = false;
        c_isig = false;
        c_ixon = false;
        c_icrnl = false;
        c_vmin = 1;
        c_vtime = 0;
      }

let restore_mode t =
  match t.orig_termios with
  | Some orig ->
      (try Unix.tcsetattr Unix.stdin TCSAFLUSH orig with _ -> ());
      t.orig_termios <- None
  | None -> ()

let install_cleanup_handlers t =
  at_exit (fun () -> restore_mode t);
  let restore_and_exit _ =
    restore_mode t;
    exit 1
  in
  ignore (Sys.signal Sys.sigint (Sys.Signal_handle restore_and_exit));
  ignore (Sys.signal Sys.sigterm (Sys.Signal_handle restore_and_exit))

(* ── UTF-8 helpers ───────────────────────────────────────────────── *)

let is_utf8_cont c = Char.code c land 0xC0 = 0x80

let next_char_pos s pos =
  let len = String.length s in
  if pos >= len then pos
  else
    let p = pos + 1 in
    let p = ref p in
    while !p < len && is_utf8_cont s.[!p] do
      incr p
    done;
    !p

let prev_char_pos s pos =
  if pos <= 0 then 0
  else
    let p = ref (pos - 1) in
    while !p > 0 && is_utf8_cont s.[!p] do
      decr p
    done;
    !p

(* ── Key reading ─────────────────────────────────────────────────── *)

let read_byte () =
  let buf = Bytes.create 1 in
  let n = Unix.read Unix.stdin buf 0 1 in
  if n = 0 then None else Some (Bytes.get buf 0)

let has_input_ready () =
  let readable, _, _ = Unix.select [ Unix.stdin ] [] [] 0.05 in
  readable <> []

let read_key () =
  match read_byte () with
  | None -> CtrlD (* EOF *)
  | Some c -> (
      let code = Char.code c in
      if code = 0x1B then
        (* Escape sequence *)
        begin if not (has_input_ready ()) then Unknown (* bare ESC *)
        else
          match read_byte () with
          | Some '[' -> (
              match read_byte () with
              | Some 'A' -> Up
              | Some 'B' -> Down
              | Some 'C' -> Right
              | Some 'D' -> Left
              | Some 'H' -> Home
              | Some 'F' -> End
              | Some '3' -> (
                  (* Delete: ESC [ 3 ~ *)
                  match read_byte () with
                  | Some '~' -> Delete
                  | _ -> Unknown)
              | Some '1' -> (
                  (* Home: ESC [ 1 ~ *)
                  match read_byte () with
                  | Some '~' -> Home
                  | _ -> Unknown)
              | Some '4' -> (
                  (* End: ESC [ 4 ~ *)
                  match read_byte () with
                  | Some '~' -> End
                  | _ -> Unknown)
              | _ -> Unknown)
          | Some 'O' -> (
              (* xterm-style: ESC O H/F *)
              match read_byte () with
              | Some 'H' -> Home
              | Some 'F' -> End
              | _ -> Unknown)
          | _ -> Unknown
        end
      else
        match code with
        | 0x01 -> CtrlA
        | 0x03 -> CtrlC
        | 0x04 -> CtrlD
        | 0x05 -> CtrlE
        | 0x0B -> CtrlK
        | 0x0C -> CtrlL
        | 0x09 -> Tab
        | 0x0D | 0x0A -> Enter
        | 0x15 -> CtrlU
        | 0x17 -> CtrlW
        | 0x7F -> Backspace
        | _ when code >= 32 || code >= 0x80 ->
            (* printable or UTF-8 lead byte *)
            Char c
        | _ -> Unknown)

(* ── Line buffer operations ──────────────────────────────────────── *)

let lb_insert buf c =
  let s = String.make 1 c in
  let before = String.sub buf.text 0 buf.cursor in
  let after =
    String.sub buf.text buf.cursor (String.length buf.text - buf.cursor)
  in
  buf.text <- before ^ s ^ after;
  buf.cursor <- buf.cursor + 1

let lb_insert_string buf s =
  let before = String.sub buf.text 0 buf.cursor in
  let after =
    String.sub buf.text buf.cursor (String.length buf.text - buf.cursor)
  in
  buf.text <- before ^ s ^ after;
  buf.cursor <- buf.cursor + String.length s

let lb_delete_back buf =
  if buf.cursor > 0 then begin
    let prev = prev_char_pos buf.text buf.cursor in
    let before = String.sub buf.text 0 prev in
    let after =
      String.sub buf.text buf.cursor (String.length buf.text - buf.cursor)
    in
    buf.text <- before ^ after;
    buf.cursor <- prev
  end

let lb_delete_at buf =
  let len = String.length buf.text in
  if buf.cursor < len then begin
    let next = next_char_pos buf.text buf.cursor in
    let before = String.sub buf.text 0 buf.cursor in
    let after = String.sub buf.text next (len - next) in
    buf.text <- before ^ after
  end

let lb_move_left buf =
  if buf.cursor > 0 then buf.cursor <- prev_char_pos buf.text buf.cursor

let lb_move_right buf =
  if buf.cursor < String.length buf.text then
    buf.cursor <- next_char_pos buf.text buf.cursor

let lb_home buf = buf.cursor <- 0
let lb_end buf = buf.cursor <- String.length buf.text
let lb_kill_to_end buf = buf.text <- String.sub buf.text 0 buf.cursor

let lb_kill_to_start buf =
  let after =
    String.sub buf.text buf.cursor (String.length buf.text - buf.cursor)
  in
  buf.text <- after;
  buf.cursor <- 0

let lb_kill_word_back buf =
  if buf.cursor > 0 then begin
    let p = ref (buf.cursor - 1) in
    (* skip whitespace *)
    while !p > 0 && buf.text.[!p] = ' ' do
      decr p
    done;
    (* skip word chars *)
    while !p > 0 && buf.text.[!p] <> ' ' do
      decr p
    done;
    let start = if !p > 0 then !p + 1 else 0 in
    let before = String.sub buf.text 0 start in
    let after =
      String.sub buf.text buf.cursor (String.length buf.text - buf.cursor)
    in
    buf.text <- before ^ after;
    buf.cursor <- start
  end

let lb_set buf text =
  buf.text <- text;
  buf.cursor <- String.length text

(* ── Rendering ───────────────────────────────────────────────────── *)

let output_str s =
  let len = String.length s in
  let written = ref 0 in
  while !written < len do
    let n =
      Unix.write Unix.stdout (Bytes.of_string s) !written (len - !written)
    in
    written := !written + n
  done

(** Count display columns for a UTF-8 string (approximation: 1 per codepoint). *)
let display_width s =
  let w = ref 0 in
  for i = 0 to String.length s - 1 do
    if not (is_utf8_cont s.[i]) then incr w
  done;
  !w

(** Count display columns up to byte offset [pos]. *)
let display_width_to s pos =
  let w = ref 0 in
  let limit = min pos (String.length s) in
  for i = 0 to limit - 1 do
    if not (is_utf8_cont s.[i]) then incr w
  done;
  !w

let redraw ?hint_fn prompt buf =
  let prompt_w = String.length prompt in
  let cursor_col = prompt_w + display_width_to buf.text buf.cursor in
  let total_w = prompt_w + display_width buf.text in
  (* Move to column 0, clear line, print prompt + text *)
  output_str "\r\027[K";
  output_str prompt;
  output_str buf.text;
  (* Show ghost hint if cursor is at end and hint_fn is provided *)
  let ghost_w = ref 0 in
  if buf.cursor = String.length buf.text then
    begin match hint_fn with
    | Some f -> (
        match f buf.text with
        | Some ghost when ghost <> "" ->
            output_str "\027[2m";
            (* dim *)
            output_str ghost;
            output_str "\027[0m";
            (* reset *)
            ghost_w := display_width ghost
        | _ -> ())
    | None -> ()
    end;
  (* Move cursor back to correct position *)
  let back = total_w + !ghost_w - cursor_col in
  if back > 0 then output_str (Printf.sprintf "\027[%dD" back)

(* ── Multi-line detection ────────────────────────────────────────── *)

let ends_with_colon s =
  let t = String.trim s in
  let len = String.length t in
  len > 0 && t.[len - 1] = ':'

let is_indented s = String.length s > 0 && (s.[0] = ' ' || s.[0] = '\t')

let should_continue mode line =
  match mode with
  | SingleLine -> ends_with_colon line
  | MultiLine ->
      if String.trim line = "" then false
      else if is_indented line then true
      else if ends_with_colon line then true
      else false

(* ── History ─────────────────────────────────────────────────────── *)

let add_history t text =
  let trimmed = String.trim text in
  if trimmed = "" then ()
  else
    let deduped =
      match t.history with
      | prev :: _ when prev = trimmed -> t.history
      | _ -> trimmed :: t.history
    in
    t.history <-
      (if List.length deduped > t.max_history then
         List.filteri (fun i _ -> i < t.max_history) deduped
       else deduped)

let history_up t =
  let max_idx = List.length t.history - 1 in
  if max_idx < 0 then () (* no history *)
  else if t.history_pos < max_idx then begin
    if t.history_pos = -1 then t.history_stash <- t.current.text;
    t.history_pos <- t.history_pos + 1;
    let entry = List.nth t.history t.history_pos in
    (* For multi-line history, show only the last line in the editor *)
    let entry_lines = String.split_on_char '\n' entry in
    let n = List.length entry_lines in
    if n > 1 then begin
      (* Print the preceding lines and set up multi-line mode *)
      t.lines <- [];
      let all_lines = Array.of_list entry_lines in
      (* Print all lines except the last with their prompts *)
      for i = 0 to n - 2 do
        let l = all_lines.(i) in
        let p = if i = 0 && t.lines = [] then ">>> " else "... " in
        output_str (Printf.sprintf "\r\027[K%s%s\n" p l);
        t.lines <- l :: t.lines
      done;
      t.mode <- MultiLine;
      lb_set t.current all_lines.(n - 1)
    end
    else lb_set t.current entry
  end

let history_down t =
  if t.history_pos > 0 then begin
    t.history_pos <- t.history_pos - 1;
    let entry = List.nth t.history t.history_pos in
    let entry_lines = String.split_on_char '\n' entry in
    let n = List.length entry_lines in
    if n > 1 then begin
      t.lines <- [];
      let all_lines = Array.of_list entry_lines in
      for i = 0 to n - 2 do
        let l = all_lines.(i) in
        let p = if i = 0 && t.lines = [] then ">>> " else "... " in
        output_str (Printf.sprintf "\r\027[K%s%s\n" p l);
        t.lines <- l :: t.lines
      done;
      t.mode <- MultiLine;
      lb_set t.current all_lines.(n - 1)
    end
    else lb_set t.current entry
  end
  else if t.history_pos = 0 then begin
    t.history_pos <- -1;
    t.lines <- [];
    t.mode <- SingleLine;
    lb_set t.current t.history_stash
  end

(* ── Non-TTY fallback ────────────────────────────────────────────── *)

let read_input_pipe () =
  let buf = Buffer.create 256 in
  let first = ref true in
  try
    while true do
      if !first then (
        print_string ">>> ";
        first := false)
      else print_string "... ";
      flush stdout;
      let line = input_line stdin in
      if String.trim line = "" && Buffer.length buf > 0 then raise Exit
      else if String.trim line = "" && Buffer.length buf = 0 then raise Exit
      else begin
        if Buffer.length buf > 0 then Buffer.add_char buf '\n';
        Buffer.add_string buf line
      end
    done;
    assert false
  with
  | Exit ->
      let s = Buffer.contents buf in
      if String.trim s = "" then Input "" else Input s
  | End_of_file ->
      if Buffer.length buf > 0 then Input (Buffer.contents buf) else Eof

(* ── Main read loop ──────────────────────────────────────────────── *)

let read_input t =
  if not t.is_tty then read_input_pipe ()
  else begin
    (* Reset per-input state *)
    t.lines <- [];
    t.current <- { text = ""; cursor = 0 };
    t.mode <- SingleLine;
    t.history_pos <- -1;
    t.history_stash <- "";
    let prompt () = if t.lines = [] then ">>> " else "... " in
    output_str (prompt ());
    let rd () = redraw ?hint_fn:t.hint_fn (prompt ()) t.current in
    let rec loop () =
      let key = read_key () in
      match key with
      | Char c ->
          lb_insert t.current c;
          rd ();
          loop ()
      | Enter ->
          let line = t.current.text in
          if should_continue t.mode line then begin
            (* Commit line, continue in multi-line mode *)
            t.lines <- line :: t.lines;
            t.mode <- MultiLine;
            t.current <- { text = ""; cursor = 0 };
            output_str "\n";
            output_str (prompt ());
            loop ()
          end
          else begin
            (* Complete input *)
            output_str "\n";
            let all_lines = List.rev (line :: t.lines) in
            let result = String.concat "\n" all_lines in
            Input result
          end
      | Backspace ->
          lb_delete_back t.current;
          rd ();
          loop ()
      | Delete ->
          lb_delete_at t.current;
          rd ();
          loop ()
      | Left ->
          lb_move_left t.current;
          rd ();
          loop ()
      | Right ->
          lb_move_right t.current;
          rd ();
          loop ()
      | Up ->
          history_up t;
          rd ();
          loop ()
      | Down ->
          history_down t;
          rd ();
          loop ()
      | Home | CtrlA ->
          lb_home t.current;
          rd ();
          loop ()
      | End | CtrlE ->
          lb_end t.current;
          rd ();
          loop ()
      | CtrlK ->
          lb_kill_to_end t.current;
          rd ();
          loop ()
      | CtrlU ->
          lb_kill_to_start t.current;
          rd ();
          loop ()
      | CtrlW ->
          lb_kill_word_back t.current;
          rd ();
          loop ()
      | CtrlC ->
          output_str "\n";
          Interrupted
      | CtrlD ->
          if t.current.text = "" && t.lines = [] then begin
            output_str "\n";
            Eof
          end
          else begin
            (* Ctrl-D on non-empty: delete char at cursor *)
            lb_delete_at t.current;
            rd ();
            loop ()
          end
      | CtrlL ->
          (* Clear screen, redraw *)
          output_str "\027[2J\027[H";
          (* Re-print committed multi-line lines *)
          let committed = List.rev t.lines in
          List.iteri
            (fun i l ->
              let p = if i = 0 then ">>> " else "... " in
              output_str p;
              output_str l;
              output_str "\n")
            committed;
          output_str (prompt ());
          output_str t.current.text;
          let back =
            display_width t.current.text
            - display_width_to t.current.text t.current.cursor
          in
          if back > 0 then output_str (Printf.sprintf "\027[%dD" back);
          loop ()
      | Tab ->
          (* Try hint completion first, then multi-match display, then indent *)
          let accepted = ref false in
          (* 1. Accept ghost hint if available *)
          (match t.hint_fn with
          | Some f -> (
              match f t.current.text with
              | Some ghost when ghost <> "" ->
                  lb_insert_string t.current ghost;
                  accepted := true
              | _ -> ())
          | None -> ());
          if not !accepted then
            (* 2. Try completions_fn for multi-match *)
            begin match t.completions_fn with
            | Some f -> (
                let matches = f t.current.text in
                match matches with
                | [ (cmd, _) ] ->
                    (* Single match: replace buffer with command *)
                    lb_set t.current cmd;
                    accepted := true
                | _ :: _ ->
                    (* Multiple matches: display below, then redraw *)
                    output_str "\n";
                    List.iter
                      (fun (cmd, desc) ->
                        output_str
                          (Printf.sprintf "  \027[1m%-16s\027[0m %s\n" cmd desc))
                      matches;
                    output_str (prompt ());
                    output_str t.current.text;
                    accepted := true
                | [] -> ())
            | None -> ()
            end;
          if not !accepted then lb_insert_string t.current "    ";
          rd ();
          loop ()
      | Unknown -> loop ()
    in
    loop ()
  end
