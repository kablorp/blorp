(** IR Intrinsic Registry.

    This is the single source of truth for all CKIntrinsic primitives.
    Each intrinsic is a backend-defined leaf operation — different backends
    emit structurally different code for the same intrinsic.

    An operation is an intrinsic (not a CKBuiltin) when backends would emit
    structurally different code: a field read vs a function call vs a WASM
    memory load. Operations that are function calls on every backend should
    use CKBuiltin instead.

    {1 Contract}

    Every intrinsic listed here MUST have:
    - A Blorp-owned renderer entry in
      [compiler/blorp/codegen_intrinsic_renderer.brp]
    - Documentation of its semantics (what it does, not how)

    IR bodies in [core_intrinsics.ml] compose these primitives into
    higher-level operations (append, remove, starts_with, etc.) that
    flow through mono, perceus, and emit like normal user code.

    {1 Adding new intrinsics}

    1. Add the entry here with name, arg types, return type, and semantics.
    2. Add the Blorp renderer case in
       [compiler/blorp/codegen_intrinsic_renderer.brp].
    3. Use it in [core_intrinsics.ml] IR bodies via [intr "name" args ty].

    [core_emit_intrinsic.ml] is retained only for the temporary OCaml bootstrap
    emitter used while building the Blorp compiler bridge. Do not add new
    production emission behavior there unless the bridge bootstrap path needs
    a matching compatibility case.

    {1 How builtin works}

    When a blorp function is declared [builtin], [core_lower.ml] calls
    [Core_intrinsics.synthesize_body] to generate its Core IR body. The body
    can use:
    - [CKIntrinsic] calls for backend-specific leaf operations
    - [CKBuiltin] calls for opaque C functions (thin wrappers)
    - Normal IR constructs (let, if, for, while, etc.)

    If synthesis returns [None], the function falls through to the standard
    [CKBuiltin] path using [codegen_builtins.ml] name mappings.

    Some std functions are thin enough that qualified calls can skip both
    generic monomorphization and CKBuiltin dispatch, resolving directly to a
    leaf [CKIntrinsic]. Those module-function bindings live in
    [ir_backed_std_functions] below.

    {1 Design principle}

    {b Collections:} each type gets structural access (_len, _get, _set),
    allocation (_alloc), COW (_ensure_unique), and ARC helpers
    (_release_elem, _retain_for). Algorithms (append, contains, etc.)
    are composed IR.

    {b Math:} [math_*] intrinsics for IEEE 754 operations — same
    operation on every platform, different emission. C: [sin(x)],
    WASM: [f64.sin], LLVM: [@llvm.sin.f64]. Constants ([math_infinity])
    emit as inline expressions, not function calls.

    {b Bitwise:} [bit_and], [shift_left], etc. — inline C operators.

    A new backend only implements the leaf intrinsics; all composed
    operations work automatically. *)

(** Arg-count contract for an intrinsic.

    - [Fixed n]: dispatcher expects exactly [n] args.
    - [Variadic]: arg count varies by call site (rare — a few math
      ops have both unary and binary forms). Tests should defer to
      the emit clause's own pattern matching rather than asserting
      a specific count. *)
type arity = Fixed of int | Variadic

type intrinsic_info = {
  name : string;
  doc : string;
  implemented : bool;  (** false = planned, not yet in emit *)
  arity : arity;
  is_pure : bool;
      (** Pure intrinsics have no side effects.
                                  RC retain/release, allocators, and
                                  setters are impure; reads and math
                                  ops are pure. *)
  elementwise_liftable : bool;
      (** Can this scalar op auto-lift over a
                                  tensor argument? See Phase 4.2. *)
}
(** Intrinsic descriptor — documents the contract and gates future
    compiler passes.

    - [arity] / [is_pure] added in Phase 2.6.6 to let tests (and
      future Phase 4.2 elementwise lift) reason without source
      inspection.
    - [elementwise_liftable] marks scalar operations that are safe
      to auto-lift over a tensor argument (e.g. [math_sqrt(vec)] →
      [map(vec, math_sqrt)]). Composite operations like [list_get]
      or [tensor_alloc] are NOT liftable; only per-element math ops. *)

(** Shorthand constructor. [~arity] and [~is_pure] are required; every
    entry must explicitly declare both. [implemented] defaults to true
    (planned intrinsics opt out with [~implemented:false]).
    [elementwise_liftable] defaults to false (most intrinsics aren't
    per-element liftable; scalar math/bitwise ops opt in).

    Making [is_pure] mandatory catches the footgun of a new impure
    intrinsic silently inheriting the default — every new entry forces
    a deliberate classification. *)
