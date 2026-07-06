(** Test Runner for blorp

    Handles test discovery, doctest extraction, test execution (sequential
    and parallel), and result reporting. *)

open Ast

let read_file = Modules.read_file
let extract_directory = Modules.extract_directory
let init_module_paths = Modules.init_module_paths

(* ============================================================================
   Utilities
   ============================================================================ *)

let contains_substring = Modules.contains

type sanitizer_mode =
  | SanitizerOff
  | SanitizerAddressUndefined
  | SanitizerUndefinedOnly

let sanitizer_mode_of_bool sanitize =
  if sanitize then SanitizerAddressUndefined else SanitizerOff

let select_sanitizer_mode ?sanitizer_mode ~sanitize () =
  match sanitizer_mode with
  | Some mode -> mode
  | None -> sanitizer_mode_of_bool sanitize

let sanitizer_enabled = function
  | SanitizerOff -> false
  | SanitizerAddressUndefined | SanitizerUndefinedOnly -> true

let sanitizer_mode_to_string = function
  | SanitizerOff -> "off"
  | SanitizerAddressUndefined -> "address,undefined"
  | SanitizerUndefinedOnly -> "undefined"

let sanitizer_mode_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "" | "0" | "false" | "off" | "none" -> Some SanitizerOff
  | "1" | "true" | "on" | "address" | "asan" | "address,undefined"
  | "undefined,address" ->
      Some SanitizerAddressUndefined
  | "undefined" | "ubsan" -> Some SanitizerUndefinedOnly
  | _ -> None

let starts_with s prefix =
  let s_len = String.length s in
  let p_len = String.length prefix in
  s_len >= p_len && String.sub s 0 p_len = prefix

let has_top_level_main_source source =
  source |> String.split_on_char '\n'
  |> List.exists (fun line ->
      let trimmed = String.trim line in
      starts_with trimmed "func main(")

let source_declares_testsuite source =
  contains_substring source "tests: TestSuite"
  || contains_substring source "tests:TestSuite"

let source_mentions_doctests source =
  contains_substring source "---" && contains_substring source "doctests:"

(** Get current time in seconds *)
let get_time () = Unix.gettimeofday ()

let close_noerr fd = try Unix.close fd with _ -> ()

let close_if_extra fd =
  if fd <> Unix.stdin && fd <> Unix.stdout && fd <> Unix.stderr then
    close_noerr fd

let fallback_random_counter = ref 0

let random_bytes len =
  let bytes = Bytes.create len in
  try
    let fd = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
        let rec loop off =
          if off < len then
            let n = Unix.read fd bytes off (len - off) in
            if n = 0 then raise End_of_file else loop (off + n)
        in
        loop 0;
        bytes)
  with _ ->
    (* Fallback for unusual platforms without /dev/urandom. Still unique
       enough for artifact isolation; cache keys remain content-derived. *)
    incr fallback_random_counter;
    let seed =
      Digest.to_hex
        (Digest.string
           (Printf.sprintf "%f:%d:%d:%d" (get_time ()) (Unix.getpid ()) len
              !fallback_random_counter))
    in
    for i = 0 to len - 1 do
      Bytes.set bytes i
        (char_of_int (Char.code seed.[i mod String.length seed]))
    done;
    bytes

let random_uuid_v4 () =
  let bytes = random_bytes 16 in
  let get i = int_of_char (Bytes.get bytes i) in
  let set i v = Bytes.set bytes i (char_of_int v) in
  set 6 (get 6 land 0x0f lor 0x40);
  set 8 (get 8 land 0x3f lor 0x80);
  Printf.sprintf
    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"
    (get 0) (get 1) (get 2) (get 3) (get 4) (get 5) (get 6) (get 7) (get 8)
    (get 9) (get 10) (get 11) (get 12) (get 13) (get 14) (get 15)

(** Read all bytes from a file descriptor into a string *)
let read_all_fd fd =
  let buf = Buffer.create 4096 in
  let bytes = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd bytes 0 4096 with
    | 0 -> ()
    | n ->
        Buffer.add_subbytes buf bytes 0 n;
        loop ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | exception _ -> ()
  in
  loop ();
  Buffer.contents buf

let exit_code_of_status = function
  | Unix.WEXITED c -> c
  | Unix.WSIGNALED s -> 128 + s
  | Unix.WSTOPPED _ -> 128

(** waitpid with EINTR retry *)
let rec waitpid_retry flags pid =
  try Unix.waitpid flags pid
  with Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_retry flags pid

let ensure_dir path =
  let rec loop dir =
    if dir = "" || dir = Filename.dirname dir then ()
    else if Sys.file_exists dir then
      begin if not (Sys.is_directory dir) then
        failwith
          (Printf.sprintf "artifact path exists but is not a directory: %s" dir)
      end
    else begin
      loop (Filename.dirname dir);
      try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  loop path

