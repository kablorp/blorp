from pathlib import Path
root = Path('/tmp/blorp-record-s5.hzyXge')
source = (root / 'oracle.instrumented.c').read_text()
assert source.count('int main(int argc, char** argv) {') == 1
source = source.replace('int main(int argc, char** argv) {', 'int s5_original_main(int argc, char** argv) {')
(root / 'mechanics.c').write_text(source + '\n' + (root / 'mechanics_tail.c').read_text())
