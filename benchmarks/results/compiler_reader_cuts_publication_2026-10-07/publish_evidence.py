#!/usr/bin/env python3
"""Project machine-local path presentation; preserve original proof authority."""
import argparse
import collections
import gzip
import hashlib
import io
import json
import re
import struct
import tarfile
from pathlib import Path

REVISION = "9ae3db857027202cc6c201abe76c6f3fc39592d6"
FAMILIES = (
    "compiler_identity_reader_cuts", "compiler_dictionary_getter_admission",
    "compiler_ranked_tensor_getter_abi", "compiler_dimension_kind_preservation",
)
ROOTS = tuple("benchmarks/results/" + name + "_2026-10-07" for name in FAMILIES)
CONTRACT = "benchmarks/results/compiler_reader_cuts_publication_2026-10-07"
FORBIDDEN = re.compile(r"/User[s]/[A-Za-z0-9_][A-Za-z0-9._-]*/|/hom[e]/[A-Za-z0-9_][A-Za-z0-9._-]*/|/var/folder[s]/")
HOME = re.compile(r"/(?:private/)?(?:Users|home)/[A-Za-z0-9_][A-Za-z0-9._-]*(?=/)")
WORKTREE = re.compile(HOME.pattern + r"/\.codex/worktrees/([A-Za-z0-9_.-]+)/blorp")
TEMP = re.compile(r"/(?:private/)?var/folder[s]/[^/\s\"']+/[^/\s\"']+/([TC])(?=/|$)")
DIGEST = re.compile(r"(?<![A-Fa-f0-9])[a-f0-9]{64}(?![A-Fa-f0-9])")

def sha(data):
    return hashlib.sha256(data).hexdigest()

def decode(path, data):
    return gzip.decompress(data) if path.endswith(".gz") else data

def allowed_path(path):
    return any(path == root + ".md" or path.startswith(root + "/") for root in ROOTS)

def publication_note(link):
    return (
        "\n> Publication note: this packet is a path-only projection of the privately "
        "archived original evidence. Original measurement, review, seal and copy "
        "hashes below remain historical original-byte authority; they do not hash "
        "the projected metadata or controllers. Numeric results, timestamps, "
        "source/compiler/C hashes and unchanged payload bytes are preserved. "
        "The [publication contract](" + link + ") and its `PUBLICATION_MANIFEST.json` "
        "identify current public byte hashes. Historical controllers are evidence, "
        "not directly runnable configurations.\n"
    )

def add_note(text, link):
    head, sep, tail = text.partition("\n")
    if not sep or not head.startswith("# "):
        raise ValueError("authored report does not start with a heading")
    return head + "\n" + publication_note(link) + "\n" + tail.rstrip() + "\n"