let rec remove_tree path =
  if Sys.file_exists path then
    begin if Sys.is_directory path then begin
      Array.iter
        (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      try Unix.rmdir path with _ -> ()
    end
    else try Unix.unlink path with _ -> ()
    end

let sanitize_component s =
  let b = Bytes.of_string s in
  for i = 0 to Bytes.length b - 1 do
    let c = Bytes.get b i in
    let ok =
      (c >= 'a' && c <= 'z')
      || (c >= 'A' && c <= 'Z')
      || (c >= '0' && c <= '9')
      || c = '_' || c = '-' || c = '.'
    in
    if not ok then Bytes.set b i '_'
  done;
  let s = Bytes.to_string b in
  if s = "" || s = "." || s = ".." then "artifact" else s

type run_artifacts = {
  root : string;
  mutable artifact_counter : int;
  mutable compilation_counter : int;
}

let current_run_artifacts : run_artifacts option ref = ref None

let make_run_artifacts () =
  let base = Filename.concat (Filename.get_temp_dir_name ()) "blorp-runs" in
  ensure_dir base;
  let rec try_create () =
    let name = Printf.sprintf "run-%s" (random_uuid_v4 ()) in
    let root = Filename.concat base name in
    try
      Unix.mkdir root 0o755;
      { root; artifact_counter = 0; compilation_counter = 0 }
    with Unix.Unix_error (Unix.EEXIST, _, _) -> try_create ()
  in
  try_create ()

let ensure_run_artifacts () =
  match !current_run_artifacts with
  | Some artifacts -> artifacts
  | None ->
      let artifacts = make_run_artifacts () in
      current_run_artifacts := Some artifacts;
      artifacts

let current_run_artifact_root () = (ensure_run_artifacts ()).root

let with_run_artifacts f =
  match !current_run_artifacts with
  | Some _ -> f ()
  | None ->
      let artifacts = make_run_artifacts () in
      current_run_artifacts := Some artifacts;
      Fun.protect
        ~finally:(fun () ->
          current_run_artifacts := None;
          if Sys.getenv_opt "BLORP_KEEP_ARTIFACTS" <> Some "1" then
            remove_tree artifacts.root
          else Printf.eprintf "Keeping blorp artifacts in %s\n%!" artifacts.root)
        f

let run_artifact_path ~kind ~prefix ~suffix =
  let artifacts = ensure_run_artifacts () in
  artifacts.artifact_counter <- artifacts.artifact_counter + 1;
  let dir = Filename.concat artifacts.root (sanitize_component kind) in
  ensure_dir dir;
  let suffix = if suffix = "" then "" else sanitize_component suffix in
  let name =
    Printf.sprintf "%s_%d_%06d%s"
      (sanitize_component prefix)
      (Unix.getpid ()) artifacts.artifact_counter suffix
  in
  Filename.concat dir name

let run_artifact_dir ~kind ~prefix =
  let path = run_artifact_path ~kind ~prefix ~suffix:"" in
  ensure_dir path;
  path

let run_compilation_dir () =
  let artifacts = ensure_run_artifacts () in
  let dir = Filename.concat artifacts.root "compilations" in
  ensure_dir dir;
  let rec allocate () =
    artifacts.compilation_counter <- artifacts.compilation_counter + 1;
    let path =
      Filename.concat dir
        (Printf.sprintf "compile-%06d" artifacts.compilation_counter)
    in
    try
      Unix.mkdir path 0o755;
      path
    with Unix.Unix_error (Unix.EEXIST, _, _) -> allocate ()
  in
  allocate ()

(** Run a program directly (no shell), capture stdout+stderr via pipe.
    Returns (exit_code, output). *)
let create_process_direct ?(new_session = false) ?(close_fds = []) ?cwd
    ?(env = []) prog argv stdin_fd stdout_fd stderr_fd =
  match Unix.fork () with
  | 0 -> (
      (try if new_session then ignore (Unix.setsid ()) with _ -> ());
      List.iter close_noerr close_fds;
      try
        Option.iter Unix.chdir cwd;
        List.iter (fun (name, value) -> Unix.putenv name value) env;
        Unix.dup2 stdin_fd Unix.stdin;
        Unix.dup2 stdout_fd Unix.stdout;
        Unix.dup2 stderr_fd Unix.stderr;
        close_if_extra stdin_fd;
        close_if_extra stdout_fd;
        close_if_extra stderr_fd;
        Unix.execvp prog argv
      with _ -> Unix._exit 127)
  | pid -> pid

let kill_process_group_or_process pid signal =
  try Unix.kill (-pid) signal
  with _ -> ( try Unix.kill pid signal with _ -> ())

let process_timeout_sigterm_grace_seconds = 1.0
let process_timeout_sigkill_settle_seconds = 0.25
let process_timeout_poll_interval_seconds = 0.05

let reap_child_if_needed pid status =
  match !status with
  | Some _ -> ()
  | None -> (
      try
        let _, st = waitpid_retry [] pid in
        status := Some st
      with Unix.Unix_error (Unix.ECHILD, _, _) -> ())

let run_process_capture ?cwd ?(env = []) prog args =
  let read_fd, write_fd = Unix.pipe () in
  let argv = Array.of_list (prog :: args) in
  let pid =
    create_process_direct ~close_fds:[ read_fd ] ?cwd ~env prog argv Unix.stdin
      write_fd write_fd
  in
  Unix.close write_fd;
  let output = read_all_fd read_fd in
  Unix.close read_fd;
  let _, status = waitpid_retry [] pid in
  (exit_code_of_status status, output)

(** Run a program directly with timeout, capture output.
    Returns (exit_code, output). exit_code 124 = timed out. *)
let run_process_capture_timeout ?cwd ?(env = []) ~timeout prog args =
  match timeout with
  | None | Some 0 -> run_process_capture ?cwd ~env prog args
  | Some seconds ->
      let read_fd, write_fd = Unix.pipe () in
      let argv = Array.of_list (prog :: args) in
      let pid =
        create_process_direct ~new_session:true ~close_fds:[ read_fd ] ?cwd ~env
          prog argv Unix.stdin write_fd write_fd
      in
      Unix.close write_fd;
      let timed_out = ref false in
      let status = ref None in
      let pipe_open = ref true in
      let output = Buffer.create 4096 in
      let bytes = Bytes.create 4096 in
      Unix.set_nonblock read_fd;
      let rec drain_available () =
        if !pipe_open then
          match Unix.read read_fd bytes 0 4096 with
          | 0 -> pipe_open := false
          | n ->
              Buffer.add_subbytes output bytes 0 n;
              drain_available ()
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> drain_available ()
          | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
            ->
              ()
          | exception _ -> pipe_open := false
      in
      let poll_status () =
        match !status with
        | Some _ -> ()
        | None -> (
            try
              match waitpid_retry [ Unix.WNOHANG ] pid with
              | 0, _ -> ()
              | _, st -> status := Some st
            with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
      in
      let deadline = get_time () +. float_of_int seconds in
      let kill_grace = ref None in
      let sent_kill = ref false in
      let rec loop () =
        drain_available ();
        poll_status ();
        match !status with
        | Some _ -> ()
        | None ->
            let now = get_time () in
            if (not !timed_out) && now >= deadline then begin
              timed_out := true;
              kill_grace := Some (now +. process_timeout_sigterm_grace_seconds);
              kill_process_group_or_process pid Sys.sigterm
            end;
            (match !kill_grace with
            | Some grace_deadline
              when !timed_out && (not !sent_kill) && now >= grace_deadline ->
                sent_kill := true;
                kill_grace :=
                  Some (now +. process_timeout_sigkill_settle_seconds);
                kill_process_group_or_process pid Sys.sigkill
            | _ -> ());
            let now = get_time () in
            let stop_waiting =
              match !kill_grace with
              | Some grace_deadline when !sent_kill -> now >= grace_deadline
              | _ -> false
            in
            if not stop_waiting then begin
              let wait =
                match !kill_grace with
                | Some grace_deadline -> max 0.0 (grace_deadline -. get_time ())
                | None -> max 0.0 (deadline -. get_time ())
              in
              let read_fds = if !pipe_open then [ read_fd ] else [] in
              let wait = min wait process_timeout_poll_interval_seconds in
              (try ignore (Unix.select read_fds [] [] wait) with _ -> ());
              loop ()
            end
      in
      loop ();
      if !timed_out then reap_child_if_needed pid status;
      drain_available ();
      Unix.close read_fd;
      let exit_code =
        if !timed_out then 124
        else
          match !status with Some st -> exit_code_of_status st | None -> 124
      in
      (exit_code, Buffer.contents output)

(** Run a program directly with timeout, inheriting stdin/stdout/stderr.
    Returns exit code (124 = timed out). For interactive use (blorp run). *)
let run_process_timeout ~timeout prog args =
  let argv = Array.of_list (prog :: args) in
  let use_new_session =
    match timeout with Some seconds when seconds > 0 -> true | _ -> false
  in
  let pid =
    create_process_direct ~new_session:use_new_session prog argv Unix.stdin
      Unix.stdout Unix.stderr
  in
  let with_forwarded_signal_handlers f =
    if not use_new_session then f ()
    else
      let old_int = ref None in
      let old_term = ref None in
      let restore () =
        Option.iter (Sys.set_signal Sys.sigint) !old_int;
        Option.iter (Sys.set_signal Sys.sigterm) !old_term
      in
      let exit_code_for_forwarded_signal signum =
        if signum = Sys.sigint then 130
        else if signum = Sys.sigterm then 143
        else 128
      in
      let forward signum =
        kill_process_group_or_process pid signum;
        exit (exit_code_for_forwarded_signal signum)
      in
      old_int := Some (Sys.signal Sys.sigint (Sys.Signal_handle forward));
      old_term := Some (Sys.signal Sys.sigterm (Sys.Signal_handle forward));
      match f () with
      | result ->
          restore ();
          result
      | exception exn ->
          restore ();
          raise exn
  in
  match timeout with
  | None | Some 0 ->
      with_forwarded_signal_handlers (fun () ->
          let _, status = waitpid_retry [] pid in
          exit_code_of_status status)
  | Some seconds ->
      with_forwarded_signal_handlers (fun () ->
          let timed_out = ref false in
          let status = ref None in
          let poll_status () =
            match !status with
            | Some _ -> ()
            | None -> (
                try
                  match waitpid_retry [ Unix.WNOHANG ] pid with
                  | 0, _ -> ()
                  | _, st -> status := Some st
                with Unix.Unix_error (Unix.ECHILD, _, _) -> ())
          in
          let deadline = get_time () +. float_of_int seconds in
          let kill_grace = ref None in
          let sent_kill = ref false in
          let rec loop () =
            poll_status ();
            match !status with
            | Some _ -> ()
            | None ->
                let now = get_time () in
                if (not !timed_out) && now >= deadline then begin
                  timed_out := true;
                  kill_grace :=
                    Some (now +. process_timeout_sigterm_grace_seconds);
                  kill_process_group_or_process pid Sys.sigterm
                end;
                (match !kill_grace with
                | Some grace_deadline
                  when !timed_out && (not !sent_kill) && now >= grace_deadline
                  ->
                    sent_kill := true;
                    kill_grace :=
                      Some (now +. process_timeout_sigkill_settle_seconds);
                    kill_process_group_or_process pid Sys.sigkill
                | _ -> ());
                let now = get_time () in
                let stop_waiting =
                  match !kill_grace with
                  | Some grace_deadline when !sent_kill -> now >= grace_deadline
                  | _ -> false
                in
                if not stop_waiting then begin
                  let wait =
                    match !kill_grace with
                    | Some grace_deadline ->
                        max 0.0 (grace_deadline -. get_time ())
                    | None -> max 0.0 (deadline -. get_time ())
                  in
                  (try
                     ignore
                       (Unix.select [] [] []
                          (min wait process_timeout_poll_interval_seconds))
                   with _ -> ());
                  loop ()
                end
          in
          loop ();
          if !timed_out then reap_child_if_needed pid status;
          if !timed_out then 124
          else
            match !status with Some st -> exit_code_of_status st | None -> 124)

(** Detect whether `cc` is Clang or GCC. Cached after first call. *)
let cc_is_clang =
  lazy
    (let _, output = run_process_capture "cc" [ "--version" ] in
     contains_substring output "clang")

let sanitizer_cc_args = function
  | SanitizerOff -> []
  | SanitizerAddressUndefined ->
      [ "-fsanitize=address,undefined"; "-fno-omit-frame-pointer"; "-g" ]
  | SanitizerUndefinedOnly ->
      [ "-fsanitize=undefined"; "-fno-omit-frame-pointer"; "-g" ]

let sanitize_cc_args = sanitizer_cc_args SanitizerAddressUndefined

(** Compile C code piped via stdin, avoiding temp file I/O.
    Uses `cc -x c - -x none` to read C from stdin, then resets the
    language so that any subsequent .o files are linked normally.
    Returns (exit_code, compiler_output). *)
let compile_c_from_stdin c_code bin_file extra_args =
  let stdin_read, stdin_write = Unix.pipe () in
  let stdout_read, stdout_write = Unix.pipe () in
  (* FD_CLOEXEC: prevent CC from inheriting the write end of its own stdin
     pipe, which would prevent it from ever seeing EOF. *)
  Unix.set_close_on_exec stdin_write;
  Unix.set_close_on_exec stdout_read;
  (* -x c - : read C from stdin; -x none : reset language for .o files *)
  let args =
    Array.of_list
      ([ "cc"; "-x"; "c"; "-"; "-x"; "none" ] @ extra_args @ [ "-o"; bin_file ])
  in
  let pid =
    Unix.create_process "cc" args stdin_read stdout_write stdout_write
  in
  Unix.close stdin_read;
  Unix.close stdout_write;
  (* Write C code to CC's stdin. CC reads concurrently as a separate process.
     Deadlock is not a concern: on success CC produces no stdout; on failure
     error messages are small enough to fit in the pipe buffer. *)
  let len = String.length c_code in
  let rec write_loop off =
    if off < len then
      let n = Unix.write_substring stdin_write c_code off (len - off) in
      write_loop (off + n)
  in
  (try write_loop 0 with Unix.Unix_error _ -> ());
  Unix.close stdin_write;
  let output = read_all_fd stdout_read in
  Unix.close stdout_read;
  let _, status = waitpid_retry [] pid in
  (exit_code_of_status status, output)

type tls_backend_profile = TlsUnsupported | TlsOpenSsl

type precompiled = {
  runtime_obj : string;  (** Compiled runtime.o *)
  header_file : string;  (** Runtime declarations for -include *)
  pch_file : string option;  (** Optional precompiled header path. *)
  tls_backend : tls_backend_profile;
      (** TLS backend profile used to compile [runtime_obj]. *)
}
(** Precompiled artifacts for test runs *)

let tls_backend_profile_to_string = function
  | TlsUnsupported -> "unsupported"
  | TlsOpenSsl -> "openssl"

let tls_backend_profile_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "" | "unsupported" -> Ok TlsUnsupported
  | "openssl" -> Ok TlsOpenSsl
  | other ->
      Error
        (Printf.sprintf
           "Invalid BLORP_TLS_BACKEND=%S. Expected 'unsupported' or 'openssl'."
           other)

let configured_tls_backend_profile () =
  match Sys.getenv_opt "BLORP_TLS_BACKEND" with
  | None -> Ok TlsUnsupported
  | Some value -> tls_backend_profile_of_string value

let current_tls_backend_profile () =
  match configured_tls_backend_profile () with
  | Ok profile -> profile
  | Error msg -> invalid_arg msg

let split_cc_arg_string value =
  value |> String.split_on_char ' ' |> List.map String.trim
  |> List.filter (fun part -> part <> "")

let openssl_pkg_config_args flag =
  let code, output = run_process_capture "pkg-config" [ flag; "openssl" ] in
  if code = 0 then split_cc_arg_string output else []

let openssl_cflags () =
  match Sys.getenv_opt "BLORP_OPENSSL_CFLAGS" with
  | Some value -> split_cc_arg_string value
  | None -> openssl_pkg_config_args "--cflags"

let openssl_libs () =
  match Sys.getenv_opt "BLORP_OPENSSL_LIBS" with
  | Some value -> split_cc_arg_string value
  | None -> openssl_pkg_config_args "--libs"

let tls_backend_runtime_cc_args = function
  | TlsUnsupported -> []
  | TlsOpenSsl ->
      [ "-DBLORP_TLS_BACKEND_PROFILE_OPENSSL=1" ] @ openssl_cflags ()

let tls_backend_link_cc_args = function
  | TlsUnsupported -> []
  | TlsOpenSsl -> openssl_libs ()

(** Persistent cache directory for precompiled artifacts *)
let cache_dir () =
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let dir = Filename.concat home ".cache/blorp" in
  ensure_dir dir;
  dir

(** Immutable content-addressed cache namespace. *)
let cas_dir () =
  let dir = Filename.concat (cache_dir ()) "cas" in
  ensure_dir dir;
  dir

let cache_object_dir ~kind key =
  Filename.concat (cas_dir ())
    (Printf.sprintf "%s-%s" (sanitize_component kind) key)

let cache_ready_path dir = Filename.concat dir "READY"
let cache_manifest_path dir = Filename.concat dir "MANIFEST"
let cache_dir_ready dir = Sys.file_exists (cache_ready_path dir)

let write_ready_marker dir =
  let path = cache_ready_path dir in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc "ready\n")

type cache_slot_state = Cache_missing | Cache_ready | Cache_stale

let classify_cache_slot final_dir ~is_ready =
  if not (Sys.file_exists final_dir) then Cache_missing
  else if is_ready final_dir then Cache_ready
  else Cache_stale

let publish_verified_dir stage_dir final_dir ~is_ready =
  if not (is_ready stage_dir) then begin
    remove_tree stage_dir;
    failwith
      (Printf.sprintf "attempted to publish unverifiable cache stage: %s"
         stage_dir)
  end;
  let rec publish_attempt repairs =
    match classify_cache_slot final_dir ~is_ready with
    | Cache_ready ->
        remove_tree stage_dir;
        final_dir
    | Cache_stale ->
        if repairs >= 2 then begin
          remove_tree stage_dir;
          failwith
            (Printf.sprintf "cache slot remains stale after repair: %s"
               final_dir)
        end
        else begin
          remove_tree final_dir;
          publish_attempt (repairs + 1)
        end
    | Cache_missing -> (
        try
          Unix.rename stage_dir final_dir;
          final_dir
        with
        | Unix.Unix_error ((Unix.EEXIST | Unix.ENOTEMPTY), _, _) ->
            publish_attempt repairs
        | exn ->
            remove_tree stage_dir;
            raise exn)
  in
  publish_attempt 0

let publish_verified_cache_dir ~kind ~key stage_dir ~is_ready =
  publish_verified_dir stage_dir (cache_object_dir ~kind key) ~is_ready

(** Content hash of the runtime sources — changes when runtime.c or decl are modified *)
let runtime_hash () =
  Digest.to_hex
    (Digest.string
       ("runtime-v2\000" ^ Runtime.runtime_code ^ "\000" ^ Runtime.runtime_decl))

let cc_identity =
  lazy
    (let code, output = run_process_capture "cc" [ "--version" ] in
     string_of_int code ^ "\000" ^ output)

(** Content hash of a file. Returns hex digest string. *)
let file_content_hash path = try Digest.to_hex (Digest.file path) with _ -> ""

(** Content hash of the compiler binary — captures all embedded std + codegen changes.
    Memoized since the binary doesn't change during a test run. *)
let compiler_hash =
  let cached = ref None in
  fun () ->
    match !cached with
    | Some h -> h
    | None ->
        let h =
          try Digest.to_hex (Digest.file Sys.executable_name) with _ -> ""
        in
        cached := Some h;
        h

let runtime_cache_key ~sanitizer_mode ~opt ~tls_backend =
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          [
            "runtime-cache-v6";
            runtime_hash ();
            compiler_hash ();
            opt;
            sanitizer_mode_to_string sanitizer_mode;
            tls_backend_profile_to_string tls_backend;
            Sys.os_type;
            Lazy.force cc_identity;
            String.concat " " (sanitizer_cc_args sanitizer_mode);
            String.concat " " (tls_backend_runtime_cc_args tls_backend);
          ]))

let runtime_manifest ~key ~obj_path ~h_path ~tls_backend =
  String.concat "\n"
    [
      "runtime-cache-manifest-v1";
      "key=" ^ key;
      "tls_backend=" ^ tls_backend_profile_to_string tls_backend;
      "runtime.o=" ^ file_content_hash obj_path;
      "runtime.h=" ^ file_content_hash h_path;
      "";
    ]

let runtime_obj_path dir = Filename.concat dir "runtime.o"
let runtime_header_path dir = Filename.concat dir "runtime.h"

let write_runtime_manifest ~key ~obj_path ~h_path ~tls_backend dir =
  let path = cache_manifest_path dir in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () ->
      output_string oc (runtime_manifest ~key ~obj_path ~h_path ~tls_backend))

let runtime_cache_verified ~key ~tls_backend dir =
  let obj_path = runtime_obj_path dir in
  let h_path = runtime_header_path dir in
  cache_dir_ready dir && Sys.file_exists obj_path && Sys.file_exists h_path
  &&
    try
      read_file (cache_manifest_path dir)
      = runtime_manifest ~key ~obj_path ~h_path ~tls_backend
    with _ -> false

(** Compile runtime artifacts to the given paths (no caching logic here) *)
let compile_runtime_artifacts ?(sanitize = false) ?sanitizer_mode ?(opt = "O0")
    ?(tls_backend = TlsUnsupported) obj_path _pch_path h_path =
  let sanitizer_mode = select_sanitizer_mode ?sanitizer_mode ~sanitize () in
  let runtime_c =
    run_artifact_path ~kind:"runtime-src" ~prefix:"runtime" ~suffix:".c"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove runtime_c with _ -> ())
    (fun () ->
      let oc = open_out runtime_c in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () -> output_string oc Runtime.runtime_code);
      let opt_flag = "-" ^ opt in
      let cc_args =
        [
          "-c";
          opt_flag;
          "-fwrapv";
          "-pipe";
          "-w";
          "-o";
          obj_path;
          runtime_c;
          "-lpthread";
        ]
        @ tls_backend_runtime_cc_args tls_backend
        @ sanitizer_cc_args sanitizer_mode
      in
      let result, _output = run_process_capture "cc" cc_args in
      if result = 0 then begin
        let dh = open_out h_path in
        Fun.protect
          ~finally:(fun () -> close_out dh)
          (fun () -> output_string dh Runtime.runtime_decl);
        (* PCH artifacts embed the header path in at least Clang, so moving them
         from a staging directory into CAS corrupts the cache. Keep runtime
         caching immutable by caching runtime.o + header only. *)
        Some
          {
            runtime_obj = obj_path;
            header_file = h_path;
            pch_file = None;
            tls_backend;
          }
      end
      else None)

