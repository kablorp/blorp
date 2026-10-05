import collections
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[4]
OUT = Path(__file__).parent
BASE = '133eaf73a63830522b659ab6a2da65f9f2963711'
files = sorted(set(subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()))
records = []
declarations = []
fixed = []

def owner(path):
    if path.startswith('blorp/src/compiler_new/'): return 'discovery'
    if path.startswith('blorp/src/compiler/'): return path.split('/')[3]
    if path.startswith('blorp/test/compiler_new/'): return 'discovery-tests'
    if path.startswith('blorp/test/compiler/'): return path.split('/')[3]
    return '/'.join(path.split('/')[:3])

def treatment(path):
    if '/should_fail/' in path or '/should_error/' in path:
        return 'manual_negative_fixture'
    if '/format/' in path or '/lsp/' in path or path.startswith('editor/'):
        return 'manual_tool_contract'
    if 'parse' in path or 'lex' in path or 'diagnostic' in path or 'syntax' in path:
        return 'manual_parser_keyword_contract'
    if any(word in path for word in ('ctfe', 'hash', 'equat', 'enum_keys', 'import', 'codegen_audit', 'ffi', 'memory', 'process', '/fs.', '/bool.')):
        return 'manual_semantic_or_native_contract'
    return 'mechanical_header_after_capability_gate'

def add(path, line, category, declaration, text, action=None):
    row = dict(path=path, line=line, owner=owner(path), category=category,
               declaration=declaration, action=action or treatment(path), text=text.strip())
    records.append(row)
    return row

def brp_regions(text):
    # Lexical boundaries only; interpolation expressions are not parsed.
    chunks=[]; start=0; index=0; doc=False
    for line_no,line in enumerate(text.splitlines(keepends=True),1):
        stripped=line.strip()
        if stripped == '---':
            doc=not doc; chunks.append((line_no,'prose',line)); continue
        if doc or stripped.startswith('--'):
            chunks.append((line_no,'prose',line)); continue
        if re.match(r'^\s*\|',line):
            chunks.append((line_no,'embedded',line)); continue
        pos=0; code=''; strings=[]
        while pos<len(line):
            if line[pos:pos+2]=='--': break
            if line[pos]=='"':
                end=pos+1
                while end<len(line):
                    if line[end]=='\\': end+=2; continue
                    if line[end]=='"': end+=1; break
                    end+=1
                raw=line[pos:end]
                try: value=json.loads(raw)
                except (ValueError,TypeError): value=raw[1:-1].replace('\\n','\n').replace('\\t','\t')
                strings.append(value); code+=' ' * len(raw); pos=end
            else: code+=line[pos]; pos+=1
        chunks.append((line_no,'code',code))
        chunks.extend((line_no,'embedded',value) for value in strings)
    return chunks

