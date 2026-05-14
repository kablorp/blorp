(** String producer/consumer fusion.

    This pass runs in the Core fusion stage, after calls have been resolved and
    before specialization/ownership insertion. The representation below is
    intentionally narrow: a producer is only modeled if the compiler knows the
    exact property a consumer needs. That avoids treating arbitrary String
    functions as interchangeable materialized values. *)

open Core

let ty_int = Ast.TyNamed ("Int", [])
let ty_bool = Ast.TyNamed ("Bool", [])
let ty_string = Ast.TyNamed ("String", [])
let ty_void = Ast.TyNamed ("Void", [])

type string_stage =
  | ReverseBytes
  | TrimBytes
  | TrimLeftBytes
  | TrimRightBytes
  | TakeLeftBytes of core
  | DropLeftBytes of core
  | TakeRightBytes of core
  | DropRightBytes of core
  | SubstringBytes of { start : core; len : core }
  | ReplaceBytes of { old_ : core; new_ : core }

type string_pipeline = { source : core; stages : string_stage list }
type source_window = { source : core; start : core; len : core }
type length_state = SourceWindow of source_window | LengthOnly of core

let mk ?(loc = Ast.dummy_loc) ty desc = { desc; ty; loc }
let void ?(loc = Ast.dummy_loc) () = mk ~loc ty_void CVoid

let intr ?(loc = Ast.dummy_loc) name args ty =
  mk ~loc ty (CCall (CKIntrinsic name, void ~loc (), args))

let lit_int ?(loc = Ast.dummy_loc) n =
  mk ~loc ty_int (CLit (Ast.LitInt (Int64.of_int n)))

let lit_bool ?(loc = Ast.dummy_loc) b = mk ~loc ty_bool (CLit (Ast.LitBool b))
let var ?(loc = Ast.dummy_loc) name ty = mk ~loc ty (CVar (Var.named name))
let bin ?(loc = Ast.dummy_loc) op lhs rhs ty = mk ~loc ty (CBin (op, lhs, rhs))
let cmp op lhs rhs = bin ~loc:lhs.loc op lhs rhs ty_bool
let add lhs rhs = bin ~loc:lhs.loc Ast.Add lhs rhs ty_int
let sub lhs rhs = bin ~loc:lhs.loc Ast.Sub lhs rhs ty_int
let mul lhs rhs = bin ~loc:lhs.loc Ast.Mul lhs rhs ty_int
let lt lhs rhs = cmp Ast.Lt lhs rhs
let gt lhs rhs = cmp Ast.Gt lhs rhs
let le lhs rhs = cmp Ast.Le lhs rhs
let ge lhs rhs = cmp Ast.Ge lhs rhs
let eq lhs rhs = cmp Ast.Eq lhs rhs
let ne lhs rhs = cmp Ast.Ne lhs rhs
let and_ lhs rhs = mk ~loc:lhs.loc ty_bool (CLog (Ast.And, lhs, rhs))
let or_ lhs rhs = mk ~loc:lhs.loc ty_bool (CLog (Ast.Or, lhs, rhs))

let if_ ?(loc = Ast.dummy_loc) cond then_ else_ ty =
  mk ~loc ty (CIf (cond, then_, else_))

let seq lhs rhs = mk ~loc:lhs.loc rhs.ty (CSeq (lhs, rhs))
let while_ cond body = mk ~loc:cond.loc ty_void (CWhile (cond, body))
let break_ ?(loc = Ast.dummy_loc) () = mk ~loc ty_void CBreak

let assign ?(loc = Ast.dummy_loc) name rhs =
  mk ~loc ty_void (CAssign (Var.named name, rhs))

let for_ name range body =
  mk ~loc:range.loc ty_void
    (CFor (loop_binder_named_forward_range name ty_int, range, body))

let range start stop = mk ~loc:start.loc ty_int (CRange (start, stop))

