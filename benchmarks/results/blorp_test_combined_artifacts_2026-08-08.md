# Blorp Test Combined-Artifact Measurements

Recorded on local macOS on 2026-08-08. Build setup was unchanged and excluded
from both sides of each comparison.

| Workload | Before | After |
|---|---:|---:|
| 37 runtime sources | 61.2 seconds / 3.44 GB peak RSS | 15.5 seconds / 600 MB peak RSS |
| 1,053 standard-library doctests | 81 seconds / 5.42 GB peak RSS | 13 seconds / 1.18 GB peak RSS |

The change compiled compatible TestSuite roots or doctest runners into one
direct aggregate harness per frontend partition. These values are historical
evidence, not a current performance baseline. Reproduce current measurements
with the registered workloads in `scripts/bench-blorp-test-session` on one host
and compiler fingerprint.