let precompile_runtime ?(sanitize = false) ?sanitizer_mode ?(opt = "O0") () =
  let sanitizer_mode = select_sanitizer_mode ?sanitizer_mode ~sanitize () in
  let tls_backend = current_tls_backend_profile () in
  let key = runtime_cache_key ~sanitizer_mode ~opt ~tls_backend in
  let dir = cache_object_dir ~kind:"runtime" key in
  let obj_path = runtime_obj_path dir in
  let h_path = runtime_header_path dir in
  let check_cached () =
    if runtime_cache_verified ~key ~tls_backend dir then
      Some
        {
          runtime_obj = obj_path;
          header_file = h_path;
          pch_file = None;
          tls_backend;
        }
    else None
  in
  match check_cached () with
  | Some _ as hit -> hit
  | None -> (
      let stage_dir =
        run_artifact_dir ~kind:"cache-stage" ~prefix:("runtime_" ^ key)
      in
      let stage_obj = runtime_obj_path stage_dir in
      let stage_h = runtime_header_path stage_dir in
      match
        compile_runtime_artifacts ~sanitizer_mode ~opt ~tls_backend stage_obj
          (Filename.concat stage_dir "runtime.h.pch")
          stage_h
      with
      | None ->
          remove_tree stage_dir;
          None
      | Some _ ->
          write_runtime_manifest ~key ~obj_path:stage_obj ~h_path:stage_h
            ~tls_backend stage_dir;
          write_ready_marker stage_dir;
          ignore
            (publish_verified_cache_dir ~kind:"runtime" ~key stage_dir
               ~is_ready:(runtime_cache_verified ~key ~tls_backend));
          check_cached ())

(** Check if raylib was imported (must be called after Pipeline.compile) *)
let has_raylib_import () =
  List.exists
    (fun m -> Filename.basename m.Modules.path = "raylib.brp")
    (Modules.get_all_modules ())

(** Platform-specific linker flags for raylib *)
let raylib_linker_flags () =
  let uname =
    let ic = Unix.open_process_in "uname" in
    let s = input_line ic in
    ignore (Unix.close_process_in ic);
    s
  in
  (* On macOS with Homebrew, raylib may be in /opt/homebrew which isn't in default search path *)
  let brew_prefix =
    if uname = "Darwin" then
      try
        let ic = Unix.open_process_in "brew --prefix raylib 2>/dev/null" in
        let s = String.trim (input_line ic) in
        ignore (Unix.close_process_in ic);
        if s <> "" then Printf.sprintf " -L%s/lib -I%s/include" s s else ""
      with _ -> ""
    else ""
  in
  if uname = "Darwin" then
    Printf.sprintf
      "%s -lraylib -framework IOKit -framework Cocoa -framework OpenGL \
       -framework CoreVideo"
      brew_prefix
  else " -lraylib -lGL -lm -lpthread -ldl -lrt -lX11"

(** Check if path is a directory *)
let is_directory path = try Sys.is_directory path with Sys_error _ -> false

(* ============================================================================
   Types
   ============================================================================ *)

type test_result = {
  file : string;
  passed : bool;
  duration : float;
  output : string;
  error_detail : string;
}
(** Result of running a single test *)

(** Test mode for --doc / --suite filtering *)
type test_mode = TestAll | DocOnly | SuiteOnly

let suite_run_all_begin_marker = "__BLORP_SUITE_RUN_ALL_BEGIN__"
let suite_run_all_end_marker = "__BLORP_SUITE_RUN_ALL_END__"

let normalized_relative_test_path filename =
  let cwd_prefix = Sys.getcwd () ^ Filename.dir_sep in
  if starts_with filename cwd_prefix then
    String.sub filename (String.length cwd_prefix)
      (String.length filename - String.length cwd_prefix)
  else if starts_with filename ("." ^ Filename.dir_sep) then
    String.sub filename 2 (String.length filename - 2)
  else filename

let path_under root path =
  path = root || starts_with path (root ^ Filename.dir_sep)

let process_isolated_suite_roots =
  [
    (* This Blorp compiler suite imports compiler_infer as part of second-pass
       body checking. When the generated run-all harness imports it before the
       compiler_infer suite, the current module-init path can exit before
	       main. Keep this file out of run-all batching until that harness/module
	       initialization issue is fixed. *)
	    "compiler/blorp/tests/test_compiler_typecheck_decl.brp";
	    (* Impl-declaration tests exercise the same declaration-checker import
	       graph and can fail in a combined run-all harness with neighboring
	       typecheck-state/typecheck-types suites. *)
	    "compiler/blorp/tests/test_compiler_typecheck_impl_decl.brp";
	    (* This suite shares the typecheck declaration path above and can exit
	       before main when imported in the same run-all harness as neighboring
	       typecheck-state tests. Run it through the ordinary one-file wrapper so
       module initialization is scoped to the test that needs it. *)
    "compiler/blorp/tests/test_compiler_typecheck_resource_decl.brp";
    "tests/test_blorp/concurrency";
    "tests/test_blorp/memory";
    "tests/test_blorp/sys";
  ]

let filesystem_isolated_suite_roots = [ "tests/test_blorp/memory" ]

let requires_process_isolation filename =
  let path = normalized_relative_test_path filename in
  List.exists (fun root -> path_under root path) process_isolated_suite_roots

let requires_filesystem_isolation filename =
  let path = normalized_relative_test_path filename in
  List.exists (fun root -> path_under root path) filesystem_isolated_suite_roots

type test_file_info = {
  test_file_path : string;
  test_file_source : string;
  test_file_has_main : bool;
  test_file_is_suite : bool;
  test_file_is_leak_baseline_program : bool;
  test_file_has_doctests : bool;
  test_file_requires_process_isolation : bool;
  test_file_requires_filesystem_isolation : bool;
}

let leak_baseline_root = "tests/test_blorp/memory/leak_check_baselines"

let is_leak_baseline_program filename =
  let path = normalized_relative_test_path filename in
  path_under leak_baseline_root path && Filename.check_suffix path ".brp"

let classify_test_file filename =
  let source = read_file filename in
  {
    test_file_path = filename;
    test_file_source = source;
    test_file_has_main = has_top_level_main_source source;
    test_file_is_suite = source_declares_testsuite source;
    test_file_is_leak_baseline_program = is_leak_baseline_program filename;
    test_file_has_doctests = source_mentions_doctests source;
    test_file_requires_process_isolation = requires_process_isolation filename;
    test_file_requires_filesystem_isolation =
      requires_filesystem_isolation filename;
  }

let isolated_test_environment cwd = [ ("TMPDIR", cwd) ]

let isolated_test_cwd filename =
  run_artifact_dir ~kind:"isolated-filesystems"
    ~prefix:(Filename.basename (Filename.remove_extension filename))

type doctest_group = {
  dtg_func_name : string;
  dtg_description : string;
  dtg_imports : string list;
  dtg_code : string;
  dtg_code_origins : int list;
}
(** A single doctest group extracted from a docstring.

    [dtg_code_origins] is a list of 1-based source-file line numbers
    parallel to [dtg_code]'s \n-split lines: element [i] is the line
    in the ORIGINAL source file where [List.nth (split_on_char '\n'
    dtg_code) i] came from. Populated by [extract_doctests_from_doc]
    which threads origin tracking through its strip/split passes. The
    map is consumed by [generate_doctest_program_with_map] to build
    the synthetic → original loc remap that lets compile errors
    surface at the user's actual source line instead of the
    synthetic temp file's. Empty list if the extractor didn't receive
    origin info (backward-compat; diagnostics stay on the synthetic
    file in that case). *)

type loc_remap_entry = { original_file : string; original_line : int }
(** One entry in the synthetic→original loc remap table. *)

type loc_remap_table = (int, loc_remap_entry) Hashtbl.t
(** Maps synthetic-source line number → original-file + line. Built
    by [generate_doctest_program_with_map] and consumed by the error-
    path remapper in [run_test_result]. Synthetic lines that don't
    appear in the table are generator-owned boilerplate (imports,
    func wrappers, the [tests:] struct) — errors pointing there
    indicate a generator bug, not user code, and the remapper falls
    back to owning-function context in that case. *)

(* ============================================================================
   Test Result Cache
   ============================================================================ *)

type cache_entry = {
  ce_test_hash : string;  (** Content hash of the test source file *)
  ce_deps : (string * string) list;
      (** (path, content_hash) for all transitive deps *)
  ce_runtime_hash : string;  (** Content hash of runtime source *)
  ce_compiler_hash : string;  (** Content hash of the blorp binary *)
  ce_result : test_result;  (** The cached test result *)
}
(** Cached test result entry — stores content-addressable fingerprint + result.
    All fields use content hashes, not timestamps, for deterministic caching. *)

(** Whether test result caching is enabled (default: true) *)
let test_cache_enabled = ref true

(** Get the compiler binary mtime *)
let compiler_mtime () =
  try (Unix.stat Sys.executable_name).st_mtime with _ -> 0.0

(* Note: compiler_mtime is still used by check_stale_std for the mtime-based
   warning about editing std/ without rebuilding. The test cache itself uses
   content-addressable compiler_hash instead. *)

(** Check if any std/ source files are newer than the compiler binary.
    Since std modules are embedded in the binary, editing .brp files without
    running `make` causes the compiler to use stale embedded sources. *)
let check_stale_std () =
  let bin_mtime = compiler_mtime () in
  if bin_mtime = 0.0 then ()
  else
    let std_dir =
      try
        let base = Filename.dirname Sys.executable_name in
        let candidate = Filename.concat base "std" in
        if Sys.file_exists candidate && Sys.is_directory candidate then
          Some candidate
        else if
          (* Try relative to cwd *)
          Sys.file_exists "std" && Sys.is_directory "std"
        then Some "std"
        else None
      with _ -> None
    in
    match std_dir with
    | None -> ()
    | Some dir ->
        let stale = ref [] in
        let rec walk path =
          if Sys.is_directory path then
            Array.iter
              (fun name -> walk (Filename.concat path name))
              (Sys.readdir path)
          else if Filename.check_suffix path ".brp" then
            try
              let mtime = (Unix.stat path).st_mtime in
              if mtime > bin_mtime then stale := path :: !stale
            with _ -> ()
        in
        (try walk dir with _ -> ());
        if !stale <> [] then begin
          Printf.eprintf
            "Warning: %d std/ file(s) modified since last build. Run `make` to \
             apply changes.\n\
             %!"
            (List.length !stale);
          List.iter
            (fun f -> Printf.eprintf "  modified: %s\n%!" f)
            (List.filteri (fun i _ -> i < 5) !stale);
          if List.length !stale > 5 then
            Printf.eprintf "  ... and %d more\n%!" (List.length !stale - 5)
        end

(** Get the test result cache directory, creating if needed *)
let test_cache_dir () =
  let dir = Filename.concat (cas_dir ()) "test-results" in
  ensure_dir dir;
  dir

let test_cache_prefix_key filename =
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          [
            "test-result-v2";
            filename;
            file_content_hash filename;
            runtime_hash ();
            compiler_hash ();
          ]))

let deps_fingerprint deps =
  let deps = List.sort (fun (a, _) (b, _) -> compare a b) deps in
  Digest.to_hex
    (Digest.string
       (String.concat "\000"
          ("deps-v1"
          :: List.concat_map (fun (path, hash) -> [ path; hash ]) deps)))

let test_cache_prefix_dir filename =
  Filename.concat (test_cache_dir ()) (test_cache_prefix_key filename)

let test_cache_entry_file dir = Filename.concat dir "result.cache"

(** Try to load a cached result for a test file.
    Returns Some result if the cache is valid, None if stale or missing.
    All checks are content-addressable — immune to timestamp changes. *)
let check_test_cache filename =
  if not !test_cache_enabled then None
  else
    let dir = test_cache_prefix_dir filename in
    if not (Sys.file_exists dir && Sys.is_directory dir) then None
    else
      let valid_entry entry =
        file_content_hash filename = entry.ce_test_hash
        && runtime_hash () = entry.ce_runtime_hash
        && compiler_hash () = entry.ce_compiler_hash
        && not
             (List.exists
                (fun (path, hash) -> file_content_hash path <> hash)
                entry.ce_deps)
      in
      let rec scan = function
        | [] -> None
        | name :: rest -> (
            let entry_dir = Filename.concat dir name in
            let cache_file = test_cache_entry_file entry_dir in
            if not (cache_dir_ready entry_dir && Sys.file_exists cache_file)
            then scan rest
            else
              try
                let ic = open_in_bin cache_file in
                let entry : cache_entry =
                  Fun.protect
                    ~finally:(fun () -> close_in ic)
                    (fun () -> Marshal.from_channel ic)
                in
                if valid_entry entry then Some entry.ce_result else scan rest
              with _ -> scan rest)
      in
      scan (Array.to_list (Sys.readdir dir))

(** Save a test result to the cache, recording all transitive dependencies.
    Only cache passing results — failed tests should always be re-run. *)
let save_test_cache filename result =
  if not !test_cache_enabled then ()
  else if not result.passed then ()
  else
    try
      let test_hash = file_content_hash filename in
      (* Hash each transitive dependency file individually.
       Skip embedded modules — their content is captured by compiler_hash. *)
      let deps =
        List.filter_map
          (fun m ->
            try
              let path = m.Modules.path in
              Some (path, file_content_hash path)
            with _ -> None)
          (Modules.get_all_modules ())
      in
      let entry =
        {
          ce_test_hash = test_hash;
          ce_deps = deps;
          ce_runtime_hash = runtime_hash ();
          ce_compiler_hash = compiler_hash ();
          ce_result = result;
        }
      in
      let prefix_dir = test_cache_prefix_dir filename in
      ensure_dir prefix_dir;
      let final_dir = Filename.concat prefix_dir (deps_fingerprint deps) in
      let stage_dir =
        run_artifact_dir ~kind:"cache-stage" ~prefix:"test_result"
      in
      let cache_file = test_cache_entry_file stage_dir in
      let oc = open_out_bin cache_file in
      Fun.protect
        ~finally:(fun () -> close_out oc)
        (fun () -> Marshal.to_channel oc entry []);
      write_ready_marker stage_dir;
      ignore
        (publish_verified_dir stage_dir final_dir ~is_ready:(fun dir ->
             cache_dir_ready dir && Sys.file_exists (test_cache_entry_file dir)))
    with _ -> ()

