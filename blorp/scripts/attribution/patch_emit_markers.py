#!/usr/bin/env python3
"""Patch a SCRATCH copy of blorp/src so emit marks the source of every RC operation.

Measures nothing itself. It makes a marker compiler: the compiler built from the
patched copy writes the same C as the normal compiler plus `/*RC:...*/` comments,
and `run` proves that stripping them reproduces the normal C byte for byte.
Never run it on the repository's own blorp/src.

Usage: patch_emit_markers.py SCRATCH_SRC_DIR   (a copy of blorp/src)

Each edit replaces whole lines of emit.brp that must occur exactly once. An anchor
is written without its indentation and matches at any depth, so moving a block
does not break it; the replacement takes the matched block's indentation. Any
other drift stops the patch with the anchor that no longer matches.

The markers come from ownership's own operation kinds, read where emit already
walks them, not guessed from names in the C:
  /*RC:B A <reason> <source> <pair> <owner>*/ ... /*RC:E*/   an AcquireOwner and its alias
  /*RC:B D <owner> <partner>*/ ... /*RC:E*/                  a DropOwner
  /*RC:K <owner> <kind>*/                    an owner that a definition, a join output,
                                             a loop header or a loop or arm input created
Every owner a drop names has an A or a K marker in its function; instrument_rc.py fails
otherwise, so no drop has a defaulted origin. K kinds: parameter, call_result,
constructed, list_suffix, string_literal, other (definitions), join_output,
loop_header, input_owner (control edges).

Reasons for an AcquireOwner. ASSUMPTION: ownership inserts an acquisition directly
before the operation it serves (stored payloads and call arguments precede their
definition; a projection's acquisition directly follows its read; a block's returned
values are acquired at its end), so the reason is read from the neighbouring
operations after skipping other acquisitions and drops:
  projection      the previous operation is the ReadRecordFieldDefinition it acquires
  call            the next definition is a call
  stored          the next definition constructs a record, variant or list or captures
  other_definition  the next definition is anything else (none occurs in the self-compile)
  before_control  the next operation is an ExecuteJoin or ExecuteLoop (none occurs in the self-compile)
  block_end       no operation follows: a returned or yielded borrowed value
  loop_entry      loop.entry_acquisitions, which emit writes itself
<source> is the borrow's source: parameter, owner or payload. <pair> is `pair` when
the same operation list acquires from an owner and then drops that owner with at
most one definition between them (a move candidate: a move would replace both), else
`solo`. A drop's <partner> is the reason of such an acquisition that precedes it, or
`none`; pairs that straddle operation lists are not seen.
"""
import re
import sys
import textwrap

