(** Core-level ownership contracts for calls.

    This module records the ownership ABI we know for intrinsics and selected
    runtime builtins. Perceus and its symbolic balance checker consume these
    contracts so known borrowed arguments do not get modeled as owned
    consumption, while COW-consuming and transfer arguments still do. *)

type arg_mode =
  | Borrow  (** Callee may read the value. Caller keeps ownership. *)
  | Retain
      (** Callee may retain/store the value, but caller keeps ownership. *)
  | Consume
      (** Callee takes ownership and is responsible for releasing or returning it. *)
  | CowConsume
      (** Callee consumes the owner and may reuse/mutate in place when unique,
          or copy/release when shared. *)
  | Transfer
      (** Callee takes ownership of a freshly-owned value without retaining. *)

type result_mode =
  | ReturnVoid
  | ReturnPrimitive
  | ReturnOwned
  | ReturnBorrowed
  | ReturnAliasOfArg of int

type call_contract = { args : arg_mode list; result : result_mode }

type contract_violation =
  | Alias_index_out_of_range of { index : int; arg_count : int }
  | Alias_of_consumed_arg of { index : int; mode : arg_mode }
  | Borrowed_result_without_preserved_arg

type receiver_strategy =
  | BorrowReceiver  (** Operation only reads the source collection. *)
  | CowConsumeReceiver
      (** Operation consumes the source collection and may reuse it through a
          COW boundary or COW-consuming runtime mutator. *)

type result_collection_strategy =
  | NoCollectionResult  (** Operation does not produce a collection result. *)
  | ReuseReceiver of { cow_boundary : string; reserve_for_len : string option }
      (** Result is the receiver after the named COW/reuse boundary or
          COW-consuming runtime mutator. [reserve_for_len], when present, is a
          post-COW capacity reservation boundary that accepts the result and an
          expected final element count. *)
  | AllocateFresh of {
      alloc : string;
      growth : string option;
      reserve_for_len : string option;
    }
      (** Result is a fresh collection. [growth] is present when the fresh
          result may need dynamic capacity growth during the operation.
          [reserve_for_len], when present, reserves once from a known upper
          bound before insertion begins. *)

type element_storage_strategy =
  | NoElementStorage
  | RetainInputElement
      (** A caller-owned input element is retained before storage. *)
  | RetainBorrowedElement
      (** A borrowed element from an existing collection is retained before
          transfer into result storage. *)
  | RetainInputAndBorrowedElements
      (** The result stores both caller-owned input elements and borrowed
          elements from an existing collection, retaining each before storage. *)
  | TransferProducedElement
      (** A newly-produced owned element is transferred into result storage. *)

type collection_strategy = {
  receiver : receiver_strategy;
  result_collection : result_collection_strategy;
  element_storage : element_storage_strategy;
}

let borrow_all n = List.init n (fun _ -> Borrow)

let arg_consumes_caller = function
  | Borrow | Retain -> false
  | Consume | CowConsume | Transfer -> true

let arg_preserves_caller mode = not (arg_consumes_caller mode)
let arg_allows_borrowed_result_alias = arg_preserves_caller

let string_of_arg_mode = function
  | Borrow -> "Borrow"
  | Retain -> "Retain"
  | Consume -> "Consume"
  | CowConsume -> "CowConsume"
  | Transfer -> "Transfer"

let string_of_contract_violation = function
  | Alias_index_out_of_range { index; arg_count } ->
      Printf.sprintf "ReturnAliasOfArg %d is outside the contract arity %d"
        index arg_count
  | Alias_of_consumed_arg { index; mode } ->
      Printf.sprintf
        "ReturnAliasOfArg %d points at %s, which does not preserve caller \
         ownership"
        index (string_of_arg_mode mode)
  | Borrowed_result_without_preserved_arg ->
      "ReturnBorrowed has no Borrow/Retain argument to anchor its lifetime"

let validate_contract (contract : call_contract) =
  match contract.result with
  | ReturnAliasOfArg index ->
      let arg_count = List.length contract.args in
      if index < 0 || index >= arg_count then
        [ Alias_index_out_of_range { index; arg_count } ]
      else
        let mode = List.nth contract.args index in
        if arg_allows_borrowed_result_alias mode then []
        else [ Alias_of_consumed_arg { index; mode } ]
  | ReturnBorrowed ->
      if List.exists arg_allows_borrowed_result_alias contract.args then []
      else [ Borrowed_result_without_preserved_arg ]
  | ReturnVoid | ReturnPrimitive | ReturnOwned -> []

let contract args result =
  let contract = { args; result } in
  match validate_contract contract with
  | [] -> contract
  | violations ->
      invalid_arg
        (Printf.sprintf "invalid ownership contract: %s"
           (String.concat "; "
              (List.map string_of_contract_violation violations)))

let fixed arity args result =
  if List.length args = arity then Some (contract args result) else None

let variadic min_arity arg_at result arity =
  if arity < min_arity then None
  else Some (contract (List.init arity arg_at) result)

let strategy receiver result_collection element_storage =
  { receiver; result_collection; element_storage }

let reuse_receiver ?reserve_for_len cow_boundary element_storage =
  strategy CowConsumeReceiver
    (ReuseReceiver { cow_boundary; reserve_for_len })
    element_storage

let allocate_fresh ?growth ?reserve_for_len alloc element_storage =
  strategy BorrowReceiver
    (AllocateFresh { alloc; growth; reserve_for_len })
    element_storage

let no_collection_result =
  strategy BorrowReceiver NoCollectionResult NoElementStorage

let collection_strategy ~(module_path : string) ~(func_name : string) =
  match (module_path, func_name) with
  | "std/list", ("append" | "__unsafe_list_append" | "__unsafe_list_insert") ->
      Some (reuse_receiver "list_ensure_capacity" RetainInputElement)
  | "std/list", ("set" | "__unsafe_list_set_index") ->
      Some (reuse_receiver "list_ensure_unique" RetainInputElement)
  | ( "std/list",
      ( "__unsafe_list_remove" | "__unsafe_list_tail" | "reverse"
      | "__unsafe_list_reverse" | "__unsafe_list_swap" ) ) ->
      Some (reuse_receiver "list_ensure_unique" NoElementStorage)
  | ( "std/list",
      ( "map" | "map_indexed" | "enumerate" | "zip" | "zip_with" | "filter_map"
      | "scan" | "windows" | "chunks" ) ) ->
      Some (allocate_fresh "list_alloc" TransferProducedElement)
  | ( "std/list",
      ( "filter" | "take_while" | "drop_while" | "partition" | "unzip" | "sort"
      | "sort_by" | "sort_desc_by" | "concat" | "take" | "drop" | "flatten"
      | "unique" ) ) ->
      Some (allocate_fresh "list_alloc" RetainBorrowedElement)
  | "std/list", "repeat" ->
      Some (allocate_fresh "list_alloc" RetainInputElement)
  | "std/list", "intersperse" ->
      Some (allocate_fresh "list_alloc" RetainInputAndBorrowedElements)
  | "std/list", "range" ->
      Some (allocate_fresh "list_alloc" TransferProducedElement)
  | "std/list", "flat_map" ->
      Some
        (allocate_fresh ~growth:"list_ensure_capacity" "list_alloc"
           RetainBorrowedElement)
  | ( "std/list",
      ( "fold_left" | "fold_right" | "all" | "any" | "for_each" | "find_index"
      | "find" | "min_by" | "max_by" | "count" | "get_or" | "length" ) ) ->
      Some no_collection_result
  | "std/set", "add" -> Some (reuse_receiver "set_cow" RetainInputElement)
  | "std/set", "remove" ->
      Some (reuse_receiver "blorp_set_remove" NoElementStorage)
  | "std/set", "combine" ->
      Some
        (reuse_receiver ~reserve_for_len:"set_reserve_for_len" "set_cow"
           RetainBorrowedElement)
  | "std/set", ("intersect" | "difference" | "filter") ->
      Some
        (allocate_fresh ~reserve_for_len:"set_reserve_for_len" "blorp_set_new"
           RetainBorrowedElement)
  | "std/set", "map" ->
      Some
        (allocate_fresh ~reserve_for_len:"set_reserve_for_len" "blorp_set_new"
           TransferProducedElement)
  | "std/set", ("contains" | "fold" | "length" | "is_subset") ->
      Some no_collection_result
  | "std/set", "to_list" ->
      Some (allocate_fresh "list_alloc" RetainBorrowedElement)
  | "std/dict", "set" -> Some (reuse_receiver "dict_cow" RetainInputElement)
  | "std/dict", "remove" ->
      Some (reuse_receiver "blorp_dict_remove" NoElementStorage)
  | "std/dict", ("keys" | "values") ->
      Some (allocate_fresh "list_alloc" RetainBorrowedElement)
  | "std/dict", "entries" ->
      Some (allocate_fresh "list_alloc" TransferProducedElement)
  | "std/dict", ("get" | "get_or" | "contains" | "length") ->
      Some no_collection_result
  | _ -> None