let lett ?(mut = false) name rhs body =
  mk ~loc:rhs.loc body.ty
    (CLet
       ( {
           bind_var = Var.named name;
           bind_mut = mut;
           bind_ty = rhs.ty;
           bind_rhs = rhs;
         },
         body ))

let borrow_lett name rhs body =
  mk ~loc:rhs.loc body.ty
    (CBorrowLet
       ( { borrow_var = Var.named name; borrow_ty = rhs.ty; borrow_rhs = rhs },
         body ))

let bind_source_alias name rhs body =
  match rhs.desc with
  | CVar _ -> borrow_lett name rhs body
  | _ -> lett name rhs body

let bind_all bindings body =
  List.fold_right
    (fun (mut, name, rhs) acc -> lett ~mut name rhs acc)
    bindings body

let state_length = function
  | SourceWindow { len; _ } -> len
  | LengthOnly len -> len

let with_state_length state len =
  match state with
  | SourceWindow window -> SourceWindow { window with len }
  | LengthOnly _ -> LengthOnly len

let string_len source = intr "string_len" [ source ] ty_int

let string_get_byte source index =
  intr "string_get_byte" [ source; index ] ty_int

let string_alloc len = intr "string_alloc" [ len ] ty_string

let string_copy_bytes result dst_pos source src_pos len =
  intr "string_copy_bytes" [ result; dst_pos; source; src_pos; len ] ty_void

let string_set_byte result index byte =
  intr "string_set_byte" [ result; index; byte ] ty_void

let string_set_len result len = intr "string_set_len" [ result; len ] ty_void

let clamp_count_to_len len n =
  if_ (le n (lit_int 0)) (lit_int 0) (if_ (gt n len) len n ty_int) ty_int

let is_ws byte =
  or_
    (or_ (eq byte (lit_int 32)) (eq byte (lit_int 9)))
    (or_ (eq byte (lit_int 10)) (eq byte (lit_int 13)))

let is_string_type = function Ast.TyNamed ("String", _) -> true | _ -> false
let is_int_value_type = Type_widening.is_scalar_int_value_type

let literal_string_byte_length e =
  match e.desc with
  | CLit (Ast.LitString (s, _)) -> Some (String.length s)
  | _ -> None

let replace_is_statically_length_preserving old_ new_ =
  match literal_string_byte_length old_ with
  | Some 0 -> true
  | Some old_len -> (
      match literal_string_byte_length new_ with
      | Some new_len -> old_len = new_len
      | None -> false)
  | None -> false

let starts_with ~prefix s =
  let plen = String.length prefix in
  String.length s >= plen && String.sub s 0 plen = prefix

let strip_prefix ~prefix s =
  if starts_with ~prefix s then
    Some
      (String.sub s (String.length prefix)
         (String.length s - String.length prefix))
  else None

let strip_mono_suffix name =
  let marker = "__mono_" in
  let marker_len = String.length marker in
  let rec find i =
    if i + marker_len > String.length name then name
    else if String.sub name i marker_len = marker then String.sub name 0 i
    else find (i + 1)
  in
  find 0

let trait_resolved_string_length_name name =
  starts_with ~prefix:"HasLength_length_String" name

let base_string_func_name name =
  let base = strip_mono_suffix name in
  let base =
    match strip_prefix ~prefix:"std_string__" base with
    | Some rest -> rest
    | None -> (
        match strip_prefix ~prefix:"__ufcs_std$string__" base with
        | Some rest -> rest
        | None -> base)
  in
  match base with
  | "drop_left" | "drop_right" | "replace" | "reverse" | "substring"
  | "take_left" | "take_right" | "trim" | "trim_left" | "trim_right" ->
      Some base
  | "length" -> Some "length"
  | _ when trait_resolved_string_length_name base -> Some "length"
  | _ -> None

let call_base_and_args e =
  match e.desc with
  | CCall (CKUser (name, _), _, args) ->
      Option.map (fun base -> (base, args)) (base_string_func_name name)
  | CCall (CKUnknown, { desc = CVar v; _ }, args) ->
      Option.map (fun base -> (base, args)) (base_string_func_name v.vname)
  | CCall (CKIntrinsic "string_len", _, args) -> Some ("length", args)
  | _ -> None

