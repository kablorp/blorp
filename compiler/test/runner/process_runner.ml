let now () = Unix.gettimeofday ()

let close_noerr fd = try Unix.close fd with _ -> ()

let close_if_extra fd =
  if fd <> Unix.stdin && fd <> Unix.stdout && fd <> Unix.stderr then
    close_noerr fd

let rec waitpid_retry flags pid =
  try Unix.waitpid flags pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retry flags pid

let exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal

let create_process ?(new_session = false) ?(close_fds = []) ?cwd ?(env = [])
    program argv stdout_fd =
  match Unix.fork () with
  | 0 -> (
      if new_session then
        (try ignore (Unix.setsid ()) with _ -> Unix._exit 127);
      List.iter close_noerr close_fds;
      try
        Option.iter Unix.chdir cwd;
        List.iter (fun (name, value) -> Unix.putenv name value) env;
        Unix.dup2 stdout_fd Unix.stdout;
        Unix.dup2 stdout_fd Unix.stderr;
        close_if_extra stdout_fd;
        Unix.execvp program argv
      with _ -> Unix._exit 127)
  | pid -> pid

let kill_process_group pid signal =
  try Unix.kill (-pid) signal
  with _ -> ( try Unix.kill pid signal with _ -> ())

let process_group_exists pid =
  try
    Unix.kill (-pid) 0;
    true
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> false
  | Unix.Unix_error (Unix.EPERM, _, _) -> true
  | _ -> false

let timeout_sigterm_grace_seconds = 1.0
let timeout_sigkill_settle_seconds = 0.25
let timeout_poll_interval_seconds = 0.05
let drain_budget_bytes_per_poll = 64 * 1024
let capture_limit_bytes = 8 * 1024 * 1024
let capture_limit_exit_code = 125

let run_process_capture_supervised ?cwd ?(env = []) timeout program args =
  let read_fd, write_fd = Unix.pipe () in
  let argv = Array.of_list (program :: args) in
  let pid =
    create_process ~new_session:true ~close_fds:[ read_fd ] ?cwd ~env program
      argv write_fd
  in
  Unix.close write_fd;
  Unix.set_nonblock read_fd;
  let output = Buffer.create 4096 in
  let bytes = Bytes.create 4096 in
  let pipe_open = ref true in
  let status = ref None in
  let timed_out = ref false in
  let capture_limit_exceeded = ref false in
  let termination_deadline = ref None in
  let sent_kill = ref false in
  let deadline =
    match timeout with
    | Some seconds when seconds > 0 -> Some (now () +. float_of_int seconds)
    | Some _ | None -> None
  in
  let close_capture_pipe () =
    if !pipe_open then begin
      pipe_open := false;
      close_noerr read_fd
    end
  in
  let mark_capture_limit_exceeded () =
    capture_limit_exceeded := true;
    close_capture_pipe ()
  in
  let rec drain remaining_budget =
    if !pipe_open && remaining_budget > 0 then
      match
        Unix.read read_fd bytes 0 (min (Bytes.length bytes) remaining_budget)
      with
      | 0 -> close_capture_pipe ()
      | count ->
          let remaining_capture = capture_limit_bytes - Buffer.length output in
          if count <= remaining_capture then begin
            Buffer.add_subbytes output bytes 0 count;
            drain (remaining_budget - count)
          end
          else begin
            if remaining_capture > 0 then
              Buffer.add_subbytes output bytes 0 remaining_capture;
            mark_capture_limit_exceeded ()
          end
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain remaining_budget
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
      | exception _ -> close_capture_pipe ()
  in
  let poll_status () =
    match !status with
    | Some _ -> ()
    | None -> (
        try
          match waitpid_retry [ Unix.WNOHANG ] pid with
          | 0, _ -> ()
          | _, child_status -> status := Some child_status
        with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
  in
  let rec loop () =
    drain drain_budget_bytes_per_poll;
    poll_status ();
    let current = now () in
    let leader_exited = Option.is_some !status in
    let group_exists = process_group_exists pid in
    if leader_exited && not group_exists then close_capture_pipe ()
    else begin
      if Option.is_none !termination_deadline then begin
        if !capture_limit_exceeded then begin
          termination_deadline :=
            Some (current +. timeout_sigterm_grace_seconds);
          kill_process_group pid Sys.sigterm
        end
        else
          match deadline with
          | Some limit when (not !timed_out) && current >= limit ->
              timed_out := true;
              termination_deadline :=
                Some (current +. timeout_sigterm_grace_seconds);
              kill_process_group pid Sys.sigterm
          | Some _ | None ->
              if
                leader_exited && group_exists
                && ((not !pipe_open) || Option.is_none deadline)
              then begin
                (* The command returned but left a member of its inherited
                   process group. Its work is outside the fixture's lifetime. *)
                termination_deadline :=
                  Some (current +. timeout_sigterm_grace_seconds);
                kill_process_group pid Sys.sigterm
              end
      end;
      (match !termination_deadline with
      | Some grace when (not !sent_kill) && current >= grace ->
          sent_kill := true;
          termination_deadline :=
            Some (current +. timeout_sigkill_settle_seconds);
          kill_process_group pid Sys.sigkill
      | Some _ | None -> ());
      let stop_waiting =
        match !termination_deadline with
        | Some settle when !sent_kill -> current >= settle
        | Some _ | None -> false
      in
      if not stop_waiting then begin
        let next_deadline =
          match (!termination_deadline, deadline) with
          | Some termination, _ -> termination
          | None, Some limit -> limit
          | None, None -> now () +. timeout_poll_interval_seconds
        in
        let wait =
          min timeout_poll_interval_seconds
            (max 0.0 (next_deadline -. now ()))
        in
        let read_fds = if !pipe_open then [ read_fd ] else [] in
        (try ignore (Unix.select read_fds [] [] wait) with _ -> ());
        loop ()
      end
    end
  in
  loop ();
  poll_status ();
  if Option.is_none !status then begin
    kill_process_group pid Sys.sigkill;
    try
      let _, child_status = waitpid_retry [] pid in
      status := Some child_status
    with Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  end;
  drain drain_budget_bytes_per_poll;
  close_noerr read_fd;
  let code =
    if !timed_out then 124
    else if !capture_limit_exceeded then capture_limit_exit_code
    else Option.fold ~none:124 ~some:exit_code !status
  in
  let captured = Buffer.contents output in
  let captured =
    if !capture_limit_exceeded then
      Printf.sprintf "Process output exceeded the %d-byte capture limit\n%s"
        capture_limit_bytes captured
    else captured
  in
  (code, captured)

let run_process_capture_timeout ?cwd ?(env = []) ~timeout program args =
  run_process_capture_supervised ?cwd ~env timeout program args
