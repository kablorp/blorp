(** Core IR for blorp.

    A typed tree-shaped intermediate representation that sits between the
    typed AST and codegen. Every compiler pass after type-checking consumes
    Core and produces Core (or, for the final emit pass, C).

    {1 Design principles}

    - {b Every node is typed.} [core.ty] is not optional — Core without
      types is invalid. This is the key difference from [Ast.expr], which
      allows [expr_type = None].

    - {b Smaller than AST.} Syntactic sugar ([ERecordUpdate], [EStringInterp],
      [ESubscript*]) is desugared during lowering. Core is the
      minimum set of nodes the backend needs to emit correct code.

    - {b Let-normal sequencing.} Statement sequencing uses [CLet] (for
      bindings) and [CSeq] (for discarded intermediate results). Blocks
      are flattened into these during lowering.

    - {b Short-circuit is explicit.} [CLog] is kept distinct from [CIf]
      even though they have overlapping semantics, because the emitter
      needs to render [&&]/[||] differently from nested [if/else].

    - {b Patterns are preserved.} [CMatchArms] carries [Ast.pattern]
      directly; decision-tree compilation is a separate pass
      ([Core_match]) which rewrites it to the compiled [CMatch] form.

    - {b Debug lowering is explicit.} [CDebugBlock] records source
      [debug:] blocks until [Core_debug] either erases them for normal builds
      or unwraps them for debug builds. Emitters do not decide this policy.

    - {b RC is explicit in late Core.} [CDup] / [CDrop] nodes are inserted
      by [Core_perceus] after specialization and before closure conversion.

    {1 What's NOT in Core}

    - Captures on [CLambda] — computed by [Core_closure], which hoists
      lambdas and task bodies into top-level functions with explicit capture
      metadata before emission.

    - Hygienic variable renaming by [vuniq] — generated temporaries still
      rely on distinct names today, while [vuniq] remains available for a
      future alpha-renaming pass.

    {1 Scope}

    This file defines the Core types, smart constructors, traversal helpers,
    and pretty-printer. Stage-specific behavior lives in the named Core pass
    modules rather than in this IR definition. *)

type var = {
  vname : string;
  vuniq : int;
  vdef_id : int option;
      (** Callable identity carried across the typed-AST-to-Core boundary.
      During the UFCS migration this may come from the legacy
      [__ufcs_...#<id>] callee suffix or from resolved function references.
      Call-site identity from typed [resolved_call] metadata is represented on
      [call_kind] instead, so qualified module aliases do not masquerade as
      callable values. Later Core phases use this only as a selected [def_id]
      hint when promoting user calls, without making Core depend on
      [env_types]. [None] for parameters, locals, closures, and genuinely
      unresolved callees. *)
}
(** Variable: a source-level name plus a uniqueness tag.

    [vuniq] is reserved for hygienic rewriting. Most pipeline-generated
    variables still use distinct [vname]s with [vuniq = 0]; downstream
    identity-sensitive dispatch uses [vdef_id] rather than overloading
    [vuniq]. *)

(** Variable helpers. *)
module Var = struct
  (** Create a var from a source name. *)
  let named (name : string) : var = { vname = name; vuniq = 0; vdef_id = None }

  (** Structural equality of vars. Ignores [vdef_id] — identity for
      equality purposes is still [(vname, vuniq)]; the DefId is metadata
      used by downstream passes for mangling, not for distinguishing two
      otherwise-identical vars. *)
  let equal (a : var) (b : var) : bool = a.vname = b.vname && a.vuniq = b.vuniq

  (** Debug / pretty-print rendering. *)
  let to_string (v : var) : string =
    if v.vuniq = 0 then v.vname else Printf.sprintf "%s_%d" v.vname v.vuniq

  (** C identifier form (delegates to existing escaping). *)
  let to_c_name (v : var) : string =
    if v.vuniq = 0 then v.vname else Printf.sprintf "%s_%d" v.vname v.vuniq
end

type core_param = { cp_name : var; cp_ty : Ast.type_expr; cp_loc : Ast.loc }
(** A function parameter in Core: always has a concrete name (pattern
    destructuring is rewritten to a [CMatchArms] wrapping the body). *)

(** Internal producer/fusion handoff mode.

    [BorrowFresh] is the semantic default: the source collection is borrowed
    for reads and the producer allocates fresh output storage.

    [ConsumeReuse] is introduced only after Perceus has produced a matching
    source-owner [CDrop] and [Core_reuse] consumes that drop. It lets emission
    use a runtime-guarded reuse boundary while preserving value semantics. *)
type handoff_mode = BorrowFresh | ConsumeReuse

(** First list handoff write policy: source indices increase monotonically and
    every output write index is at or before the current read index. This is
    the only shape that can safely reuse the source buffer while reading it. *)
type handoff_write_order = ForwardCompacting

(** Inline list element widths supported by the runtime representation.
    Keeping this as a closed variant means codegen cannot accidentally request
    unsupported byte widths such as 3 or 16. *)
type inline_storage_width =
  | InlineBytes1
  | InlineBytes2
  | InlineBytes4
  | InlineBytes8

let inline_storage_width_bytes = function
  | InlineBytes1 -> 1
  | InlineBytes2 -> 2
  | InlineBytes4 -> 4
  | InlineBytes8 -> 8

type tensor_unboxed_scalar =
  | TensorFloat64Elements
  | TensorFloat32Elements
  | TensorInt64Elements

(** Runtime storage layout for [List[T]].

    [list_storage_slot_layout] is the runtime slot shape supported today:
    generic pointer slots or inline fixed-width scalar slots. The full
    [list_storage_layout] descriptor also records the source element layout and
    ownership policies so future stack-struct/value-record storage does not have
    to infer behavior from type names or emitted C strings. *)
type list_storage_slot_layout =
  | ListPointerStorage
  | ListInlineStorage of inline_storage_width
  | ListInlineStructStorage of string

type storage_ownership =
  | StorageManaged
  | StorageUnmanaged
  | StorageUnknownOwnership of string

type storage_retain_policy =
  | StorageNoRetain
  | StorageArcRetain
  | StorageUnknownRetain of string

type storage_release_policy =
  | StorageNoRelease
  | StorageArcRelease
  | StorageUnknownRelease of string

type storage_equality_policy =
  | StorageEqualityBits
  | StorageEqualityPointer
  | StorageUnknownEquality of string

type container_storage_policy =
  | StoragePolicyUnmanagedBits
  | StoragePolicyManagedPointer
  | StoragePolicyOwnedErasedBox
  | StoragePolicyUnknown of string

let storage_policy_ownership = function
  | StoragePolicyUnmanagedBits -> StorageUnmanaged
  | StoragePolicyManagedPointer -> StorageManaged
  | StoragePolicyOwnedErasedBox -> StorageManaged
  | StoragePolicyUnknown reason -> StorageUnknownOwnership reason

let storage_policy_retain = function
  | StoragePolicyUnmanagedBits -> StorageNoRetain
  | StoragePolicyManagedPointer -> StorageArcRetain
  | StoragePolicyOwnedErasedBox -> StorageNoRetain
  | StoragePolicyUnknown reason -> StorageUnknownRetain reason

let storage_policy_release = function
  | StoragePolicyUnmanagedBits -> StorageNoRelease
  | StoragePolicyManagedPointer -> StorageArcRelease
  | StoragePolicyOwnedErasedBox -> StorageArcRelease
  | StoragePolicyUnknown reason -> StorageUnknownRelease reason

let storage_policy_equality = function
  | StoragePolicyUnmanagedBits -> StorageEqualityBits
  | StoragePolicyManagedPointer -> StorageEqualityPointer
  | StoragePolicyOwnedErasedBox -> StorageEqualityPointer
  | StoragePolicyUnknown reason -> StorageUnknownEquality reason

let storage_policy_requires_release_or_error ~phase ~loc ~subject ~hint policy =
  match storage_policy_release policy with
  | StorageNoRelease -> false
  | StorageArcRelease -> true
  | StorageUnknownRelease reason ->
      Core_error.errorf phase loc ~hint "unknown %s release policy: %s" subject
        reason

let storage_policy_requires_retain_or_error ~phase ~loc ~subject ~hint policy =
  match storage_policy_retain policy with
  | StorageNoRetain -> false
  | StorageArcRetain -> true
  | StorageUnknownRetain reason ->
      Core_error.errorf phase loc ~hint "unknown %s retain policy: %s" subject
        reason

type list_element_value_layout =
  | ListElementPointer
  | ListElementInlineBits of inline_storage_width
  | ListElementStackStruct of string
  | ListElementBoxedValue
  | ListElementUnknownValue of string

type list_storage_layout = {
  lsl_slots : list_storage_slot_layout;
  lsl_elem_ty : Ast.type_expr option;
  lsl_value_layout : list_element_value_layout;
  lsl_policy : container_storage_policy;
}

let list_storage_layout ?elem_ty ?(value_layout = ListElementPointer)
    ?(policy = StoragePolicyUnknown "unclassified list element") slots =
  {
    lsl_slots = slots;
    lsl_elem_ty = elem_ty;
    lsl_value_layout = value_layout;
    lsl_policy = policy;
  }

let list_pointer_storage ?elem_ty ?value_layout ?policy () =
  list_storage_layout ?elem_ty ?value_layout ?policy ListPointerStorage

let list_storage_layout_release_hint =
  "list element release policy should be fixed when Core_list_layout builds \
   the storage descriptor"

let list_storage_layout_retain_hint =
  "list element retain policy should be fixed when Core_list_layout builds the \
   storage descriptor"

let list_storage_layout_requires_release_or_error ~phase ~loc layout =
  storage_policy_requires_release_or_error ~phase ~loc ~subject:"list element"
    ~hint:list_storage_layout_release_hint layout.lsl_policy

let list_storage_layout_requires_retain_or_error ~phase ~loc layout =
  storage_policy_requires_retain_or_error ~phase ~loc ~subject:"list element"
    ~hint:list_storage_layout_retain_hint layout.lsl_policy

let list_inline_storage ?elem_ty ?(policy = StoragePolicyUnmanagedBits) width =
  list_storage_layout ?elem_ty ~value_layout:(ListElementInlineBits width)
    ~policy (ListInlineStorage width)

let list_inline_struct_storage ?elem_ty ?(policy = StoragePolicyUnmanagedBits)
    c_type =
  list_storage_layout ?elem_ty ~value_layout:(ListElementStackStruct c_type)
    ~policy (ListInlineStructStorage c_type)

type tensor_storage_slot_layout =
  | TensorRawScalarStorage of tensor_unboxed_scalar
  | TensorWordStorage
  | TensorPackedStorage of inline_storage_width
  | TensorInlineStructStorage of string
  | TensorBoxedStorage

type tensor_element_value_layout =
  | TensorValueRawScalar of tensor_unboxed_scalar
  | TensorValueWordSlot
  | TensorValuePackedBits of inline_storage_width
  | TensorValueInlineStruct of string
  | TensorValueBoxedPointer
  | TensorValueBoxedValue
  | TensorValueUnknown of string

type tensor_storage_layout = {
  tsl_slots : tensor_storage_slot_layout;
  tsl_elem_ty : Ast.type_expr option;
  tsl_value_layout : tensor_element_value_layout;
  tsl_policy : container_storage_policy;
}

let tensor_storage_layout ?elem_ty
    ?(value_layout = TensorValueUnknown "unknown")
    ?(policy = StoragePolicyUnknown "unclassified tensor element") slots =
  {
    tsl_slots = slots;
    tsl_elem_ty = elem_ty;
    tsl_value_layout = value_layout;
    tsl_policy = policy;
  }

let tensor_storage_layout_release_hint =
  "tensor element release policy should be fixed when Core_layout_type builds \
   the storage descriptor"

let tensor_storage_layout_requires_release_or_error ~phase ~loc layout =
  storage_policy_requires_release_or_error ~phase ~loc ~subject:"tensor element"
    ~hint:tensor_storage_layout_release_hint layout.tsl_policy

let tensor_raw_scalar_storage ?elem_ty ?(policy = StoragePolicyUnmanagedBits)
    scalar =
  tensor_storage_layout ?elem_ty ~value_layout:(TensorValueRawScalar scalar)
    ~policy (TensorRawScalarStorage scalar)

let tensor_packed_storage ?elem_ty ?(policy = StoragePolicyUnmanagedBits) width
    =
  tensor_storage_layout ?elem_ty ~value_layout:(TensorValuePackedBits width)
    ~policy (TensorPackedStorage width)

let tensor_inline_struct_storage ?elem_ty ?(policy = StoragePolicyUnmanagedBits)
    c_type =
  tensor_storage_layout ?elem_ty ~value_layout:(TensorValueInlineStruct c_type)
    ~policy (TensorInlineStructStorage c_type)

let tensor_boxed_storage ?elem_ty ?value_layout ?policy () =
  let value_layout =
    Option.value value_layout ~default:TensorValueBoxedPointer
  in
  tensor_storage_layout ?elem_ty ~value_layout ?policy TensorBoxedStorage

type tensor_storage_provenance_kind =
  | TensorStorageKnownProducer
      (** Storage was allocated by a compiler-owned producer whose layout is
          selected from the static element type. *)
  | TensorStoragePreservedProducer
      (** Storage was produced by an operation that preserves a proven source
          layout. *)
  | TensorStorageValidatedBoundary
      (** Storage crossed a boundary but was runtime-validated before the proof
          was attached. *)

type tensor_storage_provenance =
  | TensorStorageUnknown of string
  | TensorStorageProven of {
      tsp_kind : tensor_storage_provenance_kind;
      tsp_layout : tensor_storage_layout;
    }

let tensor_storage_known_producer layout =
  TensorStorageProven
    { tsp_kind = TensorStorageKnownProducer; tsp_layout = layout }

let tensor_storage_preserved_producer layout =
  TensorStorageProven
    { tsp_kind = TensorStoragePreservedProducer; tsp_layout = layout }

type loop_range_direction = RangeMayRunBackward | RangeForwardOnly

type loop_binder = {
  loop_var : var;
  loop_ty : Ast.type_expr;
  loop_range_direction : loop_range_direction;
  loop_source_storage : tensor_storage_provenance;
}
(** For-loop binder with the loop element's static type and iterable storage
    provenance.

    The emitter must not reconstruct a loop variable's type from the iterable
    shape: tuple binders such as [for (k, v) in dict:] are a different view
    over the same iterable than key-only [for k in dict:]. Carrying the binder
    type in Core keeps that decision in inference and lowering, where type
    information is authoritative.

    [loop_range_direction] is only consulted when the iterable is a [CRange].
    Most source ranges preserve Blorp's bidirectional range semantics.
    Compiler-synthesized loops over known-forward domains can opt into
    [RangeForwardOnly] so C emission does not need a runtime step variable.

    [loop_source_storage] is intentionally explicit. A tensor's static element
    type does not prove that the runtime buffer has the corresponding raw
    storage layout; parameters and FFI returns can still carry unknown storage.
    Final Core preparation may attach a proof for compiler-owned producers or
    operations that preserve a proven source layout. *)

let default_loop_source_storage =
  TensorStorageUnknown "loop source storage has not been proven"

let loop_binder (loop_var : var) (loop_ty : Ast.type_expr) : loop_binder =
  {
    loop_var;
    loop_ty;
    loop_range_direction = RangeMayRunBackward;
    loop_source_storage = default_loop_source_storage;
  }

let loop_binder_forward_range (loop_var : var) (loop_ty : Ast.type_expr) :
    loop_binder =
  {
    loop_var;
    loop_ty;
    loop_range_direction = RangeForwardOnly;
    loop_source_storage = default_loop_source_storage;
  }

let loop_binder_named (name : string) (loop_ty : Ast.type_expr) : loop_binder =
  loop_binder (Var.named name) loop_ty

let loop_binder_named_forward_range (name : string) (loop_ty : Ast.type_expr) :
    loop_binder =
  loop_binder_forward_range (Var.named name) loop_ty

type list_access_bounds = ListBoundsChecked | ListBoundsProven
type string_read_bounds_proof = StringReadBoundsProven
type string_write_bounds_proof = StringWriteBoundsProven
type string_copy_bounds_proof = StringCopyBoundsProven
type string_set_len_bounds_proof = StringSetLenBoundsProven

(** Final-Core representation of how a typed value is boxed into a generic
    [void*] runtime slot. The codegen-prepare pass selects this once; emit
    renders it without re-inferring from the type. *)
type box_kind =
  | BoxFloat
  | BoxFloat32
  | BoxFloat16
  | BoxInt128
  | BoxUInt128
  | BoxVoid
  | BoxPointer
  | BoxPrim
  | BoxStruct of string

(** Final-Core representation of how a generic [void*] runtime slot is
    projected back into a typed value. *)
type unbox_kind =
  | UnboxFloat
  | UnboxFloat32
  | UnboxFloat16
  | UnboxInt128
  | UnboxUInt128
  | UnboxPointer
  | UnboxPrim
  | UnboxStruct of string

type dict_constructor =
  | DictGeneric
  | DictString
  | DictFloat
  | DictCustom of Ast.type_expr

type set_constructor =
  | SetGeneric
  | SetString
  | SetFloat
  | SetCustom of Ast.type_expr

type tensor_literal_shape =
  | TensorVectorLength of int
  | TensorStaticShape of int list

let tensor_unboxed_scalar_of_type = function
  | Ast.TyNamed ("Float", []) -> Some TensorFloat64Elements
  | Ast.TyNamed ("Float32", []) -> Some TensorFloat32Elements
  | Ast.TyNamed ("Int", []) -> Some TensorInt64Elements
  | _ -> None

type core = { desc : desc; ty : Ast.type_expr; loc : Ast.loc }
(** A Core expression. Every node carries its type and source location. *)

(** An accessor path: a symbolic description of where to read a
    sub-value from the root match scrutinee. Self-contained (doesn't
    reference [core]) so the decision-tree IR can be reasoned about
    independently of the scrutinee expression.

    - [AccRoot]: the scrutinee itself.
    - [AccVariantField (acc, ctor, idx)]: field [idx] of constructor
      [ctor] reached via [acc]. Emits as [acc->data.Ctor.fieldN] in C.
    - [AccTupleField (acc, idx)]: tuple field [idx] of the value at
      [acc]. *)
and accessor =
  | AccRoot
  | AccVariantField of accessor * string * int
  | AccTupleField of accessor * int
  | AccListElem of accessor * int  (** list element at index [i] *)
  | AccListSpread of accessor * int  (** sub-list starting at index [i] *)

(** A decision tree compiled from a [CMatchArms] by [Core_match].

    Each internal node represents a runtime test; each leaf carries the
    bindings to establish before evaluating the user body. The tree is
    produced by [Core_match.compile_match] and consumed by [Core_perceus]
    for liveness/drop placement and by [Core_emit] for backend output.

    Design choice: the tree is self-contained with accessors instead
    of raw [core] expressions. Sub-scrutinees are reached via
    [accessor] paths, not by threading arbitrary [core] nodes through
    the tree. This keeps [ctree] small and makes Perceus's shape
    analysis straightforward. *)
and ctree =
  | CTLeaf of {
      ct_bindings : (var * accessor) list;
          (** Pattern variables to bind before evaluating [ct_body]. The
          accessor is resolved against the root scrutinee at emission. *)
      ct_body : core;
    }
  | CTFail
      (** No arm matched. Should be unreachable if exhaustiveness has
        been verified upstream. Emission raises at runtime. *)
  | CTSwitchTag of {
      cts_scrut : accessor;
      cts_cases : (string * ctree) list;  (** constructor name → subtree *)
      cts_default : ctree option;
    }
  | CTSwitchLit of {
      ctl_scrut : accessor;
      ctl_cases : (Ast.literal * ctree) list;
      ctl_default : ctree;  (** literals never exhaust — always need a default *)
    }
  | CTSwitchLen of {
      ctl_len_scrut : accessor;
      ctl_len_cases : (int * ctree) list;  (** exact length → subtree *)
      ctl_len_geq : (int * ctree) option;  (** >= N for spread patterns *)
      ctl_len_default : ctree option;  (** fallback for unmatched lengths *)
    }

(** Classification of a call by callee kind.

    [CKUnknown] is what lowering produces — no resolution done yet. A
    post-lowering pass ([Core_resolve.resolve_program]) can promote
    these to one of the concrete kinds below, based on a name-lookup
    env built from the program.

    The point of the tag is to keep [Core_emit] small: emitters switch
    on [call_kind] instead of re-doing name lookups at every call site.

    - [CKUser name]: call to a user-defined blorp function by source name.
    - [CKForeign info]: call to a foreign C function, including the C
      symbol and the argument-passing mode selected at the declaration site.
    - [CKBuiltin c_name]: call to a blorp builtin with a resolved C name.
    - [CKIntrinsic name]: a primitive operation defined at the IR level.
      Unlike [CKBuiltin], which maps to a named C function, intrinsics
      emit structural code that is backend-defined. The name identifies
      which primitive (e.g. ["list_len"], ["list_get_raw"]).
    - [CKClosure]: indirect call through a first-class function value. *)
and foreign_copy_kind = ForeignStringCopy | ForeignBytesCopy

and foreign_default_arg_policy =
  | ForeignScalarByValue
      (** Argument has unmanaged scalar layout and is safe to pass by value. *)
  | ForeignDefensiveCopy of foreign_copy_kind
      (** Argument is a runtime buffer that must be copied before C sees it. *)

and foreign_arg_passing =
  | ForeignDefaultArgs of foreign_default_arg_policy list
      (** Defensive FFI boundary: each argument carries the checked policy
        selected before call resolution. This is the default for impure
        functions inside [foreign:] blocks. *)
  | ForeignBorrowArgs
      (** Borrowing FFI boundary: pass direct runtime buffers. Used by
        pure foreign functions and explicit [@no_copy] declarations. *)

and foreign_call = { fc_c_name : string; fc_arg_passing : foreign_arg_passing }

and call_kind =
  | CKUnknown
  | CKSelectedDirect of int
      (** A direct source call whose selected [core_func.cf_def_id] came from
      typed [resolved_call] metadata but whose canonical post-flatten Core
      name is not available yet. [Core_mono] may use this id for generic body
      selection; [Core_resolve] must replace it with [CKUser] before
      specialization/emission. *)
  | CKUser of string * int option
      (** User-defined function call. The [int option] is the callee's
      [core_func.cf_def_id] when the resolver can identify the target,
      or [None] during A3 migration when the ladder produces a
      [CKUser] without having the DefId in hand. A4.2 flips all mangling
      to read from this DefId; the [None] branch falls back to the
      legacy name-based scheme for compatibility. *)
  | CKForeign of foreign_call
  | CKBuiltin of string
  | CKIntrinsic of string
  | CKClosure

and desc =
  (* === Values (no computation) === *)
  | CLit of Ast.literal  (** [42], ["hi"], [true], ['a'] *)
  | CVar of var  (** variable reference *)
  | CVoid  (** unit / void *)
  (* === Data construction === *)
  | CTuple of core list  (** [(a, b, c)] *)
  | CList of list_literal  (** [[a, b, c]] *)
  | CListAlloc of list_alloc  (** Internal fresh list allocation. *)
  | CListGet of list_get  (** Internal layout-aware list element load. *)
  | CStringByteRead of string_byte_read
      (** Internal unchecked string byte load. The node is only valid when
          [sbr_proof] proves [sbr_index] is within the source length. *)
  | CStringByteWrite of string_byte_write
      (** Internal unchecked string byte store. The node is only valid when
          [sbw_proof] proves [sbw_index] is within the target capacity. *)
  | CStringByteCopy of string_byte_copy
      (** Internal unchecked string byte-span copy. The node is only valid
          when [sbc_proof] proves both source and destination ranges. *)
  | CStringSetLen of string_set_len
      (** Internal unchecked string length update. The node is only valid when
          [ssl_proof] proves [ssl_len] is within the target capacity. *)
  | CTupleConstruct of tuple_construct
  | CListConstruct of list_construct
  | CVector of core list  (** dense numeric vector literal *)
  | CTensorLiteral of tensor_literal
  | CDict of (core * core) list  (** [{k => v, ...}] *)
  | CDictConstruct of dict_construct
  | CSetAlloc of set_alloc
  | CRecord of (string * core) list  (** [{field = val, ...}] *)
  | CRecordConstruct of record_construct
  | CRecordUpdate of core * (string * core) list
      (** [{ base | f = v, ... }] — sugar, desugar pass eliminates later *)
  | CRange of core * core  (** [start..end] (exclusive) *)
  | CLambda of lambda  (** anonymous function *)
  | CClosureCreate of closure_create
      (** closure construction (post-conversion) *)
  (* === Computation === *)
  | CBin of Ast.binop * core * core  (** arithmetic / comparison *)
  | CUn of Ast.unop * core  (** [-x], [not x] *)
  | CLog of Ast.logop * core * core  (** short-circuit [and] / [or] *)
  | CCall of call_kind * core * core list
      (** function or closure call. The
                                         [call_kind] starts as [CKUnknown]
                                         from lowering; a resolver pass
                                         promotes known callees to concrete
                                         kinds. *)
  | CTensorRawRead of tensor_raw_read
      (** Read from an internal typed raw tensor view. Only valid under a
          dominating [CTensorRawViewLet] with the same scalar kind. *)
  | CTensorRawWrite of tensor_raw_write
      (** Write through an internal typed raw tensor view. Only valid under a
          dominating [CTensorRawViewLet] with the same scalar kind and a
          uniqueness-guarded fast path. *)
  | CField of core * string  (** record field access *)
  | CStringInterp of interp_part list * bool
      (** [f"x=${x}"] — sugar, parts * is_multiline *)
  (* === Sequencing === *)
  | CLet of binding * core  (** [let x = e1 in e2] (body is the result) *)
  | CBorrowLet of borrowed_binding * core
      (** Internal borrowed alias binding. Unlike [CLet], this does not own
          [borrow_rhs] and Perceus must not emit retain/drop operations for
          [borrow_var]. Use this for compiler-synthesized aliases whose owner
          dominates the body. *)
  | CTensorRawViewLet of tensor_raw_view_binding * core
      (** Internal typed raw tensor storage view. This is stricter than a
          generic [Ptr]: reads and writes reference the bound view variable and
          carry the same closed scalar layout kind. The fast path that creates
          this node must guard storage layout and COW uniqueness before the
          view is bound. *)
  | CResourceScope of resource_scope
      (** Explicit deterministic cleanup scope. [rs_acquire] is evaluated once
          and bound to [rs_var] while [rs_body] runs; [rs_cleanup] then runs
          before the scope returns [rs_body]'s value. Cleanup is semantic
          resource finalization, distinct from ARC release/drop. *)
  | CResourceCleanupExit of resource_cleanup_exit
      (** Explicit cleanup edge before nonlocal loop control leaves one or
          more active resource scopes. Produced by [Core_resource] after the
          normal Core passes know which [break]/[continue] nodes are not
          captured by an inner loop. *)
  | CSeq of core * core  (** [e1; e2] — both evaluated, result is [e2] *)
  | CDebugBlock of core
      (** [debug: ...] — source instrumentation block. [Core_debug] lowers it
          immediately after [Core_lower] based on the compilation mode, before
          normal Core desugaring and before any backend sees the program. *)
  (* === Control flow === *)
  | CIf of core * core * core
      (** [if c then t else e] (else is [CVoid] if absent in source) *)
  | CMatchArms of core * (Ast.pattern * core) list
      (** pattern match — raw, pre-decision-tree.
                                         [Core_match] rewrites every [CMatchArms]
                                         into the compiled [CMatch] form below.
                                         Post-match, a surviving [CMatchArms] is
                                         an invariant violation
                                         (see [Core_invariants.check_no_cmatcharms]). *)
  | CMatch of core * ctree
      (** compiled match: root scrutinee + decision tree.
                                         This is the canonical post-[Core_match] form. *)
  | CWhile of core * core  (** [while cond { body }] *)
  | CFor of loop_binder * core * core  (** [for v: ty in iter { body }] *)
  | CBreak  (** loop exit *)
  | CContinue  (** loop continue *)
  | CAssign of var * core  (** mutation of a [var]-declared binding *)
  | CTailrecLoop of tailrec_loop
      (** Explicit tail-recursive self-loop. Produced by [Core_tailrec]
          after call resolution and before ownership analysis. *)
  | CTailrecRecur of tailrec_recur
      (** Rebind loop parameters and continue the enclosing [CTailrecLoop].
          Valid only in tail position inside that loop. *)
  (* === Explicit reference counting (Phase 2 Perceus) === *)
  | CDup of var * Ast.type_expr * core
      (** [incr_rc(v); body] — bump [v]'s
                                         refcount, then evaluate body.
                                         The [type_expr] is [v]'s static
                                         type, carried on the node so
                                         emission can pick the right
                                         retain function. *)
  | CDrop of var * Ast.type_expr * core
      (** [decr_rc(v); body] — drop [v]'s
                                         refcount by one, then evaluate
                                         body. The [type_expr] carries
                                         [v]'s static type so emission
                                         can pick the right release
                                         function (and Phase 2.6 can
                                         emit inline field drops for
                                         known constructors). *)
  (* === Concurrency === *)
  | CConcurrent of concurrent_block  (** [concurrent: { ... }] *)
  | CConcurrentlyLoop of concurrently_loop
      (** [for v in iter concurrently(...): ...] *)
  | CDetach of detach_expr  (** [detach expr] *)
  | CSelect of select_expr  (** [select: ...] channel/timer wait. *)
  (* === Type operations (inserted by Core_specialize) === *)
  | CCast of core * Ast.type_expr
      (** Numeric type coercion, e.g.
                                         Float→Int. Emits as C cast. *)
  | CUnbox of core * Ast.type_expr
      (** Extract typed value from void*.
                                         Float → blorp_unbox_float,
                                         Int → (long)(long)ptr, etc.
                                         [ty] is the TARGET type — the
                                         shape callers expect post-unbox. *)
  | CUnboxTyped of unbox_op
  | CBox of core * Ast.type_expr
      (** Box typed value to void-ptr.
                                         [ty] is the SOURCE type — the
                                         shape of the inner value BEFORE
                                         boxing. Backends dispatch on
                                         this annotation rather than
                                         inspecting the inner node's
                                         [.ty], which may have been
                                         rewritten by an earlier pass.
                                         (Phase 2.6.3; symmetric with
                                         CUnbox's target_ty.) *)
  | CBoxTyped of box_op
  | CUnionConstruct of union_construct
  | CListHandoff of list_handoff
      (** Internal producer/fusion handoff for
                                         list pipelines. Starts in
                                         [BorrowFresh] mode and may be upgraded
                                         to [ConsumeReuse] by [Core_reuse]
                                         after Perceus proves last use of the
                                         source owner. *)

and list_literal = { ll_layout : list_storage_layout; ll_elems : core list }
and list_alloc = { la_layout : list_storage_layout; la_capacity : core }

and list_get = {
  lg_layout : list_storage_layout;
  lg_list : core;
  lg_index : core;
  lg_bounds : list_access_bounds;
}

and string_byte_read = {
  sbr_source : core;
  sbr_index : core;
  sbr_proof : string_read_bounds_proof;
}

and string_byte_write = {
  sbw_target : core;
  sbw_index : core;
  sbw_byte : core;
  sbw_proof : string_write_bounds_proof;
}

and string_byte_copy = {
  sbc_dst : core;
  sbc_dst_pos : core;
  sbc_src : core;
  sbc_src_pos : core;
  sbc_len : core;
  sbc_proof : string_copy_bounds_proof;
}

and string_set_len = {
  ssl_target : core;
  ssl_len : core;
  ssl_proof : string_set_len_bounds_proof;
}

and tensor_raw_view_binding = {
  trv_var : var;
  trv_kind : tensor_unboxed_scalar;
  trv_source : core;
}

and resource_scope = {
  rs_var : var;
      (** Compiler-visible resource binding. User wildcard bindings should
          still lower to a hidden variable so cleanup has a stable target. *)
  rs_ty : Ast.type_expr;  (** Static resource capability type. *)
  rs_acquire : core;  (** Expression that produces the scoped resource. *)
  rs_body : core;  (** Scope body. The enclosing node returns this value. *)
  rs_cleanup : core;  (** Cleanup action. Must have type [Void]. *)
}

and resource_exit_kind = ResourceBreak | ResourceContinue

and resource_cleanup_exit = {
  rce_cleanups : core list;
      (** Cleanup actions to run before the exit. Stored innermost-first so
          nested resources close in reverse acquisition order. *)
  rce_exit : resource_exit_kind;
}

and tensor_raw_read = {
  trr_view : var;
  trr_kind : tensor_unboxed_scalar;
  trr_index : core;
}

and tensor_raw_write = {
  trw_view : var;
  trw_kind : tensor_unboxed_scalar;
  trw_index : core;
  trw_value : core;
}

and box_op = {
  box_value : core;
  box_source_ty : Ast.type_expr;
  box_kind : box_kind;
}

and unbox_op = {
  unbox_value : core;
  unbox_target_ty : Ast.type_expr;
  unbox_kind : unbox_kind;
}

and tailrec_recur =
  | TailrecRecur of { tr_args : core list }
      (** Rebind every loop parameter from [tr_args], then continue. *)
  | TailrecListSpreadRecur of {
      tr_rebinds : (int * core) list;
          (** Non-list parameter index and next value. The list parameter is
              represented by [tr_cursor_advance] instead of a materialized
              tail-list argument. *)
      tr_cursor_advance : int;
    }

and tailrec_loop =
  | TailrecUnmanagedLoop of {
      tul_params : core_param list;
      tul_return_ty : Ast.type_expr;
      tul_body : core;
    }
  | TailrecListSpreadLoop of {
      tls_params : core_param list;
      tls_return_ty : Ast.type_expr;
      tls_list_index : int;
      tls_list_param : core_param;
      tls_cursor_var : var;
      tls_body : core;
          (** Canonically a tail-context chain ending in
              [CMatch (CVar tls_list_param, tree)] with
              [TailrecListSpreadRecur] leaves. Kept as Core so ownership
              analysis still sees local bindings, the scrutinee, and
              decision-tree bindings. *)
    }

and boxed_storage_value = {
  bsv_box : box_op;
  bsv_needs_release : bool;
  bsv_transfers_ownership : bool;
}

and tensor_literal_payload =
  | TensorRawElements of tensor_unboxed_scalar * core list
  | TensorWordElements of core list
  | TensorPackedElements of inline_storage_width * core list
  | TensorInlineStructElements of string * core list
  | TensorBoxedElements of boxed_storage_value list

and tuple_construct = {
  tc_elems : boxed_storage_value list;
  tc_release_mask : int;
  tc_retain_mask : int;
}

and list_construct = {
  lc_layout : list_storage_layout;
  lc_elems : boxed_storage_value list;
  lc_elem_needs_release : bool;
}

and dict_construct = {
  dc_constructor : dict_constructor;
  dc_entries : (boxed_storage_value * boxed_storage_value) list;
  dc_value_needs_release : bool;
}

and set_alloc = { sa_constructor : set_constructor }

and record_field_arg =
  | RecordRawField of string * core
  | RecordErasedField of string * boxed_storage_value

and record_construct = {
  rc_type_name : string;
  rc_fields : record_field_arg list;
  rc_erased_release_mask : int option;
}

and tensor_literal = {
  tl_shape : tensor_literal_shape;
  tl_layout : tensor_storage_layout;
  tl_payload : tensor_literal_payload;
}

and union_representation =
  | GenericUnion
  | OptionUnion of Core_option_layout.layout
  | ResultUnion of Core_result_layout.layout

and union_construct = {
  uc_type_name : string;
  uc_constructor_name : string;
  uc_c_name : string;
  uc_tag : int;
  uc_representation : union_representation;
  uc_args : boxed_storage_value list;
  uc_release_mask : int;
}

and list_handoff = {
  lh_mode : handoff_mode;
  lh_layout : list_storage_layout;
  lh_source : core;
      (** Source list expression. The handoff emitter evaluates this exactly once
      into [lh_source_var] before running [lh_body]. *)
  lh_source_var : var;
  lh_source_ty : Ast.type_expr;
  lh_result_ty : Ast.type_expr;
  lh_capacity : core;
      (** Minimum result capacity / upper bound. Evaluated once. *)
  lh_result_var : var;
      (** Write-only result builder available inside [lh_body]. *)
  lh_len_var : var;  (** Source length available inside [lh_body]. *)
  lh_out_var : var;  (** Mutable output length available inside [lh_body]. *)
  lh_body : core;
      (** Producer body. It may read [lh_source_var], write [lh_result_var], and
      update [lh_out_var]. It must not return the result directly; the handoff
      node finalizes length and returns [lh_result_var]. *)
  lh_write_order : handoff_write_order;
}

and interp_part =
  | IPLit of string  (** literal chunk of interpolated string *)
  | IPExpr of core  (** interpolated expression *)

and binding = {
  bind_var : var;
  bind_mut : bool;  (** [var x] ([true]) vs [let x] ([false]) *)
  bind_ty : Ast.type_expr;  (** declared or inferred type of the binding *)
  bind_rhs : core;
}

and borrowed_binding = {
  borrow_var : var;
  borrow_ty : Ast.type_expr;
  borrow_rhs : core;
}

and lambda = {
  lam_params : (var * Ast.type_expr) list;
  lam_body : core;
  lam_return_ty : Ast.type_expr;
  lam_is_pure : bool;
}

and closure_create = {
  cc_func : string;  (** name of hoisted function *)
  cc_def_id : int;
      (** [cf_def_id] of the hoisted function [cc_func] refers to.
      [Core_closure] mints a fresh [core_func] for the lambda and
      copies its [cf_def_id] here so [Core_emit] can mangle the
      static closure ([__sc_<mangled>]) and the inline closure new
      call using the same DefId the function's decl site uses. *)
  cc_captures : (string * Ast.type_expr) list;
      (** captured variable names + types *)
}
(** A closure construction site — references a hoisted top-level function
    and lists the captured variables. Produced by [Core_closure]. *)

and task_closure = {
  tc_func : string;  (** name of hoisted task function *)
  tc_def_id : int;
  tc_captures : task_capture list;
      (** captured variables with task-specific ownership semantics *)
  tc_return_ty : Ast.type_expr;  (** raw task body return type *)
}
(** A Core-visible runtime task closure. Produced by [Core_closure] for
    concurrency constructs whose bodies are executed by the task runtime
    rather than called as ordinary first-class functions. *)

and task_capture = {
  task_capture_name : string;
  task_capture_ty : Ast.type_expr;
  task_capture_kind : task_capture_kind;
}

and task_capture_kind =
  | TaskCopyCapture  (** Ordinary immutable value captured into a child task. *)
  | TaskMoveResourceItem
      (** Reserved for resource-source loops where each item is moved into
          exactly one child task. *)
  | TaskStructuredTaskBorrow
      (** Reserved for structured borrows that are proven not to outlive the
          child task. *)

and task_scope_id = TaskScopeId of int

and concurrent_task_scope = {
  task_parent_scope_id : task_scope_id;
  task_child_scope_id : task_scope_id;
}

and closure_abi = {
  ca_params : (var * Ast.type_expr) list;  (** original typed parameters *)
  ca_captures : (string * Ast.type_expr) list;  (** captured variables *)
  ca_task_abi : bool;  (** true when task runtime calls this closure *)
}
(** Closure ABI metadata on hoisted lambda functions. When present on
    a [core_func], the emitter generates a void* ABI wrapper function
    that unboxes captures from env and params from void* args. *)

and conc_binding = {
  cb_var : var;  (** the binding name in the outer scope *)
  cb_ty : Ast.type_expr;
      (** [Result[T, ConcurrencyError]] — user-visible type *)
  cb_rhs : core;  (** the task body (its [.ty] is [T], the inner return) *)
  cb_task_scope : concurrent_task_scope;
      (** Lexical parent/child scope edge for the task that evaluates
      [cb_rhs]. *)
  cb_task : task_closure option;
      (** Core-visible task closure metadata after [Core_closure]. [None] is
      the pre-closure-conversion form and remains accepted so tests and
      defensive emit paths can construct early-stage Core directly. *)
}

and concurrent_block = {
  conc_bindings : conc_binding list;
      (** tasks spawned in parallel; bindings
                                         are introduced into the outer scope
                                         after all joins complete *)
  conc_body : core;  (** tail — code that uses the bindings *)
  conc_timeout : core option;
  conc_max_threads : int option;
}

and concurrently_loop_width =
  | ConcurrentlyLoopLimit of core
      (** [for ... concurrently(limit: expr)]. The parser currently admits only
          positive integer literals for source loops, but synthesized Core can
          carry a typed Int expression for helpers such as [List.concurrent]. *)

and concurrently_loop_output =
  | ConcurrentlyLoopCollect
      (** The loop is a value expression and produces
          [List[Result[T, ConcurrencyError]]]. *)
  | ConcurrentlyLoopDiscard
      (** The loop is statement fan-out and produces [Void]. Child task body
          values are sequenced for effect and discarded before task completion. *)

and concurrently_loop = {
  cf_var : var;
  cf_iter : core;
  cf_body : core;
  cf_timeout : core option;
  cf_width : concurrently_loop_width;
  cf_output : concurrently_loop_output;
  cf_task_scope : concurrent_task_scope;
  cf_task : task_closure option;
      (** Core-visible per-iteration task closure metadata after
      [Core_closure]. [None] is the pre-closure-conversion form. *)
}

and detach_expr = { detach_body : core; detach_task : task_closure option }

and select_arm_kind =
  | SelectRecv of {
      select_bind : var;
      select_elem_ty : Ast.type_expr;
      select_channel : core;
    }
  | SelectSealed of core
  | SelectAfter of core

and select_arm = {
  select_arm_kind : select_arm_kind;
  select_arm_body : core;
  select_arm_loc : Ast.loc;
}

and select_expr = { select_arms : select_arm list }

(* ============================================================================
   Smart constructors
   ============================================================================ *)

(** Build a core node. *)
let mk ~loc ~ty desc = { desc; ty; loc }

let task_copy_capture (name, ty) =
  {
    task_capture_name = name;
    task_capture_ty = ty;
    task_capture_kind = TaskCopyCapture;
  }

let task_copy_captures captures = List.map task_copy_capture captures

let task_capture_binding capture =
  (capture.task_capture_name, capture.task_capture_ty)

let task_capture_bindings captures = List.map task_capture_binding captures
let root_task_scope_id = TaskScopeId 0
let task_scope_id_to_int (TaskScopeId id) = id

let concurrent_task_scope ~parent ~child =
  let parent_id = task_scope_id_to_int parent in
  let child_id = task_scope_id_to_int child in
  if parent_id < 0 then
    invalid_arg "concurrent task parent scope id must be non-negative";
  if child_id <= 0 then
    invalid_arg "concurrent task child scope id must be positive";
  if parent_id = child_id then
    invalid_arg "concurrent task parent and child scope ids must differ";
  { task_parent_scope_id = parent; task_child_scope_id = child }

let synthetic_concurrent_task_scope =
  concurrent_task_scope ~parent:root_task_scope_id ~child:(TaskScopeId 1)

(* ============================================================================
   Traversal
   ============================================================================ *)

let map_loop_width f = function
  | ConcurrentlyLoopLimit limit -> ConcurrentlyLoopLimit (f limit)

(** [map_children f e] applies [f] to each immediate child of [e] and
    rebuilds the node. Does not recurse — caller decides when to go deep.
    This is the primitive on which every Core-to-Core pass is built. *)
let rec map_children (f : core -> core) (e : core) : core =
  let map_box_op b = { b with box_value = f b.box_value } in
  let map_unbox_op u = { u with unbox_value = f u.unbox_value } in
  let map_boxed_storage_value v = { v with bsv_box = map_box_op v.bsv_box } in
  let map_record_field_arg = function
    | RecordRawField (name, value) -> RecordRawField (name, f value)
    | RecordErasedField (name, value) ->
        RecordErasedField (name, map_boxed_storage_value value)
  in
  let d =
    match e.desc with
    | CLit _ | CVar _ | CVoid | CBreak | CContinue -> e.desc
    | CTuple xs -> CTuple (List.map f xs)
    | CList lit -> CList { lit with ll_elems = List.map f lit.ll_elems }
    | CListAlloc alloc ->
        CListAlloc { alloc with la_capacity = f alloc.la_capacity }
    | CListGet get ->
        CListGet { get with lg_list = f get.lg_list; lg_index = f get.lg_index }
    | CStringByteRead r ->
        CStringByteRead
          { r with sbr_source = f r.sbr_source; sbr_index = f r.sbr_index }
    | CStringByteWrite w ->
        CStringByteWrite
          {
            w with
            sbw_target = f w.sbw_target;
            sbw_index = f w.sbw_index;
            sbw_byte = f w.sbw_byte;
          }
    | CStringByteCopy c ->
        CStringByteCopy
          {
            c with
            sbc_dst = f c.sbc_dst;
            sbc_dst_pos = f c.sbc_dst_pos;
            sbc_src = f c.sbc_src;
            sbc_src_pos = f c.sbc_src_pos;
            sbc_len = f c.sbc_len;
          }
    | CStringSetLen s ->
        CStringSetLen
          { s with ssl_target = f s.ssl_target; ssl_len = f s.ssl_len }
    | CTupleConstruct tc ->
        CTupleConstruct
          { tc with tc_elems = List.map map_boxed_storage_value tc.tc_elems }
    | CListConstruct lc ->
        CListConstruct
          { lc with lc_elems = List.map map_boxed_storage_value lc.lc_elems }
    | CVector xs -> CVector (List.map f xs)
    | CTensorLiteral tl ->
        let payload =
          match tl.tl_payload with
          | TensorRawElements (scalar, elems) ->
              TensorRawElements (scalar, List.map f elems)
          | TensorWordElements elems -> TensorWordElements (List.map f elems)
          | TensorPackedElements (width, elems) ->
              TensorPackedElements (width, List.map f elems)
          | TensorInlineStructElements (c_ty, elems) ->
              TensorInlineStructElements (c_ty, List.map f elems)
          | TensorBoxedElements elems ->
              TensorBoxedElements (List.map map_boxed_storage_value elems)
        in
        CTensorLiteral { tl with tl_payload = payload }
    | CDict kvs -> CDict (List.map (fun (k, v) -> (f k, f v)) kvs)
    | CDictConstruct dc ->
        CDictConstruct
          {
            dc with
            dc_entries =
              List.map
                (fun (k, v) ->
                  (map_boxed_storage_value k, map_boxed_storage_value v))
                dc.dc_entries;
          }
    | CSetAlloc _ -> e.desc
    | CRecord fs -> CRecord (List.map (fun (n, v) -> (n, f v)) fs)
    | CRecordConstruct rc ->
        CRecordConstruct
          { rc with rc_fields = List.map map_record_field_arg rc.rc_fields }
    | CRecordUpdate (b, fs) ->
        CRecordUpdate (f b, List.map (fun (n, v) -> (n, f v)) fs)
    | CRange (a, b) -> CRange (f a, f b)
    | CLambda lam -> CLambda { lam with lam_body = f lam.lam_body }
    | CClosureCreate _ -> e.desc (* leaf node: no child expressions *)
    | CBin (op, l, r) -> CBin (op, f l, f r)
    | CUn (op, x) -> CUn (op, f x)
    | CLog (op, l, r) -> CLog (op, f l, f r)
    | CCall (k, fn, args) -> CCall (k, f fn, List.map f args)
    | CTensorRawRead r -> CTensorRawRead { r with trr_index = f r.trr_index }
    | CTensorRawWrite w ->
        CTensorRawWrite
          { w with trw_index = f w.trw_index; trw_value = f w.trw_value }
    | CField (e', name) -> CField (f e', name)
    | CStringInterp (parts, is_multiline) ->
        let parts' =
          List.map
            (function IPLit s -> IPLit s | IPExpr e' -> IPExpr (f e'))
            parts
        in
        CStringInterp (parts', is_multiline)
    | CLet (b, body) -> CLet ({ b with bind_rhs = f b.bind_rhs }, f body)
    | CBorrowLet (b, body) ->
        CBorrowLet ({ b with borrow_rhs = f b.borrow_rhs }, f body)
    | CTensorRawViewLet (b, body) ->
        CTensorRawViewLet ({ b with trv_source = f b.trv_source }, f body)
    | CResourceScope scope ->
        CResourceScope
          {
            scope with
            rs_acquire = f scope.rs_acquire;
            rs_body = f scope.rs_body;
            rs_cleanup = f scope.rs_cleanup;
          }
    | CResourceCleanupExit exit ->
        CResourceCleanupExit
          { exit with rce_cleanups = List.map f exit.rce_cleanups }
    | CSeq (a, b) -> CSeq (f a, f b)
    | CDebugBlock body -> CDebugBlock (f body)
    | CIf (c, t, el) -> CIf (f c, f t, f el)
    | CMatchArms (s, arms) ->
        CMatchArms (f s, List.map (fun (p, body) -> (p, f body)) arms)
    | CMatch (s, tree) -> CMatch (f s, ctree_map_bodies f tree)
    | CWhile (c, b) -> CWhile (f c, f b)
    | CFor (binder, iter, b) -> CFor (binder, f iter, f b)
    | CAssign (v, rhs) -> CAssign (v, f rhs)
    | CTailrecLoop loop ->
        let loop' =
          match loop with
          | TailrecUnmanagedLoop l ->
              TailrecUnmanagedLoop { l with tul_body = f l.tul_body }
          | TailrecListSpreadLoop l ->
              TailrecListSpreadLoop { l with tls_body = f l.tls_body }
        in
        CTailrecLoop loop'
    | CTailrecRecur recur ->
        let recur' =
          match recur with
          | TailrecRecur r -> TailrecRecur { tr_args = List.map f r.tr_args }
          | TailrecListSpreadRecur r ->
              TailrecListSpreadRecur
                {
                  r with
                  tr_rebinds =
                    List.map (fun (i, arg) -> (i, f arg)) r.tr_rebinds;
                }
        in
        CTailrecRecur recur'
    | CDup (v, t, body) -> CDup (v, t, f body)
    | CDrop (v, t, body) -> CDrop (v, t, f body)
    | CConcurrent cb ->
        CConcurrent
          {
            conc_bindings =
              List.map
                (fun b -> { b with cb_rhs = f b.cb_rhs })
                cb.conc_bindings;
            conc_body = f cb.conc_body;
            conc_timeout = Option.map f cb.conc_timeout;
            conc_max_threads = cb.conc_max_threads;
          }
    | CConcurrentlyLoop cf ->
        CConcurrentlyLoop
          {
            cf_var = cf.cf_var;
            cf_iter = f cf.cf_iter;
            cf_body = f cf.cf_body;
            cf_timeout = Option.map f cf.cf_timeout;
            cf_width = map_loop_width f cf.cf_width;
            cf_output = cf.cf_output;
            cf_task_scope = cf.cf_task_scope;
            cf_task = cf.cf_task;
          }
    | CDetach d -> CDetach { d with detach_body = f d.detach_body }
    | CSelect select ->
        let map_arm arm =
          let select_arm_kind =
            match arm.select_arm_kind with
            | SelectRecv r ->
                SelectRecv { r with select_channel = f r.select_channel }
            | SelectSealed channel -> SelectSealed (f channel)
            | SelectAfter timeout -> SelectAfter (f timeout)
          in
          { arm with select_arm_kind; select_arm_body = f arm.select_arm_body }
        in
        CSelect { select_arms = List.map map_arm select.select_arms }
    | CCast (x, ty) -> CCast (f x, ty)
    | CUnbox (x, ty) -> CUnbox (f x, ty)
    | CUnboxTyped u -> CUnboxTyped (map_unbox_op u)
    | CBox (x, ty) -> CBox (f x, ty)
    | CBoxTyped b -> CBoxTyped (map_box_op b)
    | CUnionConstruct uc ->
        CUnionConstruct
          { uc with uc_args = List.map map_boxed_storage_value uc.uc_args }
    | CListHandoff h ->
        CListHandoff
          {
            h with
            lh_source = f h.lh_source;
            lh_capacity = f h.lh_capacity;
            lh_body = f h.lh_body;
          }
  in
  { e with desc = d }

(** [ctree_map_bodies f tree] applies [f] to every body expression in
    a decision tree's leaves. Accessors and structural switches are
    untouched — [f] only runs on user-match-body [core] nodes. *)
and ctree_map_bodies (f : core -> core) (tree : ctree) : ctree =
  match tree with
  | CTLeaf { ct_bindings; ct_body } ->
      CTLeaf { ct_bindings; ct_body = f ct_body }
  | CTFail -> CTFail
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      CTSwitchTag
        {
          cts_scrut;
          cts_cases =
            List.map (fun (n, sub) -> (n, ctree_map_bodies f sub)) cts_cases;
          cts_default = Option.map (ctree_map_bodies f) cts_default;
        }
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      CTSwitchLit
        {
          ctl_scrut;
          ctl_cases =
            List.map (fun (l, sub) -> (l, ctree_map_bodies f sub)) ctl_cases;
          ctl_default = ctree_map_bodies f ctl_default;
        }
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      CTSwitchLen
        {
          ctl_len_scrut;
          ctl_len_cases =
            List.map (fun (n, sub) -> (n, ctree_map_bodies f sub)) ctl_len_cases;
          ctl_len_geq =
            Option.map (fun (n, sub) -> (n, ctree_map_bodies f sub)) ctl_len_geq;
          ctl_len_default = Option.map (ctree_map_bodies f) ctl_len_default;
        }

(** [fold_immediate_children f init e] folds [f] over {b immediate}
    children of [e]. Does not recurse into grandchildren.

    Renamed from the prior [fold_children] because that name wrongly
    suggested a full-tree traversal. For a tree-wide rewrite use
    [transform_bottom_up]; for a tree-wide fold, write a recursive
    helper that uses [fold_immediate_children] at each step. *)
let fold_immediate_children (f : 'a -> core -> 'a) (init : 'a) (e : core) : 'a =
  let acc = ref init in
  let _ =
    map_children
      (fun c ->
        acc := f !acc c;
        c)
      e
  in
  !acc

(** [transform_bottom_up f e] recursively rewrites [e] by first
    transforming all descendants bottom-up, then applying [f] to the
    result. Every Core→Core pass that doesn't need scope context should
    use this rather than hand-rolling a recursion (which is the main
    way you forget a variant).

    Example (constant folding):
    {[
      let fold_constants =
        transform_bottom_up (fun c -> match c.desc with
          | CBin (Add, { desc = CLit (LitInt a); _ },
                       { desc = CLit (LitInt b); _ }) ->
              { c with desc = CLit (LitInt (Int64.add a b)) }
          | _ -> c)
    ]} *)
let rec transform_bottom_up (f : core -> core) (e : core) : core =
  let e' = map_children (transform_bottom_up f) e in
  f e'

(** [fold_tree f init e] folds [f] over every node in [e]'s subtree,
    top-down. Visits the root first, then recursively visits every
    descendant. Prefer this over hand-rolling a full-variant recursion
    when a pass needs to {b collect} information from the tree (counts,
    names, references) without rewriting it.

    Unlike [fold_immediate_children], which only visits one level deep,
    [fold_tree] walks the entire subtree. Use [fold_immediate_children]
    when a single level is enough (cheap shallow predicates);
    [fold_tree] for anything that cares about descendants.

    For rewriting (not collecting), use [transform_bottom_up] or
    [transform_with_env]. For short-circuiting predicate searches where
    "any node matches?" is the question, use [exists_tree] — it stops
    walking as soon as the predicate returns [true].

    {b Caveats}:
    - Sibling visit order between an expression's immediate children is
      unspecified (inherits OCaml's tuple-evaluation order). Callers
      relying on a specific order should sort results or walk manually.
    - Decision-tree accessor sub-expressions in [CMatch]
      ([cts_scrut], [ctl_scrut], [ctl_len_scrut]) are NOT visited —
      only leaf bodies are. This matches [map_children]'s semantics.
      A pass that needs to inspect post-match accessors must walk the
      [ctree] explicitly.

    Example (collect every literal integer):
    {[
      let all_int_literals e =
        fold_tree (fun acc c -> match c.desc with
          | CLit (LitInt n) -> n :: acc
          | _ -> acc) [] e
    ]} *)
let rec fold_tree (f : 'a -> core -> 'a) (init : 'a) (e : core) : 'a =
  let acc = f init e in
  fold_immediate_children (fold_tree f) acc e

(** [fold_tree_bottom_up f init e] is the bottom-up counterpart of
    [fold_tree]: visits descendants first, then the root. Use for
    reductions where a node's contribution depends on its children's
    accumulated result (e.g. "deepest literal") or where order-sensitive
    last-write-wins semantics is needed. *)
let rec fold_tree_bottom_up (f : 'a -> core -> 'a) (init : 'a) (e : core) : 'a =
  let acc = fold_immediate_children (fold_tree_bottom_up f) init e in
  f acc e

(** [exists_tree pred e] returns [true] as soon as [pred] holds for any
    node in [e]'s subtree. Short-circuits — does not visit nodes past
    the first match. Use for "does this tree contain …" predicates;
    a fold-based `acc || pred c` walks every node and is O(n) even
    after [acc] becomes [true]. *)
let rec exists_tree (pred : core -> bool) (e : core) : bool =
  pred e
  || begin
    let found = ref false in
    let _ =
      map_children
        (fun c ->
          if (not !found) && exists_tree pred c then found := true;
          c)
        e
    in
    !found
  end

(** [transform_with_env f env0 e] is the scope-aware analogue of
    [transform_bottom_up]. The callback receives the current [env] and
    returns a pair of [(rewritten_node, env_for_children)]. Each child
    gets the env its direct parent's call returned. Siblings receive
    the {b same} env from the parent — env changes don't cross between
    branches, so an [if] or [CBin]'s two sides stay independent.

    The traversal is top-down: [f] runs on a node {b before} its
    children. To rewrite bottom-up, apply [f] to the post-recursion
    result manually inside the callback.

    {b Pitfall for binding-aware passes}: non-recursive [CLet]'s bound
    name is in scope {b only in the body}, not in the RHS. But
    [transform_with_env] applies [env'] uniformly to every child via
    [map_children], so a caller that extends the env on [CLet] will
    see the rhs with the bound name in scope too — wrong for
    non-recursive lets. Same pitfall for [CFor] iterators (the var is
    not in scope in the iterator, only in the body). Passes that
    care about these boundaries must either hand-roll recursion for
    binding forms, or split the transform so the rhs/iterator and
    body get different envs.

    Example (simple depth counter — safe because depth applies
    uniformly):
    {[
      let scope_depth e =
        transform_with_env (fun depth c ->
          match c.desc with
          | CLet _ -> (c, depth + 1)
          | _     -> (c, depth)
        ) 0 e
    ]} *)
let rec transform_with_env (f : 'env -> core -> core * 'env) (env : 'env)
    (e : core) : core =
  let e', env' = f env e in
  map_children (transform_with_env f env') e'

(* ============================================================================
   Pretty-printer
   ============================================================================ *)

let binop_str = function
  | Ast.Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Lt -> "<"
  | Gt -> ">"
  | Le -> "<="
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="

let unop_str = function Ast.Neg -> "-" | Not -> "not "
let logop_str = function Ast.And -> "and" | Or -> "or"

let handoff_mode_str = function
  | BorrowFresh -> "borrow-fresh"
  | ConsumeReuse -> "consume-reuse"

let handoff_write_order_str = function
  | ForwardCompacting -> "forward-compacting"

let inline_storage_width_str width =
  string_of_int (inline_storage_width_bytes width)

let list_storage_layout_str layout =
  match layout.lsl_slots with
  | ListPointerStorage -> "ptr"
  | ListInlineStorage width ->
      Printf.sprintf "inline:%s" (inline_storage_width_str width)
  | ListInlineStructStorage c_type -> Printf.sprintf "inline-struct:%s" c_type

let tensor_unboxed_scalar_str = function
  | TensorFloat64Elements -> "float64"
  | TensorFloat32Elements -> "float32"
  | TensorInt64Elements -> "int64"

let tensor_packed_width_str width =
  Printf.sprintf "packed:%d" (inline_storage_width_bytes width)

let tensor_storage_slot_layout_str = function
  | TensorRawScalarStorage scalar ->
      Printf.sprintf "raw scalar %s" (tensor_unboxed_scalar_str scalar)
  | TensorWordStorage -> "word"
  | TensorPackedStorage width ->
      Printf.sprintf "packed %s-byte" (inline_storage_width_str width)
  | TensorInlineStructStorage c_type -> Printf.sprintf "inline struct %s" c_type
  | TensorBoxedStorage -> "boxed"

let tensor_storage_provenance_kind_str = function
  | TensorStorageKnownProducer -> "known-producer"
  | TensorStoragePreservedProducer -> "preserved"
  | TensorStorageValidatedBoundary -> "validated-boundary"

let tensor_storage_provenance_str = function
  | TensorStorageUnknown reason -> Printf.sprintf "unknown:%s" reason
  | TensorStorageProven { tsp_kind; tsp_layout } ->
      Printf.sprintf "%s:%s"
        (tensor_storage_provenance_kind_str tsp_kind)
        (tensor_storage_slot_layout_str tsp_layout.tsl_slots)

let tensor_literal_payload_slot_layout = function
  | TensorRawElements (scalar, _) -> TensorRawScalarStorage scalar
  | TensorWordElements _ -> TensorWordStorage
  | TensorPackedElements (width, _) -> TensorPackedStorage width
  | TensorInlineStructElements (c_type, _) -> TensorInlineStructStorage c_type
  | TensorBoxedElements _ -> TensorBoxedStorage

let tensor_literal_layout_matches_payload layout payload =
  match (layout.tsl_slots, tensor_literal_payload_slot_layout payload) with
  | TensorRawScalarStorage expected, TensorRawScalarStorage actual ->
      expected = actual
  | TensorWordStorage, TensorWordStorage -> true
  | TensorPackedStorage expected, TensorPackedStorage actual ->
      expected = actual
  | TensorInlineStructStorage expected, TensorInlineStructStorage actual ->
      String.equal expected actual
  | TensorBoxedStorage, TensorBoxedStorage -> true
  | _ -> false

let list_access_bounds_str = function
  | ListBoundsChecked -> "checked"
  | ListBoundsProven -> "proven"

let box_kind_str = function
  | BoxFloat -> "float"
  | BoxFloat32 -> "float32"
  | BoxFloat16 -> "float16"
  | BoxInt128 -> "int128"
  | BoxUInt128 -> "uint128"
  | BoxVoid -> "void"
  | BoxPointer -> "pointer"
  | BoxPrim -> "prim"
  | BoxStruct name -> Printf.sprintf "struct:%s" name

let unbox_kind_str = function
  | UnboxFloat -> "float"
  | UnboxFloat32 -> "float32"
  | UnboxFloat16 -> "float16"
  | UnboxInt128 -> "int128"
  | UnboxUInt128 -> "uint128"
  | UnboxPointer -> "pointer"
  | UnboxPrim -> "prim"
  | UnboxStruct name -> Printf.sprintf "struct:%s" name

let option_scalar_payload_str payload =
  let open Core_option_layout in
  match payload with
  | ScalarVoid -> "void"
  | ScalarInt -> "int"
  | ScalarSizedInt name -> String.lowercase_ascii name
  | ScalarInt128 -> "int128"
  | ScalarUInt128 -> "uint128"
  | ScalarFloat -> "float"
  | ScalarFloat32 -> "float32"
  | ScalarFloat16 -> "float16"
  | ScalarBool -> "bool"
  | ScalarChar -> "char"
  | ScalarEnum name -> Printf.sprintf "enum:%s" name
  | ScalarRange -> "range"

let option_layout_str layout =
  let open Core_option_layout in
  match layout with
  | StackScalar scalar ->
      Printf.sprintf "stack-scalar:%s" (option_scalar_payload_str scalar)
  | StackValueRecord name -> Printf.sprintf "stack-record:%s" name
  | NullableManagedPointer -> "nullable-managed-pointer"
  | BoxedUnion GenericPayload -> "boxed:generic"
  | BoxedUnion NullableUnsafePayload -> "boxed:nullable-unsafe"
  | BoxedUnion NestedOptionPayload -> "boxed:nested-option"
  | BoxedUnion NestedResultPayload -> "boxed:nested-result"
  | BoxedUnion (UnsupportedPayload ty) -> Printf.sprintf "boxed:%s" ty

let union_representation_str = function
  | GenericUnion -> "generic"
  | OptionUnion layout -> Printf.sprintf "option:%s" (option_layout_str layout)
  | ResultUnion Core_result_layout.StackErased -> "result:stack-erased"
  | ResultUnion Core_result_layout.StackManaged -> "result:stack-managed"

let dict_constructor_str = function
  | DictGeneric -> "generic"
  | DictString -> "string"
  | DictFloat -> "float"
  | DictCustom ty -> Printf.sprintf "custom:%s" (Types.type_to_string ty)

let set_constructor_str = function
  | SetGeneric -> "generic"
  | SetString -> "string"
  | SetFloat -> "float"
  | SetCustom ty -> Printf.sprintf "custom:%s" (Types.type_to_string ty)

let lit_str = function
  | Ast.LitInt n -> Int64.to_string n
  | LitInt128 n -> n
  | LitFloat f -> string_of_float f
  | LitString (s, _) -> Printf.sprintf "\"%s\"" s
  | LitBool true -> "true"
  | LitBool false -> "false"
  | LitChar c -> Printf.sprintf "'%s'" (String.make 1 (Char.chr (c land 0xff)))

(** Render a type expression compactly. Not round-trippable — debug only. *)
let rec ty_str (ty : Ast.type_expr) : string =
  match ty with
  | TyNamed (n, []) -> n
  | TyNamed (n, args) ->
      Printf.sprintf "%s[%s]" n (String.concat ", " (List.map ty_str args))
  | TyArray (elem, dims) ->
      Printf.sprintf "%s[%s]" (ty_str elem)
        (String.concat ", " (List.map ty_str dims))
  | TyFunc { params; return; _ } ->
      Printf.sprintf "(%s) -> %s"
        (String.concat ", " (List.map ty_str params))
        (ty_str return)
  | TyVar n -> n
  | TyBoundVar p -> Ast.type_param_to_parser_string p
  | TyConstInt n -> "#" ^ string_of_int n
  | TyTuple ts ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map ty_str ts))
  | TySelf -> "Self"
  | TyVarDims n -> "#" ^ n ^ "..."
  | TyRange t -> Printf.sprintf "..%s" (ty_str t)
  | TyDimOp (_, a, b) -> Printf.sprintf "(%s OP %s)" (ty_str a) (ty_str b)
  | TyMeta n -> Printf.sprintf "?m%d" n

(** Render a pattern. Match the AST formatter's output where reasonable. *)
let rec pat_str (p : Ast.pattern) : string =
  match p with
  | PatWildcard -> "_"
  | PatVar n -> n
  | PatLiteral l -> lit_str l
  | PatConstructor (n, []) -> n
  | PatConstructor (n, args) ->
      Printf.sprintf "%s(%s)" n (String.concat ", " (List.map pat_str args))
  | PatQualified (m, n, []) -> Printf.sprintf "%s.%s" m n
  | PatQualified (m, n, args) ->
      Printf.sprintf "%s.%s(%s)" m n
        (String.concat ", " (List.map pat_str args))
  | PatTuple ps ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map pat_str ps))
  | PatList (ps, None) ->
      Printf.sprintf "[%s]" (String.concat ", " (List.map pat_str ps))
  | PatList (ps, Some spread) ->
      Printf.sprintf "[%s, ...%s]"
        (String.concat ", " (List.map pat_str ps))
        (pat_str spread)
  | PatOr ps -> String.concat " | " (List.map pat_str ps)

(** Collect variable names bound by a pattern. *)
let rec pat_vars : Ast.pattern -> string list = function
  | Ast.PatWildcard | Ast.PatLiteral _ -> []
  | Ast.PatVar n -> [ n ]
  | Ast.PatConstructor (_, ps)
  | Ast.PatQualified (_, _, ps)
  | Ast.PatTuple ps
  | Ast.PatOr ps ->
      List.concat_map pat_vars ps
  | Ast.PatList (ps, spread) -> (
      List.concat_map pat_vars ps
      @ match spread with Some p -> pat_vars p | None -> [])

(** Convert a Core expression to a string. Intentionally flat (no
    linebreaks) for test predictability. A structured pretty-printer
    with indentation is a later enhancement. *)
let rec pp_to_string (e : core) : string =
  match e.desc with
  | CLit l -> lit_str l
  | CVar v -> Var.to_string v
  | CVoid -> "void"
  | CTuple xs -> Printf.sprintf "(%s)" (pp_list xs)
  | CList lit -> Printf.sprintf "[%s]" (pp_list lit.ll_elems)
  | CListAlloc alloc ->
      Printf.sprintf "list-alloc[%s](%s)"
        (list_storage_layout_str alloc.la_layout)
        (pp_to_string alloc.la_capacity)
  | CListGet get ->
      Printf.sprintf "list-get[%s,%s](%s, %s)"
        (list_storage_layout_str get.lg_layout)
        (list_access_bounds_str get.lg_bounds)
        (pp_to_string get.lg_list)
        (pp_to_string get.lg_index)
  | CStringByteRead r ->
      Printf.sprintf "string-byte-read[proven](%s, %s)"
        (pp_to_string r.sbr_source)
        (pp_to_string r.sbr_index)
  | CStringByteWrite w ->
      Printf.sprintf "string-byte-write[proven](%s, %s, %s)"
        (pp_to_string w.sbw_target)
        (pp_to_string w.sbw_index) (pp_to_string w.sbw_byte)
  | CStringByteCopy c ->
      Printf.sprintf "string-byte-copy[proven](%s, %s, %s, %s, %s)"
        (pp_to_string c.sbc_dst)
        (pp_to_string c.sbc_dst_pos)
        (pp_to_string c.sbc_src)
        (pp_to_string c.sbc_src_pos)
        (pp_to_string c.sbc_len)
  | CStringSetLen s ->
      Printf.sprintf "string-set-len[proven](%s, %s)"
        (pp_to_string s.ssl_target)
        (pp_to_string s.ssl_len)
  | CTupleConstruct tc ->
      Printf.sprintf "tuple-construct[%d,%d](%s)" tc.tc_release_mask
        tc.tc_retain_mask
        (String.concat ", " (List.map pp_boxed_storage tc.tc_elems))
  | CListConstruct lc ->
      Printf.sprintf "list-construct[%s,%b](%s)"
        (list_storage_layout_str lc.lc_layout)
        lc.lc_elem_needs_release
        (String.concat ", " (List.map pp_boxed_storage lc.lc_elems))
  | CVector xs -> Printf.sprintf "vec[%s]" (pp_list xs)
  | CTensorLiteral tl ->
      let layout, elems =
        match tl.tl_payload with
        | TensorRawElements (scalar, elems) ->
            (tensor_unboxed_scalar_str scalar, List.map pp_to_string elems)
        | TensorWordElements elems -> ("word", List.map pp_to_string elems)
        | TensorPackedElements (width, elems) ->
            (tensor_packed_width_str width, List.map pp_to_string elems)
        | TensorInlineStructElements (c_ty, elems) ->
            ("inline-struct:" ^ c_ty, List.map pp_to_string elems)
        | TensorBoxedElements elems -> ("boxed", List.map pp_boxed_storage elems)
      in
      Printf.sprintf "tensor-literal[%s/%s](%s)"
        (tensor_storage_slot_layout_str tl.tl_layout.tsl_slots)
        layout (String.concat ", " elems)
  | CDict kvs ->
      let parts =
        List.map
          (fun (k, v) ->
            Printf.sprintf "%s => %s" (pp_to_string k) (pp_to_string v))
          kvs
      in
      Printf.sprintf "{%s}" (String.concat ", " parts)
  | CDictConstruct dc ->
      Printf.sprintf "dict-construct[%s,%b](%d)"
        (dict_constructor_str dc.dc_constructor)
        dc.dc_value_needs_release
        (List.length dc.dc_entries)
  | CSetAlloc sa ->
      Printf.sprintf "set-alloc[%s]" (set_constructor_str sa.sa_constructor)
  | CRecord fs ->
      let parts =
        List.map (fun (n, v) -> Printf.sprintf "%s = %s" n (pp_to_string v)) fs
      in
      Printf.sprintf "{%s}" (String.concat ", " parts)
  | CRecordConstruct rc ->
      let parts =
        List.map
          (function
            | RecordRawField (name, value) ->
                Printf.sprintf "%s = %s" name (pp_to_string value)
            | RecordErasedField (name, value) ->
                Printf.sprintf "%s = erased(%s)" name (pp_boxed_storage value))
          rc.rc_fields
      in
      Printf.sprintf "%s_make(%s)" rc.rc_type_name (String.concat ", " parts)
  | CRecordUpdate (base, fs) ->
      let parts =
        List.map (fun (n, v) -> Printf.sprintf "%s = %s" n (pp_to_string v)) fs
      in
      Printf.sprintf "{%s | %s}" (pp_to_string base) (String.concat ", " parts)
  | CRange (a, b) -> Printf.sprintf "%s..%s" (pp_to_string a) (pp_to_string b)
  | CLambda lam ->
      let params =
        String.concat ", "
          (List.map
             (fun (v, t) ->
               Printf.sprintf "%s: %s" (Var.to_string v) (ty_str t))
             lam.lam_params)
      in
      Printf.sprintf "fun(%s) -> %s { %s }" params (ty_str lam.lam_return_ty)
        (pp_to_string lam.lam_body)
  | CClosureCreate cc ->
      let caps = String.concat ", " (List.map fst cc.cc_captures) in
      Printf.sprintf "closure(%s, [%s])" cc.cc_func caps
  | CBin (op, l, r) ->
      Printf.sprintf "(%s %s %s)" (pp_to_string l) (binop_str op)
        (pp_to_string r)
  | CUn (op, x) -> Printf.sprintf "(%s%s)" (unop_str op) (pp_to_string x)
  | CLog (op, l, r) ->
      Printf.sprintf "(%s %s %s)" (pp_to_string l) (logop_str op)
        (pp_to_string r)
  | CCall (kind, fn, args) ->
      let tag =
        match kind with
        | CKUnknown -> ""
        | CKSelectedDirect id -> Printf.sprintf "<selected:#%d>" id
        | CKUser (n, Some id) -> Printf.sprintf "<user:%s#%d>" n id
        | CKUser (n, None) -> Printf.sprintf "<user:%s>" n
        | CKForeign { fc_c_name; _ } -> Printf.sprintf "<foreign:%s>" fc_c_name
        | CKBuiltin n -> Printf.sprintf "<builtin:%s>" n
        | CKIntrinsic n -> Printf.sprintf "<intrinsic:%s>" n
        | CKClosure -> "<closure>"
      in
      Printf.sprintf "%s%s(%s)" tag (pp_to_string fn) (pp_list args)
  | CTensorRawRead r ->
      Printf.sprintf "tensor-raw-read[%s](%s, %s)"
        (tensor_unboxed_scalar_str r.trr_kind)
        (Var.to_string r.trr_view) (pp_to_string r.trr_index)
  | CTensorRawWrite w ->
      Printf.sprintf "tensor-raw-write[%s](%s, %s, %s)"
        (tensor_unboxed_scalar_str w.trw_kind)
        (Var.to_string w.trw_view) (pp_to_string w.trw_index)
        (pp_to_string w.trw_value)
  | CField (e', name) -> Printf.sprintf "%s.%s" (pp_to_string e') name
  | CStringInterp (parts, _) ->
      let rendered =
        List.map
          (function
            | IPLit s -> s
            | IPExpr e' -> Printf.sprintf "${%s}" (pp_to_string e'))
          parts
      in
      Printf.sprintf "f\"%s\"" (String.concat "" rendered)
  | CLet (b, body) ->
      let kw = if b.bind_mut then "var" else "let" in
      Printf.sprintf "%s %s: %s = %s in %s" kw (Var.to_string b.bind_var)
        (ty_str b.bind_ty) (pp_to_string b.bind_rhs) (pp_to_string body)
  | CBorrowLet (b, body) ->
      Printf.sprintf "borrow %s: %s = %s in %s"
        (Var.to_string b.borrow_var)
        (ty_str b.borrow_ty)
        (pp_to_string b.borrow_rhs)
        (pp_to_string body)
  | CTensorRawViewLet (b, body) ->
      Printf.sprintf "tensor-raw-view %s[%s] = %s in %s"
        (Var.to_string b.trv_var)
        (tensor_unboxed_scalar_str b.trv_kind)
        (pp_to_string b.trv_source)
        (pp_to_string body)
  | CResourceScope s ->
      Printf.sprintf "resource %s: %s = %s in %s cleanup %s"
        (Var.to_string s.rs_var) (ty_str s.rs_ty)
        (pp_to_string s.rs_acquire)
        (pp_to_string s.rs_body)
        (pp_to_string s.rs_cleanup)
  | CResourceCleanupExit exit ->
      let exit_s =
        match exit.rce_exit with
        | ResourceBreak -> "break"
        | ResourceContinue -> "continue"
      in
      Printf.sprintf "resource-cleanup-exit[%s] %s" exit_s
        (String.concat "; " (List.map pp_to_string exit.rce_cleanups))
  | CSeq (a, b) -> Printf.sprintf "%s; %s" (pp_to_string a) (pp_to_string b)
  | CDebugBlock body -> Printf.sprintf "debug { %s }" (pp_to_string body)
  | CIf (c, t, el) ->
      Printf.sprintf "if %s then %s else %s" (pp_to_string c) (pp_to_string t)
        (pp_to_string el)
  | CMatchArms (scrut, arms) ->
      let arm_strs =
        List.map
          (fun (p, body) ->
            Printf.sprintf "%s -> %s" (pat_str p) (pp_to_string body))
          arms
      in
      Printf.sprintf "match-arms %s { %s }" (pp_to_string scrut)
        (String.concat " | " arm_strs)
  | CMatch (scrut, tree) ->
      Printf.sprintf "match %s { %s }" (pp_to_string scrut) (pp_ctree tree)
  | CWhile (c, b) ->
      Printf.sprintf "while %s { %s }" (pp_to_string c) (pp_to_string b)
  | CFor (binder, iter, b) ->
      let storage =
        match binder.loop_source_storage with
        | TensorStorageUnknown _ -> ""
        | proof ->
            Printf.sprintf " [storage=%s]" (tensor_storage_provenance_str proof)
      in
      Printf.sprintf "for %s%s in %s { %s }"
        (Var.to_string binder.loop_var)
        storage (pp_to_string iter) (pp_to_string b)
  | CBreak -> "break"
  | CContinue -> "continue"
  | CAssign (v, rhs) ->
      Printf.sprintf "%s := %s" (Var.to_string v) (pp_to_string rhs)
  | CTailrecLoop loop -> (
      match loop with
      | TailrecUnmanagedLoop l ->
          Printf.sprintf "tailrec-loop[unmanaged](%s) { %s }"
            (String.concat ", "
               (List.map (fun p -> Var.to_string p.cp_name) l.tul_params))
            (pp_to_string l.tul_body)
      | TailrecListSpreadLoop l ->
          Printf.sprintf "tailrec-loop[list:%s@%d,cursor=%s](%s) { %s }"
            (Var.to_string l.tls_list_param.cp_name)
            l.tls_list_index
            (Var.to_string l.tls_cursor_var)
            (String.concat ", "
               (List.map (fun p -> Var.to_string p.cp_name) l.tls_params))
            (pp_to_string l.tls_body))
  | CTailrecRecur recur -> (
      match recur with
      | TailrecRecur r -> Printf.sprintf "tailrec-recur(%s)" (pp_list r.tr_args)
      | TailrecListSpreadRecur r ->
          let rebinds =
            List.map
              (fun (i, arg) -> Printf.sprintf "%d=%s" i (pp_to_string arg))
              r.tr_rebinds
          in
          Printf.sprintf "tailrec-recur-list[+%d](%s)" r.tr_cursor_advance
            (String.concat ", " rebinds))
  | CDup (v, _, body) ->
      Printf.sprintf "dup %s; %s" (Var.to_string v) (pp_to_string body)
  | CDrop (v, _, body) ->
      Printf.sprintf "drop %s; %s" (Var.to_string v) (pp_to_string body)
  | CConcurrent blk ->
      let bind_strs =
        List.map
          (fun b ->
            Printf.sprintf "%s: %s = %s" (Var.to_string b.cb_var)
              (Types.type_to_string b.cb_ty)
              (pp_to_string b.cb_rhs))
          blk.conc_bindings
      in
      Printf.sprintf "concurrent { %s; %s }"
        (String.concat "; " bind_strs)
        (pp_to_string blk.conc_body)
  | CConcurrentlyLoop cf ->
      let output =
        match cf.cf_output with
        | ConcurrentlyLoopCollect -> "collect"
        | ConcurrentlyLoopDiscard -> "discard"
      in
      Printf.sprintf "for ... concurrently[%s] %s in %s { %s }" output
        (Var.to_string cf.cf_var) (pp_to_string cf.cf_iter)
        (pp_to_string cf.cf_body)
  | CDetach d -> Printf.sprintf "detach %s" (pp_to_string d.detach_body)
  | CSelect select ->
      let arm_to_string arm =
        let head =
          match arm.select_arm_kind with
          | SelectRecv r ->
              Printf.sprintf "%s from %s"
                (Var.to_string r.select_bind)
                (pp_to_string r.select_channel)
          | SelectSealed channel ->
              Printf.sprintf "sealed %s" (pp_to_string channel)
          | SelectAfter timeout ->
              Printf.sprintf "_ after %s" (pp_to_string timeout)
        in
        Printf.sprintf "%s { %s }" head (pp_to_string arm.select_arm_body)
      in
      Printf.sprintf "select { %s }"
        (String.concat "; " (List.map arm_to_string select.select_arms))
  | CCast (x, ty) ->
      Printf.sprintf "cast<%s>(%s)" (Types.type_to_string ty) (pp_to_string x)
  | CUnbox (x, ty) ->
      Printf.sprintf "unbox<%s>(%s)" (Types.type_to_string ty) (pp_to_string x)
  | CUnboxTyped u ->
      Printf.sprintf "unbox[%s]<%s>(%s)"
        (unbox_kind_str u.unbox_kind)
        (Types.type_to_string u.unbox_target_ty)
        (pp_to_string u.unbox_value)
  | CBox (x, ty) ->
      Printf.sprintf "box<%s>(%s)" (Types.type_to_string ty) (pp_to_string x)
  | CBoxTyped b ->
      Printf.sprintf "box[%s]<%s>(%s)" (box_kind_str b.box_kind)
        (Types.type_to_string b.box_source_ty)
        (pp_to_string b.box_value)
  | CUnionConstruct uc ->
      Printf.sprintf "%s[%s,tag=%d,%s](%s, mask=%d)" uc.uc_c_name
        uc.uc_type_name uc.uc_tag
        (union_representation_str uc.uc_representation)
        (String.concat ", " (List.map pp_boxed_storage uc.uc_args))
        uc.uc_release_mask
  | CListHandoff h ->
      Printf.sprintf
        "list-handoff[%s,%s,%s](%s as %s, cap=%s, len=%s, out=%s, result=%s) { \
         %s }"
        (handoff_mode_str h.lh_mode)
        (list_storage_layout_str h.lh_layout)
        (handoff_write_order_str h.lh_write_order)
        (pp_to_string h.lh_source)
        (Var.to_string h.lh_source_var)
        (pp_to_string h.lh_capacity)
        (Var.to_string h.lh_len_var)
        (Var.to_string h.lh_out_var)
        (Var.to_string h.lh_result_var)
        (pp_to_string h.lh_body)

and pp_list xs = String.concat ", " (List.map pp_to_string xs)

and pp_boxed_storage (v : boxed_storage_value) =
  Printf.sprintf "%s:%s"
    (pp_to_string v.bsv_box.box_value)
    (box_kind_str v.bsv_box.box_kind)

and pp_accessor = function
  | AccRoot -> "$"
  | AccVariantField (a, ctor, i) ->
      Printf.sprintf "%s.%s.%d" (pp_accessor a) ctor i
  | AccTupleField (a, i) -> Printf.sprintf "%s.%d" (pp_accessor a) i
  | AccListElem (a, i) -> Printf.sprintf "%s[%d]" (pp_accessor a) i
  | AccListSpread (a, i) -> Printf.sprintf "%s[%d..]" (pp_accessor a) i

and pp_ctree = function
  | CTLeaf { ct_bindings; ct_body } ->
      let binds =
        List.map
          (fun (v, a) ->
            Printf.sprintf "%s=%s" (Var.to_string v) (pp_accessor a))
          ct_bindings
      in
      let bind_str =
        if binds = [] then ""
        else Printf.sprintf "let %s in " (String.concat ", " binds)
      in
      Printf.sprintf "%s%s" bind_str (pp_to_string ct_body)
  | CTFail -> "fail"
  | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
      let cases =
        List.map
          (fun (ctor, sub) -> Printf.sprintf "%s -> %s" ctor (pp_ctree sub))
          cts_cases
      in
      let default =
        match cts_default with
        | Some d -> Printf.sprintf " | _ -> %s" (pp_ctree d)
        | None -> ""
      in
      Printf.sprintf "switch-tag %s { %s%s }" (pp_accessor cts_scrut)
        (String.concat " | " cases)
        default
  | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
      let cases =
        List.map
          (fun (lit, sub) ->
            Printf.sprintf "%s -> %s" (lit_str lit) (pp_ctree sub))
          ctl_cases
      in
      Printf.sprintf "switch-lit %s { %s | _ -> %s }" (pp_accessor ctl_scrut)
        (String.concat " | " cases)
        (pp_ctree ctl_default)
  | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
    ->
      let cases =
        List.map
          (fun (n, sub) -> Printf.sprintf "=%d -> %s" n (pp_ctree sub))
          ctl_len_cases
      in
      let geq =
        match ctl_len_geq with
        | Some (n, sub) -> Printf.sprintf " | >=%d -> %s" n (pp_ctree sub)
        | None -> ""
      in
      let default =
        match ctl_len_default with
        | Some d -> Printf.sprintf " | _ -> %s" (pp_ctree d)
        | None -> ""
      in
      Printf.sprintf "switch-len %s { %s%s%s }"
        (pp_accessor ctl_len_scrut)
        (String.concat " | " cases)
        geq default

(* ============================================================================
   Indented pretty-printer
   ============================================================================ *)

(** [pp_to_string_indented ?indent e] produces a multi-line string
    representation of a Core expression with 2-space indentation.

    Unlike the flat [pp_to_string] (which is used in byte-exact tests),
    this variant inserts newlines and indentation at the structural
    boundaries that matter for debugging:

    - [CLet] / [CSeq] — each binding or sequence step on its own line
    - [CIf] — then/else branches indented on separate lines
    - [CMatchArms] / [CMatch] — each arm on its own line

    Everything else (binary ops, calls, data literals) stays inline
    via [pp_to_string]. This keeps the output compact while still
    revealing the tree structure of large function bodies.

    Use [--dump-core] in the CLI and the diff-friendly output in
    Phase 2 before/after tests. *)
let pp_to_string_indented (e : core) : string =
  let pad n = String.make (n * 2) ' ' in
  let rec go i e =
    let p = pad i in
    match e.desc with
    (* Leaves and simple expressions: one line, flat *)
    | CLit _ | CVar _ | CVoid | CBreak | CContinue | CBin _ | CUn _ | CLog _
    | CCall _ | CTensorRawRead _ | CTensorRawWrite _ | CField _ | CTuple _
    | CList _ | CListAlloc _ | CListGet _ | CTupleConstruct _ | CListConstruct _
    | CStringByteRead _ | CStringByteWrite _ | CStringByteCopy _
    | CStringSetLen _ | CVector _ | CTensorLiteral _ | CDict _
    | CDictConstruct _ | CSetAlloc _ | CRecord _ | CRecordConstruct _
    | CRecordUpdate _ | CRange _ | CStringInterp _ | CAssign _ | CConcurrent _
    | CConcurrentlyLoop _ | CDetach _ | CSelect _ | CCast _ | CUnbox _
    | CUnboxTyped _ | CBox _ | CBoxTyped _ | CUnionConstruct _
    | CResourceCleanupExit _ | CTailrecRecur _ ->
        p ^ pp_to_string e
    | CTailrecLoop (TailrecUnmanagedLoop l) ->
        Printf.sprintf "%stailrec-loop[unmanaged] {\n%s\n%s}" p
          (go (i + 1) l.tul_body)
          p
    | CTailrecLoop (TailrecListSpreadLoop l) ->
        Printf.sprintf "%stailrec-loop[list:%s@%d,cursor=%s] {\n%s\n%s}" p
          (Var.to_string l.tls_list_param.cp_name)
          l.tls_list_index
          (Var.to_string l.tls_cursor_var)
          (go (i + 1) l.tls_body)
          p
    | CListHandoff h ->
        Printf.sprintf
          "%slist-handoff[%s,%s,%s] %s as %s cap=%s len=%s out=%s result=%s {\n\
           %s\n\
           %s}"
          p
          (handoff_mode_str h.lh_mode)
          (list_storage_layout_str h.lh_layout)
          (handoff_write_order_str h.lh_write_order)
          (pp_to_string h.lh_source)
          (Var.to_string h.lh_source_var)
          (pp_to_string h.lh_capacity)
          (Var.to_string h.lh_len_var)
          (Var.to_string h.lh_out_var)
          (Var.to_string h.lh_result_var)
          (go (i + 1) h.lh_body)
          p
    (* RC ops: each on its own line, then the wrapped body *)
    | CDup (v, _, body) ->
        Printf.sprintf "%sdup %s;\n%s" p (Var.to_string v) (go i body)
    | CDrop (v, _, body) ->
        Printf.sprintf "%sdrop %s;\n%s" p (Var.to_string v) (go i body)
    (* Let: put rhs inline, body on next line at same indent *)
    | CLet (b, body) ->
        let kw = if b.bind_mut then "var" else "let" in
        Printf.sprintf "%s%s %s: %s = %s in\n%s" p kw (Var.to_string b.bind_var)
          (ty_str b.bind_ty) (pp_to_string b.bind_rhs) (go i body)
    | CBorrowLet (b, body) ->
        Printf.sprintf "%sborrow %s: %s = %s in\n%s" p
          (Var.to_string b.borrow_var)
          (ty_str b.borrow_ty)
          (pp_to_string b.borrow_rhs)
          (go i body)
    | CTensorRawViewLet (b, body) ->
        Printf.sprintf "%stensor-raw-view %s[%s] = %s in\n%s" p
          (Var.to_string b.trv_var)
          (tensor_unboxed_scalar_str b.trv_kind)
          (pp_to_string b.trv_source)
          (go i body)
    | CResourceScope s ->
        Printf.sprintf "%sresource %s: %s = %s in\n%s\n%scleanup\n%s" p
          (Var.to_string s.rs_var) (ty_str s.rs_ty)
          (pp_to_string s.rs_acquire)
          (go i s.rs_body) p
          (go (i + 1) s.rs_cleanup)
    (* Seq: both on separate lines *)
    | CSeq (a, b) -> Printf.sprintf "%s\n%s" (go i a) (go i b)
    | CDebugBlock body ->
        Printf.sprintf "%sdebug {\n%s\n%s}" p (go (i + 1) body) p
    (* If: condition inline, branches on new lines *)
    | CIf (cond, then_e, else_e) ->
        Printf.sprintf "%sif %s then\n%s\n%selse\n%s" p (pp_to_string cond)
          (go (i + 1) then_e)
          p
          (go (i + 1) else_e)
    (* Match: scrutinee inline, each arm on its own line *)
    | CMatchArms (scrut, arms) ->
        let arm_strs =
          List.map
            (fun (pat, body) ->
              Printf.sprintf "%s%s ->\n%s"
                (pad (i + 1))
                (pat_str pat)
                (go (i + 2) body))
            arms
        in
        Printf.sprintf "%smatch-arms %s {\n%s\n%s}" p (pp_to_string scrut)
          (String.concat "\n" arm_strs)
          p
    | CMatch (scrut, tree) ->
        Printf.sprintf "%smatch %s {\n%s\n%s}" p (pp_to_string scrut)
          (pp_ctree_indented (i + 1) tree)
          p
    (* While / for keep structural — header inline, body indented *)
    | CWhile (cond, body) ->
        Printf.sprintf "%swhile %s {\n%s\n%s}" p (pp_to_string cond)
          (go (i + 1) body)
          p
    | CFor (binder, iter, body) ->
        let storage =
          match binder.loop_source_storage with
          | TensorStorageUnknown _ -> ""
          | proof ->
              Printf.sprintf " [storage=%s]"
                (tensor_storage_provenance_str proof)
        in
        Printf.sprintf "%sfor %s%s in %s {\n%s\n%s}" p
          (Var.to_string binder.loop_var)
          storage (pp_to_string iter)
          (go (i + 1) body)
          p
    (* Lambda: params on header, body indented *)
    | CLambda lam ->
        let params =
          String.concat ", "
            (List.map
               (fun (v, t) ->
                 Printf.sprintf "%s: %s" (Var.to_string v) (ty_str t))
               lam.lam_params)
        in
        Printf.sprintf "%sfun(%s) -> %s {\n%s\n%s}" p params
          (ty_str lam.lam_return_ty)
          (go (i + 1) lam.lam_body)
          p
    | CClosureCreate cc ->
        let caps = String.concat ", " (List.map fst cc.cc_captures) in
        Printf.sprintf "%sclosure(%s, [%s])" p cc.cc_func caps
  and pp_ctree_indented i tree =
    let p = pad i in
    match tree with
    | CTLeaf { ct_bindings; ct_body } ->
        let binds =
          List.map
            (fun (v, a) ->
              Printf.sprintf "%s=%s" (Var.to_string v) (pp_accessor a))
            ct_bindings
        in
        let bind_str =
          if binds = [] then ""
          else Printf.sprintf "let %s in " (String.concat ", " binds)
        in
        Printf.sprintf "%s%s%s" p bind_str (pp_to_string ct_body)
    | CTFail -> p ^ "fail"
    | CTSwitchTag { cts_scrut; cts_cases; cts_default } ->
        let case_strs =
          List.map
            (fun (ctor, sub) ->
              Printf.sprintf "%s%s ->\n%s"
                (pad (i + 1))
                ctor
                (pp_ctree_indented (i + 2) sub))
            cts_cases
        in
        let default_str =
          match cts_default with
          | None -> ""
          | Some d ->
              Printf.sprintf "\n%s_ ->\n%s"
                (pad (i + 1))
                (pp_ctree_indented (i + 2) d)
        in
        Printf.sprintf "%sswitch-tag %s {\n%s%s\n%s}" p (pp_accessor cts_scrut)
          (String.concat "\n" case_strs)
          default_str p
    | CTSwitchLit { ctl_scrut; ctl_cases; ctl_default } ->
        let case_strs =
          List.map
            (fun (lit, sub) ->
              Printf.sprintf "%s%s ->\n%s"
                (pad (i + 1))
                (lit_str lit)
                (pp_ctree_indented (i + 2) sub))
            ctl_cases
        in
        Printf.sprintf "%sswitch-lit %s {\n%s\n%s_ ->\n%s\n%s}" p
          (pp_accessor ctl_scrut)
          (String.concat "\n" case_strs)
          (pad (i + 1))
          (pp_ctree_indented (i + 2) ctl_default)
          p
    | CTSwitchLen { ctl_len_scrut; ctl_len_cases; ctl_len_geq; ctl_len_default }
      ->
        let case_strs =
          List.map
            (fun (n, sub) ->
              Printf.sprintf "%s=%d ->\n%s"
                (pad (i + 1))
                n
                (pp_ctree_indented (i + 2) sub))
            ctl_len_cases
        in
        let geq_str =
          match ctl_len_geq with
          | Some (n, sub) ->
              Printf.sprintf "\n%s>=%d ->\n%s"
                (pad (i + 1))
                n
                (pp_ctree_indented (i + 2) sub)
          | None -> ""
        in
        let default_str =
          match ctl_len_default with
          | None -> ""
          | Some d ->
              Printf.sprintf "\n%s_ ->\n%s"
                (pad (i + 1))
                (pp_ctree_indented (i + 2) d)
        in
        Printf.sprintf "%sswitch-len %s {\n%s%s%s\n%s}" p
          (pp_accessor ctl_len_scrut)
          (String.concat "\n" case_strs)
          geq_str default_str p
  in
  go 0 e

(* ============================================================================
   Top-level declarations
   ============================================================================ *)

(** Function category. Exactly one of:
    - [CFUser] — user-defined blorp function with a body in [cf_body]
    - [CFBuiltin] — maps to a C builtin (e.g. [blorp_list_get]); no body
    - [CFForeign] — FFI declaration; emits a C forward-decl from
      [c_name], pulls in any [includes], and carries [link_flags] /
      source-relative include dirs as pipeline metadata for the C compiler.
      [arg_passing] is the safety contract used when resolving call sites:
      default impure foreign functions carry checked per-argument copy/scalar
      policies, while [foreign pure] and [@no_copy] borrow.
    - [CFClosureBody] — hoisted lambda body that uses the closure
      calling convention: [void* func(void* __env, void* arg0, ...)]
      with unboxing preamble. Set by [Core_closure]. *)
type cf_kind =
  | CFUser
  | CFBuiltin
  | CFForeign of {
      c_name : string;
      includes : string list;
      link_flags : (string option * string) list;
      arg_passing : foreign_arg_passing;
    }
  | CFClosureBody of closure_abi

type core_func = {
  cf_name : string;
  cf_module : string option;
      (** The source module this function originated from, e.g. [Some "std/sorted_map"].
      [None] for main-program functions (not loaded from a module) and for
      test fixtures that bypass the pipeline.

      Populated by [Core_flatten.prefix_module_names] at the point where
      module identity is still unambiguous. Later passes read this field
      directly instead of parsing [cf_name] — [sanitize_module_name] is lossy
      (both ['/'] and ['.'] map to ['_']), so reverse-engineering the module
      path from the mangled name is incorrect for module names containing
      underscores (e.g. [std/sorted_map]). *)
  cf_type_params : Ast.type_param_decl list;
  cf_params : core_param list;
  cf_return_ty : Ast.type_expr;
  cf_body : core option;
  cf_is_pure : bool;
  cf_kind : cf_kind;
  cf_def_id : int;
      (** Canonical Core-IR identity for this function, minted fresh at
      [Core_lower] / [Core_closure] / [Core_mono] time via
      [Session.mint_def_id]. Stays stable through downstream passes —
      record-update rewrites (e.g. [Core_flatten.prefix_module_names]
      renaming [cf_name]) preserve [cf_def_id] so the "which function
      is this?" identity doesn't shift when the name does.

      Used by [Core_resolve] to key [user_funcs] entries and by
      [Core_emit] to emit the mangled C symbol for user functions. Typed as
      [int] rather than
      [Env_types.def_id] because [core.ml] must stay independent of
      [env_types] (both re-export through higher-level modules).

      For monomorphized copies: each specialization mints its own
      [cf_def_id], so [foo:Int] and [foo:String] are distinct
      identities even though they lower from a single generic source.

      Distinct from [Env_types.overload_entry.ol_def_id]: the env
      fabric identifies callsite resolution candidates at typecheck
      time; [cf_def_id] identifies compiled Core IR functions at
      codegen time. A follow-up may unify these, but today they are
      parallel and non-overlapping. *)
}
(** A Core function declaration. Mirrors [Ast.func_decl] but:
    - [cf_params] are always named (no pattern params)
    - [cf_body] is lowered Core (or [None] for builtins / foreign)
    - [cf_return_ty] is required, not [option]

    {1 Phase 2.6.4 note}

    The 15-field struct was collapsed to 8:
    - 5 flags ([cf_is_builtin] / [cf_foreign_name] / [cf_includes] /
      [cf_link_flags] / [cf_closure_abi]) became one [cf_kind] variant.
      Impossible states — "foreign AND builtin", "closure body without
      ABI" — are now unrepresentable.
    - [cf_is_tailrec] was deleted. [@tail_recursive] is
      validated in [Typecheck]; Core lowers supported resolved self-tail-call
      shapes in [Core_tailrec] without retaining the source annotation.
      [@no_copy] is represented by [CFForeign.arg_passing], so later phases
      do not need to recover FFI safety semantics from source annotations. *)

(** [is_builtin_kind k] — true iff [k = CFBuiltin]. Helper for the
    common "is this function a builtin?" check across passes.
    Keeping the predicate in one place documents the answer and avoids
    three-line pattern matches at each call site. *)
let is_builtin_kind (k : cf_kind) : bool =
  match k with CFBuiltin -> true | _ -> false

type core_var = {
  cv_name : var;
  cv_module : string option;
      (** Source module for this global, if it came from an imported module.
      Function declarations already carry [cf_module]; globals need the
      same context so passes that resolve imports inside global initializers
      do not accidentally use the main module's scope. *)
  cv_ty : Ast.type_expr;
  cv_init : core;
  cv_is_mutable : bool;
  cv_is_const : bool;
  cv_def_id : int;
      (** Canonical identity for this global. Minted at [Core_lower] via
      [Session.mint_def_id], preserved through [Core_flatten]'s
      record-update rewrite. A4.2 routes this through
      [Codegen_names.mangle_by_def_id] to emit the C symbol. Same
      rationale as [core_func.cf_def_id]. *)
}
(** A global variable declaration, with its initializer lowered to Core. *)

type core_trait_method = {
  ctm_name : string;
  ctm_params : core_param list;
  ctm_return_ty : Ast.type_expr option;
  ctm_is_pure : bool;
}
(** A trait method signature in Core IR.

    Note: the trait-level default body is NOT carried here. When an impl
    omits a method that has a default, [Typecheck] synthesizes a
    [func_decl] copy of the default into the impl's [impl_methods] before
    core lowering — so by the time Core IR is built, each default lives
    as a regular method on the impl that needs it. Holding a second copy
    on [core_trait_method] would just make every Core IR pass recurse
    into dead code. *)

type core_trait = {
  ct_name : string;
  ct_type_params : string list;
  ct_supertraits : string list;
  ct_methods : core_trait_method list;
}
(** A trait declaration in Core IR — structural only. *)

type core_impl = {
  ci_trait : string;
  ci_for_type : Ast.type_expr;
  ci_methods : core_func list;
}
(** An impl block, with each method body lowered. *)

(** A top-level Core declaration. Pass-through variants (CDType, CDRecord,
    CDImport, CDTypeAlias) reuse [Ast] types directly — they have no Core
    content and duplicating the definitions would just create drift. *)
type core_decl_desc =
  | CDFunc of core_func
  | CDVar of core_var
  | CDImpl of core_impl
  | CDTrait of core_trait
  | CDType of Ast.type_decl  (** pass-through: union/ADT *)
  | CDRecord of Ast.record_decl  (** pass-through *)
  | CDImport of Ast.import_decl  (** pass-through (compile-time only) *)
  | CDTypeAlias of Ast.type_alias_decl  (** pass-through *)
  | CDPrivate of core_decl  (** visibility wrapper *)

and core_decl = {
  cd_desc : core_decl_desc;
  cd_loc : Ast.loc;
  cd_doc : string option;
}

type core_program = core_decl list

(** Rewrite every static type slot in a Core expression. This includes the
    node's own [.ty] plus type annotations carried by binders, lambdas,
    casts/boxes, closure ABI metadata, try/RC nodes, and concurrent
    bindings. Child expressions are rewritten recursively. *)
let map_types_in_expr (f : Ast.type_expr -> Ast.type_expr) (expr : core) : core
    =
  let rewrite_var_ty (v, ty) = (v, f ty) in
  let rewrite_capture_ty (name, ty) = (name, f ty) in
  let rewrite_task_capture capture =
    { capture with task_capture_ty = f capture.task_capture_ty }
  in
  let rewrite_task_closure (tc : task_closure) =
    {
      tc with
      tc_captures = List.map rewrite_task_capture tc.tc_captures;
      tc_return_ty = f tc.tc_return_ty;
    }
  in
  let rewrite_box_op_ty b = { b with box_source_ty = f b.box_source_ty } in
  let rewrite_unbox_op_ty u =
    { u with unbox_target_ty = f u.unbox_target_ty }
  in
  let rewrite_param_ty p = { p with cp_ty = f p.cp_ty } in
  let rewrite_boxed_storage_ty v =
    { v with bsv_box = rewrite_box_op_ty v.bsv_box }
  in
  let rewrite_tensor_storage_layout_ty layout =
    { layout with tsl_elem_ty = Option.map f layout.tsl_elem_ty }
  in
  let rewrite_tensor_storage_provenance_ty = function
    | TensorStorageUnknown _ as proof -> proof
    | TensorStorageProven ({ tsp_layout; _ } as proof) ->
        TensorStorageProven
          {
            proof with
            tsp_layout = rewrite_tensor_storage_layout_ty tsp_layout;
          }
  in
  let rewrite_dict_constructor_ty = function
    | DictCustom ty -> DictCustom (f ty)
    | other -> other
  in
  let rewrite_set_constructor_ty = function
    | SetCustom ty -> SetCustom (f ty)
    | other -> other
  in
  let rewrite_record_field_arg_ty = function
    | RecordRawField (name, value) -> RecordRawField (name, value)
    | RecordErasedField (name, value) ->
        RecordErasedField (name, rewrite_boxed_storage_ty value)
  in
  let rec rewrite e =
    let e = map_children rewrite e in
    let desc =
      match e.desc with
      | CLambda lam ->
          CLambda
            {
              lam with
              lam_params = List.map rewrite_var_ty lam.lam_params;
              lam_return_ty = f lam.lam_return_ty;
            }
      | CClosureCreate cc ->
          CClosureCreate
            { cc with cc_captures = List.map rewrite_capture_ty cc.cc_captures }
      | CLet (b, body) -> CLet ({ b with bind_ty = f b.bind_ty }, body)
      | CBorrowLet (b, body) ->
          CBorrowLet ({ b with borrow_ty = f b.borrow_ty }, body)
      | CResourceScope s -> CResourceScope { s with rs_ty = f s.rs_ty }
      | CFor (binder, iter, body) ->
          CFor
            ( {
                binder with
                loop_ty = f binder.loop_ty;
                loop_source_storage =
                  rewrite_tensor_storage_provenance_ty
                    binder.loop_source_storage;
              },
              iter,
              body )
      | CDup (v, ty, body) -> CDup (v, f ty, body)
      | CDrop (v, ty, body) -> CDrop (v, f ty, body)
      | CTailrecLoop loop ->
          let loop' =
            match loop with
            | TailrecUnmanagedLoop l ->
                TailrecUnmanagedLoop
                  {
                    l with
                    tul_params = List.map rewrite_param_ty l.tul_params;
                    tul_return_ty = f l.tul_return_ty;
                  }
            | TailrecListSpreadLoop l ->
                TailrecListSpreadLoop
                  {
                    l with
                    tls_params = List.map rewrite_param_ty l.tls_params;
                    tls_return_ty = f l.tls_return_ty;
                    tls_list_param = rewrite_param_ty l.tls_list_param;
                  }
          in
          CTailrecLoop loop'
      | CConcurrent cb ->
          CConcurrent
            {
              cb with
              conc_bindings =
                List.map
                  (fun b ->
                    {
                      b with
                      cb_ty = f b.cb_ty;
                      cb_task = Option.map rewrite_task_closure b.cb_task;
                    })
                  cb.conc_bindings;
            }
      | CConcurrentlyLoop cf ->
          CConcurrentlyLoop
            { cf with cf_task = Option.map rewrite_task_closure cf.cf_task }
      | CDetach d ->
          CDetach
            {
              d with
              detach_task = Option.map rewrite_task_closure d.detach_task;
            }
      | CTupleConstruct tc ->
          CTupleConstruct
            { tc with tc_elems = List.map rewrite_boxed_storage_ty tc.tc_elems }
      | CListConstruct lc ->
          CListConstruct
            { lc with lc_elems = List.map rewrite_boxed_storage_ty lc.lc_elems }
      | CTensorLiteral tl ->
          let payload =
            match tl.tl_payload with
            | TensorRawElements _ as payload -> payload
            | TensorWordElements _ as payload -> payload
            | TensorPackedElements _ as payload -> payload
            | TensorInlineStructElements _ as payload -> payload
            | TensorBoxedElements elems ->
                TensorBoxedElements (List.map rewrite_boxed_storage_ty elems)
          in
          CTensorLiteral
            {
              tl with
              tl_layout = rewrite_tensor_storage_layout_ty tl.tl_layout;
              tl_payload = payload;
            }
      | CDictConstruct dc ->
          CDictConstruct
            {
              dc with
              dc_constructor = rewrite_dict_constructor_ty dc.dc_constructor;
              dc_entries =
                List.map
                  (fun (k, v) ->
                    (rewrite_boxed_storage_ty k, rewrite_boxed_storage_ty v))
                  dc.dc_entries;
            }
      | CSetAlloc sa ->
          CSetAlloc
            { sa_constructor = rewrite_set_constructor_ty sa.sa_constructor }
      | CRecordConstruct rc ->
          CRecordConstruct
            {
              rc with
              rc_fields = List.map rewrite_record_field_arg_ty rc.rc_fields;
            }
      | CCast (x, ty) -> CCast (x, f ty)
      | CUnbox (x, ty) -> CUnbox (x, f ty)
      | CUnboxTyped u -> CUnboxTyped (rewrite_unbox_op_ty u)
      | CBox (x, ty) -> CBox (x, f ty)
      | CBoxTyped b -> CBoxTyped (rewrite_box_op_ty b)
      | CUnionConstruct uc ->
          CUnionConstruct
            { uc with uc_args = List.map rewrite_boxed_storage_ty uc.uc_args }
      | CListHandoff h ->
          CListHandoff
            {
              h with
              lh_source_ty = f h.lh_source_ty;
              lh_result_ty = f h.lh_result_ty;
            }
      | other -> other
    in
    { e with ty = f e.ty; desc }
  in
  rewrite expr

(** Rewrite every static type slot in a Core declaration. Pass-through
    type declarations also have their field/variant/alias target types
    rewritten; declaration names are intentionally left untouched. *)
let rec map_types_in_decl (f : Ast.type_expr -> Ast.type_expr)
    (decl : core_decl) : core_decl =
  let rewrite_param p = { p with cp_ty = f p.cp_ty } in
  let rewrite_closure_abi abi =
    {
      ca_params = List.map (fun (v, ty) -> (v, f ty)) abi.ca_params;
      ca_captures = List.map (fun (name, ty) -> (name, f ty)) abi.ca_captures;
      ca_task_abi = abi.ca_task_abi;
    }
  in
  let rewrite_kind = function
    | CFClosureBody abi -> CFClosureBody (rewrite_closure_abi abi)
    | kind -> kind
  in
  let rewrite_func func =
    {
      func with
      cf_params = List.map rewrite_param func.cf_params;
      cf_return_ty = f func.cf_return_ty;
      cf_body = Option.map (map_types_in_expr f) func.cf_body;
      cf_kind = rewrite_kind func.cf_kind;
    }
  in
  let rewrite_field (field : Ast.field_decl) =
    { field with field_type = f field.field_type }
  in
  let rewrite_variant (variant : Ast.variant) =
    { variant with variant_fields = List.map f variant.variant_fields }
  in
  let desc =
    match decl.cd_desc with
    | CDFunc func -> CDFunc (rewrite_func func)
    | CDVar v ->
        CDVar
          { v with cv_ty = f v.cv_ty; cv_init = map_types_in_expr f v.cv_init }
    | CDImpl impl ->
        CDImpl
          {
            impl with
            ci_for_type = f impl.ci_for_type;
            ci_methods = List.map rewrite_func impl.ci_methods;
          }
    | CDTrait trait ->
        CDTrait
          {
            trait with
            ct_methods =
              List.map
                (fun m ->
                  {
                    m with
                    ctm_params = List.map rewrite_param m.ctm_params;
                    ctm_return_ty = Option.map f m.ctm_return_ty;
                  })
                trait.ct_methods;
          }
    | CDType t ->
        CDType
          { t with type_variants = List.map rewrite_variant t.type_variants }
    | CDRecord r ->
        CDRecord
          { r with record_fields = List.map rewrite_field r.record_fields }
    | CDTypeAlias a -> CDTypeAlias { a with alias_target = f a.alias_target }
    | CDPrivate inner -> CDPrivate (map_types_in_decl f inner)
    | CDImport _ as other -> other
  in
  { decl with cd_desc = desc }

let map_types_in_program (f : Ast.type_expr -> Ast.type_expr)
    (prog : core_program) : core_program =
  List.map (map_types_in_decl f) prog

(** [pp_program_indented prog] produces a multi-line textual rendering of
    a whole [core_program], suitable for [--dump-core] output.

    Each top-level declaration is rendered on its own block, separated by
    blank lines, with function bodies passed through [pp_to_string_indented].
    Pass-through decls ([CDType], [CDRecord], [CDImport], [CDTypeAlias])
    are rendered as compact one-liners — the Core IR carries no additional
    content for them.

    The output is intentionally human-readable (not byte-exact): stage
    diffing across [--dump-core-after] relies on stable structural markers
    (function names, types), not byte equality. *)
let pp_program_indented (prog : core_program) : string =
  let buf = Buffer.create 256 in
  let param_str (p : core_param) =
    Printf.sprintf "%s: %s" (Var.to_string p.cp_name) (ty_str p.cp_ty)
  in
  let func_header (f : core_func) =
    let params = String.concat ", " (List.map param_str f.cf_params) in
    let prefix = if f.cf_is_pure then "pure func" else "func" in
    let tags =
      match f.cf_kind with
      | CFUser -> ""
      | CFBuiltin -> " [builtin]"
      | CFForeign { c_name; _ } -> Printf.sprintf " [foreign=%s]" c_name
      | CFClosureBody _ -> " [closure]"
    in
    Printf.sprintf "%s %s(%s) -> %s%s" prefix f.cf_name params
      (ty_str f.cf_return_ty) tags
  in
  let rec emit_decl d =
    match d.cd_desc with
    | CDFunc f -> (
        Buffer.add_string buf (func_header f);
        Buffer.add_char buf '\n';
        match f.cf_body with
        | Some body ->
            Buffer.add_string buf (pp_to_string_indented body);
            Buffer.add_char buf '\n'
        | None -> ())
    | CDVar v ->
        let kw = if v.cv_is_mutable then "var" else "let" in
        Buffer.add_string buf
          (Printf.sprintf "%s %s: %s = %s\n" kw (Var.to_string v.cv_name)
             (ty_str v.cv_ty) (pp_to_string v.cv_init))
    | CDImpl i ->
        Buffer.add_string buf
          (Printf.sprintf "impl %s for %s {\n" i.ci_trait (ty_str i.ci_for_type));
        List.iter
          (fun m ->
            Buffer.add_string buf "  ";
            Buffer.add_string buf (func_header m);
            Buffer.add_char buf '\n';
            match m.cf_body with
            | Some body ->
                Buffer.add_string buf (pp_to_string_indented body);
                Buffer.add_char buf '\n'
            | None -> ())
          i.ci_methods;
        Buffer.add_string buf "}\n"
    | CDTrait t ->
        let supers =
          match t.ct_supertraits with
          | [] -> ""
          | ss -> ": " ^ String.concat " + " ss
        in
        Buffer.add_string buf
          (Printf.sprintf "trait %s%s (%d methods)\n" t.ct_name supers
             (List.length t.ct_methods))
    | CDType t ->
        Buffer.add_string buf
          (Printf.sprintf "type %s (%d variants)\n" t.type_name
             (List.length t.type_variants))
    | CDRecord r ->
        let kw = if r.record_is_value then "struct" else "record" in
        Buffer.add_string buf
          (Printf.sprintf "%s %s (%d fields)\n" kw r.record_name
             (List.length r.record_fields))
    | CDImport imp ->
        Buffer.add_string buf (Printf.sprintf "import %s\n" imp.import_module)
    | CDTypeAlias a ->
        Buffer.add_string buf (Printf.sprintf "alias %s\n" a.alias_name)
    | CDPrivate inner ->
        Buffer.add_string buf "private ";
        emit_decl inner
  in
  List.iter
    (fun d ->
      emit_decl d;
      Buffer.add_char buf '\n')
    prog;
  Buffer.contents buf

(* ============================================================================
   Build: ergonomic Core construction helpers
   ============================================================================ *)

(** Helpers for constructing Core expressions. The composition helpers
    ([add], [seq], [let_], [if_], [call], etc.) infer their type and
    location from child nodes — the ergonomic win over raw record
    construction.

    {1 Example}

    {[
      open Core.Build
      let loc = { line = 1; column = 1; end_line = 1; end_column = 1 }

      (* let x: Int = 10 in x + 1 *)
      let x = var ~loc "x" ty_int in
      let expr =
        let_ "x" ~ty:ty_int ~rhs:(lit_int ~loc 10) ~body:(add x (lit_int ~loc 1))
    ]}

    {1 Design}

    - {b Leaves} ([lit_int], [lit_bool], [lit_string], [lit_char],
      [void], [var]) take an explicit [~loc] because they have no
      child to inherit from.

    - {b Composition helpers} ([add], [sub], [mul], [div], [lt], [gt],
      [eq], [ne], [and_], [or_], [not_], [neg], [seq], [if_], [let_],
      [let_mut], [call], [field]) infer [ty] and [loc] from their
      children — typically the left-hand side for binary ops or the
      result slot for sequencing / if.

    - Types are inferred deterministically — e.g. [add] uses [lhs.ty];
      [lt] uses [TyNamed("Bool", [])]; [seq] uses [snd.ty]; [if_] uses
      [then_.ty]; [let_] uses [body.ty]. *)
module Build = struct
  let ty_int = Ast.TyNamed ("Int", [])
  let ty_bool = Ast.TyNamed ("Bool", [])
  let ty_string = Ast.TyNamed ("String", [])
  let ty_void = Ast.TyNamed ("Void", [])

  (** Raw constructor. Prefer the typed helpers below when possible. *)
  let mk ?loc ~ty desc =
    let loc = match loc with Some l -> l | None -> Ast.dummy_loc in
    { desc; ty; loc }

  (* ---- Leaves ---- *)

  let lit_int ~loc n = mk ~loc ~ty:ty_int (CLit (Ast.LitInt (Int64.of_int n)))
  let lit_bool ~loc b = mk ~loc ~ty:ty_bool (CLit (Ast.LitBool b))

  let lit_string ~loc s =
    let flags = { Ast.sf_multiline = false; sf_raw = false } in
    mk ~loc ~ty:ty_string (CLit (Ast.LitString (s, flags)))

  let lit_char ~loc c =
    mk ~loc ~ty:(Ast.TyNamed ("Char", [])) (CLit (Ast.LitChar c))

  let void ~loc = mk ~loc ~ty:ty_void CVoid
  let var ~loc ~ty name = mk ~loc ~ty (CVar (Var.named name))

  (* ---- Arithmetic (type = lhs.ty, loc = lhs.loc) ---- *)

  let bin op l r = { desc = CBin (op, l, r); ty = l.ty; loc = l.loc }
  let add l r = bin Ast.Add l r
  let sub l r = bin Ast.Sub l r
  let mul l r = bin Ast.Mul l r
  let div l r = bin Ast.Div l r
  let modulo l r = bin Ast.Mod l r

  (* ---- Comparison (type = Bool, loc = lhs.loc) ---- *)

  let cmp op l r = { desc = CBin (op, l, r); ty = ty_bool; loc = l.loc }
  let lt l r = cmp Ast.Lt l r
  let gt l r = cmp Ast.Gt l r
  let le l r = cmp Ast.Le l r
  let ge l r = cmp Ast.Ge l r
  let eq l r = cmp Ast.Eq l r
  let ne l r = cmp Ast.Ne l r

  (* ---- Logical (type = Bool, loc = lhs.loc) ---- *)

  let log op l r = { desc = CLog (op, l, r); ty = ty_bool; loc = l.loc }
  let and_ l r = log Ast.And l r
  let or_ l r = log Ast.Or l r
  let not_ x = { desc = CUn (Ast.Not, x); ty = ty_bool; loc = x.loc }
  let neg x = { desc = CUn (Ast.Neg, x); ty = x.ty; loc = x.loc }

  (* ---- Sequencing (type = body.ty, loc = first.loc / rhs.loc) ---- *)

  let seq a b = { desc = CSeq (a, b); ty = b.ty; loc = a.loc }

  (** [let_ ?mut name ~ty ~rhs ~body] — an immutable let-binding
      (set [~mut:true] for a [var]-style mutable binding). Type of the
      resulting node is [body.ty]; loc is [rhs.loc]. *)
  let let_ ?(mut = false) name ~ty ~rhs ~body =
    let b =
      {
        bind_var = Var.named name;
        bind_mut = mut;
        bind_ty = ty;
        bind_rhs = rhs;
      }
    in
    { desc = CLet (b, body); ty = body.ty; loc = rhs.loc }

  (** Shortcut for [let_ ~mut:true]. *)
  let let_mut name ~ty ~rhs ~body = let_ ~mut:true name ~ty ~rhs ~body

  (** [borrow_let name ~ty ~rhs ~body] creates an internal borrowed alias.
      The alias does not own [rhs]; Perceus must keep the original owner alive
      for [body] and must not retain or drop [name] itself. *)
  let borrow_let name ~ty ~rhs ~body =
    let b = { borrow_var = Var.named name; borrow_ty = ty; borrow_rhs = rhs } in
    { desc = CBorrowLet (b, body); ty = body.ty; loc = rhs.loc }

  (* ---- Control flow ---- *)

  let if_ ~cond ~then_ ~else_ =
    { desc = CIf (cond, then_, else_); ty = then_.ty; loc = cond.loc }

  (* ---- Calls and field access ---- *)

  (** [call fn args ~ty] — the return type must be supplied explicitly
      because it can't be inferred from the callee or args in general.
      The [call_kind] starts as [CKUnknown]. *)
  let call fn args ~ty =
    { desc = CCall (CKUnknown, fn, args); ty; loc = fn.loc }

  (** [field obj name ~ty] — record/struct field access. Type must be
      supplied (can't infer from [obj.ty] alone). *)
  let field obj name ~ty = { desc = CField (obj, name); ty; loc = obj.loc }
end