let rec append_stage source stage =
  if not (is_string_type source.ty) then None
  else
    let pipeline =
      match pipeline_of_expr source with
      | Some nested -> nested
      | None -> { source; stages = [] }
    in
    Some { pipeline with stages = pipeline.stages @ [ stage ] }

and pipeline_of_expr e =
  match call_base_and_args e with
  | Some ("reverse", [ source ])
    when is_string_type source.ty && is_string_type e.ty ->
      append_stage source ReverseBytes
  | Some ("trim", [ source ])
    when is_string_type source.ty && is_string_type e.ty ->
      append_stage source TrimBytes
  | Some ("trim_left", [ source ])
    when is_string_type source.ty && is_string_type e.ty ->
      append_stage source TrimLeftBytes
  | Some ("trim_right", [ source ])
    when is_string_type source.ty && is_string_type e.ty ->
      append_stage source TrimRightBytes
  | Some ("take_left", [ source; n ])
    when is_string_type source.ty && is_int_value_type n.ty
         && is_string_type e.ty ->
      append_stage source (TakeLeftBytes n)
  | Some ("drop_left", [ source; n ])
    when is_string_type source.ty && is_int_value_type n.ty
         && is_string_type e.ty ->
      append_stage source (DropLeftBytes n)
  | Some ("take_right", [ source; n ])
    when is_string_type source.ty && is_int_value_type n.ty
         && is_string_type e.ty ->
      append_stage source (TakeRightBytes n)
  | Some ("drop_right", [ source; n ])
    when is_string_type source.ty && is_int_value_type n.ty
         && is_string_type e.ty ->
      append_stage source (DropRightBytes n)
  | Some ("substring", [ source; start; len ])
    when is_string_type source.ty && is_int_value_type start.ty
         && is_int_value_type len.ty && is_string_type e.ty ->
      append_stage source (SubstringBytes { start; len })
  | Some ("replace", [ source; old_; new_ ])
    when is_string_type source.ty && is_string_type old_.ty
         && is_string_type new_.ty && is_string_type e.ty ->
      append_stage source (ReplaceBytes { old_; new_ })
  | _ -> None

let with_bound_expr fresh prefix rhs f =
  let name = fresh prefix in
  lett name rhs (f (var name rhs.ty))

let with_bound_mut fresh prefix rhs f =
  let name = fresh prefix in
  lett ~mut:true name rhs (f name (var name rhs.ty))

let materialize_window fresh ({ source; start; len } : source_window) =
  with_bound_expr fresh "window_len" len (fun len ->
      with_bound_expr fresh "window_result" (string_alloc len) (fun result ->
          seq
            (string_copy_bytes result (lit_int 0) source start len)
            (seq (string_set_len result len) result)))

let apply_take_left fresh state n continue =
  with_bound_expr fresh "take_n" n (fun n ->
      let len = state_length state in
      let kept = clamp_count_to_len len n in
      continue (with_state_length state kept))

let apply_drop_left fresh state n continue =
  with_bound_expr fresh "drop_n" n (fun n ->
      let len = state_length state in
      let dropped = clamp_count_to_len len n in
      with_bound_expr fresh "drop_count" dropped (fun dropped ->
          match state with
          | SourceWindow window ->
              continue
                (SourceWindow
                   {
                     window with
                     start = add window.start dropped;
                     len = sub len dropped;
                   })
          | LengthOnly _ -> continue (LengthOnly (sub len dropped))))

let apply_take_right fresh state n continue =
  with_bound_expr fresh "take_n" n (fun n ->
      let len = state_length state in
      let kept = clamp_count_to_len len n in
      with_bound_expr fresh "take_count" kept (fun kept ->
          match state with
          | SourceWindow window ->
              continue
                (SourceWindow
                   {
                     window with
                     start = add window.start (sub len kept);
                     len = kept;
                   })
          | LengthOnly _ -> continue (LengthOnly kept)))

