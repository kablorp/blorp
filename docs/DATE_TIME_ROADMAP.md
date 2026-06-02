# Date And Time Roadmap

Last updated: 2026-06-02

Status: Phase 0 baseline complete, with implementation progress through the
Phase 4 scope.

Blorp currently has a small UTC/POSIX-time surface: timestamps are raw `Int`
values containing microseconds since the POSIX epoch, extraction is UTC, and
formatting/parsing is backed by C/POSIX helpers. That is a reasonable preview
starting point, but date and time APIs are easy to make accidentally broad,
ambiguous, or platform-dependent.

The goal of this roadmap is to keep Blorp's date/time design safe,
understandable, and explicit:

```text
An instant is not a local date. A duration is not a calendar period. A fixed
offset is not a time zone. A POSIX timestamp is not full ISO 8601 support.
```

## Standards Scope

Primary references:

- POSIX.1-2024 Base Definitions, "Seconds Since the Epoch":
  https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap04.html
- POSIX.1-2024 `clock_gettime`:
  https://pubs.opengroup.org/onlinepubs/9799919799/functions/clock_gettime.html
- POSIX.1-2024 `strftime`:
  https://pubs.opengroup.org/onlinepubs/9799919799/functions/strftime.html
- POSIX.1-2024 `strptime`:
  https://pubs.opengroup.org/onlinepubs/9799919799/functions/strptime.html
- RFC 3339, "Date and Time on the Internet":
  https://www.rfc-editor.org/rfc/rfc3339
- ISO 8601 overview and catalog:
  https://www.iso.org/iso-8601-date-and-time-format.html

### POSIX Policy

Blorp should support POSIX timestamp interop explicitly:

- Store instants as signed microseconds since `1970-01-01T00:00:00Z`.
- Treat each POSIX day as exactly 86400 seconds.
- Do not model leap seconds in the timestamp arithmetic.
- Document that the POSIX timestamp relationship to astronomical UTC during
  leap seconds is outside the language's guarantee.
- Support negative timestamps intentionally or reject them intentionally. Do not
  leave pre-epoch behavior as a C implementation accident.

### RFC 3339 Policy

RFC 3339 should be the first strict interchange format:

- Accept complete date-time strings with `T` or `t`.
- Require either `Z`/`z` or a numeric offset for date-time parsing.
- Support fractional seconds with a documented precision policy.
- Validate the actual Gregorian date, not only numeric field ranges.
- Consume the whole input.
- Reject malformed offsets and offset ranges outside the standard grammar.
- Treat `-00:00` deliberately. If the result type is only `Instant`, reject it
  or document that the unknown-local-offset signal is discarded.

### ISO 8601 Policy

Blorp should not claim full ISO 8601 support until it supports the specific ISO
forms it names. ISO 8601 is a family of representations, not one parser.

Support should be split into named functions:

- Calendar date: `YYYY-MM-DD`.
- RFC 3339 date-time: `YYYY-MM-DDTHH:MM:SS[.frac](Z|+HH:MM|-HH:MM)`.
- Optional later ISO forms: ordinal dates, week dates, durations, intervals,
  and repeating intervals.

## Current Implementation

Current source surface:

- `std/time.brp` still supports raw `Int` POSIX microsecond helpers for
  low-level interop.
- `time.Instant` is a stack `struct` wrapper around POSIX microseconds for new
  instant-oriented APIs.
- `std/units.brp` exposes `Duration` as an opaque `Int`-backed type with
  `microseconds(...)` and `to_microseconds(...)` boundary helpers.
- `std/instrumentation.brp` returns typed `Duration` values for measured
  elapsed time while still exposing raw microsecond subtraction at the
  monotonic-clock boundary.
- `benchmarks/blorp/support/benchmark.brp` uses typed `Duration` results and
  stack `struct` result carriers. Raw microsecond counts remain only at text
  protocol and clock-reading boundaries.
- `time.now()` returns wall-clock `CLOCK_REALTIME` microseconds.
- `time.now_instant()` returns wall-clock `CLOCK_REALTIME` as an `Instant`.
- `system.now_microseconds()` returns monotonic `CLOCK_MONOTONIC`
  microseconds for measurement.