REASON_FUNCTIONS = """
-- Scratch attribution marker: why an AcquireOwner exists, from its neighbours.
private pure func rc_reason_before_definition(operations: List[OwnershipOperation], index: Int) -> String:
    match operations.get(index):
        Some(AcquireOwner(_, _, _)): rc_reason_before_definition(operations, index + 1)
        Some(DropOwner(_, _)): rc_reason_before_definition(operations, index + 1)
        Some(DefineValue(definition)):
            match definition.operation:
                CallDefinition(_, _) | InvokeCallableDefinition(_, _): "call"
                ConstructRecordDefinition(_, _) | ConstructDefinition(_, _) | ConstructListDefinition(_) | CapturedCallableDefinition(_, _): "stored"
                _: "other_definition"
        Some(ExecuteJoin(_)): "before_control"
        Some(ExecuteLoop(_)): "before_control"
        None: "block_end"


private pure func rc_reason(operations: List[OwnershipOperation], position: Int, borrowed_value: Int) -> String:
    var projected: Bool = False
    if position > 0:
        match operations.get(position - 1):
            Some(DefineValue(definition)):
                match definition.operation:
                    ReadRecordFieldDefinition(_, _): projected = definition.id.value_number() == borrowed_value
                    _: void
            _: void
    if projected:
        "projection"
    else:
        rc_reason_before_definition(operations, position + 1)


private pure func rc_source_name(source: BorrowSource) -> String:
    match source:
        ParameterBorrow(_): "parameter"
        OwnerBorrow(_): "owner"
        PayloadBorrow(_): "payload"


-- True when only acquisitions, drops and at most `definitions_left` definitions
-- separate the operation at `index` from a drop of `owner`: the pair
-- "acquire from owner, then drop owner" that a move would replace.
private pure func rc_drops_owner_after(operations: List[OwnershipOperation], index: Int, owner: Int, definitions_left: Int) -> Bool:
    match operations.get(index):
        Some(DropOwner(dropped, _)):
            if dropped.owner_number() == owner:
                True
            else:
                rc_drops_owner_after(operations, index + 1, owner, definitions_left)
        Some(AcquireOwner(_, _, _)): rc_drops_owner_after(operations, index + 1, owner, definitions_left)
        Some(DefineValue(_)):
            if definitions_left > 0:
                rc_drops_owner_after(operations, index + 1, owner, definitions_left - 1)
            else:
                False
        _: False


-- The reason of the acquisition from `owner` that precedes `index` (skipping acquisitions,
-- drops and at most `definitions_left` definitions), or "none".
private pure func rc_partner_reason(operations: List[OwnershipOperation], index: Int, owner: Int, definitions_left: Int) -> String:
    if index < 0:
        "none"
    else:
        match operations.get(index):
            Some(AcquireOwner(_, borrowed, _)):
                match borrowed.source:
                    OwnerBorrow(source):
                        if source.owner_number() == owner:
                            rc_reason(operations, index, borrowed.value.value_number())
                        else:
                            rc_partner_reason(operations, index - 1, owner, definitions_left)
                    _: rc_partner_reason(operations, index - 1, owner, definitions_left)
            Some(DropOwner(_, _)): rc_partner_reason(operations, index - 1, owner, definitions_left)
            Some(DefineValue(_)):
                if definitions_left > 0:
                    rc_partner_reason(operations, index - 1, owner, definitions_left - 1)
                else:
                    "none"
            _: "none"


private pure func rc_acquire_pair(operations: List[OwnershipOperation], position: Int, source: BorrowSource) -> String:
    match source:
        OwnerBorrow(owner):
            if rc_drops_owner_after(operations, position + 1, owner.owner_number(), 1):
                "pair"
            else:
                "solo"
        _: "solo"


private pure func rc_marked(operations: List[OwnershipOperation], position: Int, operation: OwnershipOperation, emitted: String) -> String:
    match operation:
        AcquireOwner(owner, borrowed, _):
            reason = rc_reason(operations, position, borrowed.value.value_number())
            source = rc_source_name(borrowed.source)
            pair = rc_acquire_pair(operations, position, borrowed.source)
            "/*RC:B A ${reason} ${source} ${pair} ${owner.owner_number()}*/${emitted}/*RC:E*/"
        DropOwner(owner, _):
            partner = rc_partner_reason(operations, position - 1, owner.owner_number(), 1)
            "/*RC:B D ${owner.owner_number()} ${partner}*/${emitted}/*RC:E*/"
        _: emitted


private pure func rc_definition_kind(operation: OwnedValueOperation) -> String:
    match operation:
        ParameterDefinition(_): "parameter"
        CallDefinition(_, _) | InvokeCallableDefinition(_, _): "call_result"
        ConstructRecordDefinition(_, _) | ConstructDefinition(_, _) | ConstructListDefinition(_) | CapturedCallableDefinition(_, _) | FreeCallableDefinition(_): "constructed"
        ListSuffixDefinition(_, _): "list_suffix"
        StringDefinition(_): "string_literal"
        _: "other"


"""

