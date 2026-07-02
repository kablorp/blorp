type collected_comment = {
  cc_text : string;
  cc_line : int;
  cc_col : int;
  cc_trailing : bool;
}

let comment_store : collected_comment list ref = ref []
let reset () = comment_store := []
let get () = List.rev !comment_store
let restore comments = comment_store := List.rev comments
let add comment = comment_store := comment :: !comment_store
