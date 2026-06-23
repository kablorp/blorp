let out_len = 32
let block_len = 64
let chunk_len = 1024
let chunk_start = Int32.shift_left 1l 0
let chunk_end = Int32.shift_left 1l 1
let parent = Int32.shift_left 1l 2
let root = Int32.shift_left 1l 3

let iv =
  [|
    0x6A09E667l;
    0xBB67AE85l;
    0x3C6EF372l;
    0xA54FF53Al;
    0x510E527Fl;
    0x9B05688Cl;
    0x1F83D9ABl;
    0x5BE0CD19l;
  |]

let msg_permutation = [| 2; 6; 3; 10; 7; 0; 4; 13; 1; 11; 12; 5; 9; 14; 15; 8 |]
let add = Int32.add
let logxor = Int32.logxor
let logor = Int32.logor

let rotate_right value bits =
  Int32.logor
    (Int32.shift_right_logical value bits)
    (Int32.shift_left value (32 - bits))

let g state a b c d mx my =
  state.(a) <- add (add state.(a) state.(b)) mx;
  state.(d) <- rotate_right (logxor state.(d) state.(a)) 16;
  state.(c) <- add state.(c) state.(d);
  state.(b) <- rotate_right (logxor state.(b) state.(c)) 12;
  state.(a) <- add (add state.(a) state.(b)) my;
  state.(d) <- rotate_right (logxor state.(d) state.(a)) 8;
  state.(c) <- add state.(c) state.(d);
  state.(b) <- rotate_right (logxor state.(b) state.(c)) 7

let round state m =
  g state 0 4 8 12 m.(0) m.(1);
  g state 1 5 9 13 m.(2) m.(3);
  g state 2 6 10 14 m.(4) m.(5);
  g state 3 7 11 15 m.(6) m.(7);
  g state 0 5 10 15 m.(8) m.(9);
  g state 1 6 11 12 m.(10) m.(11);
  g state 2 7 8 13 m.(12) m.(13);
  g state 3 4 9 14 m.(14) m.(15)

let permute m =
  let copy = Array.copy m in
  for i = 0 to 15 do
    m.(i) <- copy.(msg_permutation.(i))
  done

let int64_low_u32 value = Int64.to_int32 value
let int64_high_u32 value = Int64.(to_int32 (shift_right_logical value 32))

let compress chaining_value block_words counter block_size flags =
  let state =
    [|
      chaining_value.(0);
      chaining_value.(1);
      chaining_value.(2);
      chaining_value.(3);
      chaining_value.(4);
      chaining_value.(5);
      chaining_value.(6);
      chaining_value.(7);
      iv.(0);
      iv.(1);
      iv.(2);
      iv.(3);
      int64_low_u32 counter;
      int64_high_u32 counter;
      Int32.of_int block_size;
      flags;
    |]
  in
  let block = Array.copy block_words in
  round state block;
  permute block;
  round state block;
  permute block;
  round state block;
  permute block;
  round state block;
  permute block;
  round state block;
  permute block;
  round state block;
  permute block;
  round state block;
  for i = 0 to 7 do
    state.(i) <- logxor state.(i) state.(i + 8);
    state.(i + 8) <- logxor state.(i + 8) chaining_value.(i)
  done;
  state

let first_8_words words = Array.init 8 (fun i -> words.(i))

let word_from_bytes bytes offset =
  let byte i =
    if offset + i < Bytes.length bytes then
      Int32.of_int (Char.code (Bytes.get bytes (offset + i)))
    else 0l
  in
  Int32.logor (byte 0)
    (Int32.logor
       (Int32.shift_left (byte 1) 8)
       (Int32.logor
          (Int32.shift_left (byte 2) 16)
          (Int32.shift_left (byte 3) 24)))

let block_words_from_bytes bytes =
  Array.init 16 (fun i -> word_from_bytes bytes (i * 4))

type output = {
  input_chaining_value : int32 array;
  block_words : int32 array;
  counter : int64;
  block_size : int;
  output_flags : int32;
}

let output_chaining_value output =
  first_8_words
    (compress output.input_chaining_value output.block_words output.counter
       output.block_size output.output_flags)

let output_root_bytes output out_len =
  let out = Bytes.create out_len in
  let offset = ref 0 in
  let block_counter = ref 0L in
  while !offset < out_len do
    let words =
      compress output.input_chaining_value output.block_words !block_counter
        output.block_size
        (logor output.output_flags root)
    in
    for word_index = 0 to Array.length words - 1 do
      if !offset < out_len then begin
        let word = words.(word_index) in
        for byte_index = 0 to 3 do
          if !offset < out_len then begin
            let byte =
              Int32.to_int
                (Int32.logand
                   (Int32.shift_right_logical word (8 * byte_index))
                   0xffl)
            in
            Bytes.set out !offset (Char.chr byte);
            incr offset
          end
        done
      end
    done;
    block_counter := Int64.succ !block_counter
  done;
  Bytes.unsafe_to_string out

