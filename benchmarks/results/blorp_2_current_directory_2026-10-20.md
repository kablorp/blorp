# Current-directory failure propagation

Loader failures now produce compiler-origin 0..0 diagnostics before path, identity or file work.
Production +14/-2; tests +33/-2. Prior 33 cases and three effective fault/restores are retained.
Fixed B: 34188ccd. C changes only the loader; same library12 and preserved O2/STD91 roles.
Construction: +0.051171% allocations and +0.099296% normal min3 instructions; all four controls pass.
All 48 calls pass once: components 3635/0; native 1151/0 and 416 cost rows; strict zero/C identity pass.
Relative-path CLI checks in ASCII/UTF8-space CWDs pass; 1322 guards close; B41+library12 restored.
Err tests supply Result data, not an OS fault. Inner native artifacts are temporary; no self-compile claim.
[Raw receipt, exact roles, metrics and limits](../../build/bootstrap-evidence/self-compile-leader-2026-10-19/source-current-directory-cost01/execution01/RECEIPT.json).