- `from_parts`, `to_year`, `to_month`, `to_day`, `to_hour`, `to_minute`,
  `to_second`, and `to_weekday` operate in UTC.
- `try_from_parts` validates Gregorian date-time fields and returns
  `Option[Int]`.
- `format_time` and `parse_time` delegate to C/POSIX `strftime` and
  `strptime`; `parse_time` rejects normalized overflow results.
- `to_iso` formats whole-second UTC strings.
- `from_iso` parses either an ISO calendar date or a strict RFC3339 date-time
  into raw POSIX microseconds.
- `parse_rfc3339` parses strict RFC3339 date-times into `Option[Instant]`.
- `format_rfc3339` formats an `Instant` in UTC and preserves nonzero
  microseconds.
- `std/time.brp` still exposes raw integer duration helpers such as `seconds`,
  `days`, and `weeks` for compatibility.

Current tests cover:

- UTC extraction for a known POSIX timestamp.
- `from_parts` round trip for one valid timestamp.
- basic `format_time` and `parse_time`;
- embedded-NUL rejection for `format_time` and `parse_time`;
- `now()` nondecreasing in a two-call sample;
- basic duration arithmetic;
- basic `to_iso`;
- `from_iso` UTC, date-only, positive offset, negative offset, fractional
  seconds, invalid month, empty input, and round trip for whole seconds.
- strict `from_iso`/`parse_rfc3339` rejection for invalid dates, unknown zone
  markers, trailing junk, malformed offsets, empty fractions, missing offsets,
  leap seconds, and `-00:00`;
- RFC3339 offset boundaries including `+00:00`, `-00:00`, `+14:00`,
  `-12:00`, missing colons, out-of-range hours, and out-of-range minutes;
- lowercase `t`/`z` acceptance for RFC3339 input;
- fractional seconds at microsecond precision, including truncation after six
  digits and negative subsecond formatting;
- negative subsecond POSIX conversion around the epoch;
- `from_parts` normalization behavior for invalid fields, plus
  `try_from_parts` invalid/leap-day behavior;
- Gregorian leap-century rules for 1900, 2000, and 2100;
- `parse_time` rejection for invalid numeric calendar dates, time-field
  overflow, trailing input, and embedded NULs;
- typed `Instant`/`Duration` constructor and arithmetic wrappers.
- generated-C audit coverage for the POSIX/RFC3339 runtime helper boundary.

## Resolved Initial Gaps

The following behavior was confirmed by temporary runtime probes and now has
regression coverage:

- invalid calendar dates in `from_iso` now return `None`;
- unknown zone markers and trailing junk now return `None`;
- malformed offset digits now return `None`;
- empty fractional seconds now return `None`;
- strict `parse_rfc3339` rejects date-only strings and date-times without an
  offset;
- strict `parse_rfc3339` rejects leap second `60` and `-00:00` when returning
  only `Instant`;
- `format_rfc3339` preserves nonzero microseconds;
- `to_iso(-1)`, `to_unix_seconds(-1)`, and `to_unix_millis(-1)` use POSIX
  floor semantics before the epoch.
- `parse_time` now rejects invalid numeric Gregorian dates before accepting
  `strptime` results that a host C library normalized internally.

Other implementation gaps:

- `from_parts` remains infallible and normalizes invalid fields through
  `timegm`; use `try_from_parts` when invalid civil fields should remain
  explicit.
- `days_in_month` and `month_name` map invalid months to December-like
  behavior instead of making invalid input explicit.
- `format_time` has a fixed 256-byte output buffer and returns an empty string
  on both invalid input and valid empty output.
- `parse_time` inherits locale and platform behavior from `strptime`.
- POSIX/C helpers such as `timegm` and `strptime` are not ISO C and are not
  uniformly portable.
- Lower-level reactor waits use `CLOCK_REALTIME` absolute deadlines for
  `pthread_cond_timedwait`, so wall-clock jumps can affect some waits even
  though fiber timers use monotonic deadlines.
- There is no typed distinction between instants, durations, dates, local
  times, offset date-times, and time zones.
- There is no IANA time-zone database, daylight-saving transition model, local
  civil-time disambiguation, or locale-aware formatting.

## Design Principles

- Keep the initial API intentionally narrow. Prefer correct POSIX/RFC3339
  behavior over broad ISO claims.