def compare_json(before, after, project):
    """Require exact type/scalar preservation and only the approved string map."""
    if type(before) is not type(after):
        raise ValueError("JSON scalar/container type changed")
    if isinstance(before, dict):
        keys = [project(key) for key in before]
        if len(keys) != len(set(keys)):
            raise ValueError("path projection collides JSON keys")
        if keys != list(after):
            raise ValueError("JSON order/key mapping changed")
        for key, value in before.items():
            compare_json(value, after[project(key)], project)
    elif isinstance(before, list):
        if len(before) != len(after):
            raise ValueError("JSON list size changed")
        for left, right in zip(before, after):
            compare_json(left, right, project)
    elif isinstance(before, str):
        if project(before) != after:
            raise ValueError("JSON nonpath string changed")
    elif before != after:
        raise ValueError("JSON numeric/null/boolean changed")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--private", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("refusing to overwrite an existing projected tree")
    raw = {}
    modes = {}
    with tarfile.open(args.archive) as archive:
        if archive.pax_headers.get("comment") != REVISION:
            raise ValueError("Git archive revision is not the pinned feature commit")
        for member in archive.getmembers():
            if member.isdir():
                continue
            if not member.isfile() or not allowed_path(member.name):
                raise ValueError("unexpected archive member: " + member.name)
            if member.name in raw:
                raise ValueError("duplicate archive path")
            raw[member.name] = archive.extractfile(member).read()
            modes[member.name] = member.mode
    if len(raw) != 621:
        raise ValueError("expected exactly 621 original files")
    texts = {}
    for path, data in raw.items():
        try:
            texts[path] = decode(path, data).decode("utf-8")
        except UnicodeDecodeError:
            if FORBIDDEN.search(decode(path, data).decode("latin1")):
                raise ValueError("forbidden path in non-UTF8 payload")
    mappings = {}
    for text in texts.values():
        for match in WORKTREE.finditer(text):
            name = "reader-cuts" if match.group(1) == "2c1f" else match.group(1)
            mappings[match.group()] = "<worktree:" + name + ">"
        for match in TEMP.finditer(text):
            canonical = match.group().startswith("/private/")
            token = "$TMPDIR_CANONICAL" if canonical else "$TMPDIR"
            if match.group(1) == "C":
                token = "$USER_CACHE_CANONICAL" if canonical else "$USER_CACHE"
            mappings[match.group()] = token
        for match in HOME.finditer(text):
            mappings[match.group()] = "<home>"
    prefixes = sorted(mappings, key=lambda item: (-len(item), item))
    pattern = re.compile("|".join(re.escape(item) for item in prefixes))
    ids = {prefix: "path-" + str(index + 1).zfill(3) for index, prefix in enumerate(prefixes)}
    counts = collections.Counter()

    def project(text, count=False):
        def replacement(match):
            prefix = match.group()
            if count:
                counts[ids[prefix]] += 1
            return mappings[prefix]
        return pattern.sub(replacement, text)

    projected = {}
    records = []
    affected = collections.Counter()
    original_inventory = []
    json_count = 0
    gz_changed = 0
    for path in sorted(raw):
        stored = raw[path]
        original = decode(path, stored)
        current = original
        changes = []
        before_counts = counts.copy()
        if path in texts:
            text = texts[path]
            after = project(text, count=True)
            if FORBIDDEN.search(after):
                raise ValueError("unmapped forbidden path in " + path)
            if DIGEST.findall(text) != DIGEST.findall(after):
                raise ValueError("embedded original SHA256 changed in " + path)
            if path.endswith((".json", ".json.gz")):
                compare_json(json.loads(text), json.loads(after), project)
                json_count += 1
            if after != text:
                changes.append("path_projection")
                affected[next(root for root in ROOTS if path == root + ".md" or path.startswith(root + "/"))] += 1
            if path in [root + ".md" for root in ROOTS]:
                after = add_note(after, CONTRACT.split("/")[-1] + "/README.md")
                changes.append("publication_note")
            elif path in [root + "/README.md" for root in ROOTS]:
                after = add_note(after, "../" + CONTRACT.split("/")[-1] + "/README.md")
                changes.append("publication_note")
            current = after.encode("utf-8")
        if current == original:
            output = stored
        elif path.endswith(".gz"):
            # Header mtime is serialization provenance, not a new measurement time.
            mtime = struct.unpack("<I", stored[4:8])[0]
            buffer = io.BytesIO()
            with gzip.GzipFile(fileobj=buffer, mode="wb", filename="", mtime=mtime, compresslevel=9) as zipped:
                zipped.write(current)
            output = buffer.getvalue()
            if struct.unpack("<I", output[4:8])[0] != mtime:
                raise ValueError("gzip header timestamp changed")
            gz_changed += 1
        else:
            output = current
        projected[path] = output
        original_pin = {"stored_sha256": sha(stored), "decoded_sha256": sha(original), "stored_bytes": len(stored), "decoded_bytes": len(original)}
        public_pin = {"stored_sha256": sha(output), "decoded_sha256": sha(current), "stored_bytes": len(output), "decoded_bytes": len(current)}
        original_inventory.append({"path": path, "mode": modes[path], **original_pin})
        records.append({"path": path, "mode": modes[path], "encoding": "gzip" if path.endswith(".gz") else "identity", "changes": changes or ["unchanged"], "original": original_pin, "published": public_pin, "replacements": dict(sorted((counts - before_counts).items()))})

    for root in ROOTS:
        path = root + "/README.md"
        if path not in projected:
            content = "# " + root.split("/")[-1].replace("_", " ") + " evidence\n" + publication_note("../" + CONTRACT.split("/")[-1] + "/README.md")
            projected[path] = content.encode()
            modes[path] = 0o644
            records.append({"path": path, "mode": 0o644, "encoding": "identity", "changes": ["publication_note", "new_file"], "original": None, "published": {"stored_sha256": sha(projected[path]), "decoded_sha256": sha(projected[path]), "stored_bytes": len(projected[path]), "decoded_bytes": len(projected[path])}, "replacements": {}})

    contract_path = CONTRACT + "/README.md"
    contract = """# Compiler reader-cut evidence publication

These four packets are path-only publication projections of the exact original
evidence committed in `9ae3db857027202cc6c201abe76c6f3fc39592d6`. Their original
621 files are privately retained together in one Git archive, qualified by its
SHA256 and size in `PUBLICATION_MANIFEST.json`. The manifest maps every original
stored and decoded hash to its published stored and decoded hash. It covers all
public payloads except itself, preventing a self-reference cycle.

Projection replaces only home, worktree and per-user-temp path prefixes using a
deterministic longest-prefix rule. `<worktree:reader-cuts>` identifies the feature
checkout; other `<worktree:NAME>` tokens distinguish observed checkouts, including
background jobs. `<home>` preserves the remainder of other home paths. `$TMPDIR`
and `$TMPDIR_CANONICAL` distinguish the original temp spelling from its canonical
alias. Their physical equivalence was established by the original experiment;
publication does not rerun resolution or collapse dictionary keys. The private
prefix map is preserved outside Git, with per-rule prefix hashes in the manifest.
Shared `/tmp` paths are retained because they identify no machine user.

Measurement numeric values, raw sample order, timestamps, toolchain strings,
acceptance booleans and source, compiler, input and generated-C hash values are
unchanged. Unaffected payloads are byte-identical. Affected gzip files were
decoded, projected and recompressed with the original header timestamp; both
decoded and stored hashes are explicit. Compression does not hide local paths.

Old seal, controller, comparison, review and copy manifests remain historical
original-byte authorities. Their embedded hash fields were not rewritten to
pretend the projected metadata was measured. Such a field may no longer hash a
published JSON, report or controller: verify that public file using this new
manifest's `published` hash. Source/C/compiler hashes still identify the original
unchanged artifacts. Counts and byte totals in old delivery descriptions refer
to the original packets. Authored primary reports and packet READMEs add this
publication qualification; other historical reports retain their original claims
under this same qualification.

Historical Python controllers are evidence, mode 100644, rather than directly
runnable portable configurations. Measurements can be repeated with the maintained
benchmark harness and explicit locally configured inputs/paired compilers. The
public records support recomputing the recorded allocation totals, sample minima,
exact 0.5% ceilings and output hash comparisons. Replaying the exact historical
controllers requires the private originals and their role-root bindings.

No compiler source, tests, ABI, measurement samples, source/C/binary SHA values or
acceptance thresholds were changed by this publication step. There was no native
rerun and no new performance claim. `PUBLICATION_CHECKS.json` records structural
JSON/string-only checks, preserved embedded SHA256 values, decoded path scanning
and unchanged source/C/patch payload checks. Full original restoration is a private
archive verification; publication is explicit about that audit limitation.

The evidence-only [publisher](publish_evidence.py) reproduces this projection:
`python3 publish_evidence.py --archive ORIGINAL.tar --output PUBLIC_TREE --private
PRIVATE_METADATA`. Supply the privately retained original archive; the script
rejects other revisions, unexpected payloads, JSON key collisions and nonpath
record changes. It never edits a repository or reruns native measurements.
"""
    projected[contract_path] = contract.encode()
    modes[contract_path] = 0o644

    # Additional report-only wording is disclosed separately from raw projection.
    checks_path = CONTRACT + "/PUBLICATION_CHECKS.json"
    checks = {"schema": "blorp.evidence.publication-checks.v1", "source_revision": REVISION, "original_file_count": len(raw), "affected_file_count": sum(affected.values()), "affected_gzip_count": gz_changed, "affected_by_family": dict(affected), "decoded_forbidden_files_before": sum(bool(FORBIDDEN.search(text)) for text in texts.values()), "decoded_forbidden_files_after": 0, "json_structural_projection_checks": json_count, "embedded_original_sha256_values_preserved": True, "gzip_header_timestamps_preserved": True, "raw_changes": "approved path prefixes only", "authored_changes": "publication qualification notes; report trailing newline normalization", "source_c_patch_files_with_path_changes": [path for path in raw if path.endswith((".c", ".brp", ".patch")) and decode(path, raw[path]) != decode(path, projected[path])], "native_work": "none"}
    if checks["source_c_patch_files_with_path_changes"]:
        raise ValueError("unexpected source/C/patch projection")
    projected[checks_path] = (json.dumps(checks, indent=2, sort_keys=True) + "\n").encode()
    modes[checks_path] = 0o644
    publisher_path = CONTRACT + "/publish_evidence.py"
    projected[publisher_path] = Path(__file__).read_bytes()
    modes[publisher_path] = 0o644
    for path in (contract_path, checks_path, publisher_path):
        data = projected[path]
        records.append({"path": path, "mode": 0o644, "encoding": "identity", "changes": ["publication_contract", "new_file"], "original": None, "published": {"stored_sha256": sha(data), "decoded_sha256": sha(data), "stored_bytes": len(data), "decoded_bytes": len(data)}, "replacements": {}})
    for path, data in projected.items():
        if FORBIDDEN.search(decode(path, data).decode("utf-8", errors="replace")):
            raise ValueError("forbidden path in final public payload " + path)

    archive_bytes = args.archive.read_bytes()
    manifest = {"schema": "blorp.evidence.publication.v1", "source_revision": REVISION, "private_original_archive": {"sha256": sha(archive_bytes), "bytes": len(archive_bytes), "files": len(raw), "format": "git archive tar"}, "publisher_sha256": sha(Path(__file__).read_bytes()), "manifest_self_excluded": True, "historical_embedded_hashes": "original artifact authority; published current-byte hashes are separate", "rules": [{"id": ids[prefix], "original_prefix_sha256": sha(prefix.encode()), "published_prefix": mappings[prefix], "replacements": counts[ids[prefix]]} for prefix in prefixes], "files": sorted(records, key=lambda record: record["path"])}
    args.private.mkdir(parents=True, exist_ok=True)
    (args.private / "PRIVATE_PREFIX_MAP.json").write_text(json.dumps({"source_revision": REVISION, "rules": [{"id": ids[prefix], "original_prefix": prefix, "published_prefix": mappings[prefix]} for prefix in prefixes]}, indent=2) + "\n")
    (args.private / "ORIGINAL_FILE_INVENTORY.json").write_text(json.dumps(original_inventory, indent=2) + "\n")
    for path, data in projected.items():
        destination = args.output / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
        destination.chmod(modes[path] & 0o777)
    manifest_path = args.output / CONTRACT / "PUBLICATION_MANIFEST.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    # Make the accepted census an assertion, not an incidental displayed count.
    if checks["decoded_forbidden_files_before"] != 193 or checks["affected_file_count"] != 193 or gz_changed != 7:
        raise ValueError("committed evidence census differs from reviewed 193/7")
    result = {"archive_sha256": manifest["private_original_archive"]["sha256"], "manifest_sha256": sha(manifest_path.read_bytes()), "publisher_sha256": manifest["publisher_sha256"], "original_files": len(raw), "public_files": len(projected) + 1, "affected_files": 193, "affected_gzip_files": gz_changed, "decoded_forbidden_files_after": 0}
    (args.private / "PUBLICATION_RESULT.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))

if __name__ == "__main__":
    main()
