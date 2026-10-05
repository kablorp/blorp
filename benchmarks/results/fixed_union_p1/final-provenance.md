# Final provenance capture

Baseline:

```text
FRESH: bin/blorp matches current compiler build inputs
Build plan: 8-way split, 8 per-TU objects
blorp 0.0.1
commit: 133eaf73a638-dirty
target: aarch64-apple-darwin
channel: local
dirty: true
compiled_by: dev-d44472d3a5d0
optimization: cli=-O2 runtime=-O2
split: 8
cc: Apple clang version 21.0.0 (clang-2100.3.34.2)
memory_diagnostics: 0


29f646a02726705420cce82ac5d5c7282a50967667628fb4ec69c5f3097bba4c  bin/blorp
cea32dbc0db4d25d90f0bc36e9163964b688ef20586f07454e1dda926711715f  bin/blorp-stage2
f4e9ab52459da9545e1c2161651a6485acf22e19d8994a17edd3c44695f48897  bin/blorp-stage2-diagnostic
 M docs/README.md
?? docs/FIXED_UNION_ROADMAP.md
```

Candidate and fixpoint stage 3:

```text
FRESH: bin/blorp matches current compiler build inputs
Build plan: 8-way split, 8 per-TU objects
blorp 0.0.1
commit: 133eaf73a638-dirty
target: aarch64-apple-darwin
channel: local
dirty: true
compiled_by: dev-d44472d3a5d0
optimization: cli=-O2 runtime=-O2
split: 8
cc: Apple clang version 21.0.0 (clang-2100.3.34.2)
memory_diagnostics: 0


d107945c079c76cf57f8b12baa0d7b57295b615be6737c67c37b97ef17abff0a  bin/blorp
b2e20fe4b75c40e17244dece73a8837a6ac772c9462a3a2a64cc5376cfcd4eef  bin/blorp-stage2
8798e29b713b0204e6d444f93768c21805f8a50099f3bebd70027272fac66931  bin/blorp-stage2-diagnostic
blorp 0.0.1
commit: 133eaf73a638-dirty
target: aarch64-apple-darwin
channel: local
dirty: true
compiled_by: self-133eaf73a638
optimization: cli=-O2 runtime=-O2
split: 8
cc: Apple clang version 21.0.0 (clang-2100.3.34.2)
memory_diagnostics: 0


8ca7411914f20a815e11132f035eb8bb2a9a33201f4b8bfce5eefc424253fc27  /tmp/blorp-fixed-union-stage2.5qu3A2/fixpoint/stage1_output.c
8ca7411914f20a815e11132f035eb8bb2a9a33201f4b8bfce5eefc424253fc27  /tmp/blorp-fixed-union-stage2.5qu3A2/fixpoint/stage2_output.c
8ca7411914f20a815e11132f035eb8bb2a9a33201f4b8bfce5eefc424253fc27  /tmp/blorp-fixed-union-stage2.5qu3A2/fixpoint/stage3_output.c
```