- Make invalid civil dates explicit with `Option` or `Result`; do not silently
  normalize unless the function name says so.
- Separate wall-clock instants from monotonic measurement time.
- Separate exact durations from calendar periods. `24 hours` and `1 calendar
  day` are not always the same once time zones enter the model.
- Avoid hidden local time. UTC should be the default for timestamp extraction
  and formatting.
- Avoid locale dependence in core std APIs. Locale-aware formatting can be a
  later package or explicitly named surface.
- Use typed wrappers where they prevent common mistakes, especially around raw
  `Int` timestamp/duration mixing.
- Use opaque/newtype-style wrappers for single-field semantic values when the
  language supports them. Use `struct` for wrappers that need a field-level API
  or for compound values.
- Use `struct`, not heap `record`, for benchmark result carriers and other
  short-lived measurement values.
- Preserve Blorp's no-panic principle. Fallible parsing and invalid civil-time
  construction should return `Option` or `Result`.
- Do not rely on C library normalization when correctness depends on calendar
  validity. Validate in Blorp/runtime code with explicit rules.
- Keep full time-zone support deferred until the model and data source are
  explicit.

## Proposed Type Model

Start with stack/value types. Single-field values should use opaque/newtype
wrappers when practical; compound values should use `struct`. Do not use heap
`record` values for ordinary instants, durations, dates, local times, or fixed
offsets.

Do not add resources or services until time zones or a tzdb provider require
them.

```blorp
struct Instant {
	microseconds_since_posix_epoch: Int
}

opaque type Duration = Int

struct LocalDate {
	year: Int
	month: Int
	day: Int
}

struct LocalTime {
	hour: Int
	minute: Int
	second: Int
	microsecond: Int
}

struct LocalDateTime {
	date: LocalDate
	time: LocalTime
}

struct UtcOffset {
	seconds: Int
}

struct OffsetDateTime {
	local: LocalDateTime
	offset: UtcOffset
}
```

Possible enums:

```blorp
union Weekday {
	Sunday
	Monday
	Tuesday
	Wednesday
	Thursday
	Friday
	Saturday
}

union Month {
	January
	February
	March
	April
	May
	June
	July
	August
	September
	October
	November
	December
}
```

Keep these optional until the ergonomics are clear. Integer month/weekday
functions can remain, but invalid values should not collapse to a valid name.

## Phase 0: Conformance Baseline

Goal: freeze current behavior with tests before changing it.

Progress: complete for the Phase 0 scope. Focused runtime tests now cover the
strict parser, POSIX edge cases, calendar validation, leap-century rules,
date-only versus RFC3339 date-time behavior, fractional-second policy, and
typed instant/duration wrappers. A generated-C audit pins the runtime helper
boundary for POSIX/RFC3339 parsing.

Completed work items:

- Added focused runtime tests for the confirmed `from_iso` permissiveness cases.
- Added tests for invalid calendar dates in `from_parts`, `from_iso`, and
  `parse_time`.
- Added tests for fractional-second round-trip and truncation expectations.
- Added tests for negative POSIX timestamps, especially subsecond values before
  the epoch.
- Added tests for Gregorian leap-year rules: 1900, 2000, 2100, and February 29.
- Added tests for offset boundaries: `+00:00`, `-00:00`, `+14:00`, `-12:00`,
  malformed digits, missing colon, and out-of-range minutes.
- Added tests that clarify date-only parsing is an ISO calendar-date helper, not
  RFC3339 date-time parsing.
- Added generated-C audit coverage for runtime time helper portability where
  practical.

Acceptance: met.

- The current gaps are reproducible as failing or pinned tests before fixes.
- Each intended behavior change has a test that fails before the change.
- The test names describe standards behavior, not only implementation details.

Suggested test files:

- `tests/test_blorp/sys/test_time_iso_strictness.brp`
- `tests/test_blorp/sys/test_time_posix_edges.brp`
- `tests/test_blorp/sys/test_time_calendar_validation.brp`
- `tests/test_blorp/types/test_time_instant_duration.brp`
- `tests/test_compiler/codegen_audit/should_pass/time_runtime_helpers.brp`

## Phase 1: Clarify The Current Contract

Goal: remove misleading claims without changing broad API shape yet.

