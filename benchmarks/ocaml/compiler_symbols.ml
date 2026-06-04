(* Compiler-shaped symbol lookup benchmark.
   Models immutable nested scopes, shadowing, and repeated failed/successful
   walks through parent links. *)

module StringMap = Map.Make (String)

type scope = { parent : int; symbols : int StringMap.t }

let symbol_name scope_id slot = "s" ^ string_of_int scope_id ^ "_" ^ string_of_int slot

let make_scope scope_id parent names_per_scope =
  let symbols = ref StringMap.empty in
  for slot = 0 to names_per_scope - 1 do
    symbols := StringMap.add (symbol_name scope_id slot) ((scope_id * 1009) + slot) !symbols
  done;
  { parent; symbols = !symbols }

let build_scopes count names_per_scope =
  Array.init count (fun scope_id -> make_scope scope_id (scope_id - 1) names_per_scope)

let lookup_symbol scopes start_scope name =
  let scope_id = ref start_scope in
  let found = ref (-1) in
  let done_ = ref false in
  while (not !done_) && !scope_id >= 0 do
    if !scope_id >= Array.length scopes then done_ := true
    else
      let scope = scopes.(!scope_id) in
      match StringMap.find_opt name scope.symbols with
      | Some value ->
          found := value;
          done_ := true
      | None -> scope_id := scope.parent
  done;
  !found

let run_symbol_pass scopes scope_count names_per_scope rounds =
  let checksum = ref 0 in
  for round = 0 to rounds - 1 do
    for start_scope = 0 to scope_count - 1 do
      let local_slot = (start_scope + round) mod names_per_scope in
      let parent_scope = if start_scope > 12 then start_scope - 12 else 0 in
      let parent_slot = ((round * 7) + start_scope) mod names_per_scope in
      let missing_slot = names_per_scope + ((round + start_scope) mod names_per_scope) in
      let local_name = symbol_name start_scope local_slot in
      let parent_name = symbol_name parent_scope parent_slot in
      let missing_name = symbol_name (start_scope + scope_count + 1) missing_slot in
      checksum := !checksum + lookup_symbol scopes start_scope local_name;
      checksum := !checksum + lookup_symbol scopes start_scope parent_name;
      checksum := !checksum + lookup_symbol scopes start_scope missing_name
    done
  done;
  !checksum

let () =
  let scope_count = 220 in
  let names_per_scope = 36 in
  let scopes = build_scopes scope_count names_per_scope in
  let checksum = run_symbol_pass scopes scope_count names_per_scope 12 in
  Printf.printf "compiler_symbols checksum: %d\n" checksum