let apply_drop_right fresh state n continue =
  with_bound_expr fresh "drop_n" n (fun n ->
      let len = state_length state in
      let kept =
        if_
          (le n (lit_int 0))
          len
          (if_ (ge n len) (lit_int 0) (sub len n) ty_int)
          ty_int
      in
      continue (with_state_length state kept))

let apply_substring fresh state start req_len continue =
  with_bound_expr fresh "substring_start_arg" start (fun start_arg ->
      with_bound_expr fresh "substring_len_arg" req_len (fun req_len ->
          let len = state_length state in
          let rel_start =
            if_
              (lt start_arg (lit_int 0))
              (lit_int 0)
              (if_ (gt start_arg len) len start_arg ty_int)
              ty_int
          in
          with_bound_expr fresh "substring_start" rel_start (fun rel_start ->
              let new_len =
                if_
                  (le req_len (lit_int 0))
                  (lit_int 0)
                  (if_
                     (gt (add rel_start req_len) len)
                     (sub len rel_start) req_len ty_int)
                  ty_int
              in
              match state with
              | SourceWindow window ->
                  continue
                    (SourceWindow
                       {
                         window with
                         start = add window.start rel_start;
                         len = new_len;
                       })
              | LengthOnly _ -> continue (LengthOnly new_len))))

let apply_trim_left fresh state continue =
  match state with
  | LengthOnly _ -> None
  | SourceWindow { source; start; len } ->
      let end_ = add start len in
      Some
        (with_bound_mut fresh "trim_start" start (fun start_name trim_start ->
             with_bound_expr fresh "trim_end" end_ (fun trim_end ->
                 let cond =
                   and_ (lt trim_start trim_end)
                     (is_ws (string_get_byte source trim_start))
                 in
                 let bump = assign start_name (add trim_start (lit_int 1)) in
                 seq (while_ cond bump)
                   (continue
                      (SourceWindow
                         {
                           source;
                           start = trim_start;
                           len = sub trim_end trim_start;
                         })))))

let apply_trim_right fresh state continue =
  match state with
  | LengthOnly _ -> None
  | SourceWindow { source; start; len } ->
      let end_ = add start len in
      Some
        (with_bound_mut fresh "trim_end" end_ (fun end_name trim_end ->
             let prev = sub trim_end (lit_int 1) in
             let cond =
               and_ (gt trim_end start) (is_ws (string_get_byte source prev))
             in
             let bump = assign end_name prev in
             seq (while_ cond bump)
               (continue
                  (SourceWindow { source; start; len = sub trim_end start }))))

let apply_trim fresh state continue =
  match state with
  | LengthOnly _ -> None
  | SourceWindow { source; start; len } ->
      let end_ = add start len in
      Some
        (with_bound_mut fresh "trim_start" start (fun start_name trim_start ->
             with_bound_mut fresh "trim_end" end_ (fun end_name trim_end ->
                 let left_cond =
                   and_ (lt trim_start trim_end)
                     (is_ws (string_get_byte source trim_start))
                 in
                 let right_cond =
                   let prev = sub trim_end (lit_int 1) in
                   and_ (gt trim_end trim_start)
                     (is_ws (string_get_byte source prev))
                 in
                 let left_loop =
                   while_ left_cond
                     (assign start_name (add trim_start (lit_int 1)))
                 in
                 let right_loop =
                   while_ right_cond
                     (assign end_name (sub trim_end (lit_int 1)))
                 in
                 let next =
                   SourceWindow
                     {
                       source;
                       start = trim_start;
                       len = sub trim_end trim_start;
                     }
                 in
                 seq left_loop (seq right_loop (continue next)))))