Progress: `std/time.brp`, `std/units.brp`, this roadmap, and `docs/GUIDE.md`
now describe POSIX microseconds, UTC, strict RFC3339, wall-clock versus
monotonic clocks, and typed `Duration` spelling.

Work items:

- Update `std/time.brp` docs to say "POSIX microsecond timestamps, UTC only".
- Rename documentation wording from broad ISO parsing claims to explicit
  calendar-date and RFC3339 date-time wording.
- Document that `to_iso` emits whole-second UTC only.
- Document that `format_time` and `parse_time` are POSIX/C-library formatting
  helpers with locale/platform caveats.
- Document `time.now()` as wall-clock and `system.now_microseconds()` as
  monotonic.
- Update `docs/GUIDE.md` with a small "Date And Time" section that separates
  instants, durations, local dates, and timeouts.

Acceptance:

- No public docs claim full ISO 8601 support.
- The guide tells users which clock to use for dates and which to use for
  elapsed time.
- Existing behavior remains source-compatible except for documentation.

## Phase 2: Strict RFC3339 And Calendar-Date Parsing

Goal: make the first interchange parser correct and intentionally named.

Progress: `parse_rfc3339(s: String) -> Option[Instant]` and
`format_rfc3339(t: Instant) -> String` exist. `from_iso` now accepts date-only
calendar strings for compatibility and strict RFC3339 date-times otherwise.
The parser validates Gregorian dates, time fields, offsets, full consumption,
nonempty fractional seconds, leap-second rejection, and `-00:00` rejection.

Work items:

- Add a hand-rolled parser or table-driven parser for RFC3339 date-times.
- Validate the full Gregorian date.
- Validate hour, minute, second, fractional second, and offset ranges.
- Require full input consumption.
- Require an offset for RFC3339 date-times.
- Support `Z` and numeric offsets.
- Decide whether lowercase `t` and `z` are accepted; RFC 3339 allows grammar
  notes around case, but generated code may benefit from one canonical output.
- Reject leap second `60` initially, or support it with a documented POSIX
  mapping. Rejection is simpler and consistent with POSIX timestamp arithmetic.
- Reject `-00:00` when returning only `Instant`, or introduce an
  `OffsetDateTime` parser that can preserve unknown offset semantics.
- Add `parse_calendar_date(s: String) -> Option[LocalDate]` or a temporary
  `parse_iso_date(s: String) -> Option[Int]` if the type model has not landed.
- Keep `from_iso` as a compatibility alias only if it points to the new strict
  behavior. Since Blorp is pre-0.1, prefer renaming over preserving confusing
  behavior.

Candidate names:

- `parse_rfc3339(s: String) -> Option[Instant]`
- `format_rfc3339(t: Instant) -> String`
- `parse_iso_date(s: String) -> Option[LocalDate]`
- `format_iso_date(date: LocalDate) -> String`

Acceptance:

- All invalid probe cases return `None`.
- Valid RFC3339 timestamps with offsets normalize to the same `Instant`.
- Fractional seconds round-trip according to the chosen precision policy.
- Date-only strings are accepted only by the calendar-date parser, not the
  RFC3339 date-time parser.
- Parser code does not call `timegm` until after fields have been validated.

## Phase 3: Correct POSIX Timestamp Arithmetic

Goal: make raw timestamp conversion precise and portable enough for pre-epoch
and far-future values.

Progress: microsecond-to-second conversion now floors for negative
timestamps, and raw Unix second/millisecond conversion follows the same
pre-epoch floor semantics. Overflow/range policy and direct portable Gregorian
conversion remain open.

Work items:

- Replace C truncating division in microsecond-to-second conversion with
  floor division for negative timestamps.
- Preserve subsecond remainder for formatters that need microseconds.
- Add explicit overflow handling for `seconds * 1000000 + micros`.
- Decide and document the valid timestamp range for 64-bit `Int`
  microseconds.
- Audit `to_unix_seconds`, `to_unix_millis`, and the inverse helpers for
  negative values and overflow semantics.
- Add checked constructors if direct multiplication would silently wrap in
  surprising ways.
- Consider implementing Gregorian date conversion directly instead of relying
  on `timegm`/`gmtime_r` for all platforms.

Acceptance:

- `to_iso(-1)` produces the expected pre-epoch second if negative timestamps
  are supported.
