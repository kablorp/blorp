(** Blorp-owned policy facts for Core cooperative-fairness insertion.

    OCaml owns Core AST traversal and classifies the body-start shape. The
    named policy answer crosses the single JSON bridge through
    [Compiler_blorp_bridge]. *)

type body_start =
  | BodyCheckpoint
  | BodySeqCheckpoint
  | BodyOther

let op_of_body_start = function
  | BodyCheckpoint -> "fairness_body_checkpoint"
  | BodySeqCheckpoint -> "fairness_body_seq_checkpoint"
  | BodyOther -> "fairness_body_other"

let bool_of_policy_text = function
  | "true" -> true
  | "false" -> false
  | text -> invalid_arg ("invalid Core fairness policy boolean: " ^ text)

let body_starts_with_checkpoint body_start =
  Compiler_blorp_bridge.render_exn
    ~renderer:Compiler_blorp_bridge.core_fairness_renderer
    ~op:(op_of_body_start body_start) []
  |> bool_of_policy_text