let apply_replace fresh state old_ new_ continue =
  match state with
  | LengthOnly _ when replace_is_statically_length_preserving old_ new_ ->
      Some (continue state)
  | LengthOnly _ -> None
  | SourceWindow { source; start; len } ->
      let old_name = fresh "replace_old" in
      let new_name = fresh "replace_new" in
      let old_len_name = fresh "replace_old_len" in
      let new_len_name = fresh "replace_new_len" in
      let end_name = fresh "replace_end" in
      let count_name = fresh "replace_count" in
      let pos_name = fresh "replace_pos" in
      let match_name = fresh "replace_match" in
      let j_name = fresh "replace_j" in
      let old_v = var old_name ty_string in
      let new_v = var new_name ty_string in
      let old_len = var old_len_name ty_int in
      let new_len = var new_len_name ty_int in
      let end_ = var end_name ty_int in
      let count = var count_name ty_int in
      let pos = var pos_name ty_int in
      let match_var = var match_name ty_bool in
      let j = var j_name ty_int in
      let compare_loop =
        for_ j_name
          (range (lit_int 0) old_len)
          (if_
             (ne (string_get_byte source (add pos j)) (string_get_byte old_v j))
             (seq (assign match_name (lit_bool false)) (break_ ()))
             (void ()) ty_void)
      in
      let count_match =
        lett ~mut:true match_name (lit_bool true)
          (seq compare_loop
             (if_ match_var
                (seq
                   (assign count_name (add count (lit_int 1)))
                   (assign pos_name (add pos old_len)))
                (assign pos_name (add pos (lit_int 1)))
                ty_void))
      in
      let count_loop = while_ (le (add pos old_len) end_) count_match in
      let out_len = add len (mul count (sub new_len old_len)) in
      let body =
        if_
          (eq old_len (lit_int 0))
          (continue (LengthOnly len))
          (seq count_loop (continue (LengthOnly out_len)))
          ty_int
      in
      Some
        (bind_all
           [
             (false, old_name, old_);
             (false, new_name, new_);
             (false, old_len_name, string_len old_v);
             (false, new_len_name, string_len new_v);
             (false, end_name, add start len);
             (true, count_name, lit_int 0);
             (true, pos_name, start);
           ]
           body)

