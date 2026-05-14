(** Single source of truth for the compiler's version string.

    Used by the CLI (reported in [--version] and [--help]) and by the
    [--dump-core] header so shared dumps carry provenance a user can
    quote in a bug report. If you bump the version, update it here
    only — downstream readers pick it up automatically. *)
let version = "0.2.0"