(* ============================================================================
   Doctest Extraction
   ============================================================================ *)

(** Extract doctest groups from a docstring.

    Each line of the docstring has an origin line number in the
    original source file: [doc_start_line] is the 1-based file line
    of the docstring's FIRST content line (the line immediately after
    the opening [---]). This function threads origin numbers through
    every transformation — split-on-delimiters, blank-edge strip,
    import separation — so [dtg_code_origins] ends up parallel to
    [String.split_on_char '\n' dtg_code]. Without this, compile
    errors in doctest bodies would land on the synthetic temp file
    instead of the user's source.

    [?doc_start_line] defaults to [1] for legacy call-sites that
    don't care about origin tracking. *)
let extract_doctests_from_doc ?(doc_start_line = 1) func_name doc =
  let lines = String.split_on_char '\n' doc in
  (* Pair each line with its origin line in the source file. The doc
     starts at [doc_start_line] — that's line 0 of [lines] in the
     docstring-relative view. *)
  let lines_with_origin =
    List.mapi (fun i line -> (line, doc_start_line + i)) lines
  in
  let rec find_examples = function
    | [] -> []
    | (line, _) :: rest ->
        let trimmed = String.trim line in
        if trimmed = "doctests:" then rest else find_examples rest
  in
  let example_lines = find_examples lines_with_origin in
  if example_lines = [] then []
  else
    let strip_indent line =
      let len = String.length line in
      if len >= 4 && String.sub line 0 4 = "    " then
        String.sub line 4 (len - 4)
      else if len >= 1 && line.[0] = '\t' then String.sub line 1 (len - 1)
      else line
    in
    let stripped =
      List.map (fun (line, origin) -> (strip_indent line, origin)) example_lines
    in
    let is_delimiter line =
      let t = String.trim line in
      String.length t >= 2 && String.sub t 0 2 = "::"
    in
    let get_description line =
      let t = String.trim line in
      String.trim (String.sub t 2 (String.length t - 2))
    in
    let rec split_on_delimiters current_desc current_code groups = function
      | [] ->
          let groups =
            if current_desc <> "" then
              (current_desc, List.rev current_code) :: groups
            else groups
          in
          List.rev groups
      | (line, origin) :: rest ->
          if is_delimiter line then
            let groups =
              if current_desc <> "" then
                (current_desc, List.rev current_code) :: groups
              else groups
            in
            split_on_delimiters (get_description line) [] groups rest
          else
            split_on_delimiters current_desc
              ((line, origin) :: current_code)
              groups rest
    in
    let groups = split_on_delimiters "" [] [] stripped in
    let rec drop_while_blank = function
      | (line, _) :: rest when String.trim line = "" -> drop_while_blank rest
      | lines -> lines
    in
    let strip_blank_edges lines =
      let lines = drop_while_blank lines in
      List.rev (drop_while_blank (List.rev lines))
    in
    let separate_imports code_lines =
      match code_lines with
      | (first, _) :: rest when String.trim first = "import:" ->
          let rec consume acc = function
            | (line, origin) :: remaining
              when String.length line >= 4
                   && String.sub line 0 4 = "    "
                   && String.trim line <> "" ->
                consume (("    " ^ String.trim line, origin) :: acc) remaining
            | other -> (List.rev acc, other)
          in
          consume [] rest
      | _ -> ([], code_lines)
    in
    List.map
      (fun (desc, code_lines) ->
        let cleaned = strip_blank_edges code_lines in
        let imports, remaining = separate_imports cleaned in
        let kept = strip_blank_edges remaining in
        let code_only = List.map fst kept in
        let origins = List.map snd kept in
        let code = String.concat "\n" code_only in
        {
          dtg_func_name = func_name;
          dtg_description = desc;
          dtg_imports = List.map fst imports;
          dtg_code = code;
          dtg_code_origins = origins;
        })
      groups
    |> List.filter (fun g -> String.trim g.dtg_code <> "")

(** Get function name from a decl_desc *)
let func_name_of_decl_desc = function
  | Ast.DFunc f -> f.func_name
  | Ast.DType t -> Some t.type_name
  | Ast.DRecord r -> Some r.record_name
  | Ast.DTrait t -> Some t.trait_name
  | _ -> None

(** Find the source-file line where a docstring's content starts.

    blorp docstrings are structured as
    {v
    ---
    docstring line 1
    docstring line 2
    ---
    pure func foo():
    v}

    Given the decl's line and the source text, scan backward past
    blank lines, expect a closing [---], then continue scanning
    backward past docstring content to find the opening [---]. The
    opening line + 1 is the docstring's first content line, which
    is what [extract_doctests_from_doc] wants as [~doc_start_line].

    Returns [None] if the expected shape isn't found (e.g. the
    docstring is attached via a different path, or the decl's loc
    predates the opening marker for some reason — either is harmless;
    origin tracking just falls back to synthetic line numbers). *)
let find_docstring_start_line (source_text : string) (decl_line : int) :
    int option =
  if decl_line <= 1 then None
  else
    let lines = Array.of_list (String.split_on_char '\n' source_text) in
    let n = Array.length lines in
    if decl_line > n then None
    else
      let is_delim i = i >= 0 && i < n && String.trim lines.(i) = "---" in
      (* [$symbolstartpos] in the parser's docstring→decl rules points
         at the CLOSING [---] line (empirically; attaches the doc's
         span via the rule's start symbol which is the docstring
         itself). decl_line here is therefore usually the line of the
         closing delimiter when a docstring is present.

         Start at [decl_line - 1] (0-based array index of decl_line).
         If that's a [---], use it as the closing delimiter and scan
         backward for the opening [---]. The opening line + 1 is the
         first content line. If decl_line - 1 is NOT a delimiter,
         the decl doesn't have the expected [---]/.../--- shape
         above it and we bail with [None] — the extractor falls back
         to assuming line 1, which loses remap fidelity but doesn't
         crash. *)
      let closing_idx = decl_line - 1 in
      if not (is_delim closing_idx) then None
      else
        let rec find_opening i =
          if i < 0 then None
          else if is_delim i then Some i
          else find_opening (i - 1)
        in
        match find_opening (closing_idx - 1) with
        | Some opening_idx -> Some (opening_idx + 2)
        | None -> None