let apply_replace_materialized fresh ({ source; start; len } as window) old_
    new_ =
  let old_name = fresh "replace_old" in
  let new_name = fresh "replace_new" in
  let old_len_name = fresh "replace_old_len" in
  let new_len_name = fresh "replace_new_len" in
  let end_name = fresh "replace_end" in
  let count_name = fresh "replace_count" in
  let count_pos_name = fresh "replace_count_pos" in
  let old_v = var old_name ty_string in
  let new_v = var new_name ty_string in
  let old_len = var old_len_name ty_int in
  let new_len = var new_len_name ty_int in
  let end_ = var end_name ty_int in
  let count = var count_name ty_int in
  let count_pos = var count_pos_name ty_int in
  let compare_loop match_name pos =
    let j_name = fresh "replace_j" in
    let j = var j_name ty_int in
    for_ j_name
      (range (lit_int 0) old_len)
      (if_
         (ne (string_get_byte source (add pos j)) (string_get_byte old_v j))
         (seq (assign match_name (lit_bool false)) (break_ ()))
         (void ()) ty_void)
  in
  let count_match =
    with_bound_mut fresh "replace_match" (lit_bool true)
      (fun match_name match_var ->
        seq
          (compare_loop match_name count_pos)
          (if_ match_var
             (seq
                (assign count_name (add count (lit_int 1)))
                (assign count_pos_name (add count_pos old_len)))
             (assign count_pos_name (add count_pos (lit_int 1)))
             ty_void))
  in
  let count_loop = while_ (le (add count_pos old_len) end_) count_match in
  let build_result =
    with_bound_expr fresh "replace_out_len"
      (add len (mul count (sub new_len old_len)))
      (fun out_len ->
        with_bound_expr fresh "replace_result" (string_alloc out_len)
          (fun result ->
            with_bound_mut fresh "replace_in_pos" start
              (fun in_pos_name in_pos ->
                with_bound_mut fresh "replace_out_pos" (lit_int 0)
                  (fun out_pos_name out_pos ->
                    with_bound_mut fresh "replace_segment_start" start
                      (fun segment_start_name segment_start ->
                        let copy_replacement =
                          string_copy_bytes result out_pos new_v (lit_int 0)
                            new_len
                        in
                        let copy_source_segment segment_len =
                          string_copy_bytes result out_pos source segment_start
                            segment_len
                        in
                        let advance_past_match =
                          let next_in = add in_pos old_len in
                          seq
                            (assign segment_start_name next_in)
                            (assign in_pos_name next_in)
                        in
                        let copy_current_segment_and_replacement =
                          with_bound_expr fresh "replace_segment_len"
                            (sub in_pos segment_start) (fun segment_len ->
                              seq
                                (copy_source_segment segment_len)
                                (seq
                                   (assign out_pos_name
                                      (add out_pos segment_len))
                                   (seq copy_replacement
                                      (seq
                                         (assign out_pos_name
                                            (add out_pos new_len))
                                         advance_past_match))))
                        in
                        let advance_one_byte =
                          assign in_pos_name (add in_pos (lit_int 1))
                        in
                        let fill_body =
                          with_bound_expr fresh "replace_can_match"
                            (le (add in_pos old_len) end_)
                            (fun can_match ->
                              with_bound_mut fresh "replace_match" can_match
                                (fun match_name match_var ->
                                  seq
                                    (if_ can_match
                                       (compare_loop match_name in_pos)
                                       (void ()) ty_void)
                                    (if_ match_var
                                       copy_current_segment_and_replacement
                                       advance_one_byte ty_void)))
                        in
                        let fill_loop = while_ (lt in_pos end_) fill_body in
                        let copy_final_segment =
                          with_bound_expr fresh "replace_final_segment_len"
                            (sub end_ segment_start) (fun final_segment_len ->
                              string_copy_bytes result out_pos source
                                segment_start final_segment_len)
                        in
                        seq fill_loop
                          (seq copy_final_segment
                             (seq (string_set_len result out_len) result)))))))
  in
  let body =
    if_
      (eq old_len (lit_int 0))
      (materialize_window fresh window)
      (seq count_loop
         (if_
            (eq count (lit_int 0))
            (materialize_window fresh window)
            build_result ty_string))
      ty_string
  in
  bind_all
    [
      (false, old_name, old_);
      (false, new_name, new_);
      (false, old_len_name, string_len old_v);
      (false, new_len_name, string_len new_v);
      (false, end_name, add start len);
      (true, count_name, lit_int 0);
      (true, count_pos_name, start);
    ]
    body

let apply_reverse_materialized fresh ({ source; start; len } : source_window) =
  with_bound_expr fresh "reverse_len" len (fun len ->
      with_bound_expr fresh "reverse_result" (string_alloc len) (fun result ->
          let i_name = fresh "reverse_i" in
          let i = var i_name ty_int in
          let src_idx = add start (sub (sub len (lit_int 1)) i) in
          let write =
            string_set_byte result i (string_get_byte source src_idx)
          in
          seq
            (for_ i_name (range (lit_int 0) len) write)
            (seq (string_set_len result len) result)))