- Conversion tests pass for values around epoch, leap days, 1900/2000/2100,
  2038, and large positive values within the documented range.
- Runtime conversion behavior is independent of host local time zone.

## Phase 4: Typed Instants And Durations

Goal: stop accidental mixing of timestamps, durations, milliseconds, and raw
integers in new APIs.

Progress: `Instant` is a stack `struct`; `Duration` is an opaque `Int`-backed
microsecond value; `std/time.brp` exposes typed constructors and arithmetic
wrappers for instant/duration interop. Timeout lowering now converts the
typed duration's microsecond backing. Instrumentation and benchmark helpers
now return typed `Duration` values, and benchmark result carriers are stack
`struct`s instead of heap records.

Work items:

- Introduce `Instant` as a small value wrapper over POSIX microseconds.
- Move or re-export `Duration` so date/time and timeout APIs can share one
  canonical duration type.
- Add constructors:
  - `instant_from_posix_microseconds(microseconds: Int) -> Instant`
  - `instant_to_posix_microseconds(t: Instant) -> Int`
  - `instant_from_unix_seconds(s: Int) -> Instant`
  - `instant_to_unix_seconds(t: Instant) -> Int`
  - `duration_from_microseconds(microseconds: Int) -> Duration`
  - `duration_to_microseconds(d: Duration) -> Int`
- Add arithmetic:
  - `add_duration(t: Instant, d: Duration) -> Instant`
  - `subtract_duration(t: Instant, d: Duration) -> Instant`
  - `duration_between(a: Instant, b: Instant) -> Duration`
- Keep raw `Int` compatibility functions temporarily, but mark them in docs as
  low-level POSIX interop.
- Update `std/log.brp`, `std/rate_limit.brp`, `std/instrumentation.brp`, and
  timeout wrappers where typed values improve clarity.
- Update benchmark helpers to return `Duration` and use raw microseconds only
  when reading clocks, computing derived rates, or emitting existing text
  protocol fields.

Acceptance:

- New APIs do not take raw `Int` when the value is semantically an instant or a
  duration.
- Existing timeout APIs still accept raw milliseconds where that is part of the
  current language surface, but typed `Duration` is preferred in docs.
- Benchmark elapsed values are typed `Duration`; raw `microseconds` appears
  only at explicit interop boundaries.
- Tests prove UFCS works for typed instant and duration helpers.

## Phase 5: Local Date And Time Values

Goal: support civil-date operations without pretending they are instants.

Work items:

- Add `LocalDate`, `LocalTime`, and `LocalDateTime`.
- Add checked constructors returning `Option`.
- Add infallible clamping/normalizing functions only with explicit names such
  as `clamp_day` or `normalize_date_time`.
- Add extraction from UTC instants:
  - `instant.to_utc_date_time() -> LocalDateTime`
  - `utc_date_time_to_instant(local: LocalDateTime) -> Option[Instant]`
- Add date-only arithmetic:
  - `date.add_days(n)`
  - `date.add_months_clamped(n)`
  - `date.add_years_clamped(n)`
  - `date.days_until(other)`
- Keep duration arithmetic separate:
  - adding `Duration` to `Instant` is exact elapsed time;
  - adding calendar months to `LocalDate` is calendar arithmetic.
- Replace `days_in_month(year, month) -> Int` with a checked shape:
  - `days_in_month(year, month) -> Option[Int]`, or
  - `Month` enum input.
- Replace `month_name(Int)` and `weekday_name(Int)` fallthrough behavior with
  checked functions or enum-based names.

Acceptance:

- Invalid dates cannot be constructed accidentally through the checked API.
- Month/year arithmetic around end-of-month is explicitly clamped or explicitly
  rejected.
- Calendar tests cover leap years, month boundaries, and negative additions.

## Phase 6: Formatting And Parsing Surface

Goal: separate stable Blorp-owned formats from host C/POSIX formatting.

Work items:

- Add Blorp-owned formatters for:
  - RFC3339 instants;
  - ISO calendar dates;
  - local times;
  - local date-times without zone;
  - fixed-offset date-times.
- Add Blorp-owned parsers for the same stable formats.
- Keep `strftime`/`strptime` wrappers, but rename or document them as POSIX
  compatibility helpers.