let mk ?(implemented = true) ~is_pure ?(elementwise_liftable = false) ~arity
    name doc : intrinsic_info =
  { name; doc; implemented; arity; is_pure; elementwise_liftable }

type ir_backed_std_function = {
  mod_path : string;
  func_name : string;
  arity : int;
  receiver_type : string;
  intrinsic_name : string;
}

(** {1 List intrinsics}

    List is a refcounted dynamic array: [header, len, capacity,
    elem_release, data\[\]]. Elements are type-erased to [void*].

    Composed operations built from these (in core_intrinsics.ml):
    append, set_index, remove, insert, tail, reverse, get. *)

let list_intrinsics =
  [
    (* --- Structural access (pure reads) --- *)
    mk ~arity:(Fixed 0) ~is_pure:true "elem_release_fn"
      "Return the generic ARC release function pointer for boxed elements";
    mk ~arity:(Fixed 1) ~is_pure:true "list_len"
      "Read the length field. list -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "list_capacity"
      "Read the capacity field. list -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "list_get"
      "Read element at index (unchecked, returns void*). list * Int -> Ptr";
    (* --- Structural writes (impure — mutate the list) --- *)
    mk ~arity:(Fixed 3) ~is_pure:false "list_set"
      "Write element at index (unchecked, no ARC). list * Int * Ptr -> Void";
    mk ~arity:(Fixed 3) ~is_pure:false "list_set_owned"
      "Write freshly-owned element at index (unchecked, transfer ownership). \
       list * Int * Ptr -> Void";
    mk ~arity:(Fixed 3) ~is_pure:false "list_handoff_set_owned"
      "Producer-handoff store. Releases the old slot when overwriting a reused \
       list, then transfers a freshly-owned element. list * Int * Ptr -> Void";
    mk ~arity:(Fixed 4) ~is_pure:false "list_handoff_set_source_slot"
      "Producer-handoff source-slot store. Moves a slot when the source \
       storage is reused, otherwise retains the source element into the fresh \
       result. result list * Int * source list * Int -> Void";
    mk ~arity:(Fixed 5) ~is_pure:false "list_copy_span_uninit"
      "Copy a borrowed source span into uninitialized destination slots, \
       retaining pointer elements when destination storage owns them. dst list \
       * Int * src list * Int * Int -> Void";
    mk ~arity:(Fixed 3) ~is_pure:false "list_swap_slots"
      "Swap two initialized list slots in place without changing element \
       ownership. list * Int * Int -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "list_set_len"
      "Set the length field. list * Int -> Void";
    (* --- Allocation / COW (impure — allocates) --- *)
    mk ~arity:(Fixed 1) ~is_pure:false "list_alloc"
      "Allocate a fresh empty list with given capacity. Int -> list";
    mk ~arity:(Fixed 1) ~is_pure:false "list_ensure_unique"
      "COW check: copy if shared, return as-is if unique. Preserves \
       elem_release. Retains all elements in the copy. list -> list";
    mk ~arity:(Fixed 2) ~is_pure:false "list_ensure_capacity"
      "COW + grow: ensure list is unique with capacity >= n. list * Int -> list";
    mk ~arity:(Fixed 2) ~is_pure:false "list_reuse_alloc"
      "Consume a dead list owner and return an empty list allocation. Reuses \
       storage only when unique. list * Int -> list";
    mk ~arity:(Fixed 1) ~is_pure:false "list_reverse_owned"
      "Consume one list owner and return a reversed owned list. Reuses storage \
       when unique and otherwise returns a retained reversed copy. list -> \
       list";
    (* --- Element-level ARC (impure — retain/release) --- *)
    mk ~arity:(Fixed 2) ~is_pure:false "list_release_elem"
      "Release element at index if list has elem_release. No-op for primitive \
       element types. list * Int -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "list_retain_for"
      "Retain a value being stored into list, if list has elem_release. No-op \
       for primitives. list * Ptr -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "list_set_elem_release"
      "Set the elem_release function pointer. list * Ptr -> Void";
  ]

