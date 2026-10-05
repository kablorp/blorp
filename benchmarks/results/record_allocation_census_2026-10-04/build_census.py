"""Use repository-owned stage-2 compile/link extraction, without regeneration."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess

repo = Path('/Users/keithphilpott/.codex/worktrees/record-spelling-verification/blorp')
scratch = Path('/tmp/blorp-record-s5.hzyXge')
os.environ['BLORP_CLI_C_OPTIMIZATION'] = '-O2'
loader = importlib.machinery.SourceFileLoader('stage2_recipe', str(repo / 'benchmarks/build_stage2_compiler'))
spec = importlib.util.spec_from_loader(loader.name, loader)
recipe = importlib.util.module_from_spec(spec)
loader.exec_module(recipe)
recipe.prepare_runtime(1)
text = recipe.make_recipe('compile-prepared-blorp-cli', 1)
obj = scratch / 'compiler.instrumented.o'
binary = scratch / 'compiler.instrumented'
compile_command = recipe.extract_compile_command(text, scratch / 'compiler.instrumented.c', obj)
link_command = recipe.extract_link_command(text, obj, binary)
runtime = recipe.runtime_object_from_recipe(text)
metadata = {'compile': compile_command, 'link': link_command, 'runtime_path': str(runtime), 'runtime_sha256': recipe.sha256_file(runtime), 'normal_body_sha256': recipe.sha256_file(scratch / 'compiler.normal.c'), 'retained_stage2_body_sha256': recipe.sha256_file(repo / 'blorp/build/_build/blorp-cli/stage2_main.c'), 'retained_stage2_binary_sha256': recipe.sha256_file(repo / 'bin/blorp-stage2-diagnostic'), 'generator_sha256': recipe.sha256_file(repo / 'bin/blorp'), 'input_rev': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()}
(scratch / 'build.commands.json').write_text(json.dumps(metadata, indent=2) + '\n')
for label, command in [('COMPILE', compile_command), ('LINK', link_command)]:
    print(label, json.dumps(command), flush=True)
    subprocess.run(command, cwd=repo, check=True)
metadata['binary_sha256'] = recipe.sha256_file(binary)
metadata['instrumented_body_sha256'] = recipe.sha256_file(scratch / 'compiler.instrumented.c')
(scratch / 'build.commands.json').write_text(json.dumps(metadata, indent=2) + '\n')