- Replace the fixed 256-byte `strftime` buffer with dynamic sizing or a
  fallible result that distinguishes valid empty output from truncation/failure.
- Decide whether core formatting should ever be locale-aware. Default answer:
  no, not in `std/time`.
- Make English month and weekday names explicit fixed-English helpers if they
  remain in std.

Acceptance:

- Standard formatters do not depend on process locale.
- `format_rfc3339(parse_rfc3339(s)?)` is stable for canonical accepted inputs.
- POSIX formatting failure is distinguishable from a valid empty string.

## Phase 7: Clock And Deadline Model

Goal: make elapsed time, wall time, and runtime deadlines coherent.

Work items:

- Introduce explicit clock names:
  - `wall_now() -> Instant`
  - `monotonic_now() -> MonotonicInstant` or keep
    `system.now_microseconds()` as low-level interop.
- Consider a `MonotonicInstant` type only if arithmetic APIs need stronger
  type safety.
- Audit all runtime waits that use `CLOCK_REALTIME` absolute deadlines.
- Prefer monotonic timed waits where the platform supports condition-variable
  clock selection.
- Keep relative sleeps and timeout APIs based on monotonic elapsed time.
- Document that wall-clock changes can affect wall-clock readings but should
  not shorten or lengthen monotonic deadlines.

Acceptance:

- Concurrency timeouts and sleeps are monotonic in the runtime implementation
  or explicitly documented where POSIX condvar limitations remain.
- `time.now()` or its successor is not used for elapsed-time measurement in std
  modules.
- Tests cover timeout behavior enough to catch obvious immediate-expiry
  regressions.

## Phase 8: Portability And Runtime Backend

Goal: reduce accidental dependence on GNU/POSIX details or make those
dependencies explicit.

Work items:

- Inventory all time-related C helpers by portability:
  - ISO C;
  - POSIX;
  - GNU/BSD;
  - macOS-specific;
  - Windows replacement needed.
- Replace `timegm` with an internal UTC conversion helper or provide a
  platform abstraction.
- Replace direct `strptime` dependence for standard parsers with Blorp-owned
  parsers.
- Keep POSIX compatibility functions behind explicit names and docs.
- Add runtime declarations and compiler metadata tests for new time builtins.
- Add static-analysis coverage for timestamp arithmetic overflow and C-string
  conversion paths.

Acceptance:

- The preview portability story says exactly which time APIs require POSIX.
- Standard RFC3339/calendar parsing works without `strptime`.
- UTC conversion does not depend on host local time zone or non-portable
  `timegm` when a portable backend is available.

## Phase 9: ISO 8601 Extensions

Goal: add useful ISO forms only after the core RFC3339/date model is solid.

Candidate work items:

- Ordinal dates: `YYYY-DDD`.
- Week dates: `YYYY-Www-D`.
- Reduced precision dates only if a separate type represents partial dates.
- ISO durations, separate from exact elapsed `Duration` if they contain years
  or months.
- Intervals:
  - start/end;
  - start/duration;
  - duration/end.
- Repeating intervals, likely deferred until stream/iterator ergonomics are
  settled.

Design constraints:

- Do not store month/year durations in `Duration`; they are calendar periods.
- Do not let partial dates masquerade as complete dates.
- Do not accept multiple ISO spellings through one broad parser unless the
  result type preserves what was parsed.

Acceptance:

- Each supported ISO form has a named parser/formatter and tests.
- Docs say exactly which ISO forms are implemented.
- Unsupported ISO forms fail clearly instead of being partly normalized.

## Phase 10: Time Zones And Local Civil Time

Goal: defer full time zones until Blorp has an explicit data-source and
ambiguity model.

Non-goals for the first implementation:

- IANA tzdb bundling.
- Daylight-saving transition rules.
- Historical time-zone changes.
- Local system time-zone discovery.
- Ambiguous or nonexistent local time resolution.

Future model questions:

- Is a time-zone database a package, an embedded std asset, or a runtime
  service?
- How are tzdb version and update policy exposed?
- Does `TimeZone` remain pure data, or does it reference a service/data table?
- How are ambiguous local times represented?
  - `Earlier`
  - `Later`
  - `Reject`
  - `BestEffort`