(** {1 String intrinsics}

    String is a refcounted byte buffer: [header, len, capacity, data\[\]].
    UTF-8 encoded. Byte-level access is safe for prefix/suffix/equality
    comparisons because UTF-8 is a deterministic encoding.

    Composed operations built from these (in core_intrinsics.ml, 29 total):
    substring, starts_with, ends_with, contains, raw_index_of, count,
    is_numeric, is_ascii, is_blank, is_lower, is_upper, repeat, reverse,
    drop_left, take_left, take_right, drop_right, trim, trim_left, trim_right,
    capitalize, title_case, pad_left, pad_right, center, trim_chars,
    raw_last_index_of, longest_common_prefix, hamming_distance_raw.

    Permanent CKBuiltin (not decomposable with current intrinsics):
    - split, split_n, lines, words — build List[String], algorithmically
      complex (delimiter matching + list construction interleaved)
    - replace, replace_first — two-pass algorithms (count matches then
      build result), complex state management
    - from_char, from_chars, chars — UTF-8 multi-byte encoding/decoding
    - length, get — trait impls, resolved via core_specialize intercept
    - to_bytes — crosses String/Bytes type boundary
    - parse_int, parse_float — C library (strtol/strtod)
    - url_encode, url_decode, html_escape — RFC-driven encoding tables
    - base64_encode, base64_decode — base64 lookup tables
    - upper, lower — Unicode default case mapping includes
      multi-codepoint expansions and context-sensitive final sigma
    - codepoint_length, codepoints, codepoint_reverse — UTF-8 state machine
    - levenshtein, longest_common_substring — DP algorithms *)

let string_intrinsics =
  [
    (* --- Structural access --- *)
    mk ~arity:(Fixed 1) ~is_pure:true "string_len"
      "Read the byte length field. string -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "string_get_byte"
      "Read byte at index as Int (unsigned char). string * Int -> Int";
    mk ~arity:(Fixed 3) ~is_pure:true "string_find_byte_from"
      "Find byte from start offset, returning byte index or -1. string * Int * \
       Int -> Int";
    (* --- Allocation / mutation --- *)
    mk ~arity:(Fixed 1) ~is_pure:false "string_alloc"
      "Allocate a fresh empty string with given byte capacity. len=0, data[0] \
       null-terminated, rest uninitialized. Int -> string";
    mk ~arity:(Fixed 3) ~is_pure:false "string_set_byte"
      "Write byte at index. No bounds check. string * Int * Int -> Void";
    mk ~arity:(Fixed 5) ~is_pure:false "string_copy_bytes"
      "Copy a proven non-overlapping byte range between strings. No bounds \
       check. dst * dst_pos * src * src_pos * len -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "string_set_len"
      "Set the byte length field and null-terminate. string * Int -> Void";
    mk ~arity:(Fixed 1) ~is_pure:false "string_ensure_unique"
      "COW check: copy if shared/immortal. string -> string";
    mk ~arity:(Fixed 2) ~is_pure:false "string_ensure_capacity"
      "COW + grow: ensure unique with capacity >= n bytes. string * Int -> \
       string";
  ]

(** {1 Bytes intrinsics (planned)}

    Bytes is a mutable byte buffer: same layout as String but
    mutable semantics. Used for binary I/O and protocol parsing.

    Follows the same structural pattern as String. *)

let bytes_intrinsics =
  [
    mk ~arity:(Fixed 1) ~is_pure:true "bytes_len"
      "Read the byte length field. bytes -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "bytes_get"
      "Read byte at index (unchecked). bytes * Int -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "bytes_set"
      "Write byte at index (unchecked). bytes * Int * Int -> Void";
    mk ~arity:(Fixed 1) ~is_pure:false "bytes_alloc"
      "Allocate fresh byte buffer with capacity (len=0, uninitialized). Int -> \
       bytes";
    mk ~arity:(Fixed 2) ~is_pure:false "bytes_set_len"
      "Set the byte length field. bytes * Int -> Void";
    mk ~arity:(Fixed 1) ~is_pure:false "bytes_cow"
      "COW check: copy if shared, return as-is if unique. bytes -> bytes";
  ]

(** {1 Set intrinsics}

    Set is a separate-chaining hash table: [header, size, capacity,
    mask, buckets\[\], first/last (insertion order), hash_fn, eq_fn,
    key_release]. Entries are linked lists with key + bucket chain +
    insertion order pointers.

    Composed operations: contains, is_subset, combine, difference, filter,
    fold, intersect, map, to_list, length. *)