type chunk_state = {
  mutable chaining_value : int32 array;
  chunk_counter : int64;
  block : bytes;
  mutable block_size : int;
  mutable blocks_compressed : int;
  chunk_flags : int32;
}

let make_chunk_state key_words chunk_counter flags =
  {
    chaining_value = Array.copy key_words;
    chunk_counter;
    block = Bytes.make block_len '\000';
    block_size = 0;
    blocks_compressed = 0;
    chunk_flags = flags;
  }

let chunk_state_len state =
  (block_len * state.blocks_compressed) + state.block_size

let chunk_start_flag state =
  if state.blocks_compressed = 0 then chunk_start else 0l

let chunk_update state input offset len =
  let input_offset = ref offset in
  let remaining = ref len in
  while !remaining > 0 do
    if state.block_size = block_len then begin
      let block_words = block_words_from_bytes state.block in
      state.chaining_value <-
        first_8_words
          (compress state.chaining_value block_words state.chunk_counter
             block_len
             (logor state.chunk_flags (chunk_start_flag state)));
      state.blocks_compressed <- state.blocks_compressed + 1;
      Bytes.fill state.block 0 block_len '\000';
      state.block_size <- 0
    end;
    let want = block_len - state.block_size in
    let take = min want !remaining in
    Bytes.blit_string input !input_offset state.block state.block_size take;
    state.block_size <- state.block_size + take;
    input_offset := !input_offset + take;
    remaining := !remaining - take
  done

let chunk_output state =
  {
    input_chaining_value = Array.copy state.chaining_value;
    block_words = block_words_from_bytes state.block;
    counter = state.chunk_counter;
    block_size = state.block_size;
    output_flags =
      logor state.chunk_flags (logor (chunk_start_flag state) chunk_end);
  }

let parent_output left_child_cv right_child_cv key_words flags =
  let block_words = Array.make 16 0l in
  Array.blit left_child_cv 0 block_words 0 8;
  Array.blit right_child_cv 0 block_words 8 8;
  {
    input_chaining_value = Array.copy key_words;
    block_words;
    counter = 0L;
    block_size = block_len;
    output_flags = logor parent flags;
  }

let parent_cv left_child_cv right_child_cv key_words flags =
  output_chaining_value
    (parent_output left_child_cv right_child_cv key_words flags)

type hasher = {
  key_words : int32 array;
  flags : int32;
  mutable chunk_state : chunk_state;
  mutable cv_stack : int32 array list;
}

let create () =
  {
    key_words = Array.copy iv;
    flags = 0l;
    chunk_state = make_chunk_state iv 0L 0l;
    cv_stack = [];
  }

let pop_stack hasher =
  match hasher.cv_stack with
  | head :: tail ->
      hasher.cv_stack <- tail;
      head
  | [] -> invalid_arg "BLAKE3 stack underflow"

let push_stack hasher cv = hasher.cv_stack <- cv :: hasher.cv_stack

let rec merge_completed_subtrees hasher new_cv total_chunks =
  if Int64.logand total_chunks 1L = 0L then
    let parent =
      parent_cv (pop_stack hasher) new_cv hasher.key_words hasher.flags
    in
    merge_completed_subtrees hasher parent
      (Int64.shift_right_logical total_chunks 1)
  else new_cv

let add_chunk_chaining_value hasher new_cv total_chunks =
  push_stack hasher (merge_completed_subtrees hasher new_cv total_chunks)

let update hasher input =
  let input_offset = ref 0 in
  let remaining = ref (String.length input) in
  while !remaining > 0 do
    if chunk_state_len hasher.chunk_state = chunk_len then begin
      let chunk_cv = output_chaining_value (chunk_output hasher.chunk_state) in
      let total_chunks = Int64.succ hasher.chunk_state.chunk_counter in
      add_chunk_chaining_value hasher chunk_cv total_chunks;
      hasher.chunk_state <-
        make_chunk_state hasher.key_words total_chunks hasher.flags
    end;
    let want = chunk_len - chunk_state_len hasher.chunk_state in
    let take = min want !remaining in
    chunk_update hasher.chunk_state input !input_offset take;
    input_offset := !input_offset + take;
    remaining := !remaining - take
  done

let finalize hasher out_len =
  let output = ref (chunk_output hasher.chunk_state) in
  List.iter
    (fun left_child ->
      output :=
        parent_output left_child
          (output_chaining_value !output)
          hasher.key_words hasher.flags)
    hasher.cv_stack;
  output_root_bytes !output out_len

let hash_string input =
  let hasher = create () in
  update hasher input;
  finalize hasher out_len

let to_hex bytes =
  let hex = Bytes.create (String.length bytes * 2) in
  let digit n =
    Char.chr (if n < 10 then Char.code '0' + n else Char.code 'a' + n - 10)
  in
  String.iteri
    (fun i c ->
      let value = Char.code c in
      Bytes.set hex (i * 2) (digit (value lsr 4));
      Bytes.set hex ((i * 2) + 1) (digit (value land 0x0f)))
    bytes;
  Bytes.unsafe_to_string hex

let hash_string_hex input = hash_string input |> to_hex
