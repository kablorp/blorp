#!/usr/bin/env python3
"""Verify sealed baseline products; never require live pre-edit source/bin freshness."""
from pathlib import Path
import hashlib
import json
import seal_reused_baseline as seal

OUT = Path(__file__).resolve().parent
PROOF_SHA = '3cd26b9a7a8bf551c973c4f02007d464b146fce9d2cfc674ab1ad6debf6a0109'
GENERATOR_PROOF_SHA = 'be0b2a6b79ee779a6211ee17adae50deebaa918604844a5f33fc02476189ba90'


def verify():
    seal.require(seal.sha(OUT / 'BASELINE_READY.json') == PROOF_SHA, 'Baseline reuse proof changed.')
    proof = json.loads((OUT / 'BASELINE_READY.json').read_text())
    for name, expected in proof['file_pins'].items():
        seal.require(seal.sha(OUT / name) == expected, 'Sealed new baseline payload changed: ' + name)
    old_pins = json.loads((OUT / 'prior-authority-file-pins.json').read_text())
    for name, expected in old_pins.items():
        seal.require(seal.sha(name) == expected, 'Referenced prior authority changed: ' + name)
    seal.require(seal.sha(OUT / 'GENERATOR_RETAINED.json') == GENERATOR_PROOF_SHA, 'Generator retention proof changed.')
    generator = json.loads((OUT / 'GENERATOR_RETAINED.json').read_text())
    seal.require(seal.sha(generator['retained_path']) == generator['retained_sha256'], 'Retained owned baseline generator changed.')
    for item in proof['pairs'].values():
        seal.require(seal.sha(item['path']) == item['sha256'], 'Reused baseline paired binary changed.')
    frozen = seal.check_frozen({'frozen_input': proof['frozen_input']})
    seal.require(frozen == proof['frozen_input'], 'Canonical frozen input proof changed.')
    # Immutable git objects remain authority even after the candidate changes live source.
    old_prepared = json.loads((seal.OLD / 'prepared.json').read_text())
    archive = seal.git('archive', proof['revision'], *proof['production_paths'])
    seal.require(hashlib.sha256(archive).hexdigest() == old_prepared['production_archive_sha256'], 'Original committed production authority changed.')
    return proof


if __name__ == '__main__':
    proof = verify()
    print(json.dumps({'status': 'SEALED_BASELINE_PASS', 'proof_sha256': PROOF_SHA,
                      'live_pre_edit_source_or_binary_required': False,
                      'normal_sha256': proof['pairs']['normal']['sha256'],
                      'diagnostic_sha256': proof['pairs']['diagnostic']['sha256']}))