let set_intrinsics =
  [
    (* Field reads *)
    mk ~arity:(Fixed 1) ~is_pure:true "set_len"
      "Read the size (element count) field. set -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "set_capacity"
      "Read the capacity field. set -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "set_mask"
      "Read the mask field (capacity-1). set -> Int";
    (* Bucket access *)
    mk ~arity:(Fixed 2) ~is_pure:true "set_bucket"
      "Read bucket head at index. set * Int -> Ptr (SetEntry* or NULL)";
    mk ~arity:(Fixed 3) ~is_pure:false "set_set_bucket"
      "Write bucket head at index. set * Int * Ptr -> Void";
    (* Insertion-order linked list *)
    mk ~arity:(Fixed 1) ~is_pure:true "set_first"
      "Read first entry (insertion order). set -> Ptr";
    mk ~arity:(Fixed 1) ~is_pure:true "set_last"
      "Read last entry (insertion order). set -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:false "set_set_first"
      "Write first entry pointer. set * Ptr -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "set_set_last"
      "Write last entry pointer. set * Ptr -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "set_set_len"
      "Write the size field. set * Int -> Void";
    (* Entry field access *)
    mk ~arity:(Fixed 1) ~is_pure:true "set_entry_key"
      "Read key from entry. Ptr -> Ptr";
    mk ~arity:(Fixed 1) ~is_pure:true "set_entry_next"
      "Read bucket chain next pointer. Ptr -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:false "set_entry_set_next"
      "Write bucket chain next pointer. Ptr * Ptr -> Void";
    mk ~arity:(Fixed 1) ~is_pure:true "set_entry_prev_order"
      "Read insertion-order prev pointer. Ptr -> Ptr";
    mk ~arity:(Fixed 1) ~is_pure:true "set_entry_next_order"
      "Read insertion-order next pointer. Ptr -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:false "set_entry_set_prev_order"
      "Write insertion-order prev pointer. Ptr * Ptr -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "set_entry_set_next_order"
      "Write insertion-order next pointer. Ptr * Ptr -> Void";
    (* Hash/equality dispatch: pure — blorp's purity tracking forbids
     impure Hashable / Equatable impls at the call site (see
     [typecheck.ml]'s purity checks), so transitive purity is safe. *)
    mk ~arity:(Fixed 2) ~is_pure:true "set_hash"
      "Call type-dispatched hash function. set * Ptr -> Int";
    mk ~arity:(Fixed 3) ~is_pure:true "set_eq"
      "Call type-dispatched equality function. set * Ptr * Ptr -> Bool";
    mk ~arity:(Fixed 1) ~is_pure:true "set_hash_immediate"
      "Hash an immediate primitive key directly. Ptr -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "set_eq_immediate"
      "Compare immediate primitive keys directly. Ptr * Ptr -> Bool";
    (* Storage ownership *)
    mk ~arity:(Fixed 2) ~is_pure:false "set_retain_key_for"
      "Retain a key before storing it in a set if the set owns RC keys. set * \
       Ptr -> Void";
    (* Allocation *)
    mk ~arity:(Fixed 1) ~is_pure:false "set_alloc"
      "Allocate empty set with given capacity. Int -> set";
    mk ~arity:(Fixed 1) ~is_pure:false "set_alloc_entry"
      "Allocate a new SetEntry with key. Ptr -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:false "set_free_entry"
      "Free a SetEntry (release key if needed). set * Ptr -> Void";
    (* COW + resize *)
    mk ~arity:(Fixed 1) ~is_pure:false "set_cow"
      "Copy-on-write: deep copy if shared, return unique. set -> set";
    mk ~arity:(Fixed 2) ~is_pure:false "set_reuse_alloc"
      "Consume a dead set owner and return an empty set allocation. Reuses \
       storage only when unique. set * Int -> set";
    mk ~arity:(Fixed 2) ~is_pure:false "set_resize"
      "Resize and rehash to new capacity. set * Int -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "set_reserve_for_len"
      "Resize once if needed so the set can hold the expected element count. \
       set * Int -> Void";
  ]

(** {1 Dict intrinsics}

    Dict is a Swiss table (open addressing with group-of-16 probing):
    [header, size, order_len, capacity, mask, grow_at, keys\[\],
    values\[\], meta\[\], order\[\], order_index\[\], hash_fn, eq_fn,
    key_release, value_release]. Meta bytes: 0xFF=empty, 0x80=deleted,
    0x00-0x7F=occupied (h2 fingerprint).

    Composed operations: keys, values, length. *)

let dict_intrinsics =
  [
    (* Field reads *)
    mk ~arity:(Fixed 1) ~is_pure:true "dict_len"
      "Read the size (entry count) field. dict -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "dict_capacity"
      "Read the capacity field. dict -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "dict_mask"
      "Read the mask field (capacity-1). dict -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "dict_grow_at"
      "Read the grow threshold. dict -> Int";
    (* Slot access *)
    mk ~arity:(Fixed 2) ~is_pure:true "dict_key_at"
      "Read key at slot index. dict * Int -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:true "dict_value_at"
      "Read value at slot index. dict * Int -> Ptr";
    mk ~arity:(Fixed 3) ~is_pure:false "dict_set_key_at"
      "Write key at slot index. dict * Int * Ptr -> Void";
    mk ~arity:(Fixed 3) ~is_pure:false "dict_set_value_at"
      "Write value at slot index. dict * Int * Ptr -> Void";
    (* Metadata (Swiss table control bytes) *)
    mk ~arity:(Fixed 2) ~is_pure:true "dict_meta_get"
      "Read metadata byte at slot. dict * Int -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "dict_meta_set"
      "Write metadata byte at slot. dict * Int * Int -> Void";
    (* Insertion order *)
    mk ~arity:(Fixed 2) ~is_pure:true "dict_order_get"
      "Read order[i] (slot index). dict * Int -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "dict_order_set"
      "Write order[i]. dict * Int * Int -> Void";
    mk ~arity:(Fixed 1) ~is_pure:true "dict_order_len"
      "Read order_len (includes holes). dict -> Int";
    mk ~arity:(Fixed 2) ~is_pure:false "dict_set_order_len"
      "Write order_len. dict * Int -> Void";
    mk ~arity:(Fixed 2) ~is_pure:true "dict_order_index_get"
      "Read order_index[slot] (reverse map). dict * Int -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "dict_order_index_set"
      "Write order_index[slot]. dict * Int * Int -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "dict_set_len"
      "Write the size field. dict * Int -> Void";
    (* Hash/equality dispatch *)
    mk ~arity:(Fixed 1) ~is_pure:true "dict_key_release_fn"
      "Read key_release function pointer. dict -> Ptr";
    mk ~arity:(Fixed 1) ~is_pure:true "dict_value_release_fn"
      "Read value_release function pointer. dict -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:true "dict_hash"
      "Call type-dispatched hash function. dict * Ptr -> Int";
    mk ~arity:(Fixed 3) ~is_pure:true "dict_eq"
      "Call type-dispatched equality function. dict * Ptr * Ptr -> Bool";
    mk ~arity:(Fixed 1) ~is_pure:true "dict_hash_immediate"
      "Hash an immediate primitive key directly. Ptr -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "dict_eq_immediate"
      "Compare immediate primitive keys directly. Ptr * Ptr -> Bool";
    (* Storage ownership *)
    mk ~arity:(Fixed 2) ~is_pure:false "dict_retain_key_for"
      "Retain a key before storing it in a dict if the dict owns RC keys. dict \
       * Ptr -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "dict_retain_value_for"
      "Retain a value before storing it in a dict if the dict owns RC values. \
       dict * Ptr -> Void";
    mk ~arity:(Fixed 2) ~is_pure:false "dict_release_value_for"
      "Release a value overwritten in a dict if the dict owns RC values. dict \
       * Ptr -> Void";
    (* Allocation *)
    mk ~arity:(Fixed 1) ~is_pure:false "dict_alloc"
      "Allocate empty dict with given capacity. Int -> dict";
    (* COW + resize *)
    mk ~arity:(Fixed 1) ~is_pure:false "dict_cow"
      "Copy-on-write: deep copy if shared, return unique. dict -> dict";
    mk ~arity:(Fixed 2) ~is_pure:false "dict_reuse_alloc"
      "Consume a dead dict owner and return an empty dict allocation. Reuses \
       storage only when unique. dict * Int -> dict";
    mk ~arity:(Fixed 2) ~is_pure:false "dict_resize"
      "Resize and rehash to new capacity. dict * Int -> Void";
  ]

(** {1 Slice intrinsics}

    StringSlice is a zero-copy view: [header, source*, start, len].
    The source string is retained for the slice's lifetime.

    Composed operations: from_string, length, to_string, substring,
    starts_with, get. *)

let slice_intrinsics =
  [
    mk ~arity:(Fixed 1) ~is_pure:true "slice_source"
      "Read the source string pointer. slice -> String";
    mk ~arity:(Fixed 1) ~is_pure:true "slice_start"
      "Read the start offset. slice -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "slice_len"
      "Read the length. slice -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "slice_alloc"
      "Allocate slice with source, start, len. Retains source. String * Int * \
       Int -> slice";
  ]

(** {1 Tensor intrinsics}

    Tensor is a refcounted numeric array: [header, len, capacity,
    elem_size, ndim, dims\[\], data\[\]]. Elements are typed
    (Float64/Float32/Float16/Int), not void*. Strides enable
    multi-dimensional views without copying.

    SIMD-specific operations (vectorized add/mul) remain as CKBuiltin. *)

let tensor_intrinsics =
  [
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_len"
      "Total element count (length field). tensor -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_capacity"
      "Total allocated cell count (capacity field; >= len). tensor -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_is_word_storage"
      "Return whether tensor data uses unmanaged immediate word slots. tensor \
       -> Bool";
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_is_f64_storage"
      "Return whether tensor data uses raw Float64 storage. tensor -> Bool";
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_is_f32_storage"
      "Return whether tensor data uses raw Float32 storage. tensor -> Bool";
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_is_i64_storage"
      "Return whether tensor data uses raw Int64 storage. tensor -> Bool";
    mk ~arity:(Fixed 1) ~is_pure:true "tensor_is_unique"
      "Return whether tensor object is uniquely owned for COW-safe raw writes. \
       tensor -> Bool";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_unchecked"
      "Direct data[idx] access with bounds proven safe at compile time. \
       Returns raw void* — callers unbox per element type. tensor * Int -> Ptr";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_i64_word_unchecked"
      "Read immediate word pointer-slot element after storage mode has been \
       checked. tensor * Int -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_i64_raw_unchecked"
      "Read raw Int64 element after storage mode has been checked. tensor * \
       Int -> Int";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_f64_raw_unchecked"
      "Read raw Float64 element after storage mode has been checked. tensor * \
       Int -> Float";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_f32_raw_unchecked"
      "Read raw Float32 element after storage mode has been checked. tensor * \
       Int -> Float32";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_f64"
      "Read Float64 element at flat index. tensor * Int -> Float";
    mk ~arity:(Fixed 3) ~is_pure:false "tensor_set_f64"
      "Write Float64 element at flat index. tensor * Int * Float -> Void";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_f32"
      "Read Float32 element at flat index. tensor * Int -> Float32";
    mk ~arity:(Fixed 3) ~is_pure:false "tensor_set_f32"
      "Write Float32 element at flat index. tensor * Int * Float32 -> Void";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_f16"
      "Read Float16 element at flat index. tensor * Int -> Float16";
    mk ~arity:(Fixed 3) ~is_pure:false "tensor_set_f16"
      "Write Float16 element at flat index. tensor * Int * Float16 -> Void";
    mk ~arity:(Fixed 2) ~is_pure:true "tensor_get_i64"
      "Read Int element at flat index (void* unbox). tensor * Int -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "tensor_set_i64"
      "Write Int element at flat index (void* box). tensor * Int * Int -> Void";
    mk ~arity:(Fixed 1) ~is_pure:false "tensor_alloc"
      "Allocate tensor with given element count. Int -> tensor";
    mk ~arity:(Fixed 2) ~is_pure:true ~implemented:false "tensor_stride"
      "Read stride for dimension d. tensor * Int -> Int";
  ]

let fixed_intrinsics =
  [
    mk ~arity:(Fixed 1) ~is_pure:true "fixed_value"
      "Read the scaled integer value field. fixed -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "fixed_scale"
      "Read the scale (decimal places) field. fixed -> Int";
    mk ~arity:(Fixed 1) ~is_pure:true "fixed_precision"
      "Read the precision (total digits) field. fixed -> Int";
    mk ~arity:(Fixed 3) ~is_pure:false "fixed_alloc"
      "Allocate Fixed with raw value, scale, precision. Int * Int * Int -> \
       Fixed";
    mk ~arity:(Fixed 1) ~is_pure:true "fixed_pow10"
      "Compute 10^n (clamped to 18 digits). Int -> Int";
  ]

(** {1 ARC intrinsics (planned)}

    Currently CDup/CDrop Core IR nodes handle retain/release, and
    the emitter hardcodes blorp_retain/blorp_release. When targeting
    non-C backends, these should become intrinsics so the backend
    can emit its own refcounting mechanism. *)

(** {1 Math intrinsics}

    IEEE 754 math operations. Float64-only — the C backend emits bare
    function names (sin, cos, etc.), WASM would emit f64.sin, LLVM would
    emit @llvm.sin.f64. These are the same operations on every platform;
    only the emission differs.

    NOT included: abs/min/max/round — these are polymorphic (Int + Float)
    and stay as CKBuiltin with type dispatch in core_specialize. *)

let math_intrinsics =
  let mk_unary name doc =
    mk ~arity:(Fixed 1) ~is_pure:true ~elementwise_liftable:true name doc
  in
  let mk_binary name doc =
    mk ~arity:(Fixed 2) ~is_pure:true ~elementwise_liftable:true name doc
  in
  [
    (* Unary: Float -> Float — all elementwise-liftable. *)
    mk_unary "math_sin" "sin(x)";
    mk_unary "math_cos" "cos(x)";
    mk_unary "math_tan" "tan(x)";
    mk_unary "math_asin" "asin(x)";
    mk_unary "math_acos" "acos(x)";
    mk_unary "math_atan" "atan(x)";
    mk_unary "math_sinh" "sinh(x)";
    mk_unary "math_cosh" "cosh(x)";
    mk_unary "math_tanh" "tanh(x)";
    mk_unary "math_asinh" "asinh(x)";
    mk_unary "math_acosh" "acosh(x)";
    mk_unary "math_atanh" "atanh(x)";
    mk_unary "math_exp" "exp(x)";
    mk_unary "math_exp2" "exp2(x)";
    mk_unary "math_expm1" "expm1(x)";
    mk_unary "math_log" "log(x) (natural)";
    mk_unary "math_log2" "log2(x)";
    mk_unary "math_log10" "log10(x)";
    mk_unary "math_log1p" "log1p(x)";
    mk_unary "math_sqrt" "sqrt(x)";
    mk_unary "math_cbrt" "cbrt(x)";
    mk_unary "math_floor" "floor(x)";
    mk_unary "math_ceil" "ceil(x)";
    mk_unary "math_trunc" "trunc(x)";
    (* Binary: Float * Float -> Float — elementwise only if both operands
     are same-shape tensors or scalar-with-tensor. Marking liftable lets
     Phase 4.2 pick them up; the lifter checks arg shapes before applying. *)
    mk_binary "math_pow" "pow(base, exp)";
    mk_binary "math_atan2" "atan2(y, x)";
    mk_binary "math_hypot" "hypot(x, y)";
    mk_binary "math_fmod" "fmod(x, y)";
    mk_binary "math_copysign" "copysign(x, y)";
    (* Ternary: Float * Float * Float -> Float *)
    mk ~arity:(Fixed 3) ~is_pure:true ~elementwise_liftable:true "math_fma"
      "fma(x, y, z)";
    (* Constants: () -> Float — not per-element. *)
    mk ~arity:(Fixed 0) ~is_pure:true "math_infinity" "Positive infinity";
    mk ~arity:(Fixed 0) ~is_pure:true "math_neg_infinity" "Negative infinity";
    mk ~arity:(Fixed 0) ~is_pure:true "math_nan" "Quiet NaN";
    (* Classification: Float -> Bool — elementwise predicates. *)
    mk_unary "math_is_nan" "isnan(x)";
    mk_unary "math_is_inf" "isinf(x)";
    mk_unary "math_is_finite" "isfinite(x)";
  ]

let bitwise_intrinsics =
  [
    mk ~arity:(Fixed 2) ~is_pure:true ~elementwise_liftable:true "bit_and"
      "Bitwise AND. Int * Int -> Int. Emits: (a & b)";
    mk ~arity:(Fixed 2) ~is_pure:true ~elementwise_liftable:true "bit_or"
      "Bitwise OR. Int * Int -> Int. Emits: (a | b)";
    mk ~arity:(Fixed 2) ~is_pure:true ~elementwise_liftable:true "bit_xor"
      "Bitwise XOR. Int * Int -> Int. Emits: (a ^ b)";
    mk ~arity:(Fixed 1) ~is_pure:true ~elementwise_liftable:true "bit_not"
      "Bitwise NOT. Int -> Int. Emits: (~a)";
    mk ~arity:(Fixed 2) ~is_pure:true ~elementwise_liftable:true "shift_left"
      "Left shift. Int * Int -> Int. Emits: (a << n)";
    mk ~arity:(Fixed 2) ~is_pure:true ~elementwise_liftable:true "shift_right"
      "Arithmetic right shift. Int * Int -> Int. Emits: (a >> n)";
  ]

let debug_reflection_intrinsics =
  [
    mk ~arity:(Fixed 1) ~is_pure:true ~implemented:false "type_name"
      "Debug reflection. T -> String. Folded by Core_specialize.";
    mk ~arity:(Fixed 1) ~is_pure:true ~implemented:false "is_heap"
      "Debug heap-layout reflection. T -> Bool. Folded by Core_specialize.";
  ]

let arc_intrinsics =
  [
    mk ~arity:(Fixed 1) ~is_pure:false ~implemented:false "rc_retain"
      "Increment reference count. Ptr -> Void";
    mk ~arity:(Fixed 1) ~is_pure:false ~implemented:false "rc_release"
      "Decrement reference count, free if zero. Ptr -> Void";
    mk ~arity:(Fixed 1) ~is_pure:true ~implemented:false "rc_is_unique"
      "Check if refcount == 1 (for COW). Ptr -> Bool";
  ]

(* ================================================================
   Registry queries
   ================================================================ *)

(** All intrinsics, flat list (used by [is_known]). *)
let all =
  list_intrinsics @ string_intrinsics @ bytes_intrinsics @ dict_intrinsics
  @ set_intrinsics @ slice_intrinsics @ tensor_intrinsics @ fixed_intrinsics
  @ math_intrinsics @ bitwise_intrinsics @ debug_reflection_intrinsics
  @ arc_intrinsics

(** Check if a name is a registered intrinsic (implemented or planned). *)
let is_known name = List.exists (fun i -> i.name = name) all

let arity_matches expected actual =
  match expected with Fixed n -> n = actual | Variadic -> true

let lookup_bitwise_intrinsic ~name ~arity =
  bitwise_intrinsics
  |> List.find_opt (fun intrinsic ->
      intrinsic.name = name && arity_matches intrinsic.arity arity)
  |> Option.map (fun intrinsic -> intrinsic.name)

let lookup_debug_reflection_intrinsic ~mod_path ~name ~arity =
  let source_name =
    match mod_path with
    | Some "std/debug" -> Some name
    | Some _ -> None
    | None -> (
        match name with
        | "type_name" | "is_heap" -> Some name
        | "std_debug__type_name" -> Some "type_name"
        | "std_debug__is_heap" -> Some "is_heap"
        | _ -> None)
  in
  match source_name with
  | None -> None
  | Some source_name ->
      debug_reflection_intrinsics
      |> List.find_opt (fun intrinsic ->
          intrinsic.name = source_name && arity_matches intrinsic.arity arity)
      |> Option.map (fun intrinsic -> intrinsic.name)

(** Std functions that should resolve directly to leaf IR intrinsics.

    This is intentionally separate from [Codegen_builtins]: entries here
    must not require a C runtime wrapper or generic std monomorphization.
    The receiver type guard prevents a module alias typo or malformed Core
    from turning an unrelated call into a raw structural intrinsic. *)
let mk_ir_backed_std_function ?(arity = 1) ~mod_path ~func_name ~receiver_type
    ~intrinsic_name () =
  { mod_path; func_name; arity; receiver_type; intrinsic_name }

let length_entry mod_path receiver_type intrinsic_name =
  mk_ir_backed_std_function ~mod_path ~func_name:"length" ~receiver_type
    ~intrinsic_name ()

let ir_backed_std_functions =
  List.map
    (fun (mod_path, receiver_type, intrinsic) ->
      length_entry mod_path receiver_type intrinsic)
    [
      ("std/list", "List", "list_len");
      ("std/string", "String", "string_len");
      ("std/bytes", "Bytes", "bytes_len");
      ("std/dict", "Dict", "dict_len");
      ("std/set", "Set", "set_len");
    ]

let receiver_matches expected ty =
  match Codegen_types.normalize_type ty with
  | Ast.TyNamed (name, _) -> name = expected
  | _ -> false

let lookup_ir_backed_std_function ~mod_path ~func_name ~arity ~receiver_ty =
  match
    List.find_opt
      (fun entry ->
        entry.mod_path = mod_path
        && entry.func_name = func_name
        && entry.arity = arity
        && receiver_matches entry.receiver_type receiver_ty)
      ir_backed_std_functions
  with
  | Some entry -> Some entry.intrinsic_name
  | None -> None