for relative in files:
    path=ROOT/relative
    if not path.is_file() or relative.startswith('benchmarks/results/'): continue
    try: text=path.read_text()
    except (UnicodeError,OSError): continue
    if relative.endswith('.brp'):
        for line_no,region,chunk in brp_regions(text):
            if region=='code':
                match=re.match(r'^\s*(?:private\s+)?enum\s+(\w+)',chunk)
                if match:
                    row=add(relative,line_no,'source_declaration',match[1],chunk)
                    declarations.append(row)
                match_fixed=re.match(r'^\s*(?:private\s+)?fixed\s+union\s+(\w+)',chunk)
                if match_fixed:
                    body=[]
                    for next_line in text.splitlines()[line_no:]:
                        if next_line.strip() and not next_line[0].isspace(): break
                        body.append(next_line)
                    row=dict(path=relative,line=line_no,declaration=match_fixed[1],kind='source',
                        direct_string=bool(re.search(r'\bString\b','\n'.join(body))),body='\n'.join(body))
                    fixed.append(row)
                if not match and re.search('enum',chunk,re.I):
                    category='compiler_model_reference' if relative.startswith('blorp/src/') else 'test_model_or_identifier_reference'
                    if re.search(r'\benumerat\w*',chunk,re.I) and not re.search(r'\benum\b|EnumType|EnumDecl|EnumKeyword|is_enum|enum_decl',chunk): category='unrelated_identifier'
                    add(relative,line_no,category,'',chunk)
            elif region=='embedded':
                matches=list(re.finditer(r'(?:^|\n)\s*\|?\s*(?:private\s+)?enum\s+(\w+)(?=\s*[:\[\n])',chunk))
                if matches:
                    for match in matches:
                        row=add(relative,line_no,'embedded_declaration',match[1],chunk)
                        declarations.append(row)
                elif re.search('enum',chunk,re.I):
                    add(relative,line_no,'embedded_enum_text_or_wire', '',chunk)
                for match in re.finditer(r'(?:^|\n)\s*\|?\s*(?:private\s+)?fixed\s+union\s+(\w+)(?=\s*[:\[\n]|$)',chunk):
                    fragment=chunk[match.start():].lstrip()
                    next_decl=re.search(r'\n(?:private\s+)?(?:fixed\s+union|union|enum|record|func|pure\s+func)\b',fragment)
                    if next_decl: fragment=fragment[:next_decl.start()]
                    fixed.append(dict(path=relative,line=line_no,declaration=match[1],kind='embedded',
                        direct_string=bool(re.search(r'\bString\b',fragment)),body=fragment))
            elif re.search('enum',chunk,re.I):
                add(relative,line_no,'comment_or_documentation','',chunk,'do_not_blindly_replace')
    else:
        for line_no,line in enumerate(text.splitlines(),1):
            if not re.search('enum',line,re.I): continue
            if relative.endswith(('.c','.h')):
                category='native_c_enum_construct' if re.search(r'\benum\b',line) else 'native_c_enum_reference'
                action='exclude_native_representation_review_contract'
            elif relative.endswith('.py') or (relative.startswith('scripts/') and text.startswith('#!/usr/bin/env python')):
                category='python_native_enum_or_reference'
                action='exclude_python_enum_review_embedded_blorp_or_wire'
                if re.search(r'enum\s+\w+\s*:',line): category='python_embedded_blorp_or_text'
                elif re.search(r'\benumerat\w*',line,re.I) and not re.search(r'\benum\b|EnumType|EnumDecl|EnumKeyword|is_enum|enum_decl',line): category='unrelated_identifier'
            elif relative.endswith('.md'):
                category='documentation_or_embedded_example'; action='manual_documentation_current_vs_planned'
            elif relative.startswith('editor/'):
                category='editor_keyword_or_scope'; action='manual_editor_keyword_contract'
            else:
                category='script_wire_or_configuration'; action='manual_protocol_or_generator_contract'
            header=re.match(r'^\s*(?:private\s+)?enum\s+(\w+)\s*:',line) if relative.endswith('.md') else None
            row=add(relative,line_no,category,header[1] if header else '',line,action)
            if header:
                row['category']='documentation_enum_example'
                declarations.append(row)

summary=dict(base=BASE,root=str(ROOT),file_inventory='git ls-files --cached --others --exclude-standard',
    exclusions=['ignored build/cache files','benchmarks/results historical evidence','binary/non-UTF8 files'],
    limitations=['Lexical region scan, not parser/typechecked dependency graph','Quoted strings decoded as JSON escapes with newline/tab fallback','Interpolation expressions not separately parsed','Embedded positive-vs-negative treatment inferred from owner path and retained for manual review'],
    counts=dict(collections.Counter(row['category'] for row in records)),
    source_by_owner=dict(collections.Counter(row['owner'] for row in declarations if row['category']=='source_declaration')),
    embedded_by_action=dict(collections.Counter(row['action'] for row in declarations if row['category']=='embedded_declaration')),
    fixed_counts=dict(total=len(fixed),direct_string=sum(row['direct_string'] for row in fixed)))
native=[]
for relative in files:
    if not relative.endswith(('.c','.h','.py')): continue
    try: text=(ROOT/relative).read_text()
    except (UnicodeError,OSError): continue
    if relative.endswith(('.c','.h')):
        masked=re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"',lambda m: ''.join('\n' if c=='\n' else ' ' for c in m[0]),text,flags=re.S)
        for match in re.finditer(r'\benum\s*(\w+)?\s*\{([^}]+)\}\s*(\w+)?',masked):
            native.append(dict(path=relative,line=text.count('\n',0,match.start())+1,
                kind='native_c',name=match[1] or match[3] or '(anonymous)',action='exclude_from_blorp_spelling_migration'))
    else:
        for match in re.finditer(r'^class\s+(\w+)\([^\n]*(?:Enum|IntEnum)[^\n]*\)',text,re.M):
            native.append(dict(path=relative,line=text.count('\n',0,match.start())+1,
                kind='native_python',name=match[1],action='exclude_from_blorp_spelling_migration'))
        for match in re.finditer(r'\benum\s*\{[^}]+\}',text):
            native.append(dict(path=relative,line=text.count('\n',0,match.start())+1,
                kind='python_embedded_native_c',name='(anonymous)',action='exclude_from_blorp_spelling_migration'))