- How are nonexistent local times represented?
  - `Reject`
  - `ShiftForward`
  - `ShiftBackward`
- Should local system zone access be impure because it depends on OS
  configuration?

Acceptance for a future time-zone phase:

- Fixed offsets work before named zones.
- Named zones preserve tzdb version in tests or docs.
- Ambiguous/nonexistent local times are represented in the type or result, not
  hidden behind normalization.
- Tests cover DST spring-forward and fall-back cases for at least one zone.

## Phase 11: Documentation And Migration

Goal: keep docs, examples, tests, and std call sites coherent.

Work items:

- Add a `docs/GUIDE.md` date/time section:
  - instants;
  - durations;
  - local dates;
  - UTC formatting;
  - RFC3339 parsing;
  - monotonic measurement;
  - known non-goals.
- Update `docs/GRAMMAR.md` only if new syntax is introduced. No syntax should
  be needed for the first phases.
- Update std examples that use raw integer timestamps.
- Update `std/log.brp` to use canonical RFC3339 formatting.
- Update `std/rate_limit.brp` comments to prefer monotonic time and typed
  duration where appropriate.
- Add migration-style diagnostics only if old APIs create confusing failures.
  Since Blorp is pre-0.1, prefer coherent names over long-term compatibility
  shims.

Acceptance:

- `docs/GUIDE.md`, `std/time.brp` docstrings, tests, and runtime behavior agree.
- Public examples use typed APIs when available.
- The old raw-`Int` API is either clearly low-level or removed.

## Phase 12: Quality Gates

Goal: make date/time changes hard to regress.

Gates for parser/calendar changes:

```bash
make
scripts/test unit
scripts/test compiler
scripts/test runtime
scripts/test doctest
```

Additional focused checks:

```bash
./blorp test tests/test_blorp/sys/test_time.brp
./blorp test tests/test_blorp/sys/test_time_extensions.brp
./blorp test tests/test_blorp/sys/test_time_iso_strictness.brp
./blorp test tests/test_blorp/sys/test_time_posix_edges.brp
./blorp test tests/test_blorp/sys/test_time_calendar_validation.brp
```

Future fuzz/property checks:

- Generate valid Gregorian dates and verify parse/format round trips.
- Generate invalid date fields and verify constructors reject them.
- Generate RFC3339 strings with malformed offsets/trailing bytes.
- Compare UTC conversion against a reference algorithm over a bounded range.
- Property: `instant.add_duration(d).duration_between(instant) == d` within
  documented overflow limits.
- Property: calendar date round-trip through `format_iso_date` and
  `parse_iso_date`.

Codegen/runtime checks:

- Read generated C for new builtins touching `String`, `Option`, or `Result`
  ownership.
- Run sanitizer/leak checks for runtime parser and formatter changes.
- Add static analysis checks for timestamp arithmetic overflow helpers.

## Suggested Implementation Order

1. Add failing tests for the confirmed strictness and negative timestamp gaps.
2. Clarify docs so current behavior is not over-promised while fixes are in
   progress.
3. Implement strict RFC3339 parsing and calendar-date validation.
4. Fix negative timestamp conversion and timestamp arithmetic edge cases.
5. Add typed `Instant` and consolidate `Duration` usage.
6. Add local date/time records and checked constructors.
7. Add stable Blorp-owned formatters and parsers.
8. Audit monotonic vs realtime deadline behavior.
9. Reduce non-portable C helper dependence.
10. Consider ISO extensions.
11. Consider fixed offsets and then IANA time zones.

## Open Decisions

- Should `from_iso` be removed, renamed, or kept as a strict alias?
- Should `to_iso` remain whole-second-only, or should canonical RFC3339 output
  include fractional seconds when microseconds are nonzero?
- Should date-only parsing return `LocalDate` only, or is midnight-UTC instant
  conversion useful enough to keep under a separate name?
- Should `Duration` move from `std/units.brp` to `std/time.brp`, or should
  `time` re-export the units duration?
- Should leap second text be rejected or normalized to the preceding/following
  POSIX second?
- What is the documented timestamp range for microsecond `Int` instants?
- Should POSIX `strftime`/`strptime` wrappers stay in std, or move to a
  compatibility package once Blorp-owned parsers/formatters exist?
- How much local time support is acceptable before an IANA tzdb exists?