let lower_length (pipeline : string_pipeline) =
  let counter = ref 0 in
  let fresh prefix =
    incr counter;
    Printf.sprintf "__sp_%s_%d" prefix !counter
  in
  let rec lower_stages state = function
    | [] -> state_length state
    | ReverseBytes :: rest ->
        lower_stages (LengthOnly (state_length state)) rest
    | TakeLeftBytes n :: rest ->
        apply_take_left fresh state n (fun state -> lower_stages state rest)
    | DropLeftBytes n :: rest ->
        apply_drop_left fresh state n (fun state -> lower_stages state rest)
    | TakeRightBytes n :: rest ->
        apply_take_right fresh state n (fun state -> lower_stages state rest)
    | DropRightBytes n :: rest ->
        apply_drop_right fresh state n (fun state -> lower_stages state rest)
    | SubstringBytes { start; len } :: rest ->
        apply_substring fresh state start len (fun state ->
            lower_stages state rest)
    | TrimLeftBytes :: rest -> (
        match
          apply_trim_left fresh state (fun state -> lower_stages state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimRightBytes :: rest -> (
        match
          apply_trim_right fresh state (fun state -> lower_stages state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimBytes :: rest -> (
        match apply_trim fresh state (fun state -> lower_stages state rest) with
        | Some lowered -> lowered
        | None -> raise Exit)
    | ReplaceBytes { old_; new_ } :: rest -> (
        match
          apply_replace fresh state old_ new_ (fun state ->
              lower_stages state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
  in
  let source_name = fresh "source" in
  let source = var source_name ty_string in
  try
    Some
      (bind_source_alias source_name pipeline.source
         (lower_stages
            (SourceWindow { source; start = lit_int 0; len = string_len source })
            pipeline.stages))
  with Exit -> None

let lower_materialized_replace (pipeline : string_pipeline) =
  let counter = ref 0 in
  let fresh prefix =
    incr counter;
    Printf.sprintf "__sp_%s_%d" prefix !counter
  in
  let rec lower_stages saw_window_stage state = function
    | [] -> raise Exit
    | ReverseBytes :: _ -> raise Exit
    | ReplaceBytes { old_; new_ } :: [] when saw_window_stage -> (
        match state with
        | SourceWindow window ->
            apply_replace_materialized fresh window old_ new_
        | LengthOnly _ -> raise Exit)
    | ReplaceBytes _ :: _ -> raise Exit
    | TakeLeftBytes n :: rest ->
        apply_take_left fresh state n (fun state ->
            lower_stages true state rest)
    | DropLeftBytes n :: rest ->
        apply_drop_left fresh state n (fun state ->
            lower_stages true state rest)
    | TakeRightBytes n :: rest ->
        apply_take_right fresh state n (fun state ->
            lower_stages true state rest)
    | DropRightBytes n :: rest ->
        apply_drop_right fresh state n (fun state ->
            lower_stages true state rest)
    | SubstringBytes { start; len } :: rest ->
        apply_substring fresh state start len (fun state ->
            lower_stages true state rest)
    | TrimLeftBytes :: rest -> (
        match
          apply_trim_left fresh state (fun state ->
              lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimRightBytes :: rest -> (
        match
          apply_trim_right fresh state (fun state ->
              lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimBytes :: rest -> (
        match
          apply_trim fresh state (fun state -> lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
  in
  let source_name = fresh "source" in
  let source = var source_name ty_string in
  try
    Some
      (bind_source_alias source_name pipeline.source
         (lower_stages false
            (SourceWindow { source; start = lit_int 0; len = string_len source })
            pipeline.stages))
  with Exit -> None

let lower_materialized_reverse (pipeline : string_pipeline) =
  let counter = ref 0 in
  let fresh prefix =
    incr counter;
    Printf.sprintf "__sp_%s_%d" prefix !counter
  in
  let rec lower_stages saw_window_stage state = function
    | [] -> raise Exit
    | ReverseBytes :: [] when saw_window_stage -> (
        match state with
        | SourceWindow window -> apply_reverse_materialized fresh window
        | LengthOnly _ -> raise Exit)
    | ReverseBytes :: _ | ReplaceBytes _ :: _ -> raise Exit
    | TakeLeftBytes n :: rest ->
        apply_take_left fresh state n (fun state ->
            lower_stages true state rest)
    | DropLeftBytes n :: rest ->
        apply_drop_left fresh state n (fun state ->
            lower_stages true state rest)
    | TakeRightBytes n :: rest ->
        apply_take_right fresh state n (fun state ->
            lower_stages true state rest)
    | DropRightBytes n :: rest ->
        apply_drop_right fresh state n (fun state ->
            lower_stages true state rest)
    | SubstringBytes { start; len } :: rest ->
        apply_substring fresh state start len (fun state ->
            lower_stages true state rest)
    | TrimLeftBytes :: rest -> (
        match
          apply_trim_left fresh state (fun state ->
              lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimRightBytes :: rest -> (
        match
          apply_trim_right fresh state (fun state ->
              lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimBytes :: rest -> (
        match
          apply_trim fresh state (fun state -> lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
  in
  let source_name = fresh "source" in
  let source = var source_name ty_string in
  try
    Some
      (bind_source_alias source_name pipeline.source
         (lower_stages false
            (SourceWindow { source; start = lit_int 0; len = string_len source })
            pipeline.stages))
  with Exit -> None

let lower_materialized_window (pipeline : string_pipeline) =
  let counter = ref 0 in
  let fresh prefix =
    incr counter;
    Printf.sprintf "__sp_%s_%d" prefix !counter
  in
  let rec lower_stages saw_window_stage state = function
    | [] when saw_window_stage -> (
        match state with
        | SourceWindow window -> materialize_window fresh window
        | LengthOnly _ -> raise Exit)
    | [] -> raise Exit
    | ReverseBytes :: _ | ReplaceBytes _ :: _ -> raise Exit
    | TakeLeftBytes n :: rest ->
        apply_take_left fresh state n (fun state ->
            lower_stages true state rest)
    | DropLeftBytes n :: rest ->
        apply_drop_left fresh state n (fun state ->
            lower_stages true state rest)
    | TakeRightBytes n :: rest ->
        apply_take_right fresh state n (fun state ->
            lower_stages true state rest)
    | DropRightBytes n :: rest ->
        apply_drop_right fresh state n (fun state ->
            lower_stages true state rest)
    | SubstringBytes { start; len } :: rest ->
        apply_substring fresh state start len (fun state ->
            lower_stages true state rest)
    | TrimLeftBytes :: rest -> (
        match
          apply_trim_left fresh state (fun state ->
              lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimRightBytes :: rest -> (
        match
          apply_trim_right fresh state (fun state ->
              lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
    | TrimBytes :: rest -> (
        match
          apply_trim fresh state (fun state -> lower_stages true state rest)
        with
        | Some lowered -> lowered
        | None -> raise Exit)
  in
  let source_name = fresh "source" in
  let source = var source_name ty_string in
  try
    Some
      (bind_source_alias source_name pipeline.source
         (lower_stages false
            (SourceWindow { source; start = lit_int 0; len = string_len source })
            pipeline.stages))
  with Exit -> None

let try_fuse_length e =
  match call_base_and_args e with
  | Some ("length", [ source ])
    when is_string_type source.ty && is_int_value_type e.ty -> (
      match pipeline_of_expr source with
      | Some pipeline -> lower_length pipeline
      | None -> None)
  | _ -> None

let try_fuse_materialization e =
  if not (is_string_type e.ty) then None
  else
    match pipeline_of_expr e with
    | Some p -> (
        match lower_materialized_replace p with
        | Some _ as fused -> fused
        | None -> (
            match lower_materialized_reverse p with
            | Some _ as fused -> fused
            | None -> lower_materialized_window p))
    | None -> None

let rec fuse_expr e =
  match try_fuse_length e with
  | Some fused -> fused
  | None -> (
      match try_fuse_materialization e with
      | Some fused -> fused
      | None -> (
          let e = map_children fuse_expr e in
          match try_fuse_length e with
          | Some fused -> fused
          | None -> (
              match try_fuse_materialization e with
              | Some fused -> fused
              | None -> e)))

let fuse_func f = { f with cf_body = Option.map fuse_expr f.cf_body }

let rec fuse_decl d =
  let desc =
    match d.cd_desc with
    | CDFunc f -> CDFunc (fuse_func f)
    | CDVar v -> CDVar { v with cv_init = fuse_expr v.cv_init }
    | CDImpl impl ->
        CDImpl { impl with ci_methods = List.map fuse_func impl.ci_methods }
    | CDPrivate inner -> CDPrivate (fuse_decl inner)
    | other -> other
  in
  { d with cd_desc = desc }

let fuse_program ?reg:_ prog = List.map fuse_decl prog