let intrinsic_contract name arity =
  let borrowed n result = fixed arity (borrow_all n) result in
  match name with
  (* List structural reads. [list_get] returns an alias to storage owned by arg0. *)
  | "elem_release_fn" -> fixed arity [] ReturnPrimitive
  | "list_len" | "list_capacity" -> fixed arity [ Borrow ] ReturnPrimitive
  | "list_get" | "list_get_unchecked" ->
      fixed arity [ Borrow; Borrow ] (ReturnAliasOfArg 0)
  (* List mutation helpers operate on an already-owned/unique list. *)
  | "list_set" -> fixed arity [ Borrow; Borrow; Borrow ] ReturnVoid
  | "list_set_owned" -> fixed arity [ Borrow; Borrow; Transfer ] ReturnVoid
  | "list_handoff_set_owned" ->
      fixed arity [ Borrow; Borrow; Transfer ] ReturnVoid
  | "list_handoff_set_source_slot" ->
      fixed arity [ Borrow; Borrow; Borrow; Borrow ] ReturnVoid
  | "list_copy_span_uninit" ->
      fixed arity [ Borrow; Borrow; Borrow; Borrow; Borrow ] ReturnVoid
  | "list_swap_slots" -> fixed arity [ Borrow; Borrow; Borrow ] ReturnVoid
  | "list_set_len" | "list_release_elem" | "list_set_elem_release" ->
      fixed arity [ Borrow; Borrow ] ReturnVoid
  | "list_retain_for" -> fixed arity [ Borrow; Retain ] ReturnVoid
  (* List allocation and COW. *)
  | "list_alloc" -> fixed arity [ Borrow ] ReturnOwned
  | "list_ensure_unique" -> fixed arity [ CowConsume ] ReturnOwned
  | "list_ensure_capacity" -> fixed arity [ CowConsume; Borrow ] ReturnOwned
  | "list_reuse_alloc" -> fixed arity [ CowConsume; Borrow ] ReturnOwned
  | "list_reverse_owned" -> fixed arity [ CowConsume ] ReturnOwned
  (* String structural reads. *)
  | "string_len" -> fixed arity [ Borrow ] ReturnPrimitive
  | "string_get_byte" -> fixed arity [ Borrow; Borrow ] ReturnPrimitive
  | "string_find_byte_from" ->
      fixed arity [ Borrow; Borrow; Borrow ] ReturnPrimitive
  | "string_alloc" -> fixed arity [ Borrow ] ReturnOwned
  | "string_set_byte" -> fixed arity [ Borrow; Borrow; Borrow ] ReturnVoid
  | "string_copy_bytes" ->
      fixed arity [ Borrow; Borrow; Borrow; Borrow; Borrow ] ReturnVoid
  | "string_set_len" -> fixed arity [ Borrow; Borrow ] ReturnVoid
  | "string_ensure_unique" -> fixed arity [ CowConsume ] ReturnOwned
  | "string_ensure_capacity" -> fixed arity [ CowConsume; Borrow ] ReturnOwned
  (* Bytes. *)
  | "bytes_len" -> borrowed 1 ReturnPrimitive
  | "bytes_get" -> borrowed 2 ReturnPrimitive
  | "bytes_set" -> borrowed 3 ReturnVoid
  | "bytes_set_len" -> borrowed 2 ReturnVoid
  | "bytes_alloc" -> borrowed 1 ReturnOwned
  | "bytes_cow" -> fixed arity [ CowConsume ] ReturnOwned
  (* Dict structural reads. Key/value slot reads return aliases to storage
     owned by the dict. Release-function reads return raw function pointers. *)
  | "dict_len" | "dict_capacity" | "dict_mask" | "dict_grow_at"
  | "dict_order_len" | "dict_key_release_fn" | "dict_value_release_fn" ->
      borrowed 1 ReturnPrimitive
  | "dict_key_at" | "dict_value_at" ->
      fixed arity [ Borrow; Borrow ] (ReturnAliasOfArg 0)
  | "dict_meta_get" | "dict_order_get" | "dict_order_index_get" ->
      borrowed 2 ReturnPrimitive
  | "dict_hash" -> borrowed 2 ReturnPrimitive
  | "dict_eq" -> borrowed 3 ReturnPrimitive
  | "dict_hash_immediate" -> borrowed 1 ReturnPrimitive
  | "dict_eq_immediate" -> borrowed 2 ReturnPrimitive
  (* Dict mutation helpers operate on an already-owned/unique dict. *)
  | "dict_retain_key_for" | "dict_retain_value_for" ->
      fixed arity [ Borrow; Retain ] ReturnVoid
  | "dict_release_value_for" -> borrowed 2 ReturnVoid
  | "dict_set_key_at" -> fixed arity [ Borrow; Borrow; Transfer ] ReturnVoid
  | "dict_set_value_at" -> fixed arity [ Borrow; Borrow; Transfer ] ReturnVoid
  | "dict_meta_set" | "dict_order_set" | "dict_order_index_set" ->
      borrowed 3 ReturnVoid
  | "dict_set_len" | "dict_set_order_len" | "dict_resize" ->
      borrowed 2 ReturnVoid
  | "dict_alloc" -> borrowed 1 ReturnOwned
  | "dict_cow" -> fixed arity [ CowConsume ] ReturnOwned
  | "dict_reuse_alloc" -> fixed arity [ CowConsume; Borrow ] ReturnOwned
  (* Set structural reads. Entry and bucket reads are borrowed aliases. *)
  | "set_len" | "set_capacity" | "set_mask" -> borrowed 1 ReturnPrimitive
  | "set_bucket" -> fixed arity [ Borrow; Borrow ] (ReturnAliasOfArg 0)
  | "set_first" | "set_last" | "set_entry_key" | "set_entry_next"
  | "set_entry_prev_order" | "set_entry_next_order" ->
      fixed arity [ Borrow ] (ReturnAliasOfArg 0)
  | "set_hash" -> borrowed 2 ReturnPrimitive
  | "set_eq" -> borrowed 3 ReturnPrimitive
  | "set_hash_immediate" -> borrowed 1 ReturnPrimitive
  | "set_eq_immediate" -> borrowed 2 ReturnPrimitive
  | "set_contains" -> borrowed 2 ReturnPrimitive
  (* Set mutation helpers operate on an already-owned/unique set. *)
  | "set_retain_key_for" -> fixed arity [ Borrow; Retain ] ReturnVoid
  | "set_set_bucket" -> borrowed 3 ReturnVoid
  | "set_entry_set_next" | "set_entry_set_prev_order"
  | "set_entry_set_next_order" ->
      borrowed 2 ReturnVoid
  | "set_set_first" | "set_set_last" | "set_set_len" | "set_resize" ->
      borrowed 2 ReturnVoid
  | "set_reserve_for_len" -> borrowed 2 ReturnVoid
  | "set_alloc" -> borrowed 1 ReturnOwned
  | "set_alloc_entry" -> fixed arity [ Transfer ] ReturnOwned
  | "set_free_entry" -> fixed arity [ Borrow; Transfer ] ReturnVoid
  | "set_cow" -> fixed arity [ CowConsume ] ReturnOwned
  | "set_reuse_alloc" -> fixed arity [ CowConsume; Borrow ] ReturnOwned
  (* StringSlice. [slice_source] aliases the source retained by the slice;
     [slice_alloc] retains the source internally and returns an owned slice. *)
  | "slice_source" -> fixed arity [ Borrow ] (ReturnAliasOfArg 0)
  | "slice_start" | "slice_len" -> borrowed 1 ReturnPrimitive
  | "slice_alloc" -> borrowed 3 ReturnOwned
  (* Tensor and fixed-value primitives. Tensor element reads are primitive
     except the raw unchecked pointer read, which aliases tensor storage. *)
  | "tensor_len" | "tensor_capacity" | "tensor_is_word_storage"
  | "tensor_is_f64_storage" | "tensor_is_f32_storage" | "tensor_is_i64_storage"
  | "tensor_is_unique" ->
      borrowed 1 ReturnPrimitive
  | "tensor_stride" -> borrowed 2 ReturnPrimitive
  | "tensor_get_unchecked" ->
      fixed arity [ Borrow; Borrow ] (ReturnAliasOfArg 0)
  | "tensor_get_f64" | "tensor_get_f32" | "tensor_get_f16" | "tensor_get_i64" ->
      borrowed 2 ReturnPrimitive
  | "tensor_get_i64_word_unchecked" | "tensor_get_i64_raw_unchecked"
  | "tensor_get_f64_raw_unchecked" | "tensor_get_f32_raw_unchecked" ->
      borrowed 2 ReturnPrimitive
  | "tensor_set_f64" | "tensor_set_f32" | "tensor_set_f16" | "tensor_set_i64" ->
      borrowed 3 ReturnVoid
  | "tensor_alloc" -> borrowed 1 ReturnOwned
  | "fixed_value" | "fixed_scale" | "fixed_precision" | "fixed_pow10" ->
      borrowed 1 ReturnPrimitive
  | "fixed_alloc" -> borrowed 3 ReturnOwned
  (* Scalar math/bitwise intrinsics operate only on immediate primitive values.
     They still get explicit contracts so CKIntrinsic never falls back to
     generic ownership behavior. *)
  | "math_infinity" | "math_neg_infinity" | "math_nan" ->
      borrowed 0 ReturnPrimitive
  | "math_sin" | "math_cos" | "math_tan" | "math_asin" | "math_acos"
  | "math_atan" | "math_sinh" | "math_cosh" | "math_tanh" | "math_asinh"
  | "math_acosh" | "math_atanh" | "math_exp" | "math_exp2" | "math_expm1"
  | "math_log" | "math_log2" | "math_log10" | "math_log1p" | "math_sqrt"
  | "math_cbrt" | "math_floor" | "math_ceil" | "math_round"
  | "math_trunc" | "math_is_nan" | "math_is_inf" | "math_is_finite"
  | "bit_not" ->
      borrowed 1 ReturnPrimitive
  | "math_pow" | "math_atan2" | "math_hypot" | "math_fmod" | "math_copysign"
  | "bit_and" | "bit_or" | "bit_xor" | "shift_left" | "shift_right" ->
      borrowed 2 ReturnPrimitive
  | "math_fma" -> borrowed 3 ReturnPrimitive
  | _ -> None

