#!/usr/bin/env python3
"""Conservative current-Core JSON census; static, never a dynamic site count."""
import collections
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_text()
marker = "===== after fusion =====\n"
assert raw.count(marker) == 1, "require exactly one fusion observation"
program = json.loads(raw.split(marker, 1)[1])
assert program["kind"] == "program"
decls = program["decls"]
records = {d["name"]: d for d in decls if d["kind"] == "heap_record"}
# Strict scalar subset of named_type_is_stack_option_payload in unmanaged_type.brp.
# No suffix/name-pattern guessing, aliases deliberately not admitted here.
scalars = set("Int Int8 Int16 Int32 Int64 Int128 UInt8 UInt16 UInt32 UInt64 UInt128 Float Float32 Float16 Bool Char".split())
counts = collections.Counter()
rows = []

def nodes(value, trail=()):
    if isinstance(value, dict):
        yield value, trail
        for key, child in value.items():
            yield from nodes(child, trail + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from nodes(child, trail + (index,))

def identity(value):
    return (value["name"], value["id"])

def scalar(typ):
    return typ["kind"] == "enum" or (typ["kind"] == "named" and not typ["args"] and typ["name"] in scalars)

def uses(value, target, refs, inside_lambda=False):
    if isinstance(value, list):
        return sum((uses(v, target, refs, inside_lambda) for v in value), [])
    if not isinstance(value, dict):
        return []
    inside_lambda |= value.get("kind") == "lambda"
    base = value.get("expr", {})
    if value.get("kind") == "field" and base.get("kind") == "var" and identity(base["var"]) == target:
        ref = value["field_ref"]["field_id"]
        return ["capture" if inside_lambda else "projection" if ref != -1 and ref in refs else "unresolved_or_wrong_field"]
    # CoreVar serialization is used for *all* variable identities, including
    # Assign/Dup/Drop, capture containers and match/loop binder metadata.
    if {"name", "id", "def_id"} <= value.keys() and identity(value) == target:
        return ["capture" if inside_lambda else "whole_value_or_rebinding"]
    return sum((uses(v, target, refs, inside_lambda) for v in value.values()), [])

for function in (d for d in decls if d["kind"] == "function"):
    counts["functions"] += 1
    if function["body"] is None:
        counts["bodyless_functions"] += 1
        continue
    for node, trail in nodes(function["body"]):
        if node.get("kind") != "let" or node["type"].get("kind") != "heap_record":
            continue
        counts["record_locals"] += 1
        why = []
        rhs = node["rhs"]
        if node["mutable"]:
            why.append("mutable")
        if rhs.get("kind") not in ("record", "record_construct"):
            why.append("nonliteral_rhs_" + str(rhs.get("kind")))
        declaration = records.get(node["type"]["name"])
        if declaration is None:
            why.append("missing_record_declaration")
        elif declaration["abi_type"] is not None or declaration["type_params"]:
            why.append("abi_or_generic_record")
        elif not all(scalar(f["type"]) for f in declaration["fields"]):
            why.append("outside_strict_scalar_subset")
        refs = {f["field_ref"]["field_id"] for f in declaration["fields"]} if declaration else set()
        if -1 in refs or len(refs) != len(declaration["fields"] if declaration else []):
            why.append("unresolved_or_duplicate_declaration_ref")
        if rhs.get("kind") in ("record", "record_construct"):
            actual = [f["field_ref"]["field_id"] for f in rhs["fields"]]
            if set(actual) != refs or len(actual) != len(refs) or rhs["type"] != node["type"]:
                why.append("literal_shape_mismatch")
        occurrences = uses(node["body"], identity(node["name"]), refs)
        why.extend(sorted(set(occurrences) - {"projection"}))
        if not occurrences:
            why.append("dead_no_projections")
        result = "strict_eligible" if not why else "rejected"
        counts[result] += 1
        counts.update(why)
        rows.append({"function": function["name"], "module": function["module"], "def_id": function["def_id"], "binder": node["name"], "path": trail, "rhs_kind": rhs.get("kind"), "result": result, "reasons": why, "projections": occurrences.count("projection")})
print(json.dumps({"sha256": hashlib.sha256(raw.encode()).hexdigest(), "boundary": "fusion after tuple_flatten", "coverage": "top-level function declarations only; embedded impl methods/globals not scanned; strict primitive/enum fields only; aliases outside scope; static not dynamic; zero is not an exhaustive no-go", "counts": counts, "locals": rows}, indent=2))
