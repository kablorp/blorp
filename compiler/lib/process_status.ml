external signal_number : int -> int = "blorp_process_status_signal_number"
  [@@noalloc]

let exit_code_of_signal signal = 128 + signal_number signal

let exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      exit_code_of_signal signal