type builtin_contract_spec =
  | Builtin_fixed of arg_mode list * result_mode
  | Builtin_cases of (arg_mode list * result_mode) list
  | Builtin_variadic of {
      min_arity : int;
      arg_at : int -> arg_mode;
      result : result_mode;
    }

type builtin_contract_entry = {
  builtin_name : string;
  builtin_spec : builtin_contract_spec;
  builtin_void_boxed_args : int list;
}

type builtin_ownership_coverage =
  | Covered_by_contract
  | Pre_perceus_sentinel of string

let normalize_positions positions = List.sort_uniq Int.compare positions

let builtin_contract_spec_sample_arities = function
  | Builtin_fixed (args, _) -> [ List.length args ]
  | Builtin_cases cases ->
      cases
      |> List.map (fun (args, _) -> List.length args)
      |> List.sort_uniq compare
  | Builtin_variadic { min_arity; _ } -> [ min_arity; min_arity + 3 ]

let builtin_contract_spec_has_arg_position builtin_spec position =
  position >= 0
  &&
  match builtin_spec with
  | Builtin_variadic _ -> true
  | _ ->
      builtin_contract_spec_sample_arities builtin_spec
      |> List.exists (fun arity -> arity > position)

let validate_void_boxed_args ~name builtin_spec positions =
  let positions = normalize_positions positions in
  let negative_positions = List.filter (fun pos -> pos < 0) positions in
  if negative_positions <> [] then
    invalid_arg
      (Printf.sprintf "%s has negative void* ABI arg positions: %s" name
         (String.concat ", " (List.map string_of_int negative_positions)));
  (match positions with
  | [] -> ()
  | _ ->
      let max_position = List.fold_left max 0 positions in
      if not (builtin_contract_spec_has_arg_position builtin_spec max_position)
      then
        invalid_arg
          (Printf.sprintf
             "%s has void* ABI arg positions through %d, but no ownership \
              contract arity includes that argument"
             name max_position));
  positions

let builtin ?(void_boxed_args = []) name builtin_spec =
  {
    builtin_name = name;
    builtin_spec;
    builtin_void_boxed_args =
      validate_void_boxed_args ~name builtin_spec void_boxed_args;
  }

let builtins ?void_boxed_args names builtin_spec =
  List.map (fun name -> builtin ?void_boxed_args name builtin_spec) names

let bfixed args result = Builtin_fixed (args, result)
let bcases cases = Builtin_cases cases

let bvariadic min_arity arg_at result =
  Builtin_variadic { min_arity; arg_at; result }

let arg_mode_of_runtime_ownership = function
  | Operation_result_metadata.ArgBorrow -> Borrow
  | Operation_result_metadata.ArgRetain -> Retain
  | Operation_result_metadata.ArgConsume -> Consume
  | Operation_result_metadata.ArgCowConsume -> CowConsume
  | Operation_result_metadata.ArgTransfer -> Transfer

