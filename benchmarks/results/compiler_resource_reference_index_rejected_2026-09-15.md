# Resource-Reference Membership Index: Rejected

Issue 104 tested switching ordered resource-reference admission from list scans
to a membership set whenever `extra.length() >= 16`. Candidate commit
`e1e2f0528a9b03242efba7edbd8b248534294ae3` was based on
`9ecb72e934c42f730fe15b5f3f05ee62a76db5f6`. No candidate code was merged.

## Decision

Reject the threshold. It substantially helps a wide `64 + 512` merge, but
severely regresses the plausible compiler shape where a large accumulated
`refs` list receives a small `extra` list. A guard based only on `extra` width
cannot distinguish those cases.

Three paired runs used the exact production scan/set bodies with construction
outside the measured loop:

| Shape | Iterations | Scan to set elapsed | Scan to set instructions | Allocations/call |
| --- | ---: | ---: | ---: | ---: |
| narrow 4+8 | 100,000 | 33,849 to 52,753 us | 685M to 1,286M | 2 to 3 |
| threshold 64+16 distinct | 20,000 | 58,001 to 55,659 us | 1,240M to 1,284M | 1 to 2 |
| all duplicate 16+128 | 20,000 | 67,652 to 28,695 us | 1,246M to 665M | 0 to 1 |
| wide mixed 64+512 | 1,000 | 131,525 to 15,859 us | 2,792M to 348M | 3 to 4 |
| 4096+16 early duplicates | 2,000 | 835 to 283,865 us | 74.6M to 5,676M | 0 to 1 |
| 4096+16 distinct | 500 | 66,111 to 78,080 us | 1,293M to 1,550M | 1 to 2 |

The wide mixed case improved instructions by 87.6% and elapsed by 87.9%.
However, the production guard also selected the set for both `4096 + 16`
cases. Early duplicates regressed instructions by 7,512% and elapsed by
33,896%; distinct inputs regressed instructions by 19.9%, elapsed by 18.1%,
and doubled allocations. The nominal `64 + 16` boundary also increased
instructions 3.6% and doubled allocations.

## Correctness and validation

The algorithm preserved existing base duplicates and order, first occurrence
among `extra`, and output construction independent of set iteration. Eight
independent output checks matched, including
`["keep", "keep", "x"] + ["keep", "new", "new"]`. A representative resource
fixture produced byte-identical C (SHA-256 beginning `56b4689d`).

The candidate was fresh and passed the focused inference suite (320/320), the
typecheck stage (38/38 suites and 2/2 checks, including leak), and
`compiler-blorp` (4,556/4,556). Raw paired samples were written under
`/private/tmp/issue104independent/raw3`; their manifest SHA-256 began
`aedea2d9`. Those temporary paths are recorded as audit context, not claimed
as durable artifacts.

## Follow-up boundary

First measure the production distribution of `(refs width, extra width,
duplicate density and placement)`. Any retry must account for both widths,
exercise the actual hybrid and its threshold boundaries, retain pre-existing
base duplicates and exact order tests, and report durable paired allocations,
retired instructions, and elapsed samples. A one-shot always-scan versus
always-set model is not sufficient acceptance evidence.
