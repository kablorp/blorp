#!/usr/bin/env python3
"""Patch a SCRATCH copy of blorp_2/src so emit marks the source of every RC operation.

Measures nothing itself. It makes a marker compiler: the compiler built from the
patched copy writes the same C as the normal compiler plus `/*RC:...*/` comments,
and `run` proves that stripping them reproduces the normal C byte for byte.
Never run it on the repository's own blorp_2/src.

Usage: patch_emit_markers.py SCRATCH_SRC_DIR   (a copy of blorp_2/src)

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
import sys

ROOT = sys.argv[1]

REASON_FUNCTIONS = '''
-- Scratch attribution marker: why an AcquireOwner exists, from its neighbours.
private pure func rc_reason_before_definition(operations: List[OwnershipOperation], index: Int) -> String:
	match operations.get(index):
		Some(AcquireOwner(_, _, _)): rc_reason_before_definition(operations, index.add(1))
		Some(DropOwner(_, _)): rc_reason_before_definition(operations, index.add(1))
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
	if position.greater_than(0):
		match operations.get(position.subtract(1)):
			Some(DefineValue(definition)):
				match definition.operation:
					ReadRecordFieldDefinition(_, _): projected = value_number(definition.id) == borrowed_value
					_: void
			_: void
	if projected:
		"projection"
	else:
		rc_reason_before_definition(operations, position.add(1))


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
			if owner_number(dropped) == owner:
				True
			else:
				rc_drops_owner_after(operations, index.add(1), owner, definitions_left)
		Some(AcquireOwner(_, _, _)): rc_drops_owner_after(operations, index.add(1), owner, definitions_left)
		Some(DefineValue(_)):
			if definitions_left.greater_than(0):
				rc_drops_owner_after(operations, index.add(1), owner, definitions_left.subtract(1))
			else:
				False
		_: False


-- The reason of the acquisition from `owner` that precedes `index` (skipping acquisitions,
-- drops and at most `definitions_left` definitions), or "none".
private pure func rc_partner_reason(operations: List[OwnershipOperation], index: Int, owner: Int, definitions_left: Int) -> String:
	if index.less_than(0):
		"none"
	else:
		match operations.get(index):
			Some(AcquireOwner(_, borrowed, _)):
				match borrowed.source:
					OwnerBorrow(source):
						if owner_number(source) == owner:
							rc_reason(operations, index, value_number(borrowed.value))
						else:
							rc_partner_reason(operations, index.subtract(1), owner, definitions_left)
					_: rc_partner_reason(operations, index.subtract(1), owner, definitions_left)
			Some(DropOwner(_, _)): rc_partner_reason(operations, index.subtract(1), owner, definitions_left)
			Some(DefineValue(_)):
				if definitions_left.greater_than(0):
					rc_partner_reason(operations, index.subtract(1), owner, definitions_left.subtract(1))
				else:
					"none"
			_: "none"


private pure func rc_acquire_pair(operations: List[OwnershipOperation], position: Int, source: BorrowSource) -> String:
	match source:
		OwnerBorrow(owner):
			if rc_drops_owner_after(operations, position.add(1), owner_number(owner), 1):
				"pair"
			else:
				"solo"
		_: "solo"


private pure func rc_marked(operations: List[OwnershipOperation], position: Int, operation: OwnershipOperation, emitted: String) -> String:
	match operation:
		AcquireOwner(owner, borrowed, _):
			"/*RC:B A ${rc_reason(operations, position, value_number(borrowed.value))} ${rc_source_name(borrowed.source)} ${rc_acquire_pair(operations, position, borrowed.source)} ${owner_number(owner).to_string()}*/${emitted}/*RC:E*/"
		DropOwner(owner, _):
			"/*RC:B D ${owner_number(owner).to_string()} ${rc_partner_reason(operations, position.subtract(1), owner_number(owner), 1)}*/${emitted}/*RC:E*/"
		_: emitted


-- A join output, loop header or loop or arm input owner is created without a definition.
private pure func rc_control_alias(output: String, owner: OwnerId, value: ValueId, value_type: TypeRef, unions: List[ConcreteUnion], span: Span, kind: String) -> Result[String, Diagnostic]:
	match append_owner_alias(output, owner, value, value_type, unions, span):
		Ok(aliased): Ok("${aliased}/*RC:K ${owner_number(owner).to_string()} ${kind}*/")
		Err(error): Err(error)


private pure func rc_definition_kind(operation: OwnedValueOperation) -> String:
	match operation:
		ParameterDefinition(_): "parameter"
		CallDefinition(_, _) | InvokeCallableDefinition(_, _): "call_result"
		ConstructRecordDefinition(_, _) | ConstructDefinition(_, _) | ConstructListDefinition(_) | CapturedCallableDefinition(_, _) | FreeCallableDefinition(_): "constructed"
		ListSuffixDefinition(_, _): "list_suffix"
		StringDefinition(_): "string_literal"
		_: "other"


'''

EDITS = [
    # The reason functions name the borrow sources.
    (
        "\t\tOwnedValueOperation(\n",
        "\t\tBorrowSource(ParameterBorrow, OwnerBorrow, PayloadBorrow),\n\t\tOwnedValueOperation(\n",
    ),
    # Mark acquisitions and drops inside every operation list.
    (
        '''	var fragments: List[String] = [output]
	var failure: Option[Diagnostic] = None

	for operation in operations:
		match append_ownership_operation("", operation, unions, types, records, nearest):
			Err(error):
				failure = Some(error)
				break
			Ok(emitted):
				fragments = fragments.append(emitted)
''',
        '''	var fragments: List[String] = [output]
	var failure: Option[Diagnostic] = None
	var position = 0

	for operation in operations:
		match append_ownership_operation("", operation, unions, types, records, nearest):
			Err(error):
				failure = Some(error)
				break
			Ok(emitted):
				fragments = fragments.append(rc_marked(operations, position, operation, emitted))
		position = position.add(1)
''',
    ),
    # Loop entry acquisitions are emitted outside any operation list.
    (
        '''		match append_ownership_operation(entered, AcquireOwner(acquisition.owner, acquisition.borrow, join_parameter(loop.result).span), unions, types, records, None):
			Ok(acquired): entered = acquired
''',
        '''		match append_ownership_operation("", AcquireOwner(acquisition.owner, acquisition.borrow, join_parameter(loop.result).span), unions, types, records, None):
			Ok(acquired): entered = "${entered}/*RC:B A loop_entry ${rc_source_name(acquisition.borrow.source)} solo ${owner_number(acquisition.owner).to_string()}*/${acquired}/*RC:E*/"
''',
    ),
    # Say what kind of definition created each owner it owns.
    (
        '''		OwnedResult(owner):
			append_owner_alias(value, owner, definition.id, definition.value_type, unions, definition.span)
''',
        '''		OwnedResult(owner):
			match append_owner_alias(value, owner, definition.id, definition.value_type, unions, definition.span):
				Ok(aliased): Ok("${aliased}/*RC:K ${owner_number(owner).to_string()} ${rc_definition_kind(definition.operation)}*/")
				Err(error): Err(error)
''',
    ),
    # Mark the owners that control edges create (they have no definition).
    ("match append_owner_alias(result, owner, fact.id, fact.value_type, unions, fact.span):",
     "match rc_control_alias(result, owner, fact.id, fact.value_type, unions, fact.span, \"input_owner\"):"),
    ("match append_owner_alias(snapshots, owner, fact.id, fact.value_type, unions, fact.span):",
     "match rc_control_alias(snapshots, owner, fact.id, fact.value_type, unions, fact.span, \"loop_header\"):"),
    ("match append_owner_alias(joined, owner, fact.id, fact.value_type, unions, fact.span):",
     "match rc_control_alias(joined, owner, fact.id, fact.value_type, unions, fact.span, \"join_output\"):"),
    # The helper functions sit before their first use.
    (
        "private pure func append_ownership_operation(\n",
        REASON_FUNCTIONS + "private pure func append_ownership_operation(\n",
    ),
]


def main():
    path = ROOT.rstrip("/") + "/emit/emit.brp"
    with open(path) as handle:
        text = handle.read()
    for old, new in EDITS:
        if text.count(old) != 1:
            sys.exit("error: patch_emit_markers: anchor found %d times (expected 1):\n%s" % (text.count(old), old))
        text = text.replace(old, new, 1)
    with open(path, "w") as handle:
        handle.write(text)
    print("patched", path, "with", len(EDITS), "edits")


if __name__ == "__main__":
    main()
