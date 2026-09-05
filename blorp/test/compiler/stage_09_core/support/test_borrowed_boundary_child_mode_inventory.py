"""Executable inventory of the three pre-fusion borrowed-boundary walks.

Each child mode is ``(call, storage, result)``. Paths name serialized Core
children, including nested records. ``$self`` records a boundary handled at the
current node rather than a structurally visited child.
"""

from __future__ import annotations


SKIP = ("skip", "skip", "skip")


def entry(classification: str, **children):
    return {"classification": classification, "children": children}


def opaque(*children: str):
    return entry("opaque", **{child: SKIP for child in children})


def leaf():
    return entry("leaf")


EXPRESSION_BEARING_CORE_COMPOSITES = frozenset({
    "CoreBoxOp",
    "CoreBoxedStorageValue",
    "CoreConcurrentBinding",
    "CoreConcurrentBlock",
    "CoreConcurrentlyLoop",
    "CoreConstructorLengthMatch",
    "CoreConstructorLengthMatchBranch",
    "CoreConstructorLengthMatchCase",
    "CoreConstructorLengthMatchGeq",
    "CoreConstructorLiteralMatch",
    "CoreConstructorMatchBody",
    "CoreConstructorMatchCase",
    "CoreConstructorMatchFallback",
    "CoreDecl",
    "CoreDictConstruct",
    "CoreDictEntry",
    "CoreDictLiteralEntry",
    "CoreForChannel",
    "CoreForDict",
    "CoreForList",
    "CoreForResourceSource",
    "CoreForSet",
    "CoreForStream",
    "CoreForString",
    "CoreForTensor",
    "CoreFunction",
    "CoreGlobal",
    "CoreImplDecl",
    "CoreListAlloc",
    "CoreListConstruct",
    "CoreListGet",
    "CoreListHandoff",
    "CoreListHandoffSetSourceSlot",
    "CoreListRetain",
    "CoreListSet",
    "CoreListSwap",
    "CoreLiteralMatchCase",
    "CoreLiteralMatchFallback",
    "CorePreClosureConcurrentBinding",
    "CorePreClosureConcurrentBlock",
    "CorePreClosureConcurrentlyLoop",
    "CoreProgram",
    "CoreRawMatchCase",
    "CoreRecordCowField",
    "CoreRecordFieldValue",
    "CoreResourceCleanupExit",
    "CoreResourceScope",
    "CoreSelectArm",
    "CoreSelectArmKind",
    "CoreSelectRecvArm",
    "CoreSemanticConstructorMatchCase",
    "CoreSemanticLengthMatchCase",
    "CoreSemanticLengthMatchGeq",
    "CoreSemanticLiteralMatchCase",
    "CoreSemanticMatchTree",
    "CoreStringByteCopy",
    "CoreStringByteRead",
    "CoreStringByteWrite",
    "CoreStringSetLen",
    "CoreTailrecListSpreadLoop",
    "CoreTailrecListSpreadRebind",
    "CoreTensorBoxedLiteral",
    "CoreTensorInlineStructLiteral",
    "CoreTensorLiteral",
    "CoreTensorLiteralPayload",
    "CoreTensorPackedLiteral",
    "CoreTensorRawFill",
    "CoreTensorRawLiteral",
    "CoreTensorRawRead",
    "CoreTensorRawViewBinding",
    "CoreTensorRawWrite",
    "CoreTupleConstruct",
    "CoreTupleElement",
    "CoreUnionConstruct",
    "CoreUnionReuseConstruct",
})


