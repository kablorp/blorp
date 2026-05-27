(** Single source of truth for the compiler's version string.

    Used by the CLI (reported in [--version] and [--help]) and by the
    [--dump-core] header so shared dumps carry provenance a user can
    quote in a bug report. If you bump the version, update it here
    only — downstream readers pick it up automatically. *)
let source_version = "0.0.1"

let version =
  if Build_info.version_override = "" then source_version
  else Build_info.version_override

let commit = Build_info.commit
let target = Build_info.target
let channel = Build_info.channel
let dirty = Build_info.dirty
let std_digest = Embedded_std.digest

let describe () =
  String.concat "\n"
    [
      Printf.sprintf "blorp %s" version;
      Printf.sprintf "commit: %s" commit;
      Printf.sprintf "target: %s" target;
      Printf.sprintf "channel: %s" channel;
      Printf.sprintf "dirty: %s" dirty;
      Printf.sprintf "std: embedded, hash %s" std_digest;
    ]
