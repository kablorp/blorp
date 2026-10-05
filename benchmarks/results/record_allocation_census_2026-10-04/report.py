import hashlib
import json
import re
from pathlib import Path

root = Path('/tmp/blorp-record-s5.hzyXge')
mapping = json.loads((root / 'compiler.mapping.json').read_text())
observed = {}
text = (root / 'self.instrumented.census').read_text()
for match in re.finditer(r'^S5_SITE site=(\d+) count=(\d+) requested_bytes=(\d+) type=(.*)$', text, re.M):
    site = int(match[1])
    assert site not in observed
    observed[site] = (int(match[2]), int(match[3]))
total = re.search(r'^S5_TOTAL direct_alloc_calls=(\d+) record_maker_allocations=(\d+) managed_allocations=(\d+) boundary=process_destructor$', text, re.M)
assert total
records = []
for site in mapping['sites']:
    if site['classification'] == 'managed_record_maker':
        count, requested = observed.get(site['site'], (0, 0))
        records.append({**site, 'count': count, 'requested_bytes': requested})
assert len(records) == mapping['record_makers']
direct, allocated_records, managed = map(int, total.groups())
assert sum(count for count, _ in observed.values()) == direct
assert sum(row['count'] for row in records) == allocated_records
screen_names = ['TupleBinderMint', 'CoreSsaFreshVar', 'CoreParallelFreshVar', 'CanonicalModuleTypeNameSplit', 'KeepsBoxAnswer', 'LocalFactsAnswer', 'PlacedChild', 'PlacedSubtree', 'MemoizedTypeShapeCheck']
screened = {name: [row for row in records if row['record'] == name or row['record'].endswith('__' + name)] for name in screen_names}
checkpoints = re.findall(r'^BLORP_COMPILER_MEMORY_CHECKPOINT .*$', text, re.M)
summary = {'boundary': 'process destructor after self-compile; not phase-local', 'direct_body_allocations': direct, 'record_maker_allocations': allocated_records, 'global_managed_allocations': managed, 'external_runtime_or_other_residual': managed - direct, 'record_fraction_of_global_endpoint': allocated_records / managed, 'record_fraction_of_instrumented_body_calls': allocated_records / direct, 'maker_catalog_count': len(records), 'executed_maker_count': sum(row['count'] > 0 for row in records), 'top15_by_count': sorted(records, key=lambda row: row['count'], reverse=True)[:15], 'top15_by_requested_bytes': sorted(records, key=lambda row: row['requested_bytes'], reverse=True)[:15], 'screened': screened, 'checkpoints': checkpoints}
(root / 'ranking.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps({key: summary[key] for key in ['direct_body_allocations', 'record_maker_allocations', 'global_managed_allocations', 'external_runtime_or_other_residual', 'record_fraction_of_global_endpoint', 'executed_maker_count']}, indent=2))
for row in summary['top15_by_count']:
    print(row['record'], row['count'], row['requested_bytes'])
print('SCREENED')
for name, rows in screened.items():
    print(name, [(row['record'], row['count'], row['requested_bytes']) for row in rows])