summary['native_constructs']=dict(collections.Counter(row['kind'] for row in native))
summary['native_word_lines_not_constructs']=summary['counts'].pop('native_c_enum_construct')
for row in records:
    if row['category']=='native_c_enum_construct': row['category']='native_c_enum_word_line'
    context='global'
    if row['path'].endswith('.brp'):
        for line in (ROOT/row['path']).read_text().splitlines()[:row['line']]:
            match=re.match(r'^(?:private )?(?:pure )?func (\w+)',line)
            if match: context=match[1]
    row['context']=context
    if row['category']=='embedded_declaration':
        if row['declaration']=='PlainSyntaxCode':
            row['role']='source_scanner_header_must_change_with_authority'
        elif re.search(r'reject|invalid|missing|malformed|unsupported|diagnostics',context):
            row['role']='intentional_rejected_or_unsupported_input_manual'
        elif '/format/' in row['path']:
            row['role']='expected_formatter_output_manual'
        else: row['role']='positive_embedded_blorp_migrate_with_assertions'
    elif row['category']=='source_declaration':
        row['role']='negative_fixture_program_manual' if '/should_fail/' in row['path'] else 'authored_blorp_declaration'
    else: row['role']='reference_not_declaration'
summary['embedded_roles']=dict(collections.Counter(row['role'] for row in declarations if row['category']=='embedded_declaration'))
baseline_sources=[]; baseline_raw=0
archive=tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['git','archive',BASE],cwd=ROOT)))
for member in archive:
    relative=member.name
    if not member.isfile() or not relative.endswith('.brp') or relative.startswith('benchmarks/results/'): continue
    text=archive.extractfile(member).read().decode()
    baseline_raw+=len(re.findall(r'^\s*(?:private\s+)?enum\s+',text,re.M))
    for line_no,region,chunk in brp_regions(text):
        if region=='code' and re.match(r'^\s*(?:private\s+)?enum\s+\w+',chunk):
            baseline_sources.append((relative,line_no,chunk.strip()))
production=lambda path:path.startswith(('blorp/src/','standard_library/','pkg/','examples/'))
summary['declaration_controls']=dict(baseline_exact=len(baseline_sources),candidate_exact=len([r for r in declarations if r['category']=='source_declaration']),
    baseline_raw_anchored=baseline_raw,candidate_raw_anchored=sum(len(re.findall(r'^\s*(?:private\s+)?enum\s+', (ROOT/path).read_text(), re.M)) for path in files if path.endswith('.brp') and (ROOT/path).is_file() and not path.startswith('benchmarks/results/')),
    production_baseline_exact=sum(production(r[0]) for r in baseline_sources),
    production_candidate_exact=sum(r['category']=='source_declaration' and production(r['path']) for r in declarations),
    known_anchored_prose_false_positive='blorp/src/compiler/stage_06_typecheck/type_system/builtins.brp:1110')
summary['fixed_direct_string_locations']=[dict(path=r['path'],line=r['line'],name=r['declaration']) for r in fixed if r['direct_string']]
summary['source_content_sha256']=hashlib.sha256('\n'.join(relative+' '+hashlib.sha256((ROOT/relative).read_bytes()).hexdigest() for relative in files if (ROOT/relative).is_file() and not relative.startswith('benchmarks/results/')).encode()).hexdigest()
payload=dict(summary=summary,declarations=declarations,references=records,fixed_examples=fixed,native_declarations=native)
(OUT/'inventory.json').write_text(json.dumps(payload,indent=2)+'\n')
for name, rows in [('inventory.tsv',records),('declarations.tsv',declarations)]:
    with (OUT/name).open('w',newline='') as stream:
        fields=['path','line','owner','category','declaration','action','role','context']
        if name=='inventory.tsv': fields.append('text')
        writer=csv.DictWriter(stream,fieldnames=fields,delimiter='\t',extrasaction='ignore',lineterminator='\n')
        writer.writeheader(); writer.writerows(rows)
print(json.dumps(summary,indent=2))
