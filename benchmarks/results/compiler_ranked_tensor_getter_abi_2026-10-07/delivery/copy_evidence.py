from pathlib import Path
import argparse, gzip, hashlib, json, re, shutil

ROOT = Path('<worktree:reader-cuts>')
DEST = ROOT / 'benchmarks/results/compiler_ranked_tensor_getter_abi_2026-10-07'
VALIDATION = Path('/tmp/blorp-ranked-tensor-abi-validation')
RESOURCE = Path('/tmp/blorp-ranked-tensor-reader-resource')
IMPLEMENTATION = Path('/tmp/blorp-ranked-tensor-abi-implementation')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--copy', action='store_true')
    args = parser.parse_args()
    groups = [(VALIDATION / name, 'correctness/' + name) for name in
              ['baseline-controls', 'retry-v2', 'retry-v3', 'retry-v4',
               'diagnostic-probe', 'preparation-qualification', 'final-correctness',
               'hygiene-supplement']]
    groups += [(RESOURCE, 'resource'),
               (IMPLEMENTATION, 'implementation'),
               (Path('/tmp/blorp-ranked-tensor-controller-review'), 'review'),
               (Path(__file__).resolve().parent, 'delivery')]
    # Raw reports stay byte-identical; keep their relative links usable.
    linked_payloads = set()
    for directory, _ in groups:
        for report in directory.rglob('*.md'):
            for target in re.findall(r'\]\(([^)]+)\)', report.read_text()):
                if '://' not in target and not target.startswith('/'):
                    linked_payloads.add((report.parent / target.split('#', 1)[0]).resolve())
    selected, omitted = [], []
    for directory, prefix in groups:
        for path in sorted(directory.rglob('*')):
            if not path.is_file() or '__pycache__' in path.parts:
                continue
            relative = path.relative_to(directory)
            if path.suffix not in {'.md', '.json', '.log', '.txt', '.patch', '.py', '.brp'}:
                reason = 'Generated C, object, executable or source archive stays in owned scratch; hash authority is retained.'
            elif path.name == 'stdout.log' and '-parse-packet' in path.parent.name:
                reason = 'Large successful AST output stays in scratch; syntax result and metadata are retained.'
            elif path.suffix == '.brp' and (prefix in {'resource', 'implementation'} or 'initial-source' in relative.parts):
                reason = 'Compiler source snapshot duplicates the reviewed exact patch or current owning suite; hashes and patches are retained.'
            else:
                selected.append((path, Path(prefix) / relative))
                continue
            omitted.append({'source': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size, 'reason': reason})
    print(json.dumps({'selected_files': len(selected), 'selected_bytes': sum(p.stat().st_size for p, _ in selected),
                      'omitted_files': len(omitted)}, indent=2))
    if not args.copy:
        return
    if DEST.exists():
        raise SystemExit('Delivery directory already exists; preserve rather than overwrite.')
    manifest = []
    for source, relative in selected:
        compressed = source.stat().st_size > 131072 and source.resolve() not in linked_payloads
        destination = DEST / (Path(str(relative) + '.gz') if compressed else relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        expected = sha(source)
        if compressed:
            destination.write_bytes(gzip.compress(source.read_bytes(), mtime=0))
            restored = gzip.decompress(destination.read_bytes())
            retained_sha = hashlib.sha256(restored).hexdigest()
        else:
            shutil.copyfile(source, destination)
            retained_sha = sha(destination)
        if sha(source) != expected or retained_sha != expected:
            raise SystemExit('Evidence changed during byte-preserving copy: ' + str(source))
        manifest.append({'source': str(source), 'destination': str(destination.relative_to(DEST)),
            'sha256': expected, 'bytes': source.stat().st_size, 'lossless_gzip': compressed,
            'stored_sha256': sha(destination), 'stored_bytes': destination.stat().st_size})
    (DEST / 'COPY_MANIFEST.json').write_text(json.dumps({'kind': 'Exact raw bytes retained; larger payloads use deterministic lossless gzip storage',
        'copied': manifest, 'omitted': omitted}, indent=2) + '\n')
    (DEST / '.gitattributes').write_text('*.patch -whitespace\n*.log whitespace=-blank-at-eof\n*.txt whitespace=-blank-at-eof\n')

if __name__ == '__main__':
    main()