let operation_result_bridge_builtin_contracts =
  Operation_result_metadata.result_bridges
  |> List.map (fun (bridge : Operation_result_metadata.result_bridge) ->
      builtin bridge.Operation_result_metadata.builtin_name
        (bfixed
           (List.map arg_mode_of_runtime_ownership bridge.arguments)
           ReturnOwned))

let fallible_stream_source_builtin_contracts =
  Operation_result_metadata.fallible_stream_sources
  |> List.map
       (fun (source : Operation_result_metadata.fallible_stream_source) ->
         builtin source.Operation_result_metadata.builtin_name
           (bfixed
              (List.map arg_mode_of_runtime_ownership source.arguments)
              ReturnOwned))

let fallible_stream_terminal_builtin_contracts =
  Operation_result_metadata.fallible_stream_terminals
  |> List.map
       (fun (terminal : Operation_result_metadata.fallible_stream_terminal) ->
         builtin ~void_boxed_args:terminal.void_boxed_args terminal.builtin_name
           (bfixed
              (List.map arg_mode_of_runtime_ownership terminal.arguments)
              ReturnOwned))

let channel_stack_option_suffixes =
  [
    "int";
    "int8";
    "int16";
    "int32";
    "int64";
    "uint8";
    "uint16";
    "uint32";
    "uint64";
    "float";
    "bool";
    "char";
    "f32";
    "f16";
  ]

let channel_recv_stack_option_builtins base =
  List.map (Printf.sprintf "%s_%s" base) channel_stack_option_suffixes