(** Extract all doctests from a parsed program.

    When [~source_text] is supplied, each doctest group's code lines
    are tagged with their origin line number in the source file
    (see [find_docstring_start_line]). Without it, origins default
    to [1]-offset into the docstring, which is fine for feature
    parity but doesn't support the synthetic→original loc remap. *)
let extract_all_doctests ?(source_text = "") program =
  let extract_from_decl decl =
    let doc =
      match decl.Ast.decl_doc with
      | Some d -> Some d
      | None -> (
          match decl.Ast.decl_desc with
          | Ast.DPrivate inner -> inner.Ast.decl_doc
          | _ -> None)
    in
    match doc with
    | Some d when contains_substring d "doctests:" ->
        let name =
          match decl.Ast.decl_desc with
          | Ast.DPrivate inner -> (
              match func_name_of_decl_desc inner.Ast.decl_desc with
              | Some n -> n
              | None -> "unknown")
          | other -> (
              match func_name_of_decl_desc other with
              | Some n -> n
              | None -> "unknown")
        in
        let doc_start_line =
          if source_text = "" then 1
          else
            match
              find_docstring_start_line source_text decl.Ast.decl_loc.line
            with
            | Some l -> l
            | None -> 1
        in
        extract_doctests_from_doc ~doc_start_line name d
    | _ -> []
  in
  List.concat_map extract_from_decl program

(* ============================================================================
   Test File Helpers
   ============================================================================ *)

(** Collect import declarations from a program as import block item lines *)
let collect_import_lines program =
  List.filter_map
    (fun decl ->
      match decl.Ast.decl_desc with
      | Ast.DImport imp ->
          let line =
            match (imp.import_symbols, imp.import_alias) with
            | Some syms, Some alias ->
                let sym_strs =
                  List.map
                    (fun (s : Ast.import_symbol) ->
                      match s.sym_alias with
                      | Some a -> s.sym_name ^ " as " ^ a
                      | None -> s.sym_name)
                    syms
                in
                Printf.sprintf "    %s as %s: %s" imp.import_module alias
                  (String.concat ", " sym_strs)
            | Some syms, None ->
                let sym_strs =
                  List.map
                    (fun (s : Ast.import_symbol) ->
                      match s.sym_alias with
                      | Some a -> s.sym_name ^ " as " ^ a
                      | None -> s.sym_name)
                    syms
                in
                Printf.sprintf "    %s: %s" imp.import_module
                  (String.concat ", " sym_strs)
            | None, Some alias ->
                Printf.sprintf "    %s as %s" imp.import_module alias
            | None, None -> Printf.sprintf "    %s" imp.import_module
          in
          Some line
      | _ -> None)
    program

(** Collect imported module basenames from a program *)
let collect_imported_module_names program =
  List.filter_map
    (fun decl ->
      match decl.Ast.decl_desc with
      | Ast.DImport imp -> Some (Filename.basename imp.import_module)
      | _ -> None)
    program

let import_line_module_name line =
  let trimmed = String.trim line in
  let stop =
    let len = String.length trimmed in
    let rec loop i =
      if i >= len then len
      else match trimmed.[i] with ' ' | ':' -> i | _ -> loop (i + 1)
    in
    loop 0
  in
  if stop = 0 then "" else Filename.basename (String.sub trimmed 0 stop)

let import_block_indent = "    "

let split_import_symbols raw =
  let flush current acc =
    let sym = Buffer.contents current |> String.trim in
    Buffer.clear current;
    if sym = "" then acc else sym :: acc
  in
  let rec loop depth current acc i =
    if i >= String.length raw then List.rev (flush current acc)
    else
      let ch = raw.[i] in
      match ch with
      | ',' when depth = 0 -> loop depth current (flush current acc) (i + 1)
      | '(' ->
          Buffer.add_char current ch;
          loop (depth + 1) current acc (i + 1)
      | ')' ->
          Buffer.add_char current ch;
          loop (max 0 (depth - 1)) current acc (i + 1)
      | _ ->
          Buffer.add_char current ch;
          loop depth current acc (i + 1)
  in
  loop 0 (Buffer.create (String.length raw)) [] 0

type selective_import_line = {
  import_head : string;
  import_module_name : string;
  import_symbols : string list;
}

let parse_selective_import_line line =
  let trimmed = String.trim line in
  match String.index_opt trimmed ':' with
  | None -> None
  | Some colon ->
      let head = String.sub trimmed 0 colon |> String.trim in
      let raw_symbols =
        String.sub trimmed (colon + 1) (String.length trimmed - colon - 1)
      in
      Some
        {
          import_head = head;
          import_module_name = import_line_module_name line;
          import_symbols = split_import_symbols raw_symbols;
        }

let format_selective_import_line parsed =
  Printf.sprintf "%s%s: %s" import_block_indent parsed.import_head
    (String.concat ", " parsed.import_symbols)

let merge_symbol_lists existing additions =
  List.fold_left
    (fun acc sym -> if List.mem sym acc then acc else acc @ [ sym ])
    existing additions

let merge_doctest_import_line lines line =
  match parse_selective_import_line line with
  | Some requested ->
      let rec go acc = function
        | [] ->
            if
              List.exists
                (fun existing ->
                  import_line_module_name existing
                  = requested.import_module_name)
                lines
            then lines
            else lines @ [ line ]
        | existing :: rest -> (
            match parse_selective_import_line existing with
            | Some parsed when parsed.import_head = requested.import_head ->
                let merged =
                  {
                    parsed with
                    import_symbols =
                      merge_symbol_lists parsed.import_symbols
                        requested.import_symbols;
                  }
                  |> format_selective_import_line
                in
                List.rev_append acc (merged :: rest)
            | _ -> go (existing :: acc) rest)
      in
      go [] lines
  | None ->
      if
        List.mem line lines
        || List.exists
             (fun existing ->
               import_line_module_name existing = import_line_module_name line)
             lines
      then lines
      else lines @ [ line ]

(** Collect exported function names from a program *)
let collect_exported_names program =
  List.filter_map
    (fun decl ->
      match decl.Ast.decl_desc with
      | Ast.DPrivate _ | Ast.DImport _ -> None
      | other -> func_name_of_decl_desc other)
    program
  |> List.sort_uniq String.compare

(** Collect imported symbol names that are already in scope for a module.
    Used to avoid re-importing conflicting export names in generated doctests. *)
let collect_imported_names program =
  List.concat_map
    (fun decl ->
      match decl.Ast.decl_desc with
      | Ast.DImport imp -> (
          match imp.import_symbols with
          | Some syms ->
              List.map
                (fun (s : Ast.import_symbol) ->
                  match s.sym_alias with Some a -> a | None -> s.sym_name)
                syms
          | None -> (
              match imp.import_alias with
              | Some alias -> [ alias ]
              | None -> [ Filename.basename imp.import_module ]))
      | _ -> [])
    program

(** Generate a synthetic doctest program + its synthetic→original
    loc remap table.

    The table is populated only for lines emitted from [dtg_code] —
    generator-owned scaffolding (imports, [func __doctest_foo_0()…]
    wrappers, the [tests:] struct) is intentionally absent. Callers
    can fall back to owning-function context when a loc doesn't
    appear in the table.

    This function doesn't compute [doc_start_line] from the source
    itself — it trusts [doctests]' [dtg_code_origins] field, which
    was populated upstream by [extract_all_doctests ~source_text].
    Origins of [0] or [1] (the legacy "unknown origin" sentinel) are
    still recorded as-is; the caller decides whether to treat them
    as meaningful. *)
let generate_doctest_program_with_map_impl source_path program doctests =
  let module_path =
    let base = Filename.remove_extension source_path in
    let cwd = Sys.getcwd () in
    if
      String.starts_with ~prefix:cwd base
      && String.length base > String.length cwd
    then
      String.sub base
        (String.length cwd + 1)
        (String.length base - String.length cwd - 1)
    else base
  in
  let buf = Buffer.create 1024 in
  let remap : loc_remap_table = Hashtbl.create 32 in
  let cur_line = ref 1 in
  let emit s =
    Buffer.add_string buf s;
    String.iter (fun c -> if c = '\n' then incr cur_line) s
  in
  let import_lines = collect_import_lines program in
  let imported_names = collect_imported_names program in
  let exported =
    collect_exported_names program
    |> List.filter (fun n -> not (List.mem n imported_names))
  in
  let all_code =
    String.concat "\n" (List.map (fun dt -> dt.dtg_code) doctests)
  in
  let needs_result =
    contains_substring all_code "Ok("
    || contains_substring all_code "Err("
    || contains_substring all_code "Result["
    || contains_substring all_code "to_bool("
  in
  let needs_option =
    contains_substring all_code "Some("
    || contains_substring all_code "None"
    || contains_substring all_code "Option["
  in
  let imported_mod_names = collect_imported_module_names program in
  let self_module_name = Filename.basename module_path in
  let doctest_imports =
    List.concat_map (fun dt -> dt.dtg_imports) doctests
    |> List.sort_uniq String.compare
  in
  let doctest_imported_mod_names =
    List.map import_line_module_name doctest_imports
  in
  let prelude_imports =
    (if
       needs_option
       && (not (List.mem "option" imported_mod_names))
       && (not (List.mem "option" doctest_imported_mod_names))
       && self_module_name <> "option"
     then [ "    std/option: Option(Some, None)" ]
     else [])
    @
    if
      needs_result
      && (not (List.mem "result" imported_mod_names))
      && (not (List.mem "result" doctest_imported_mod_names))
      && self_module_name <> "result"
    then [ "    std/result: Result(Ok, Err)" ]
    else []
  in
  let extra_lines =
    (if exported <> [] && not (List.mem self_module_name imported_mod_names)
     then
       [ Printf.sprintf "    %s: %s" module_path (String.concat ", " exported) ]
     else [])
    @ (if
         (not (List.mem "test" imported_mod_names))
         && self_module_name <> "test"
       then [ "    std/test: TestSuite, run_suite" ]
       else [])
    @ prelude_imports
  in
  let all_import_lines =
    List.fold_left merge_doctest_import_line
      (import_lines @ extra_lines)
      doctest_imports
  in
  if all_import_lines <> [] then begin
    emit "import:\n";
    List.iter
      (fun line ->
        emit line;
        emit "\n")
      all_import_lines
  end;
  emit "\n";
  List.iteri
    (fun i dt ->
      let fn_name = Printf.sprintf "__doctest_%s_%d" dt.dtg_func_name i in
      emit (Printf.sprintf "func %s() -> Bool:\n" fn_name);
      let code_lines = String.split_on_char '\n' dt.dtg_code in
      (* Walk code lines in parallel with origins; on mismatch (which
       happens only if origins wasn't populated), leave unmapped. *)
      let origins_arr = Array.of_list dt.dtg_code_origins in
      List.iteri
        (fun j line ->
          let syn_line = !cur_line in
          if j < Array.length origins_arr && origins_arr.(j) > 0 then
            Hashtbl.replace remap syn_line
              { original_file = source_path; original_line = origins_arr.(j) };
          emit "    ";
          emit line;
          emit "\n")
        code_lines;
      emit "\n")
    doctests;
  (* Emit [main] inline here rather than leaving a [tests: TestSuite]
     struct for [generate_test_wrapper] to rearrange. The wrapper
     moves the tests block inside [main], which shifts line numbers
     downstream and invalidates the synthetic→original [remap] we
     just built — the remap is keyed on THIS source's line numbers,
     not the post-wrap version's. Emitting the final form in one go
     keeps the mapping stable end-to-end. *)
  emit "tests: TestSuite = {\n";
  emit "    description = \"Doctests\",\n";
  emit "    tests = [\n";
  List.iteri
    (fun i dt ->
      let fn_name = Printf.sprintf "__doctest_%s_%d" dt.dtg_func_name i in
      let test_name =
        Printf.sprintf "%s: %s" dt.dtg_func_name dt.dtg_description
      in
      let comma = if i < List.length doctests - 1 then "," else "" in
      emit (Printf.sprintf "        (\"%s\", %s)%s\n" test_name fn_name comma))
    doctests;
  emit "    ]\n";
  emit "}\n";
  emit "\n";
  emit "func main(args: List[String]) -> Int:\n";
  emit "    if run_suite(tests):\n";
  emit "        0\n";
  emit "    else:\n";
  emit "        1\n";
  (Buffer.contents buf, remap)

let generate_doctest_program_with_map ~source_path ~source_text program =
  let doctests = extract_all_doctests ~source_text program in
  generate_doctest_program_with_map_impl source_path program doctests

(** Check if a file looks like a valid test *)
let is_valid_test_info ~leak_check info =
  info.test_file_is_suite || info.test_file_has_doctests
  || (leak_check && info.test_file_is_leak_baseline_program)

let classify_valid_test_file ~leak_check filename =
  let info = classify_test_file filename in
  if is_valid_test_info ~leak_check info then Some info else None

let classify_discovered_test_file ~leak_check filename =
  try classify_valid_test_file ~leak_check filename with _ -> None

(** Directories to skip when searching for test files *)
let skip_directories =
  [ "test_compiler"; "should_fail"; "should_pass" ]

(** Find all .brp test files in a directory *)
let sorted_directory_entries path =
  Sys.readdir path |> Array.to_list |> List.sort String.compare

let find_brp_file_infos ~leak_check dir =
  let rec walk acc path =
    if Sys.is_directory path then
      let dirname = Filename.basename path in
      if List.mem dirname skip_directories then acc
      else
        List.fold_left
          (fun acc name -> walk acc (Filename.concat path name))
          acc
          (sorted_directory_entries path)
    else if Filename.check_suffix path ".brp" then
      match classify_discovered_test_file ~leak_check path with
      | Some info -> info :: acc
      | None -> acc
    else acc
  in
  List.rev (walk [] dir)

let find_brp_files ?(leak_check = false) dir =
  List.map
    (fun info -> info.test_file_path)
    (find_brp_file_infos ~leak_check dir)

let collect_test_file_infos ~leak_check paths =
  let infos_for_path path =
    if is_directory path then find_brp_file_infos ~leak_check path
    else
      match classify_valid_test_file ~leak_check path with
      | Some info -> [ info ]
      | None -> []
  in
  List.fold_right (fun path acc -> infos_for_path path @ acc) paths []

let collect_test_files paths =
  let files_for_path path =
    if is_directory path then find_brp_files path
    else
      match classify_valid_test_file ~leak_check:false path with
      | Some info -> [ info.test_file_path ]
      | None -> []
  in
  List.fold_right (fun path acc -> files_for_path path @ acc) paths []

(* ============================================================================
   Test Wrapper Generation
   ============================================================================ *)

(** Generate a test wrapper for a TestSuite file *)
let generate_test_wrapper ?(leak_check = false) test_file_content =
  let run_fn = if leak_check then "run_suite_leak_check" else "run_suite" in
  let has_run_suite_import = contains_substring test_file_content "run_suite" in
  let content_with_import =
    if has_run_suite_import && not leak_check then test_file_content
    else
      let lines = String.split_on_char '\n' test_file_content in
      (* Core-emit needs [run_suite] explicitly imported into test files.
         Match the ["test: ..."] selective import form and inject
         [run_suite] into the import list. *)
      let is_test_import trimmed =
        let prefix_match =
          contains_substring trimmed "std/test"
          || contains_substring trimmed "test:"
        in
        prefix_match
        && contains_substring trimmed "TestSuite"
        && contains_substring trimmed ":"
      in
      let modified_lines =
        List.map
          (fun line ->
            let trimmed = String.trim line in
            if is_test_import trimmed then line ^ ", " ^ run_fn else line)
          lines
      in
      String.concat "\n" modified_lines
  in
  let lines = String.split_on_char '\n' content_with_import in
  let before_tests, tests_lines, after_tests =
    let rec find_tests acc = function
      | [] -> (List.rev acc, [], [])
      | line :: rest ->
          if
            contains_substring line "tests: TestSuite"
            || contains_substring line "tests:TestSuite"
          then
            let rec collect_tests_block block_lines brace_depth remaining =
              match remaining with
              | [] -> (List.rev block_lines, [])
              | l :: rs ->
                  let opens =
                    String.fold_left
                      (fun c ch -> if ch = '{' then c + 1 else c)
                      0 l
                  in
                  let closes =
                    String.fold_left
                      (fun c ch -> if ch = '}' then c + 1 else c)
                      0 l
                  in
                  let new_depth = brace_depth + opens - closes in
                  let new_block = l :: block_lines in
                  if new_depth <= 0 then (List.rev new_block, rs)
                  else collect_tests_block new_block new_depth rs
            in
            let tests_block, remaining = collect_tests_block [ line ] 1 rest in
            (List.rev acc, tests_block, remaining)
          else find_tests (line :: acc) rest
    in
    find_tests [] lines
  in
  let before_str = String.concat "\n" before_tests in
  let after_str = String.concat "\n" after_tests in
  let tests_str = String.concat "\n    " tests_lines in
  before_str ^ "\n" ^ after_str
  ^ "\n\nfunc main(args: List[String]) -> Int:\n    " ^ tests_str ^ "\n    if "
  ^ run_fn ^ "(tests):\n        0\n    else:\n        1\n"

let module_path_for_import filename =
  let base = Filename.remove_extension filename in
  let cwd = Sys.getcwd () in
  let cwd_prefix = cwd ^ Filename.dir_sep in
  let relative =
    if starts_with base cwd_prefix then
      String.sub base (String.length cwd_prefix)
        (String.length base - String.length cwd_prefix)
    else if starts_with base ("." ^ Filename.dir_sep) then
      String.sub base 2 (String.length base - 2)
    else base
  in
  if
    Filename.is_relative relative
    && (not (starts_with relative ("." ^ Filename.dir_sep)))
    && (not (starts_with relative (".." ^ Filename.dir_sep)))
    && not (starts_with relative "std/")
  then "." ^ Filename.dir_sep ^ relative
  else relative

let blorp_string_literal value = Printf.sprintf "%S" value

let emit_suite_harness_imports ?(selector_support = false)
    ?(suite_type_support = false) emit run_fn test_files =
  emit "import:";
  let test_import =
    if suite_type_support then Printf.sprintf "TestSuite, %s" run_fn else run_fn
  in
  emit (Printf.sprintf "    std/test: %s" test_import);
  if selector_support then begin
    emit "    std/string: parse_int";
    emit "    std/list: get";
    emit "    std/option: Option(Some, None)"
  end;
  List.iteri
    (fun i file ->
      emit (Printf.sprintf "    %s as T%d" (module_path_for_import file) i))
    test_files;
  emit "";
  emit ""

(** Generate a selector harness that compiles multiple TestSuite modules once
    while still running exactly one suite per process. *)
let generate_suite_selector_harness ?(leak_check = false) test_files =
  let run_fn = if leak_check then "run_suite_leak_check" else "run_suite" in
  let buf = Buffer.create 4096 in
  let emit line =
    Buffer.add_string buf line;
    Buffer.add_char buf '\n'
  in
  emit_suite_harness_imports ~selector_support:true emit run_fn test_files;
  emit "func __run_selected(index: Int) -> Bool:";
  emit "    match index:";
  List.iteri
    (fun i _file ->
      emit (Printf.sprintf "        %d:" i);
      emit (Printf.sprintf "            %s(T%d.tests)" run_fn i))
    test_files;
  emit "        _:";
  emit "            False";
  emit "";
  emit "";
  emit "func main(args: List[String]) -> Int:";
  emit "    match get(args, 1):";
  emit "        Some(selector):";
  emit "            match parse_int(selector):";
  emit "                Some(index):";
  emit "                    if __run_selected(index):";
  emit "                        0";
  emit "                    else:";
  emit "                        1";
  emit "                None:";
  emit "                    2";
  emit "        None:";
  emit "            2";
  Buffer.contents buf

(** Generate a harness that compiles multiple TestSuite modules once and runs
    ordinary suites inside one process. Process-sensitive suites are kept out
    by [suite_run_all_eligible]; this generator only builds the fast path. *)
let generate_suite_run_all_harness test_files =
  let run_fn = "run_suite" in
  let buf = Buffer.create 4096 in
  let emit line =
    Buffer.add_string buf line;
    Buffer.add_char buf '\n'
  in
  emit_suite_harness_imports ~suite_type_support:true emit run_fn test_files;
  List.iteri
    (fun i file ->
      emit (Printf.sprintf "func __run_suite_%d() -> Bool:" i);
      emit
        (Printf.sprintf "    print(%s)"
           (blorp_string_literal
              (Printf.sprintf "%s %d %s" suite_run_all_begin_marker i file)));
      emit (Printf.sprintf "    suite: TestSuite = T%d.tests" i);
      emit (Printf.sprintf "    passed: Bool = %s(suite)" run_fn);
      emit "    if passed:";
      emit
        (Printf.sprintf "        print(%s)"
           (blorp_string_literal
              (Printf.sprintf "%s %d PASS %s" suite_run_all_end_marker i file)));
      emit "    else:";
      emit
        (Printf.sprintf "        print(%s)"
           (blorp_string_literal
              (Printf.sprintf "%s %d FAIL %s" suite_run_all_end_marker i file)));
      emit "    passed";
      emit "";
      emit "")
    test_files;
  emit "func __run_all_suites() -> Bool:";
  emit "    var passed: Bool = True";
  List.iteri
    (fun i _file ->
      emit (Printf.sprintf "    if not __run_suite_%d():" i);
      emit "        passed = False")
    test_files;
  emit "    passed";
  emit "";
  emit "";
  emit "func main(args: List[String]) -> Int:";
  emit "    if __run_all_suites():";
  emit "        0";
  emit "    else:";
  emit "        1";
  Buffer.contents buf

(* ============================================================================
   Test Execution
   ============================================================================ *)

(** Parse a blorp file and return the AST *)
let parse_file_source filename input =
  let base_dir = extract_directory filename in
  init_module_paths base_dir;
  match Modules.parse_typecheck_source ~filename input with
  | Ok program -> Ok (program, base_dir)
  | Error err -> Error (Diagnostics.format_error ~file:filename err)

(** Format pipeline errors for display *)
let format_pipeline_errors ~file errors = Diagnostics.format_errors ~file errors

(** Remap a loc through a synthetic→original table.

    Returns the original loc unchanged when [table] has no entry for
    the loc's line — either because it points into generator
    scaffolding (imports, func wrapper, [tests:] struct) or because
    the table is empty (non-doctest callers). Callers decide what to
    do with unmapped locs; this helper is purely structural.

    [end_line] is remapped independently with fallback to the
    start line's mapped value. Multi-line error spans (e.g. a
    delimiter mismatch that opens on one line and closes on
    another) preserve their height when both endpoints have
    origin entries. Column carries over as-is — the synthetic
    indent prefix is "    " (4 spaces), matching standard
    four-space doctest indentation. Mis-indents are visible but
    not wrong. *)
let remap_loc (table : loc_remap_table) (loc : Ast.loc) : Ast.loc =
  match Hashtbl.find_opt table loc.line with
  | None -> loc
  | Some entry ->
      let end_line =
        match Hashtbl.find_opt table loc.end_line with
        | Some e -> e.original_line
        | None -> entry.original_line
      in
      {
        loc with
        line = entry.original_line;
        end_line;
        loc_file = Some entry.original_file;
      }

(** Apply a loc remap to every loc-carrying field of a
    [compiler_error]. Notes don't currently carry independent locs,
    so there's only one to rewrite today — but keeping this function
    isolated means future additions drop into one place. *)
let remap_compiler_error (table : loc_remap_table) (e : Ast.compiler_error) :
    Ast.compiler_error =
  { e with loc = remap_loc table e.loc }

let cc_args_for_test_binary ?precompiled ?(include_dirs = [])
    ?(sanitize = false) ?sanitizer_mode ~link_flags () =
  let sanitizer_mode = select_sanitizer_mode ?sanitizer_mode ~sanitize () in
  let sanitize = sanitizer_enabled sanitizer_mode in
  let raylib_flags =
    if has_raylib_import () then raylib_linker_flags () else ""
  in
  let header_args =
    match precompiled with
    | Some p -> [ "-include"; p.header_file ]
    | None -> []
  in
  let runtime_obj_args =
    match precompiled with Some p -> [ p.runtime_obj ] | None -> []
  in
  let tls_backend =
    match precompiled with
    | Some p -> p.tls_backend
    | None -> current_tls_backend_profile ()
  in
  let runtime_feature_args =
    if Option.is_none precompiled then tls_backend_runtime_cc_args tls_backend
    else []
  in
  [ "-O0"; "-fwrapv"; "-pipe" ]
  @ (if sanitize then [] else [ "-w" ])
  @ runtime_feature_args
  @ List.concat_map (fun dir -> [ "-I"; dir ]) include_dirs
  @ header_args @ runtime_obj_args @ [ "-lm"; "-lpthread" ]
  @ sanitizer_cc_args sanitizer_mode
  @ tls_backend_link_cc_args tls_backend
  @ (if raylib_flags = "" then []
     else String.split_on_char ' ' (String.trim raylib_flags))
  @ Ffi_boundary.link_flags_cc_args link_flags

let run_test_result ?(debug = false) ?(sanitize = false) ?sanitizer_mode
    ?precompiled ?(leak_check = false) ?(isolate_filesystem = false)
    ?(cache_result = true) ?loc_remap ?module_base_dir ?source_text
    ?suite_file ~timeout filename =
  let start_time = get_time () in
  let make_result ?(output = "") ?(error_detail = "") passed =
    {
      file = filename;
      passed;
      duration = get_time () -. start_time;
      output;
      error_detail;
    }
  in

  Modules.reset ();

  let raw_source =
    match source_text with Some source -> source | None -> read_file filename
  in
  (* Skip the TestSuite→main rewriter when the source already has
     its own [main]. This is important for doctest temp files: the
     doctest generator emits [main] inline so the synthetic→original
     loc remap stays valid. If [generate_test_wrapper] ran here it
     would move the [tests:] block inside a newly-synthesized
     [main] and invalidate the remap. *)
  let generated_suite_wrapper =
    (match suite_file with
    | Some value -> value
    | None -> source_declares_testsuite raw_source)
    && not (has_top_level_main_source raw_source)
  in
  let source =
    if generated_suite_wrapper then generate_test_wrapper ~leak_check raw_source
    else raw_source
  in
  (match Sys.getenv_opt "BLORP_DUMP_WRAPPED" with
  | Some path ->
      let oc = open_out path in
      output_string oc source;
      close_out oc
  | None -> ());

  let source_dir =
    Option.value module_base_dir ~default:(extract_directory filename)
  in
  init_module_paths source_dir;

  let embed_runtime = Option.is_none precompiled in
  let compile_result =
    match (loc_remap, generated_suite_wrapper) with
    | Some _, _ | None, true ->
        Pipeline.compile_generated_test_harness ~debug
          ~allow_debug_only_calls:true ~retain_debug_blocks:true ~embed_runtime
          ~filename ~source ()
    | None, false ->
        Pipeline.compile ~debug ~allow_debug_only_calls:true
          ~retain_debug_blocks:true ~embed_runtime ~filename ~source ()
  in
  match compile_result with
  | Error errors ->
      let errors =
        match loc_remap with
        | None -> errors
        | Some table -> List.map (remap_compiler_error table) errors
      in
      let display_file =
        match (loc_remap, errors) with
        | Some _, e :: _ -> (
            match e.loc.loc_file with Some f -> f | None -> filename)
        | _ -> filename
      in
      let detail =
        let formatted = format_pipeline_errors ~file:display_file errors in
        if
          List.for_all
            (fun (e : Ast.compiler_error) -> e.phase = Ast.TypeCheck)
            errors
        then "(type errors)\n  " ^ formatted
        else formatted
      in
      make_result ~error_detail:detail false
  | Ok (Pipeline.Stopped_at _) ->
      (* Unreachable: test_runner never supplies ~on_stage. *)
      assert false
  | Ok (Pipeline.Compiled { c_code; link_flags; include_dirs; _ }) ->
      (match Sys.getenv_opt "BLORP_DUMP_C" with
      | Some path ->
          let oc = open_out path in
          output_string oc c_code;
          close_out oc
      | None -> ());
      let compilation_dir = run_compilation_dir () in
      let bin_file = Filename.concat compilation_dir "program.bin" in

      let result =
        Fun.protect
          ~finally:(fun () -> try Sys.remove bin_file with _ -> ())
          (fun () ->
            let cc_args =
              cc_args_for_test_binary ?precompiled ~include_dirs ~sanitize
                ?sanitizer_mode ~link_flags ()
            in
            let cc_result, cc_output =
              compile_c_from_stdin c_code bin_file cc_args
            in
            if cc_result <> 0 then
              let detail =
                if String.trim cc_output = "" then "(C compilation failed)"
                else
                  "(C compilation failed)\n  "
                  ^ String.concat "\n  "
                      (String.split_on_char '\n' (String.trim cc_output))
              in
              make_result ~error_detail:detail false
            else begin
              let cwd =
                if isolate_filesystem then Some (isolated_test_cwd filename)
                else None
              in
              let env =
                match cwd with
                | Some dir -> isolated_test_environment dir
                | None -> []
              in
              let result, output =
                run_process_capture_timeout ?cwd ~env ~timeout bin_file []
              in
              if result = 0 then make_result ~output true
              else if result = 99 then
                make_result ~output ~error_detail:"(leak detected at exit)"
                  false
              else if result = 124 then
                let secs = match timeout with Some s -> s | None -> 0 in
                make_result ~output
                  ~error_detail:(Printf.sprintf "(timed out after %ds)" secs)
                  false
              else
                let detail =
                  if String.trim output = "" then
                    Printf.sprintf "(exit code %d)" result
                  else
                    Printf.sprintf "(exit code %d)\n  %s" result
                      (String.trim output)
                in
                make_result ~output ~error_detail:detail false
            end)
      in
      (* Save result to cache — modules are still loaded from Pipeline.compile *)
      (match loc_remap with
      | None when cache_result -> save_test_cache filename result
      | None -> ()
      | Some _ -> ());
      result

(** Run doctests from a source file. *)
let run_doctests ?(debug = false) ?(sanitize = false) ?sanitizer_mode
    ?precompiled ?source_text ~timeout source_filename =
  let source_text_result =
    match source_text with
    | Some source -> Ok source
    | None -> (
        try Ok (read_file source_filename)
        with exn -> Error (Printexc.to_string exn))
  in
  match source_text_result with
  | Error msg ->
      [
        {
          file = source_filename;
          passed = false;
          duration = 0.0;
          output = "";
          error_detail = msg;
        };
      ]
  | Ok source_text -> (
      match parse_file_source source_filename source_text with
      | Error msg ->
          [
            {
              file = source_filename;
              passed = false;
              duration = 0.0;
              output = "";
              error_detail = msg;
            };
          ]
      | Ok (program, _base_dir) ->
          let test_source, remap =
            generate_doctest_program_with_map ~source_path:source_filename
              ~source_text program
          in
          if
            Hashtbl.length remap = 0
            && extract_all_doctests ~source_text program = []
          then []
          else begin
            let tmp_base =
              ".blorp_doctest_"
              ^ Filename.basename (Filename.remove_extension source_filename)
            in
            let tmp_file =
              run_artifact_path ~kind:"doctests" ~prefix:tmp_base ~suffix:".brp"
            in
            Fun.protect
              ~finally:(fun () -> try Sys.remove tmp_file with _ -> ())
              (fun () ->
                let oc = open_out tmp_file in
                Fun.protect
                  ~finally:(fun () -> close_out oc)
                  (fun () -> output_string oc test_source);
                (* Threading [~loc_remap] into [run_test_result] is what
                 converts synthetic temp-file locs into their original-
                 source counterparts before errors get rendered. Earlier
                 iterations did a post-hoc string replace on rendered
                 error text to swap the file path — the loc number and
                 snippet stayed synthetic, so users saw a path from
                 their file with line numbers from the temp file. The
                 current approach rewrites the loc object pre-render,
                 so the snippet, line-number gutter, column marker, and
                 file path all agree with the user's real source. *)
                let r =
                  run_test_result ~debug ~sanitize ?sanitizer_mode ?precompiled
                    ~loc_remap:remap
                    ~module_base_dir:(extract_directory source_filename)
                    ~timeout tmp_file
                in
                let cleaned_detail = r.error_detail in
                [
                  {
                    r with
                    file = source_filename ^ " (doctests)";
                    error_detail = cleaned_detail;
                  };
                ])
          end)

(* ============================================================================
   Result Reporting
   ============================================================================ *)

(** Print a test result *)
let print_test_result ?(profile = false) ?(leak_check = false) r =
  if r.passed then begin
    if profile then Printf.printf "PASS: %s (%.3fs)\n" r.file r.duration
    else Printf.printf "PASS: %s\n" r.file;
    if leak_check && r.output <> "" then begin
      let lines = String.split_on_char '\n' r.output in
      List.iter
        (fun line ->
          if contains_substring line "leak check:" then
            Printf.printf "  %s\n" (String.trim line))
        lines
    end
  end
  else begin
    Printf.printf "FAIL: %s %s\n" r.file r.error_detail;
    if r.output <> "" then print_string r.output
  end

(** Run a suite test, checking cache first *)
let source_text_matches_current_file filename = function
  | None -> true
  | Some source -> file_content_hash filename = Digest.to_hex (Digest.string source)

let run_suite_test_cached ?(debug = false) ?(sanitize = false) ?sanitizer_mode
    ?precompiled ?(leak_check = false) ?(isolate_filesystem = false) ~timeout
    ?source_text ?suite_file filename =
  let cache_allowed =
    (not isolate_filesystem)
    && source_text_matches_current_file filename source_text
  in
  match if cache_allowed then check_test_cache filename else None with
  | Some cached -> cached
  | None ->
      run_test_result ~debug ~sanitize ?sanitizer_mode ?precompiled ~leak_check
        ~isolate_filesystem ~cache_result:cache_allowed ~timeout
        ?source_text ?suite_file filename

(** Run a single test file with mode dispatch *)
let run_test_with_info ?(debug = false) ?(sanitize = false) ?sanitizer_mode
    ?precompiled ?(leak_check = false) ?(mode = TestAll) ~timeout info =
  let filename = info.test_file_path in
  let isolate_filesystem =
    leak_check || info.test_file_requires_filesystem_isolation
  in
  let invalid_suite_main_result () =
    {
      file = filename;
      passed = false;
      duration = 0.0;
      output = "";
      error_detail =
        "(invalid test file: TestSuite files must not define func main)";
    }
  in
  let is_leak_baseline_program =
    leak_check && info.test_file_is_leak_baseline_program
  in
  let is_suite_file = info.test_file_is_suite && not info.test_file_has_main in
  let is_runnable_file = is_suite_file || is_leak_baseline_program in
  match mode with
  | DocOnly ->
      if info.test_file_has_doctests then
        run_doctests ~debug ~sanitize ?sanitizer_mode ?precompiled ~timeout
          ~source_text:info.test_file_source filename
      else []
  | SuiteOnly ->
      if info.test_file_is_suite && info.test_file_has_main then
        [ invalid_suite_main_result () ]
      else if is_runnable_file then
        [
          run_suite_test_cached ~debug ~sanitize ?sanitizer_mode ?precompiled
            ~leak_check ~isolate_filesystem ~timeout
            ~source_text:info.test_file_source
            ~suite_file:info.test_file_is_suite filename;
        ]
      else []
  | TestAll ->
      let suite_results =
        if is_runnable_file then
          [
            run_suite_test_cached ~debug ~sanitize ?sanitizer_mode ?precompiled
              ~leak_check ~isolate_filesystem ~timeout
              ~source_text:info.test_file_source
              ~suite_file:info.test_file_is_suite filename;
          ]
        else []
      in
      let doc_results =
        if info.test_file_has_doctests then
          run_doctests ~debug ~sanitize ?sanitizer_mode ?precompiled ~timeout
            ~source_text:info.test_file_source filename
        else []
      in
      let invalid_results =
        if info.test_file_is_suite && info.test_file_has_main then
          [ invalid_suite_main_result () ]
        else []
      in
      invalid_results @ suite_results @ doc_results

let print_test_start ?worker file =
  match worker with
  | Some id -> Printf.eprintf "RUN[%d]: %s\n%!" id file
  | None -> Printf.eprintf "RUN: %s\n%!" file

let compile_suite_harness_source ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?precompiled ~harness_label ~filename_base source =
  (match Sys.getenv_opt "BLORP_DUMP_WRAPPED" with
  | Some path ->
      let oc = open_out path in
      output_string oc source;
      close_out oc
  | None -> ());
  Modules.full_reset ();
  let cwd = Sys.getcwd () in
  init_module_paths cwd;
  let filename = Filename.concat cwd filename_base in
  let embed_runtime = Option.is_none precompiled in
  match
    Pipeline.compile ~debug ~allow_debug_only_calls:true
      ~retain_debug_blocks:true ~embed_runtime ~filename ~source ()
  with
  | Error errors ->
      Error (format_pipeline_errors ~file:("<" ^ harness_label ^ ">") errors)
  | Ok (Pipeline.Stopped_at _) -> assert false
  | Ok (Pipeline.Compiled { c_code; link_flags; include_dirs; _ }) ->
      (match Sys.getenv_opt "BLORP_DUMP_C" with
      | Some path ->
          let oc = open_out path in
          output_string oc c_code;
          close_out oc
      | None -> ());
      let compilation_dir = run_compilation_dir () in
      let bin_file = Filename.concat compilation_dir "program.bin" in
      let cc_args =
        cc_args_for_test_binary ?precompiled ~include_dirs ~sanitize
          ?sanitizer_mode ~link_flags ()
      in
      let cc_result, cc_output = compile_c_from_stdin c_code bin_file cc_args in
      if cc_result = 0 then Ok bin_file
      else
        let detail =
          if String.trim cc_output = "" then "(C compilation failed)"
          else
            "(C compilation failed)\n  "
            ^ String.concat "\n  "
                (String.split_on_char '\n' (String.trim cc_output))
        in
        Error detail

let compile_suite_selector_harness ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?precompiled ?(leak_check = false) files =
  compile_suite_harness_source ~debug ~sanitize ?sanitizer_mode ?precompiled
    ~harness_label:"suite-selector-harness"
    ~filename_base:"__suite_selector_harness__.brp"
    (generate_suite_selector_harness ~leak_check files)

let compile_suite_run_all_harness ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?precompiled files =
  compile_suite_harness_source ~debug ~sanitize ?sanitizer_mode ?precompiled
    ~harness_label:"suite-run-all-harness"
    ~filename_base:"__suite_run_all_harness__.brp"
    (generate_suite_run_all_harness files)

let run_suite_selector_case ~cwd ~timeout ~bin_file ~file ~index =
  let start_time = get_time () in
  let make_result ?(output = "") ?(error_detail = "") passed =
    { file; passed; duration = get_time () -. start_time; output; error_detail }
  in
  let env =
    match cwd with Some dir -> isolated_test_environment dir | None -> []
  in
  let result, output =
    run_process_capture_timeout ?cwd ~env ~timeout bin_file
      [ string_of_int index ]
  in
  if result = 0 then make_result ~output true
  else if result = 99 then
    make_result ~output ~error_detail:"(leak detected at exit)" false
  else if result = 124 then
    let secs = match timeout with Some s -> s | None -> 0 in
    make_result ~output
      ~error_detail:(Printf.sprintf "(timed out after %ds)" secs)
      false
  else if result = 2 then
    make_result ~output ~error_detail:"(test harness selector failed)" false
  else
    let detail =
      if String.trim output = "" then Printf.sprintf "(exit code %d)" result
      else Printf.sprintf "(exit code %d)\n  %s" result (String.trim output)
    in
    make_result ~output ~error_detail:detail false

let int_of_string_opt value = try Some (int_of_string value) with _ -> None

let split_marker_fields line =
  line |> String.split_on_char ' '
  |> List.filter (fun part -> String.trim part <> "")

let parse_suite_run_all_begin line =
  match split_marker_fields line with
  | marker :: raw_index :: _ when marker = suite_run_all_begin_marker ->
      int_of_string_opt raw_index
  | _ -> None

let parse_suite_run_all_end line =
  match split_marker_fields line with
  | marker :: raw_index :: raw_status :: _
    when marker = suite_run_all_end_marker -> (
      match (int_of_string_opt raw_index, raw_status) with
      | Some index, "PASS" -> Some (index, true)
      | Some index, "FAIL" -> Some (index, false)
      | _ -> None)
  | _ -> None

let suite_run_all_results_from_output ~elapsed files output =
  let file_array = Array.of_list files in
  let expected_count = Array.length file_array in
  let results_by_index = Hashtbl.create expected_count in
  let current = ref None in
  let invalid = ref false in
  let valid_index index = index >= 0 && index < expected_count in
  let append_output buffer line =
    Buffer.add_string buffer line;
    Buffer.add_char buffer '\n'
  in
  let finish_suite index passed buffer =
    if (not (valid_index index)) || Hashtbl.mem results_by_index index then
      invalid := true
    else
      Hashtbl.add results_by_index index
        {
          file = file_array.(index);
          passed;
          duration = elapsed;
          output = Buffer.contents buffer;
          error_detail = (if passed then "" else "(suite failed)");
        }
  in
  output |> String.split_on_char '\n'
  |> List.iter (fun line ->
      if not !invalid then
        match
          (parse_suite_run_all_begin line, parse_suite_run_all_end line)
        with
        | Some index, _ ->
            if Option.is_some !current || not (valid_index index) then
              invalid := true
            else current := Some (index, Buffer.create 1024)
        | _, Some (index, passed) -> (
            match !current with
            | Some (current_index, buffer) when current_index = index ->
                finish_suite index passed buffer;
                current := None
            | _ -> invalid := true)
        | None, None -> (
            match !current with
            | Some (_, buffer) -> append_output buffer line
            | None -> ()));
  (match !current with Some _ -> invalid := true | None -> ());
  if !invalid || Hashtbl.length results_by_index <> expected_count then None
  else
    Some
      (List.init expected_count (fun index ->
           Hashtbl.find results_by_index index))

let run_suite_run_all_case ~timeout ~bin_file ~files =
  let start_time = get_time () in
  let make_harness_result ?(output = "") ?(error_detail = "") passed =
    [
      {
        file = "combined TestSuite run-all harness";
        passed;
        duration = get_time () -. start_time;
        output;
        error_detail;
      };
    ]
  in
  let result, output =
    run_process_capture_timeout ~timeout bin_file []
  in
  let elapsed = get_time () -. start_time in
  match result with
  | 0 | 1 -> (
      match suite_run_all_results_from_output ~elapsed files output with
      | Some results -> results
      | None ->
          make_harness_result ~output
            ~error_detail:"(test harness run-all output was incomplete)" false)
  | 99 ->
      make_harness_result ~output ~error_detail:"(leak detected at exit)" false
  | 124 ->
      let secs = match timeout with Some s -> s | None -> 0 in
      make_harness_result ~output
        ~error_detail:(Printf.sprintf "(timed out after %ds)" secs)
        false
  | code ->
      let detail =
        if String.trim output = "" then Printf.sprintf "(exit code %d)" code
        else Printf.sprintf "(exit code %d)\n  %s" code (String.trim output)
      in
      make_harness_result ~output ~error_detail:detail false

let importable_test_module filename =
  Filename.is_relative filename
  || starts_with
       (Filename.remove_extension filename)
       (Sys.getcwd () ^ Filename.dir_sep)

let suite_selector_eligible_info mode info =
  match mode with
  | DocOnly -> false
  | SuiteOnly ->
      importable_test_module info.test_file_path
      && info.test_file_is_suite
      && not info.test_file_has_main
  | TestAll ->
      importable_test_module info.test_file_path
      && info.test_file_is_suite
      && (not info.test_file_has_doctests)
      && not info.test_file_has_main

let suite_run_all_eligible_info ~leak_check mode info =
  (not leak_check)
  && suite_selector_eligible_info mode info
  && not info.test_file_requires_process_isolation

(* Keep combined TestSuite harnesses below the size where module initialization
   and process-exit cleanup can fail before or after all suites pass. Four is
   the largest currently-safe batch for the compiler-owned Blorp suites while
   still avoiding one compile per small suite. *)
let run_all_suite_batch_size = 4

let chunk_by_count size items =
  let rec take remaining count taken =
    if count = 0 then (List.rev taken, remaining)
    else
      match remaining with
      | [] -> (List.rev taken, [])
      | item :: rest -> take rest (count - 1) (item :: taken)
  in
  let rec loop remaining chunks =
    match remaining with
    | [] -> List.rev chunks
    | _ ->
        let chunk, rest = take remaining size [] in
        loop rest (chunk :: chunks)
  in
  loop items []

(* ============================================================================
   Parallel Execution
   ============================================================================ *)

(** Detect number of CPU cores, capped for macOS code signing stability.
    On macOS, too many parallel workers overwhelm syspolicyd (the code signing
    daemon), causing sporadic SIGKILL/SIGABRT on freshly compiled binaries.
    Cap at 4 workers on macOS for reliability. *)
let detect_num_cores () =
  let try_cmd prog args =
    let code, output = run_process_capture prog args in
    if code = 0 then
      try Some (max 1 (int_of_string (String.trim output))) with _ -> None
    else None
  in
  let cores =
    match try_cmd "sysctl" [ "-n"; "hw.ncpu" ] with
    | Some n -> n
    | None -> ( match try_cmd "nproc" [] with Some n -> n | None -> 4)
  in
  (* Cap workers on macOS to avoid syspolicyd code signing races *)
  let is_macos = Sys.file_exists "/usr/bin/codesign" in
  if is_macos then min cores 4 else cores

(** Split a list into n roughly-equal chunks *)
let split_work items n =
  let len = List.length items in
  let chunk_size = (len + n - 1) / n in
  let rec split acc remaining =
    match remaining with
    | [] -> List.rev acc
    | _ ->
        let rec take n lst acc =
          if n = 0 then (List.rev acc, lst)
          else
            match lst with
            | [] -> (List.rev acc, [])
            | x :: rest -> take (n - 1) rest (x :: acc)
        in
        let chunk, rest = take chunk_size remaining [] in
        split (chunk :: acc) rest
  in
  split [] items

(** Pre-warm parse cache before forking *)
let prewarm_parse_cache () =
  let base_dir = Sys.getcwd () in
  init_module_paths base_dir;
  let std_modules =
    [
      "std/test";
      "std/option";
      "std/list";
      "std/result";
      "std/vector";
      "std/tensor";
      "std/matrix";
      "std/dict";
      "std/set";
      "std/slice";
      "std/parser";
      "std/string";
      "std/char";
      "std/int";
      "std/float";
      "std/bool";
      "std/int8";
      "std/int16";
      "std/int32";
      "std/int128";
      "std/uint8";
      "std/uint16";
      "std/uint32";
      "std/uint64";
      "std/uint128";
      "std/fixed";
      "std/math";
      "std/io";
      "std/traits";
      "std/random";
      "std/regex";
      "std/time";
    ]
  in
  List.iter (fun m -> ignore (Modules.load_module m base_dir)) std_modules;
  Modules.reset ()

(** Count individual [PASS] and [FAIL] lines in test output *)
let count_individual_tests output =
  let lines = String.split_on_char '\n' output in
  let pass_count =
    List.length (List.filter (fun l -> contains_substring l "[PASS]") lines)
  in
  let fail_count =
    List.length (List.filter (fun l -> contains_substring l "[FAIL]") lines)
  in
  (pass_count, fail_count)

(** Check if a test result is from doctests *)
let is_doctest_result r = String.ends_with ~suffix:" (doctests)" r.file

(** Print test result summary *)
let print_results_summary ?(profile = false) ?(num_workers = 0) elapsed passed
    failed results =
  let suite_passed = ref 0 in
  let suite_failed = ref 0 in
  let doc_passed = ref 0 in
  let doc_failed = ref 0 in
  List.iter
    (fun r ->
      let p, f = count_individual_tests r.output in
      if is_doctest_result r then begin
        doc_passed := !doc_passed + p;
        doc_failed := !doc_failed + f
      end
      else begin
        suite_passed := !suite_passed + p;
        suite_failed := !suite_failed + f
      end)
    results;
  let suite_tests = !suite_passed + !suite_failed in
  let doc_tests = !doc_passed + !doc_failed in
  let total_individual = suite_tests + doc_tests in
  let result_passed =
    if total_individual > 0 then !suite_passed + !doc_passed else passed
  in
  let result_failed =
    if total_individual > 0 then !suite_failed + !doc_failed else failed
  in
  let time_str =
    if profile then
      if num_workers > 0 then
        Printf.sprintf " (total: %.3fs, %d workers)" elapsed num_workers
      else Printf.sprintf " (total: %.3fs)" elapsed
    else ""
  in
  if doc_tests > 0 then
    Printf.printf "\nResults: %d passed, %d failed (%d tests, %d doctests)%s\n"
      result_passed result_failed suite_tests doc_tests time_str
  else if total_individual > 0 then
    Printf.printf "\nResults: %d passed, %d failed (%d tests)%s\n" result_passed
      result_failed total_individual time_str
  else
    Printf.printf "\nResults: %d passed, %d failed%s\n" passed failed time_str;
  match Sys.getenv_opt "BLORP_GATE_RESULT" with
  | Some gate when String.trim gate <> "" ->
      let status = if failed = 0 then "PASS" else "FAIL" in
      let tests =
        if total_individual > 0 then total_individual else passed + failed
      in
      Printf.printf
        "BLORP_GATE_RESULT gate=%s status=%s passed=%d failed=%d tests=%d\n"
        gate status result_passed result_failed tests
  | _ -> ()

(* ============================================================================
   Test Runners
   ============================================================================ *)

let try_run_suite_selector_tests ?(profile = false) ?(debug = false)
    ?(sanitize = false) ?sanitizer_mode ?precompiled ?(leak_check = false)
    ?(mode = TestAll) ~timeout infos =
  let files = List.map (fun info -> info.test_file_path) infos in
  let run_all_infos =
    List.filter (suite_run_all_eligible_info ~leak_check mode) infos
  in
  let run_all_files = List.map (fun info -> info.test_file_path) run_all_infos in
  let selector_infos =
    List.filter
      (fun info ->
        suite_selector_eligible_info mode info
        && not (List.mem info.test_file_path run_all_files)
        && not info.test_file_requires_process_isolation)
      infos
  in
  let selector_files =
    List.map (fun info -> info.test_file_path) selector_infos
  in
  if List.length run_all_files < 2 && List.length selector_files < 2 then None
  else begin
    let start_time = get_time () in
    (* Combined harnesses deliberately skip per-file result caching. After one
       combined compile, saving one cache entry per suite hashes the same loaded
       module graph repeatedly and can hide memory-focused regressions. *)
    let result_by_file = Hashtbl.create (List.length files) in
    let handled_files = Hashtbl.create (List.length files) in
    let extra_results = ref [] in
    let mark_handled files =
      List.iter (fun file -> Hashtbl.replace handled_files file ()) files
    in
    let record_result result =
      if List.mem result.file files then
        Hashtbl.replace result_by_file result.file result
      else extra_results := result :: !extra_results
    in
    let record_results results = List.iter record_result results in
    let record_harness_failure file detail =
      record_result
        {
          file;
          passed = false;
          duration = get_time () -. start_time;
          output = "";
          error_detail = detail;
        }
    in
    let run_all_combined () =
      run_all_files
      |> chunk_by_count run_all_suite_batch_size
      |> List.iter (fun batch ->
          if List.length batch >= 2 then begin
            mark_handled batch;
            match
              compile_suite_run_all_harness ~debug ~sanitize ?sanitizer_mode
                ?precompiled batch
            with
            | Error detail ->
                Printf.eprintf "Combined run-all test compile failed:\n%s\n%!"
                  detail;
                record_harness_failure "combined TestSuite run-all compile"
                  ("(compile failed)\n  " ^ detail)
            | Ok bin_file ->
                Fun.protect
                  ~finally:(fun () -> try Sys.remove bin_file with _ -> ())
                  (fun () ->
                    record_results
                      (run_suite_run_all_case ~timeout ~bin_file ~files:batch))
          end)
    in
    let run_selector_combined () =
      if List.length selector_files < 2 then ()
      else begin
        mark_handled selector_files;
        match
          compile_suite_selector_harness ~debug ~sanitize ?sanitizer_mode
            ?precompiled ~leak_check selector_files
        with
        | Error detail ->
            Printf.eprintf "Combined isolated test compile failed:\n%s\n%!"
              detail;
            record_harness_failure "combined isolated TestSuite compile"
              ("(compile failed)\n  " ^ detail)
        | Ok bin_file ->
            Fun.protect
              ~finally:(fun () -> try Sys.remove bin_file with _ -> ())
              (fun () ->
                List.iteri
                  (fun index info ->
                    let file = info.test_file_path in
                    let cwd =
                      if leak_check || info.test_file_requires_filesystem_isolation
                      then
                        Some (isolated_test_cwd file)
                      else None
                    in
                    record_result
                      (run_suite_selector_case ~cwd ~timeout ~bin_file ~file
                         ~index))
                  selector_infos)
      end
    in
    run_all_combined ();
    run_selector_combined ();
    List.iter
      (fun info ->
        let file = info.test_file_path in
        if
          (not (Hashtbl.mem handled_files file))
          && not (Hashtbl.mem result_by_file file)
        then
          record_results
            (run_test_with_info ~debug ~sanitize ?sanitizer_mode ?precompiled
               ~leak_check ~mode ~timeout info))
      infos;
    let ordered_results =
      List.filter_map (fun file -> Hashtbl.find_opt result_by_file file) files
      @ List.rev !extra_results
    in
    List.iter (print_test_result ~profile ~leak_check) ordered_results;
    let elapsed = get_time () -. start_time in
    let passed =
      List.length (List.filter (fun r -> r.passed) ordered_results)
    in
    let failed =
      List.length (List.filter (fun r -> not r.passed) ordered_results)
    in
    print_results_summary ~profile elapsed passed failed ordered_results;
    Some (if failed > 0 then 1 else 0)
  end

let run_tests_sequential ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?precompiled ?(leak_check = false) ?(mode = TestAll)
    ~timeout infos =
  let start_time = get_time () in
  let passed = ref 0 in
  let failed = ref 0 in
  let all_results = ref [] in
  List.iter
    (fun info ->
      let file = info.test_file_path in
      print_test_start file;
      let results =
        run_test_with_info ~debug ~sanitize ?sanitizer_mode ?precompiled
          ~leak_check ~mode ~timeout info
      in
      List.iter
        (fun r ->
          print_test_result ~profile ~leak_check r;
          if r.passed then incr passed else incr failed;
          all_results := r :: !all_results)
        results)
    infos;
  let elapsed = get_time () -. start_time in
  print_results_summary ~profile elapsed !passed !failed (List.rev !all_results);
  if !failed > 0 then 1 else 0

(** Run tests in parallel using fork *)
let run_tests_parallel ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?precompiled ?(leak_check = false) ?(mode = TestAll)
    ~timeout ~num_workers infos =
  let start_time = get_time () in
  let files = List.map (fun info -> info.test_file_path) infos in
  let n = min num_workers (List.length infos) in

  prewarm_parse_cache ();

  let sized_infos =
    List.map
      (fun info -> (String.length info.test_file_source, info))
      infos
  in
  let sorted_infos =
    List.map snd (List.sort (fun (a, _) (b, _) -> compare b a) sized_infos)
  in

  let chunks = split_work sorted_infos n in

  let child_pids = ref [] in
  let old_handler =
    Sys.signal Sys.sigint
      (Sys.Signal_handle
         (fun _ ->
           List.iter
             (fun pid -> try Unix.kill pid Sys.sigterm with _ -> ())
             !child_pids;
           List.iter
             (fun pid -> try ignore (waitpid_retry [] pid) with _ -> ())
             !child_pids;
           exit 130))
  in

  (* Track read FDs so forked children can close inherited ones *)
  let parent_read_fds = ref [] in
  let worker_info =
    List.mapi
      (fun worker_idx tests ->
        let read_fd, write_fd = Unix.pipe () in
        match Unix.fork () with
        | 0 ->
            Unix.close read_fd;
            (* Close all inherited read FDs from previously forked workers *)
            List.iter
              (fun fd -> try Unix.close fd with _ -> ())
              !parent_read_fds;
            (* Prevent CC subprocesses from inheriting our result pipe *)
            Unix.set_close_on_exec write_fd;
            let results =
              try
                List.concat_map
                  (fun info ->
                    let file = info.test_file_path in
                    print_test_start ~worker:(worker_idx + 1) file;
                    run_test_with_info ~debug ~sanitize ?sanitizer_mode
                      ?precompiled ~leak_check ~mode ~timeout info)
                  tests
              with exn ->
                List.map
                  (fun info ->
                    let file = info.test_file_path in
                    {
                      file;
                      passed = false;
                      duration = 0.0;
                      output = "";
                      error_detail =
                        Printf.sprintf "(worker crash: %s)"
                          (Printexc.to_string exn);
                    })
                  tests
            in
            let oc = Unix.out_channel_of_descr write_fd in
            Marshal.to_channel oc results [];
            close_out oc;
            exit 0
        | pid ->
            Unix.close write_fd;
            parent_read_fds := read_fd :: !parent_read_fds;
            child_pids := pid :: !child_pids;
            (pid, read_fd))
      chunks
  in

  let all_results =
    List.map
      (fun (_pid, read_fd) ->
        let ic = Unix.in_channel_of_descr read_fd in
        try
          let (results : test_result list) = Marshal.from_channel ic in
          close_in ic;
          results
        with _ ->
          close_in ic;
          [])
      worker_info
  in

  List.iter (fun (pid, _) -> ignore (waitpid_retry [] pid)) worker_info;

  Sys.set_signal Sys.sigint old_handler;

  (* Precompiled artifacts are cached persistently — no cleanup needed *)
  let file_index = Hashtbl.create (List.length files) in
  List.iteri (fun i f -> Hashtbl.replace file_index f i) files;

  let sorted =
    List.concat all_results
    |> List.sort (fun a b ->
        let ia =
          try Hashtbl.find file_index a.file with Not_found -> max_int
        in
        let ib =
          try Hashtbl.find file_index b.file with Not_found -> max_int
        in
        compare ia ib)
  in

  List.iter (print_test_result ~profile ~leak_check) sorted;

  let elapsed = get_time () -. start_time in
  let passed = List.length (List.filter (fun r -> r.passed) sorted) in
  let failed = List.length (List.filter (fun r -> not r.passed) sorted) in
  print_results_summary ~profile ~num_workers:n elapsed passed failed sorted;
  if failed > 0 then 1 else 0

(** Run tests: dispatches to sequential or parallel *)
let run_test_infos ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?(leak_check = false) ?(mode = TestAll) ~timeout ?(jobs = 0)
    ?(cache = true) ?(repeat = 1) test_infos =
  with_run_artifacts (fun () ->
      if test_infos = [] then begin
        prerr_endline "Error: no runnable tests found";
        1
      end
      else
      let sanitizer_mode = select_sanitizer_mode ?sanitizer_mode ~sanitize () in
      let sanitize = sanitizer_enabled sanitizer_mode in
      let files = List.map (fun info -> info.test_file_path) test_infos in
      (* Warn if std/ sources are newer than the compiler binary *)
      check_stale_std ();
      (* Set leak check env var at top level — inherited by forked workers *)
      if leak_check then Unix.putenv "BLORP_LEAK_CHECK" "strict";
      (* Disable test result caching if --no-cache or if leak_check/sanitize
       (these change behavior without changing source files) *)
      let repeat = max 1 repeat in
      test_cache_enabled :=
        cache && repeat = 1 && (not sanitize) && not leak_check;
      let effective_jobs =
        if sanitize then begin
          if jobs > 1 then
            prerr_endline
              "Note: --sanitize forces sequential execution (ASan is not \
               fork-safe)";
          1
        end
        else if jobs = 1 || List.length files <= 1 then 1
        else if jobs > 0 then jobs
        else detect_num_cores ()
      in
      let precompiled = precompile_runtime ~sanitizer_mode ~opt:"O0" () in
      let run_once iteration =
        if repeat > 1 then Printf.printf "\nRepeat %d/%d\n%!" iteration repeat;
        match
          try_run_suite_selector_tests ~profile ~debug ~sanitizer_mode
            ?precompiled ~leak_check ~mode ~timeout test_infos
        with
        | Some result -> result
        | None ->
            if effective_jobs = 1 then
              run_tests_sequential ~profile ~debug ~sanitizer_mode ?precompiled
                ~leak_check ~mode ~timeout test_infos
            else
              run_tests_parallel ~profile ~debug ~sanitizer_mode ?precompiled
                ~leak_check ~mode ~timeout ~num_workers:effective_jobs
                test_infos
      in
      let rec loop iteration =
        let result = run_once iteration in
        if result <> 0 || iteration >= repeat then result
        else loop (iteration + 1)
      in
      loop 1)

(** Run tests: dispatches to sequential or parallel *)
let run_tests ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?(leak_check = false) ?(mode = TestAll) ~timeout ?(jobs = 0)
    ?(cache = true) ?(repeat = 1) path =
  run_test_infos ~profile ~debug ~sanitize ?sanitizer_mode ~leak_check ~mode
    ~timeout ~jobs ~cache ~repeat
    (collect_test_file_infos ~leak_check [ path ])

let run_tests_paths ?(profile = false) ?(debug = false) ?(sanitize = false)
    ?sanitizer_mode ?(leak_check = false) ?(mode = TestAll) ~timeout ?(jobs = 0)
    ?(cache = true) ?(repeat = 1) paths =
  run_test_infos ~profile ~debug ~sanitize ?sanitizer_mode ~leak_check ~mode
    ~timeout ~jobs ~cache ~repeat (collect_test_file_infos ~leak_check paths)