BORROWED_BOUNDARY_CHILD_MODES = {
    "LiteralExpr": leaf(),
    "StaticStringLiteralExpr": leaf(),
    "VarExpr": entry("boundary", **{"$self": ("skip", "skip", "terminal")}),
    "VoidExpr": leaf(),
    "DebugBlockExpr": opaque("body"),
    "CooperativeCheckpointExpr": leaf(),
    "CallExpr": entry(
        "boundary",
        callee=("traverse", "skip", "skip"),
        **{
            "args[]": ("traverse", "traverse", "skip"),
            "$self": ("boundary", "skip", "terminal"),
        },
    ),
    "BinaryExpr": entry(
        "boundary",
        left=("traverse", "skip", "skip"),
        right=("traverse", "skip", "skip"),
        **{"$self": ("boundary", "skip", "skip")},
    ),
    "UnaryExpr": entry("structural", value=("traverse", "skip", "skip")),
    "LogicalExpr": entry(
        "structural",
        left=("traverse", "skip", "skip"),
        right=("traverse", "skip", "skip"),
    ),
    "AssignExpr": entry("structural", rhs=("traverse", "traverse", "skip")),
    "CastExpr": entry(
        "boundary",
        value=("traverse", "skip", "skip"),
        **{"$self": ("skip", "skip", "terminal")},
    ),
    "BoxExpr": entry("structural", **{"box.value": ("traverse", "skip", "skip")}),
    "UnboxExpr": entry(
        "boundary",
        value=("traverse", "skip", "skip"),
        **{"$self": ("skip", "skip", "terminal")},
    ),
    "FieldExpr": entry(
        "boundary",
        owner=("traverse", "skip", "skip"),
        **{"$self": ("skip", "skip", "terminal")},
    ),
    "TupleFieldExpr": entry(
        "boundary",
        owner=("traverse", "skip", "skip"),
        **{"$self": ("skip", "skip", "terminal")},
    ),
    "TupleExpr": entry("boundary", **{"items[]": ("traverse", "transfer", "skip")}),
    "TupleConstructExpr": entry(
        "boundary",
        **{
            "construct.elements[].value": (
                "skip",
                "conditional_transfer",
                "skip",
            )
        },
    ),
    "VectorExpr": entry("boundary", **{"items[]": ("traverse", "transfer", "skip")}),
    "LambdaExpr": opaque("body"),
    "ClosureCreateExpr": leaf(),
    "ListConstructExpr": entry(
        "boundary",
        **{
            "construct.elements[].value": (
                "traverse",
                "conditional_transfer",
                "skip",
            )
        },
    ),
    "ListAllocExpr": opaque("alloc.capacity"),
    "ListGetExpr": opaque("get.list", "get.index"),
    "ListHandoffExpr": opaque(
        "handoff.source",
        "handoff.capacity",
        "handoff.body",
    ),
    "ListHandoffSetOwnedExpr": entry(
        "boundary",
        **{
            "set.list": ("traverse", "skip", "skip"),
            "set.index": ("traverse", "skip", "skip"),
            "set.value.value": (
                "traverse",
                "conditional_transfer",
                "skip",
            ),
        },
    ),
    "ListHandoffSetSourceSlotExpr": opaque(
        "slot.result",
        "slot.out_index",
        "slot.source",
        "slot.source_index",
    ),
    "StringByteReadExpr": opaque("read.source", "read.index"),
    "StringByteWriteExpr": opaque("write.target", "write.index", "write.byte"),
    "StringByteCopyExpr": opaque(
        "copy.dst",
        "copy.dst_pos",
        "copy.src",
        "copy.src_pos",
        "copy.len",
    ),
    "StringSetLenExpr": opaque("set_len.target", "set_len.len"),
    "TensorLiteralExpr": opaque("literal.payload.elements[]"),
    "TensorBoxedLiteralExpr": entry(
        "boundary",
        **{
            "literal.elements[].value": (
                "traverse",
                "conditional_transfer",
                "skip",
            )
        },
    ),
    "TensorPackedLiteralExpr": opaque("literal.elements[]"),
    "TensorRawFillExpr": opaque("fill.value", "fill.dims[]"),
    "TensorRawReadExpr": opaque("read.index"),
    "TensorRawWriteExpr": opaque("write.index", "write.value"),
    "TensorRawViewLetExpr": opaque("binding.source", "body"),
    "DictExpr": opaque("entries[].key", "entries[].value"),
    "DictConstructExpr": entry(
        "boundary",
        **{
            "construct.entries[].key.value": (
                "traverse",
                "conditional_transfer",
                "skip",
            ),
            "construct.entries[].value.value": (
                "traverse",
                "conditional_transfer",
                "skip",
            ),
        },
    ),
    "SetAllocExpr": leaf(),
    "ListRetainExpr": opaque("retain.list", "retain.value.value"),
    "ListSetExpr": entry(
        "boundary",
        **{
            "set.list": ("traverse", "skip", "skip"),
            "set.index": ("traverse", "skip", "skip"),
            "set.value.value": (
                "traverse",
                "conditional_transfer",
                "skip",
            ),
        },
    ),
    "ListSwapExpr": opaque("swap.list", "swap.left_index", "swap.right_index"),
    "RecordExpr": entry("boundary", **{"fields[].value": ("traverse", "transfer", "skip")}),
    "RecordUpdateExpr": entry(
        "boundary",
        base=("traverse", "traverse", "skip"),
        **{"fields[].value": ("traverse", "transfer", "skip")},
    ),
    "RecordReuseExpr": entry(
        "boundary",
        source=("traverse", "traverse", "skip"),
        **{"fields[].value": ("traverse", "transfer", "skip")},
    ),
    "RecordCowUpdateExpr": entry(
        "boundary",
        source=("traverse", "traverse", "skip"),
        **{"fields[].replacement": ("traverse", "transfer", "skip")},
    ),
    "RecordConstructExpr": entry(
        "boundary",
        **{"fields[].value": ("traverse", "transfer", "skip")},
    ),
    "UnionConstructExpr": entry(
        "boundary",
        **{
            "construct.args[].value": (
                "traverse",
                "conditional_transfer",
                "skip",
            )
        },
    ),
    "UnionReuseConstructExpr": opaque(
        "construct.source",
        "construct.args[].value",
    ),
    "DetachExpr": leaf(),
    "DupExpr": entry(
        "structural",
        body=("legacy_fallback", "traverse", "satisfied_traverse"),
    ),
    "DropExpr": entry(
        "structural",
        body=("legacy_fallback", "traverse", "traverse"),
    ),
    "LetExpr": entry(
        "structural",
        rhs=("traverse", "traverse", "skip"),
        body=("traverse", "traverse", "traverse"),
    ),
    "BorrowLetExpr": entry(
        "structural",
        rhs=("traverse", "traverse", "skip"),
        body=("traverse", "traverse", "traverse"),
    ),
    "SeqExpr": entry(
        "structural",
        first=("traverse", "traverse", "skip"),
        second=("traverse", "traverse", "traverse"),
    ),
    "WhileExpr": entry(
        "structural",
        cond=("traverse", "traverse", "skip"),
        body=("traverse", "traverse", "skip"),
    ),
    "BreakExpr": leaf(),
    "ContinueExpr": leaf(),
    "ResourceScopeExpr": entry(
        "structural",
        **{
            "scope.acquire": ("traverse", "traverse", "skip"),
            "scope.body": ("traverse", "traverse", "traverse"),
            "scope.cleanup": ("traverse", "traverse", "skip"),
        },
    ),
    "ResourceCleanupExitExpr": opaque("cleanup_exit.cleanups[]"),
    "TailrecLoopExpr": opaque("body"),
    "TailrecRecurExpr": opaque("args[]"),
    "TailrecListSpreadLoopExpr": opaque("loop.body"),
    "TailrecListSpreadRecurExpr": opaque("rebinds[].value"),
    "ForRangeExpr": entry(
        "structural",
        start=("traverse", "skip", "skip"),
        end=("traverse", "skip", "skip"),
        body=("traverse", "skip", "skip"),
    ),
    "ForChannelExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForListExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForStringExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForDictExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForSetExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForStreamExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForResourceSourceExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "ForTensorExpr": entry(
        "structural",
        **{
            "loop.iterable": ("traverse", "skip", "skip"),
            "loop.body": ("traverse", "skip", "skip"),
        },
    ),
    "PreClosureConcurrentlyLoopExpr": opaque(
        "loop.iterable",
        "loop.body",
        "loop.timeout",
        "loop.limit",
    ),
    "ConcurrentlyLoopExpr": opaque(
        "loop.iterable",
        "loop.body",
        "loop.timeout",
        "loop.limit",
    ),
    "PreClosureConcurrentExpr": opaque(
        "block.bindings[].rhs",
        "block.body",
        "block.timeout",
    ),
    "ConcurrentExpr": opaque(
        "block.bindings[].rhs",
        "block.body",
        "block.timeout",
    ),
    "PreClosureDetachExpr": opaque("body"),
    "SelectExpr": opaque("arms[].kind.channel_or_timeout", "arms[].body"),
    "RangeExpr": opaque("start", "end"),
    "RawMatchExpr": opaque("scrutinee", "cases[].body"),
    "SemanticMatchExpr": opaque("scrutinee", "tree.bodies"),
    "LiteralMatchExpr": entry(
        "structural",
        scrutinee=("traverse", "traverse", "skip"),
        **{
            "cases[].body": ("traverse", "traverse", "traverse"),
            "fallback.body": ("traverse", "traverse", "traverse"),
        },
    ),
    "AccessorLiteralMatchExpr": entry(
        "structural",
        scrutinee=("traverse", "traverse", "skip"),
        **{
            "match.cases[].body": ("traverse", "traverse", "traverse"),
            "match.fallback.body": ("traverse", "traverse", "traverse"),
        },
    ),
    "LengthMatchExpr": entry(
        "structural",
        scrutinee=("traverse", "traverse", "skip"),
        **{
            "match.cases[].branch.body": ("traverse", "traverse", "traverse"),
            "match.geq.branch.body": ("traverse", "traverse", "traverse"),
            "match.fallback.body": ("traverse", "traverse", "traverse"),
        },
    ),
    "ConstructorMatchExpr": entry(
        "structural",
        scrutinee=("traverse", "traverse", "skip"),
        **{
            "cases[].body": ("traverse", "traverse", "traverse"),
            "fallback.body": ("traverse", "traverse", "traverse"),
        },
    ),
    "IfExpr": entry(
        "structural",
        cond=("traverse", "traverse", "skip"),
        then_branch=("traverse", "traverse", "traverse"),
        else_branch=("traverse", "traverse", "traverse"),
    ),
}