let builtin_contract_table =
  List.concat
    [
      (* Option/Result wrappers take ownership of their payload when present. *)
      builtins ~void_boxed_args:[ 0 ]
        [ "blorp_option_some"; "blorp_result_ok"; "blorp_result_err" ]
        (bfixed [ Transfer ] ReturnOwned);
      builtins [ "blorp_option_none" ] (bfixed [] ReturnOwned);
      builtins
        [ "__blorp_option_eq_layout" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_option_div_int"; "blorp_option_mod_int" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      (* Scalar math calls operate only on immediate primitive values. Some
         source-level std/float builtins intentionally remain direct C
         passthroughs at Final, so they need ordinary builtin contracts in
         addition to the IR intrinsic math contracts above. *)
      builtins
        [
          "sqrt";
          "sin";
          "cos";
          "tan";
          "floor";
          "ceil";
          "asin";
          "acos";
          "atan";
          "sinh";
          "cosh";
          "tanh";
          "asinh";
          "acosh";
          "atanh";
          "exp";
          "exp2";
          "log";
          "log2";
          "log10";
          "log1p";
          "expm1";
          "cbrt";
          "trunc";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [ "pow"; "atan2"; "hypot"; "fmod"; "copysign" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins [ "fma" ] (bfixed [ Borrow; Borrow; Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_abs";
          "blorp_float_abs";
          "blorp_round";
          "blorp_is_nan";
          "blorp_is_inf";
          "blorp_is_finite";
          "blorp_black_box_int";
          "blorp_black_box_float";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_min"; "blorp_max"; "blorp_float_min"; "blorp_float_max" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_infinity"; "blorp_neg_infinity"; "blorp_nan_value" ]
        (bfixed [] ReturnPrimitive);
      (* OS-boundary helpers borrow caller-owned Blorp values. The runtime may
         copy them into C strings, but it does not take ownership of the source
         String/List/Bytes objects. *)
      builtins
        [ "blorp_read_file"; "blorp_read_bytes" ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_read_all"; "blorp_read_line"; "blorp_read_line_or_empty" ]
        (bfixed [] ReturnOwned);
      builtins
        [ "blorp_input"; "blorp_input_or_empty" ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_write_file"; "blorp_write_bytes" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_read_all_lines" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_append_file" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins [ "blorp_for_each_line" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_for_each_chunk" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_file_exists";
          "blorp_is_directory";
          "blorp_mkdir";
          "blorp_remove_file";
          "blorp_remove_dir";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins [ "blorp_rename" ] (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_file_writer_path"; "blorp_directory_path" ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_file_size"; "blorp_file_modified"; "blorp_mkstemp_path" ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [
          "blorp_getcwd";
          "blorp_temp_dir";
          "blorp_compiler_runtime_source";
          "blorp_compiler_runtime_decl";
        ]
        (bfixed [] ReturnOwned);
      builtins
        [ "blorp_process_run"; "blorp_process_run_inherit" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_process_run_command_raw" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_process_shell" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_exec" ] (bfixed [ Borrow ] ReturnPrimitive);
      builtins [ "blorp_exec_output" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_setenv" ] (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_signal_hangup";
          "blorp_signal_interrupt";
          "blorp_signal_terminate";
          "blorp_signal_user1";
          "blorp_signal_user2";
        ]
        (bfixed [] ReturnPrimitive);
      builtins [ "blorp_signal_on" ] (bfixed [ Borrow; Retain ] ReturnVoid);
      builtins [ "blorp_signal_received" ] (bfixed [ Borrow ] ReturnPrimitive);
      builtins [ "blorp_signal_raise" ] (bfixed [ Borrow ] ReturnVoid);
      builtins [ "blorp_seed_random" ] (bfixed [ Borrow ] ReturnVoid);
      builtins [ "blorp_random_int" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins [ "blorp_random_float" ] (bfixed [] ReturnPrimitive);
      builtins [ "blorp_crypto_random_bytes" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_sleep" ] (bfixed [ Borrow ] ReturnVoid);
      builtins [ "blorp_yield_now" ] (bfixed [] ReturnVoid);
      builtins [ "blorp_now_us"; "blorp_time_now" ] (bfixed [] ReturnPrimitive);
      builtins
        [
          "blorp_time_to_year";
          "blorp_time_to_month";
          "blorp_time_to_day";
          "blorp_time_to_hour";
          "blorp_time_to_minute";
          "blorp_time_to_second";
          "blorp_time_to_weekday";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_time_from_parts" ]
        (bfixed
           [ Borrow; Borrow; Borrow; Borrow; Borrow; Borrow ]
           ReturnPrimitive);
      builtins [ "blorp_time_format" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_time_parse" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_time_from_iso"; "blorp_time_parse_rfc3339" ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins [ "blorp_get_mem_stats" ] (bfixed [] ReturnOwned);
      builtins
        [ "blorp_reset_mem_stats"; "blorp_print_live_object_summary" ]
        (bfixed [] ReturnVoid);
      builtins
        [
          "blorp_debug_log_msg";
          "blorp_debug_info";
          "blorp_debug_warn";
          "blorp_debug_error";
        ]
        (bfixed [ Borrow ] ReturnVoid);
      builtins
        [
          "blorp_hash";
          "blorp_hash_int";
          "blorp_hash_string";
          "blorp_hash_float";
          "blorp_hash_bytes";
          "blorp_crc32";
          "blorp_crc32_bytes";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins [ "blorp_hash_combine" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_sha256";
          "blorp_md5";
          "blorp_sha1";
          "blorp_sha512";
          "blorp_sha256_bytes";
          "blorp_md5_bytes";
          "blorp_sha1_bytes";
          "blorp_sha512_bytes";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_hmac_sha256" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_regex_test"; "blorp_regex_find"; "blorp_regex_find_all" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_regex_replace_all" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      (* List runtime functions that consume/reuse the list owner. *)
      builtins [ "blorp_list_new" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_channel_new" ] (bfixed [ Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ] [ "blorp_list_append" ]
        (bfixed [ CowConsume; Retain ] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_list_append_owned" ]
        (bfixed [ CowConsume; Transfer ] ReturnOwned);
      builtins
        [
          "blorp_list_to_string_bool";
          "blorp_list_to_string_cb";
          "blorp_list_to_string_float";
          "blorp_list_to_string_float16";
          "blorp_list_to_string_float32";
          "blorp_list_to_string_int";
          "blorp_list_to_string_string";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      (* Channel operations borrow the channel owner. Send operations retain
         stored values when the channel element metadata requires ARC; receive
         operations transfer a fresh Option wrapper or stack option result to
         the caller. *)
      builtins ~void_boxed_args:[ 1 ]
        [
          "blorp_channel_send";
          "blorp_channel_try_send";
          "blorp_channel_try_send_status";
        ]
        (bfixed [ Borrow; Retain ] ReturnPrimitive);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_channel_try_send_attempt" ]
        (bfixed [ Borrow; Retain ] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_channel_send_timeout"; "blorp_channel_send_timeout_status" ]
        (bfixed [ Borrow; Retain; Borrow ] ReturnPrimitive);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_channel_send_timeout_attempt" ]
        (bfixed [ Borrow; Retain; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_channel_recv";
          "blorp_channel_try_recv";
          "blorp_channel_recv_nullable";
          "blorp_channel_try_recv_nullable";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_channel_recv_timeout"; "blorp_channel_recv_timeout_nullable" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_channel_try_recv_attempt" ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_channel_recv_timeout_attempt" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        (channel_recv_stack_option_builtins "blorp_channel_recv"
        @ channel_recv_stack_option_builtins "blorp_channel_try_recv")
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        (channel_recv_stack_option_builtins "blorp_channel_recv_timeout")
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins [ "blorp_channel_seal" ] (bfixed [ Borrow ] ReturnVoid);
      builtins [ "blorp_get_scheduler_stats" ] (bfixed [] ReturnOwned);
      builtins [ "blorp_reset_scheduler_stats" ] (bfixed [] ReturnVoid);
      builtins
        [ "blorp_test_cancel_after_parked" ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_test_task_window_pending_cleanup_probe";
          "blorp_test_task_join_slot_probe";
          "blorp_test_fiber_created_schedule_probe";
          "blorp_test_timer_waiter_identity_probe";
          "blorp_test_wait_ready_to_park_probe";
          "blorp_test_fiber_lifecycle_ready_to_park_probe";
          "blorp_test_fiber_cancel_before_park_probe";
          "blorp_test_current_timer_wait_install_probe";
          "blorp_test_timeout_arithmetic_probe";
          "blorp_test_cooperative_checkpoint_probe";
        ]
        (bfixed [] ReturnPrimitive);
      builtins [ "blorp_test_tls_state_probe" ] (bfixed [] ReturnPrimitive);
      builtins
        [ "blorp_test_websocket_state_probe" ]
        (bfixed [] ReturnPrimitive);
      (* Dict runtime functions. Mutating operations consume the dict owner through
       COW; reads borrow and allocate owned result wrappers/lists as needed. *)
      builtins
        [ "blorp_dict_new"; "blorp_dict_new_string"; "blorp_dict_new_float" ]
        (bfixed [] ReturnOwned);
      builtins
        [
          "blorp_dict_with_capacity";
          "blorp_dict_with_capacity_string";
          "blorp_dict_with_capacity_float";
          "blorp_dict_with_capacity_custom";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_dict_new_custom" ] (bfixed [] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_dict_get"; "blorp_dict_get_nullable" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 1; 2 ] [ "blorp_dict_insert" ]
        (bfixed [ CowConsume; Retain; Retain ] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ] [ "blorp_dict_remove" ]
        (bfixed [ CowConsume; Borrow ] ReturnOwned);
      builtins [ "blorp_dict_entries" ] (bfixed [ Borrow ] ReturnOwned);
      (* Set runtime functions. *)
      builtins
        [ "blorp_set_new"; "blorp_set_new_string"; "blorp_set_new_float" ]
        (bfixed [] ReturnOwned);
      builtins [ "blorp_set_new_custom" ] (bfixed [] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ] [ "blorp_set_add" ]
        (bfixed [ CowConsume; Retain ] ReturnOwned);
      builtins ~void_boxed_args:[ 1 ] [ "blorp_set_remove" ]
        (bfixed [ CowConsume; Borrow ] ReturnOwned);
      builtins [ "blorp_map_parallel" ]
        (bcases
           [
             ([ Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins
        [ "blorp_map_parallel_with" ]
        (bcases
           [
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins
        [ "blorp_filter_parallel" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_filter_map_parallel";
          "blorp_filter_map_parallel_int";
          "blorp_filter_map_parallel_int8";
          "blorp_filter_map_parallel_int16";
          "blorp_filter_map_parallel_int32";
          "blorp_filter_map_parallel_int64";
          "blorp_filter_map_parallel_uint8";
          "blorp_filter_map_parallel_uint16";
          "blorp_filter_map_parallel_uint32";
          "blorp_filter_map_parallel_uint64";
          "blorp_filter_map_parallel_float";
          "blorp_filter_map_parallel_bool";
          "blorp_filter_map_parallel_char";
          "blorp_filter_map_parallel_f32";
          "blorp_filter_map_parallel_f16";
          "blorp_filter_map_parallel_nullable";
        ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_filter_parallel_with" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_zip_parallel" ]
        (bcases
           [
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins
        [ "blorp_zip_parallel_with" ]
        (bcases
           [
             ([ Borrow; Borrow; Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_fold_parallel"; "blorp_fold_parallel_ordered" ]
        (bcases
           [
             ([ Borrow; Consume; Borrow ], ReturnOwned);
             ([ Borrow; Consume; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins ~void_boxed_args:[ 1 ]
        [ "blorp_fold_parallel_with"; "blorp_fold_parallel_ordered_with" ]
        (bcases
           [
             ([ Borrow; Consume; Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Consume; Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins ~void_boxed_args:[ 1 ] [ "blorp_stream_fold" ]
        (bfixed [ Borrow; Consume; Borrow; Borrow ] ReturnOwned);
      (* Stream runtime functions. Source/intermediate stream constructors
         retain stored inputs and return a fresh stream owner. Terminal
         operations borrow the stream; callers remain responsible for dropping
         owned stream temporaries after the terminal call. *)
      builtins [ "blorp_stream_from_list" ] (bfixed [ Retain ] ReturnOwned);
      builtins
        [ "blorp_stream_from_range" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_stream_repeat" ] (bfixed [ Retain; Borrow ] ReturnOwned);
      builtins [ "blorp_stream_unfold" ]
        (bfixed [ Retain; Retain; Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_stream_empty" ] (bfixed [] ReturnOwned);
      builtins [ "blorp_stream_map" ]
        (bfixed [ Retain; Retain; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_stream_filter";
          "blorp_stream_filter_map";
          "blorp_stream_filter_map_int";
          "blorp_stream_filter_map_int8";
          "blorp_stream_filter_map_int16";
          "blorp_stream_filter_map_int32";
          "blorp_stream_filter_map_int64";
          "blorp_stream_filter_map_uint8";
          "blorp_stream_filter_map_uint16";
          "blorp_stream_filter_map_uint32";
          "blorp_stream_filter_map_uint64";
          "blorp_stream_filter_map_float";
          "blorp_stream_filter_map_bool";
          "blorp_stream_filter_map_char";
          "blorp_stream_filter_map_f32";
          "blorp_stream_filter_map_f16";
          "blorp_stream_filter_map_nullable";
          "blorp_stream_take_while";
        ]
        (bfixed [ Retain; Retain ] ReturnOwned);
      builtins
        [ "blorp_stream_take"; "blorp_stream_drop" ]
        (bfixed [ Retain; Borrow ] ReturnOwned);
      builtins [ "blorp_stream_enumerate" ] (bfixed [ Retain ] ReturnOwned);
      builtins [ "blorp_stream_collect" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_stream_count" ] (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_stream_for_each" ]
        (bfixed [ Borrow; Borrow ] ReturnVoid);
      builtins
        [ "blorp_stream_find"; "blorp_stream_find_nullable" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_stream_find_int";
          "blorp_stream_find_int8";
          "blorp_stream_find_int16";
          "blorp_stream_find_int32";
          "blorp_stream_find_int64";
          "blorp_stream_find_uint8";
          "blorp_stream_find_uint16";
          "blorp_stream_find_uint32";
          "blorp_stream_find_uint64";
          "blorp_stream_find_float";
          "blorp_stream_find_bool";
          "blorp_stream_find_char";
          "blorp_stream_find_f32";
          "blorp_stream_find_f16";
          "blorp_stream_any";
          "blorp_stream_all";
        ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      (* Fixed constructors allocate managed Fixed objects from primitive
         payloads. The numeric inputs are borrowed scalar values. *)
      builtins
        [ "blorp_fixed_new"; "blorp_fixed_from_int" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_fixed_to_string" ] (bfixed [ Borrow ] ReturnOwned);
      (* String concatenation variants. *)
      builtins
        [ "blorp_print"; "blorp_puts"; "blorp_print_error" ]
        (bfixed [ Borrow ] ReturnVoid);
      builtins [ "blorp_tcp_listen" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_tcp_accept" ] (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_tcp_connect" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_tcp_read" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_tcp_write" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_tcp_close_listener"; "blorp_tcp_close_stream" ]
        (bfixed [ Consume ] ReturnVoid);
      builtins [ "blorp_tcp_ipv4_raw" ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_tcp_parse_ip_raw";
          "blorp_tcp_dns_name_raw";
          "blorp_tcp_interface_scope_raw";
          "blorp_tcp_ip_text_raw";
          "blorp_tcp_dns_name_text_raw";
          "blorp_tcp_interface_scope_text_raw";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_tcp_port_raw" ] (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_tcp_port_value_raw" ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_tcp_set_reuse_addr";
          "blorp_tcp_local_port_listener";
          "blorp_tcp_local_port_stream";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [ "blorp_tcp_set_timeout_listener"; "blorp_tcp_set_timeout_stream" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_tcp_connections_stop_on_error_raw";
          "blorp_tcp_connections_continue_on_error_raw";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [
          "blorp_tls_native_available_raw";
          "blorp_websocket_native_available_raw";
        ]
        (bfixed [] ReturnPrimitive);
      (* Resource finalizers consume the scoped capability. For unmanaged
         handles such as files, directories, and UDP sockets this is resource
         ownership rather than ARC ownership: the finalizer closes/frees the
         native handle, and no separate ARC drop exists. For managed handles
         such as TCP, TLS, and websocket sessions, the finalizer also releases
         the ARC owner. *)
      builtins [ "blorp_tls_close_session" ] (bfixed [ Consume ] ReturnVoid);
      builtins
        [ "blorp_websocket_close_session" ]
        (bfixed [ Consume ] ReturnVoid);
      builtins [ "blorp_udp_close_socket" ] (bfixed [ Consume ] ReturnVoid);
      builtins [ "blorp_dir_close" ] (bfixed [ Consume ] ReturnVoid);
      builtins
        [
          "blorp_file_close_reader";
          "blorp_file_close_writer";
          "blorp_file_close_appender";
          "blorp_file_close_read_writer";
          "blorp_file_close_read_appender";
        ]
        (bfixed [ Consume ] ReturnVoid);
      operation_result_bridge_builtin_contracts;
      fallible_stream_source_builtin_contracts;
      fallible_stream_terminal_builtin_contracts;
      builtins [ "blorp_string_concat" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_string_concat_consume" ]
        (bfixed [ CowConsume; Consume ] ReturnOwned);
      builtins
        [ "blorp_string_concat_many" ]
        (bvariadic 1 (fun i -> if i = 0 then Borrow else Consume) ReturnOwned);
      builtins [ "blorp_string_append" ]
        (bfixed [ CowConsume; Borrow ] ReturnOwned);
      builtins
        [ "blorp_string_append_int" ]
        (bfixed [ CowConsume; Borrow ] ReturnOwned);
      builtins [ "blorp_string_eq" ] (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_to_string";
          "blorp_int128_to_string";
          "blorp_uint128_to_string";
          "blorp_float_to_string";
          "blorp_float32_to_string";
          "blorp_float16_to_string";
          "blorp_bool_to_string";
          "blorp_bool_to_string_long";
          "blorp_from_char";
          "blorp_from_chars";
          "blorp_bytes_from_string";
          "blorp_getenv";
          "blorp_getenv_nullable";
          "blorp_upper";
          "blorp_lower";
          "blorp_base64_encode";
          "blorp_bytes_to_string";
          "blorp_encode_utf8";
          "blorp_decode_utf8";
          "blorp_decode_utf8_nullable";
          "blorp_base64_decode";
          "blorp_base64_decode_nullable";
          "blorp_bytes_from_hex";
          "blorp_bytes_from_hex_nullable";
          "blorp_url_encode";
          "blorp_url_decode";
          "blorp_html_escape";
          "blorp_string_chars";
          "blorp_string_codepoints";
          "blorp_codepoint_reverse";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins [ "blorp_string_lcs" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_format_float" ] (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_to_int";
          "blorp_to_float";
          "blorp_to_int8";
          "blorp_to_int16";
          "blorp_to_int32";
          "blorp_to_int128";
          "blorp_to_uint8";
          "blorp_to_uint16";
          "blorp_to_uint32";
          "blorp_to_uint64";
          "blorp_to_uint128";
          "blorp_parse_int";
          "blorp_parse_float";
          "blorp_codepoint_length";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins [ "blorp_string_get_opt" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_string_levenshtein" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins ~void_boxed_args:[ 1 ]
        [
          "blorp_dict_get_int";
          "blorp_dict_get_int8";
          "blorp_dict_get_int16";
          "blorp_dict_get_int32";
          "blorp_dict_get_int64";
          "blorp_dict_get_uint8";
          "blorp_dict_get_uint16";
          "blorp_dict_get_uint32";
          "blorp_dict_get_uint64";
          "blorp_dict_get_float";
          "blorp_dict_get_bool";
          "blorp_dict_get_char";
          "blorp_dict_get_f32";
          "blorp_dict_get_f16";
        ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      (* Vector/tensor reads borrow the collection; COW setters consume it. *)
      builtins
        [ "blorp_vector_get_opt"; "blorp_vector_get_nullable" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_vector_get_opt_int";
          "blorp_vector_get_opt_int8";
          "blorp_vector_get_opt_int16";
          "blorp_vector_get_opt_int32";
          "blorp_vector_get_opt_int64";
          "blorp_vector_get_opt_uint8";
          "blorp_vector_get_opt_uint16";
          "blorp_vector_get_opt_uint32";
          "blorp_vector_get_opt_uint64";
          "blorp_vector_get_opt_float";
          "blorp_vector_get_opt_bool";
          "blorp_vector_get_opt_char";
          "blorp_vector_get_opt_f32";
          "blorp_vector_get_opt_f16";
        ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_matrix_get_opt"; "blorp_matrix_get_nullable" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_assert_shape"; "blorp_assert_shape_nullable" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_matrix_get_opt_int";
          "blorp_matrix_get_opt_int8";
          "blorp_matrix_get_opt_int16";
          "blorp_matrix_get_opt_int32";
          "blorp_matrix_get_opt_int64";
          "blorp_matrix_get_opt_uint8";
          "blorp_matrix_get_opt_uint16";
          "blorp_matrix_get_opt_uint32";
          "blorp_matrix_get_opt_uint64";
          "blorp_matrix_get_opt_float";
          "blorp_matrix_get_opt_bool";
          "blorp_matrix_get_opt_char";
          "blorp_matrix_get_opt_f32";
          "blorp_matrix_get_opt_f16";
        ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnPrimitive);
      builtins [ "blorp_checked_get" ]
        (bfixed [ Borrow; Borrow ] (ReturnAliasOfArg 0));
      builtins [ "blorp_checked_slice" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_matrix_checked_get" ]
        (bfixed [ Borrow; Borrow; Borrow ] (ReturnAliasOfArg 0));
      builtins [ "blorp_tensor3_checked_get" ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow ] (ReturnAliasOfArg 0));
      builtins [ "blorp_tensor4_checked_get" ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow; Borrow ] (ReturnAliasOfArg 0));
      builtins [ "blorp_tensor5_checked_get" ]
        (bfixed
           [ Borrow; Borrow; Borrow; Borrow; Borrow; Borrow ]
           (ReturnAliasOfArg 0));
      builtins [ "blorp_tensor3_checked_get_shape" ]
        (bfixed
           [ Borrow; Borrow; Borrow; Borrow; Borrow; Borrow; Borrow ]
           (ReturnAliasOfArg 0));
      builtins [ "blorp_tensor4_checked_get_shape" ]
        (bfixed
           [
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
           ]
           (ReturnAliasOfArg 0));
      builtins [ "blorp_tensor5_checked_get_shape" ]
        (bfixed
           [
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
           ]
           (ReturnAliasOfArg 0));
      builtins
        [ "blorp_checked_get_f64"; "blorp_checked_get_f32" ]
        (bfixed [ Borrow; Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_matrix_checked_get_f64"; "blorp_matrix_checked_get_f32" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_tensor3_checked_get_shape_f64";
          "blorp_tensor3_checked_get_shape_f32";
        ]
        (bfixed
           [ Borrow; Borrow; Borrow; Borrow; Borrow; Borrow; Borrow ]
           ReturnPrimitive);
      builtins
        [
          "blorp_tensor4_checked_get_shape_f64";
          "blorp_tensor4_checked_get_shape_f32";
        ]
        (bfixed
           [
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
           ]
           ReturnPrimitive);
      builtins
        [
          "blorp_tensor5_checked_get_shape_f64";
          "blorp_tensor5_checked_get_shape_f32";
        ]
        (bfixed
           [
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
             Borrow;
           ]
           ReturnPrimitive);
      builtins ~void_boxed_args:[ 2 ] [ "blorp_vector_get_or" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnBorrowed);
      builtins ~void_boxed_args:[ 2 ] [ "blorp_vector_set" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnVoid);
      builtins ~void_boxed_args:[ 2 ]
        [
          "blorp_vector_set_cow";
          "blorp_vector_set_cow_nullable";
          "blorp_checked_set";
          "blorp_vector_set_inplace";
        ]
        (bfixed [ CowConsume; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_vector_set_cow_f32";
          "blorp_vector_set_cow_nullable_f32";
          "blorp_vector_set_cow_i64";
          "blorp_vector_set_cow_nullable_i64";
          "blorp_vector_set_inplace_packed";
          "blorp_vector_set_inplace_f32";
          "blorp_vector_set_inplace_f64";
          "blorp_vector_set_inplace_i64";
          "blorp_vector_set_inplace_f16";
        ]
        (bfixed [ CowConsume; Borrow; Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 3 ]
        [
          "blorp_matrix_checked_set";
          "blorp_matrix_set_opt";
          "blorp_matrix_set_opt_nullable";
        ]
        (bfixed [ CowConsume; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_matrix_checked_set_f64";
          "blorp_matrix_checked_set_f32";
          "blorp_matrix_checked_set_i64";
          "blorp_matrix_set_opt_i64";
          "blorp_matrix_set_opt_nullable_i64";
        ]
        (bfixed [ CowConsume; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_tensor3_checked_set" ]
        (bfixed [ CowConsume; Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_tensor4_checked_set" ]
        (bfixed
           [ CowConsume; Borrow; Borrow; Borrow; Borrow; Borrow ]
           ReturnOwned);
      builtins
        [ "blorp_tensor5_checked_set" ]
        (bfixed
           [ CowConsume; Borrow; Borrow; Borrow; Borrow; Borrow; Borrow ]
           ReturnOwned);
      builtins ~void_boxed_args:[ 0 ]
        [ "blorp_vector_new_fill" ]
        (bfixed [ Retain; Borrow ] ReturnOwned);
      builtins
        [ "blorp_vector_new_fill_f64"; "blorp_vector_new_fill_f32" ]
        (bfixed [ Retain; Borrow ] ReturnOwned);
      builtins
        [ "blorp_vector_new_fill_i64" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_vector_new_fill_packed" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 0 ]
        [ "blorp_matrix_new_fill" ]
        (bfixed [ Retain; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_matrix_new_fill_f64"; "blorp_matrix_new_fill_f32" ]
        (bfixed [ Retain; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_matrix_new_fill_i64" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_matrix_new_fill_packed" ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 0 ] [ "blorp_tensor3_new" ]
        (bfixed [ Retain; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 0 ] [ "blorp_tensor4_new" ]
        (bfixed [ Retain; Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins ~void_boxed_args:[ 0 ] [ "blorp_tensor5_new" ]
        (bfixed [ Retain; Borrow; Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      (* Vector arithmetic allocates fresh results and borrows all inputs. *)
      builtins [ "blorp_vector_op" ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_vector_add_i64";
          "blorp_vector_sub_i64";
          "blorp_vector_mul_i64";
          "blorp_vector_div_i64";
          "blorp_vector_mod_i64";
          "blorp_simd_vector_add_f32";
          "blorp_simd_vector_sub_f32";
          "blorp_simd_vector_mul_f32";
          "blorp_simd_vector_div_f32";
          "blorp_simd_vector_add_f64";
          "blorp_simd_vector_sub_f64";
          "blorp_simd_vector_mul_f64";
          "blorp_simd_vector_div_f64";
        ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins [ "blorp_vector_eq" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnPrimitive);
      builtins
        [
          "blorp_vector_abs";
          "blorp_vector_exp";
          "blorp_vector_exp_float16";
          "blorp_vector_exp_float32";
          "blorp_vector_log";
          "blorp_vector_log_float16";
          "blorp_vector_log_float32";
          "blorp_vector_sqrt";
          "blorp_vector_sqrt_float16";
          "blorp_vector_sqrt_float32";
          "blorp_vector_to_string_bool";
          "blorp_vector_to_string_float";
          "blorp_vector_to_string_float16";
          "blorp_vector_to_string_float32";
          "blorp_vector_to_string_int";
        ]
        (bfixed [ Borrow ] ReturnOwned);
      builtins
        [
          "blorp_vector_max_float";
          "blorp_vector_max_float16";
          "blorp_vector_max_float32";
          "blorp_vector_max_int";
          "blorp_vector_min_float";
          "blorp_vector_min_float16";
          "blorp_vector_min_float32";
          "blorp_vector_min_int";
          "blorp_vector_norm";
          "blorp_vector_norm_float16";
          "blorp_vector_norm_float32";
        ]
        (bfixed [ Borrow ] ReturnPrimitive);
      builtins
        [ "blorp_vector_cross_float"; "blorp_vector_zip" ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_vector_scalar_op_int";
          "blorp_vector_scalar_op_float";
          "blorp_vector_scalar_op_float32";
          "blorp_vector_scalar_op_float16";
          "blorp_vector_scalar_op_rev_int";
          "blorp_vector_scalar_op_rev_float";
          "blorp_vector_scalar_op_rev_float32";
          "blorp_vector_scalar_op_rev_float16";
        ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_vector_scalar_add_i64";
          "blorp_vector_scalar_sub_i64";
          "blorp_vector_scalar_mul_i64";
          "blorp_vector_scalar_div_i64";
          "blorp_vector_scalar_mod_i64";
          "blorp_vector_scalar_rev_sub_i64";
          "blorp_vector_scalar_rev_div_i64";
          "blorp_vector_scalar_rev_mod_i64";
          "blorp_vector_scalar_add_f64";
          "blorp_vector_scalar_sub_f64";
          "blorp_vector_scalar_mul_f64";
          "blorp_vector_scalar_div_f64";
          "blorp_vector_scalar_rev_sub_f64";
          "blorp_vector_scalar_rev_div_f64";
          "blorp_vector_scalar_add_f32";
          "blorp_vector_scalar_sub_f32";
          "blorp_vector_scalar_mul_f32";
          "blorp_vector_scalar_div_f32";
          "blorp_vector_scalar_rev_sub_f32";
          "blorp_vector_scalar_rev_div_f32";
        ]
        (bfixed [ Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_tensor_add_scaled_f32_cow"; "blorp_tensor_add_scaled_f64_cow" ]
        (bfixed [ CowConsume; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_tensor_matrix_multiply_float";
          "blorp_tensor_matrix_multiply_float16";
          "blorp_tensor_matrix_multiply_float32";
          "blorp_tensor_matrix_multiply_int";
        ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [
          "blorp_tensor_matrix_vector_multiply_float";
          "blorp_tensor_matrix_vector_multiply_float16";
          "blorp_tensor_matrix_vector_multiply_float32";
          "blorp_tensor_matrix_vector_multiply_int";
          "blorp_tensor_transposed_matrix_vector_multiply_float";
          "blorp_tensor_transposed_matrix_vector_multiply_float16";
          "blorp_tensor_transposed_matrix_vector_multiply_float32";
          "blorp_tensor_transposed_matrix_vector_multiply_int";
          "blorp_tensor_outer_float";
          "blorp_tensor_outer_float16";
          "blorp_tensor_outer_float32";
          "blorp_tensor_outer_int";
        ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_tensor_transpose" ]
        (bfixed [ Borrow; Borrow; Borrow ] ReturnOwned);
      builtins
        [ "blorp_tensor_slice_row" ]
        (bfixed [ Borrow; Borrow; Borrow; Borrow ] ReturnOwned);
      (* Vector/matrix maps borrow their input and callback, returning a fresh
       result tensor. *)
      builtins [ "blorp_vector_map" ]
        (bcases
           [
             ([ Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins
        [ "blorp_matrix_map"; "blorp_matrix_map_indexed" ]
        (bcases
           [
             ([ Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins [ "blorp_matrix_zip_map" ]
        (bcases
           [
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      (* Parallel tensor maps use the same ownership shape as sequential matrix
       maps. *)
      builtins
        [
          "blorp_vmap_parallel";
          "blorp_vmap_indexed_parallel";
          "blorp_mmap_parallel";
          "blorp_mmap_indexed_parallel";
          "blorp_mmap_flat_indexed_parallel";
        ]
        (bcases
           [
             ([ Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
      builtins
        [
          "blorp_vzip_parallel";
          "blorp_mzip_parallel";
          "blorp_mzip_indexed_parallel";
        ]
        (bcases
           [
             ([ Borrow; Borrow; Borrow ], ReturnOwned);
             ([ Borrow; Borrow; Borrow; Borrow ], ReturnOwned);
           ]);
    ]

let builtin_void_boxed_arg_positions =
  builtin_contract_table
  |> List.filter_map (fun entry ->
      match entry.builtin_void_boxed_args with
      | [] -> None
      | positions -> Some (entry.builtin_name, positions))

let contract_of_builtin_spec spec arity =
  match spec with
  | Builtin_fixed (args, result) -> fixed arity args result
  | Builtin_cases cases -> (
      match List.find_opt (fun (args, _) -> List.length args = arity) cases with
      | Some (args, result) -> fixed arity args result
      | None -> None)
  | Builtin_variadic { min_arity; arg_at; result } ->
      variadic min_arity arg_at result arity

let string_has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len && String.sub value 0 prefix_len = prefix

let generated_builtin_contract name arity =
  (* Enum vector stringifiers are emitted from type declarations with a
     type-suffixed C name by specialization/backend emission. They share the
     runtime vector-to-string ABI: borrow the vector and return a new String. *)
  if string_has_prefix ~prefix:"blorp_vector_to_string_" name then
    fixed arity [ Borrow ] ReturnOwned
  else None

let builtin_contract name arity =
  match
    List.find_opt
      (fun entry -> entry.builtin_name = name)
      builtin_contract_table
  with
  | Some entry -> contract_of_builtin_spec entry.builtin_spec arity
  | None -> generated_builtin_contract name arity

let builtin_contract_entry name =
  List.find_opt (fun entry -> entry.builtin_name = name) builtin_contract_table

let builtin_ownership_coverage name =
  match builtin_contract_entry name with
  | Some _ -> Some Covered_by_contract
  | None -> (
      match name with
      | "blorp_eq_dispatch" ->
          Some
            (Pre_perceus_sentinel
               "type-dispatched equality is specialized before Perceus")
      | "blorp_tensor_matrix_multiply" | "blorp_tensor_matrix_vector_multiply"
      | "blorp_tensor_transposed_matrix_vector_multiply" | "blorp_tensor_outer"
      | "blorp_tensor_peel" ->
          Some
            (Pre_perceus_sentinel
               "generic tensor dispatch is specialized before Perceus")
      | _ -> None)

let contract_for_call_kind (kind : Core.call_kind) ~(arg_count : int) =
  match kind with
  | Core.CKIntrinsic name -> intrinsic_contract name arg_count
  | Core.CKBuiltin name -> builtin_contract name arg_count
  | Core.CKUnknown | Core.CKSelectedDirect _ | Core.CKUser _ | Core.CKForeign _
  | Core.CKClosure ->
      None