# (anchor, replacement): whole lines, written at their own relative indentation.
EDITS = [
    # The reason functions name the borrow sources (in emit's import of own).
    (
        """
        OwnedValueOperation(
        """,
        """
        BorrowSource(ParameterBorrow, OwnerBorrow, PayloadBorrow),
        OwnedValueOperation(
        """,
    ),
    # Mark acquisitions and drops inside every operation list.
    (
        """
        var fragments: List[String] = [output]
        var failure: Option[Diagnostic] = None

        for operation in operations:
            match "".append_ownership_operation(operation, unions, types, records, nearest):
                Err(error):
                    failure = Some(error)
                    break
                Ok(emitted):
                    fragments = fragments.append(emitted)
        """,
        """
        var fragments: List[String] = [output]
        var failure: Option[Diagnostic] = None
        var position = 0

        for operation in operations:
            match "".append_ownership_operation(operation, unions, types, records, nearest):
                Err(error):
                    failure = Some(error)
                    break
                Ok(emitted):
                    fragments = fragments.append(rc_marked(operations, position, operation, emitted))
            position = position + 1
        """,
    ),
    # Loop entry acquisitions are emitted outside any operation list.
    (
        """
        for acquisition in loop.entry_acquisitions:
            match entered.append_ownership_operation(
                AcquireOwner(acquisition.owner, acquisition.borrow, loop.result.join_parameter().span),
                unions,
                types,
                records,
                None,
            ):
                Ok(acquired):
                    entered = acquired
        """,
        """
        for acquisition in loop.entry_acquisitions:
            match "".append_ownership_operation(
                AcquireOwner(acquisition.owner, acquisition.borrow, loop.result.join_parameter().span),
                unions,
                types,
                records,
                None,
            ):
                Ok(acquired):
                    source = rc_source_name(acquisition.borrow.source)
                    entered = "${entered}/*RC:B A loop_entry ${source} solo ${acquisition.owner.owner_number()}*/${acquired}/*RC:E*/"
        """,
    ),
    # Say what kind of definition created each owner it owns.
    (
        """
        Ok(binding): Ok("${value}${binding}")
        """,
        """
        Ok(binding): Ok("${value}${binding}/*RC:K ${owner.owner_number()} ${rc_definition_kind(definition.operation)}*/")
        """,
    ),
    # Mark the owners that control edges create (they have no definition): a
    # loop or arm input owner, a loop header and a join output.
    (
        """
        Ok(binding):
            result = "${result}${binding}"
        """,
        """
        Ok(binding):
            result = "${result}${binding}/*RC:K ${owner.owner_number()} input_owner*/"
        """,
    ),
    (
        """
        Ok(binding):
            snapshots = "${snapshots}${binding}"
        """,
        """
        Ok(binding):
            snapshots = "${snapshots}${binding}/*RC:K ${owner.owner_number()} loop_header*/"
        """,
    ),
    (
        """
        Ok(binding): joined = "${joined}${binding}"
        """,
        """
        Ok(binding): joined = "${joined}${binding}/*RC:K ${owner.owner_number()} join_output*/"
        """,
    ),
    # The helper functions sit before their first use.
    (
        """
        private pure func append_ownership_operation(
        """,
        REASON_FUNCTIONS + "private pure func append_ownership_operation(\n",
    ),
]


def lines_of(block):
    """A block's lines without their common indentation or the surrounding blank lines."""
    return textwrap.dedent(block).strip("\n").split("\n")


def anchor_pattern(anchor):
    """Match the anchor's lines in full, at any one indentation, captured as `indent`."""
    first, *rest = lines_of(anchor)
    pattern = r"^(?P<indent>[ \t]*)" + re.escape(first)
    for line in rest:
        pattern += r"\n" + (r"(?P=indent)" + re.escape(line) if line else "")
    return re.compile(pattern + "$", re.M)


def indented(block, indent):
    return "\n".join(indent + line if line else line for line in lines_of(block))


def apply_edit(text, anchor, replacement):
    matches = list(anchor_pattern(anchor).finditer(text))
    if len(matches) != 1:
        sys.exit("error: patch_emit_markers: anchor found %d times in emit.brp (expected 1):\n%s"
                 % (len(matches), "\n".join(lines_of(anchor))))
    match = matches[0]
    return text[:match.start()] + indented(replacement, match.group("indent")) + text[match.end():]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1].rstrip("/") + "/compile/emit/emit.brp"
    with open(path) as handle:
        text = handle.read()
    for anchor, replacement in EDITS:
        text = apply_edit(text, anchor, replacement)
    with open(path, "w") as handle:
        handle.write(text)
    print("patched", path, "with", len(EDITS), "edits")


if __name__ == "__main__":
    main()
