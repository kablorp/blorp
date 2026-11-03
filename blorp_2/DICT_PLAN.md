# Blorp 2 Dict

Status: approved 2026-11-02, with the decisions below. Phases 0 to 4 are done ([spike report](../benchmarks/results/blorp2-dict-spike-2026-11-02.md), [phase 1 results](../benchmarks/results/blorp2-dict-phase1-2026-11-02.md), [phase 2 results](../benchmarks/results/blorp2-dict-phase2-2026-11-02.md), [phase 3 results](../benchmarks/results/blorp2-dict-phase3-2026-11-02.md), [phase 4 results](../benchmarks/results/blorp2-dict-phase4-2026-11-02.md)); their findings are folded in below, and phase 5 (record keys) is next. Each phase gets its own implementation brief.

## Problem

Blorp 2 has no dictionary.

**What the compiler uses instead:**
- **One stopgap map,** `blorp_2/src/utils/hash_map.brp`. Its header says it is deleted "once Blorp has a dict implementation". It offers `get`, `set` and `values`, with no `remove`, no key listing and no literal syntax.
- **Hand-made Int keys.** Only `Int` implements `Hashable` (`standard_library/int.brp:15`), so the map's six users squash their real keys into an Int:
  - `namespace.brp`: `2 * name_number + kind`;
  - `instantiation_paths.brp`: `source * count + target`;
  - `model.brp`: `head_hint(TypeHead)`.
- **Bespoke quasi-maps:**
  - `utils/names.brp` interns names through its own bucket table (`spelling_bucket`, `lookup`, `with_bucket_entry`, `index_spellings`);
  - `specialize.brp` keeps `IndexedList`, a digest-to-positions multimap on top of `HashMap`, with 11 hand-written digest functions;
  - `check/model.brp` keeps `implementation_table`, buckets keyed by a head hint.

**What it costs:** little speed, a lot of code.
- A one-off self-compile sample at `8ac29e78e` (2026-11-02, not retained) put the hashed and bucketed lookups at about 6% of the run (`specialize.find_position` 2.8% inclusive, `hash_map.probe`/`set` 2.7%), with no linear lookup above 3%.
- The retained 2026-10-30 attribution (`benchmarks/results/blorp_2_attribution_after_o1_2026-10-30.md`) showed `indexed_list.find_position` at 19.4% inclusive. Phase 0 re-measures both.

**Goal:** an ordinary, insertion-ordered `Dict[K, V]` value in the Blorp 2 standard library, with the legacy literal syntax. Then remove the stopgap map and the bespoke structures. Sets follow after Dict.

## Requirements

1. **Insertion-ordered.** `keys`, `values` and `entries` list keys in first-insertion order.
   - `set` on an existing key keeps its position.
   - `remove` keeps the relative order of the rest.
   - A key removed and set again goes last.
2. **API:** `get`, `get_or`, `set`, `remove`, `keys` and `values`, plus the basics below. `insert` is deferred (D1): it would only alias `set` unless it gained a meaning that pays for itself.
3. **A simple, well-defined implementation.** It is written in Blorp over `List`, with no SIMD, no parallelism and no new C runtime type.
4. **Value semantics, as for `List`:**
   - an update returns a new Dict;
   - an update to a uniquely owned Dict reuses its storage in place;
   - an update to a shared one copies (COW).
5. **Infallible:** a missing key is an `Option` or a default. No operation fails.
6. **Deterministic:** the same operations in the same order give the same Dict and order everywhere. Hashes are unseeded (D5).
7. **Legacy literals:** `{}` and `{"a" => 1, "b" => 500}`.

## Surface

### Key trait

`dict.brp` declares a bundle trait, using the supertraits milestone 1 that is in the pinned seed:

```blorp
-- A Dict key is hashed to find its slot and compared to tell collisions apart.
trait DictKey: Hashable + Equatable
```

- **Each key type opts in with one bodyless line:** `implements DictKey for String`. Blorp 2 writes every implementation; SUPERTRAITS_PLAN's deviations table says so ("Every implementation is written") and shows the bodyless bundle form. The library supplies `DictKey` for `Int`, `String` and `Bool`.
- **Hashable stays independent of Equatable,** as `blorp_2/README.md` records today. `DictKey` is the one place that combines them, which matches Rust: `Hash` and `Eq` are separate traits, and `HashMap` requires both.
- **The type declares the bound:** `opaque type Dict[K: DictKey, V]`. The existing declaration-bound diagnostics (commits 51d98be37 and 2972ae0ce) then reject `Dict[Point, Int]` at every written type, with "implement DictKey for Point, or use a type that implements it". No Dict-specific error is needed, and an invalid Dict can't be represented. Functions repeat `K: DictKey`.

### Operations

All of these are pure. `n` is the number of live entries.

| Function | Result | Meaning | Cost |
| --- | --- | --- | --- |
| `empty()` | `Dict[K, V]` | no entries | small constant (a `MINIMUM_SLOTS` = 7 index) |
| `with_capacity(count)` | `Dict[K, V]` | holds `count` entries before the index grows: the smallest 2^k − 1 slot count, at least 7, with `count` at most 2/3 of it | O(count) |
| `get(dict, key)` | `Option[V]` | the value, or `None` | O(1) average |
| `get_or(dict, key, default)` | `V` | the value, or `default` | O(1) average |
| `contains(dict, key)` | `Bool` | whether the key is present | O(1) average |
| `set(dict, key, value)` | `Dict[K, V]` | insert, or replace the value and keep the key's position | O(1) amortized |
| `remove(dict, key)` | `Dict[K, V]` | without the key; unchanged if absent | O(1) amortized |
| `keys(dict)` | `List[K]` | live keys in insertion order | O(1) with no removed entries pending, else O(n) |
| `values(dict)` | `List[V]` | values in the same order | same as `keys` |
| `entries(dict)` | `List[(K, V)]` | pairs in order; each pair is a managed tuple | O(n) |
| `length(dict)`, `is_empty(dict)` | `Int`, `Bool` | live entry count | O(1) |

**Left out:**
- `insert` (D1);
- `for` over a Dict (D4): iterate `keys()` or `entries()`;
- `update`/`update_or` (see Risks);
- `merge`, `map_values`, `filter`, `fold` and `sort_by_key`, until a caller needs them.

### Equality

`implements Equatable for Dict[K: DictKey, V: Equatable]`. Two Dicts are equal when their lengths match and each key of one is present in the other with an equal value. Order does not matter, as in legacy Blorp. The cost is O(n) on average, and O(n²) only with a degenerate hash. A Dict is neither `Hashable` nor a `DictKey`.

### Literals

- **`{}`** is an empty Dict. Its key and value types come from the expected type. Without one, the error is "an empty Dict needs its type; write `name: Dict[K, V] = {}`".
- **`{k1 => v1, k2 => v2, ...}`** is a populated Dict, with an optional trailing comma.
  - Its types come from the entries, unified as for a List literal, or from the expected type.
  - Evaluation is left to right, each key then its value.
  - The meaning is successive `set` calls, so a repeated key keeps its first position and the last value.
- **Lowering:** checking rewrites a literal as ordinary calls, `{}` as `empty()` and `{k1 => v1, k2 => v2}` as `with_capacity(2).set(k1, v1).set(k2, v2)`. Lower, own, verify, specialize and emit see only calls. The `set` chain on a fresh unique Dict updates in place, with no tuples or pair List.
- **Prelude:** it imports `dict: Dict`, the type and its UFCS receiver methods. (`Type methods` is for a type declared elsewhere, as `list: List methods` is, because `List` comes from `_base`; `module: Type` already enables the module's receiver functions for its own type.) Free functions such as `empty` and `with_capacity` are not imported. Code reaches them through `import: dict as D`, or uses literals.
- **How checking finds `empty`, `with_capacity` and `set` (D6, resolved): by identity, not by name lookup.**
  - The prelude fixes which declaration is `Dict`. After names resolve, checking rewrites a literal as calls to the functions declared in the module that declares that `Dict`.
  - A user's own `set`, a local `dict.brp` or an alias can't stand in, because user code can't add declarations to that module. Visibility doesn't matter either: the free functions aren't imported, and they don't need to be.
  - Checking needs a path that builds calls to known functions rather than to resolved names. Phase 0 estimated it at about 140 to 190 production lines in `check/`, following the operator precedent (`method_id_contract`, `CanonicalContracts`):
    - a `declared_id_contract` helper;
    - the Dict function ids, located once at admission;
    - a planned Dict-literal base with a worklist step. A nested `set` chain can't be written as parsed-expression arguments, so this needs its own base;
    - the empty-literal error.
  - Rejected alternatives:
    - the test-entry route (a special load of the library file, a synthetic import under an alias nobody can write, and a rewrite at assembly): the prelude already loads `dict.brp`;
    - new designation machinery for library functions.
  - **As built in phase 2:**
    - `CanonicalContracts.dict_literal` holds the three `FunctionId`s, found in `accept_trait_contracts` (`check/traits.brp`) through the foundation words `Dict`, `empty`, `with_capacity` and `set`, the route the operator traits already take. It is `None` when the prelude's `Dict` is not an opaque type whose module declares all three as pure functions (a literal is pure, so this is the one purity check), and a literal then gets "Dict literals require the prelude's Dict".
    - A literal's calls check exactly like the nested calls `set(set(with_capacity(2), k1, v1), k2, v2)`, which emit the same C. The receiver chain `D.with_capacity(2).set(k1, v1)` does not check today: `set` is an overloaded receiver method, and its selection fails on a receiver whose K and V are still unsolved. A literal avoids that because its `set` is known by identity.
    - A key type without `DictKey` gets the declaration-bound error where `Dict[Point, Int]` is written. In an unannotated literal no Dict type is written, so it gets the existing call-bound error, "type does not satisfy the required trait bound".
    - **Owner-visible diagnostic change.** `{}` where a record is expected became an ordinary type mismatch through one general checking change: when the expected type of a whole value has another head, its unsolved type parameters are reported as that mismatch. This changes calls too: `p: Point = D.empty()` now reports "expression does not match the expected type" instead of "cannot infer the type parameter from the argument". Argument positions such as `takes_point({})` are unchanged.
    - After the first expression in braces, anything but `|` or `=>` is "expected '|' or '=>' after the first expression in braces", naming both forms. Inside a Dict, a missing key or a second `=>` in an entry gets a Dict message; a stray `=>` elsewhere keeps the lexer's former comparison and lambda message.
- **Parser and lexer changes:**
  - A braced form currently decides by two-token lookahead (`consume_braced_record`, `parse/parse.brp`), so `{x => 1}` would fall into record update today, if the lexer did not reject `=>` first. The rule becomes: after `{`, a name then `=` is a record literal. Otherwise read one expression; then `|` means a record update and `=>` a Dict. This matches legacy `braced` in `docs/GRAMMAR.md`.
  - The changes:
    - a new AST variant for a Dict literal;
    - `{}` becomes an empty Dict rather than an empty record literal. Today it parses at `parse.brp:3822` and is rejected by `constructors.brp:283` with `RecordNeedsExpectedType`;
    - `=>` becomes a token. Today `lex.brp:852` rejects it everywhere. It stays rejected outside a Dict entry, with today's teaching message moved to the parser;
    - `grammar.ebnf` adds `dict_literal`, and `record_literal`'s field list becomes required.
  - Tests that pin the old behaviour change:
    - `test/e2e/test_records.brp:25`: it expects "missing field in record literal" at 3:2;
    - `test_check/test_records.brp:713` and `:867`;
    - `test_check/test_record_admission.brp:154`;
    - `test_grammar/test_records.brp:130` (`test_empty_literal_is_syntax_but_empty_declaration_is_not`);
    - `test_module.brp:407`;
    - `test_lex/test_ordering_operators.brp:40-41`.

    `test_parse/test_record_syntax.brp:18` only lexes `{}` and checks brace spans, so it stays.
  - Blorp 2 rejects empty record declarations, so no program loses meaning.

## Hashing

- **`Int`:** identity, as today.
- **`String`:** the byte formula `utils/names.brp`'s bucket index used, `hash = (hash + byte) * PRIME`, wrapping, from a named basis. It moves to `string.brp` as `implements Hashable for String`.
- **`Bool`:** `False` is 0 and `True` is 1.
- **Records and unions get written implementations, never derived.** `_base.brp` ("never derived"), both READMEs and the 2026-10-30 Hashable report record that owner decision, and this spec keeps it. Compiler key types migrated in phase 5 get written `Hashable` and `DictKey` implementations:
  - `TypeHead`, the sealed instance keys, and the opaque ids in `utils/ids.brp`.
  - Those ids already have written `Equatable`, so derivation couldn't reach them anyway.
  - If a key needs a List, for example the argument lists in instance keys, add written `implements Hashable for List[T: Hashable]` and `implements DictKey for List[T: DictKey]`.
- **Combining:** one named library function, `combine_hash(seed, value) = (seed + value) * PRIME`, wrapping. Blorp 2 has no xor or shift operators, and this needs neither.
- **No Float keys (D2).** Float doesn't implement `DictKey`. A program that needs one wraps the Float in an opaque type with written implementations, for example over its bits or a canonicalized value.

## Implementation

### Representation

The design follows CPython's compact dict: a dense, ordered entry array plus a separate open-addressing index.

```blorp
-- Entry i is keys[i] with values[i]; live[i] is False once it is removed.
-- slots[s] is EMPTY, DELETED, or the position of the entry whose probe passes s.
-- Every entry, live or dead, owns exactly one non-EMPTY slot until the next
-- rebuild, which compacts: DELETED slots and dead entries are the same count.
private record DictContents[K: DictKey, V] {
    keys: List[K],
    values: List[V],
    live: List[Bool],
    slots: List[Int],
    dead_count: Int
}
opaque type Dict[K: DictKey, V] = DictContents[K, V]
```

- **Derived facts:** the live count is `keys.length() - dead_count`, and nothing else records a count.
- **Removal:** the entry is marked dead and its slot becomes `DELETED`. Its key and value stay referenced until the next rebuild. That isn't observable; it only costs memory.
- **Slot sentinels:** plain Ints, named constants `EMPTY_SLOT = -1` and `DELETED_SLOT = -2`. `hash_map.brp` measured that an `Option[Int]` per slot boxes every position.

### Probing

- **Home slot:** `(key.hash() * HASH_SPREAD)` as a non-negative remainder by the slot count. `HASH_SPREAD` is a named odd 64-bit constant, and the multiply wraps. Hashes may be any signed Int, including `INT_MIN`.
  - The spread is required. With identity hashing, sequential Int keys fill one contiguous run of slots, so a lookup that starts inside the run walks to its end. Phase 0 measured 125.0 G instructions on `dict_ops` without the spread against 3.84 G with it; today's `HashMap` pays 133 k instructions per missed lookup for the same reason.
  - `Hashable for Int` stays identity; the spread belongs to the table.
- **Slot counts are 2^k − 1:** 7, 15, 31 and so on.
  - A power-of-two count would keep only the low bits, so power-of-two strides, like the compiler's `2 * name + kind`, would pile into a few slots. 2^k − 1 shares no factor with 2, so those strides spread.
  - Composite counts (63 = 7·9, 255 = 3·5·17 …) still cluster strides that share their factors, a weakness identity hashing accepts, as the arithmetic plan notes. The constant-hash and stride tests pin correctness, not performance.
- **Linear probing:** step +1, wrapping. A lookup stops at `EMPTY` (absent) or at an entry with an equal key, probing past `DELETED`. `set` of a new key takes the `EMPTY` slot where its probe stops. `DELETED` slots are not reused: the rebuild trigger counts entries, dead ones included, so reuse would never delay a rebuild, and dropping it keeps one slot per entry.
- **Termination:** an `EMPTY` slot always exists. The non-`EMPTY` slots number exactly `keys.length()`, which the rebuild trigger keeps within 2/3 of the slots.

### Rebuild

One operation both grows and compacts.

- **Triggers:**
  - adding an entry would make `keys.length() + 1` exceed 2/3 of the slots, counting dead entries;
  - or `remove` leaves `dead_count > live` with `dead_count >= MINIMUM_COMPACTION` (8).
- **Effect:**
  - copy the live entries, in order, into fresh Lists;
  - choose the smallest 2^k − 1 slot count, at least `MINIMUM_SLOTS` (7), where the live count plus one is at most **1/2** of the slots;
  - index every entry;
  - set `dead_count = 0`.
- **Why 1/2 and not 2/3:** rebuilding to 1/2 load leaves slack, so a churn of `remove` followed by `set` of a new key can't trip a rebuild every few operations. Each rebuild is paid for by at least n/6 cheap operations, so `set` and `remove` are O(1) amortized.
- **O2's known limit:** a loop that updates a record's List field stays quadratic (ROADMAP.md, O2 known limits, `record_loop`). `hash_map.brp`'s `reindexed` has exactly that shape. Rebuild therefore fills local `var` Lists and builds the record once at the end. A linearity witness at 65,536 entries pins this.

### `keys()` and `values()`

With `dead_count == 0`, they return the stored List: an O(1) shared reference, copied on write if either side later changes. Otherwise they build a filtered List.

### Ownership

This is ordinary library code; lower, own, verify and emit need nothing new. Two shapes are required, both measured in phase 0:
- **Updates use record-update syntax,** `{ contents | keys = contents.keys.append(key), ... }`. O2 then projects the fields before the replacements run, so each field List stays unique and `append` or `set` reuses its buffer (L1/L2): 1 allocation per `set`, linear. A fresh literal built from the old record's fields, `{ keys = contents.keys.append(key), ... }`, keeps the old record alive while its Lists are appended. That costs 5 allocations per `set` and is quadratic.
- **Rebuild fills local `var` Lists and builds the record once** (above). Today's `HashMap` updates `slots` in its record inside `reindexed`'s loop, and is quadratic for that reason: it grows about 15× for each 4× of keys.

The record itself is reallocated on each update until O3 cell reuse lands. That costs 527 instructions per update, about 45% of a `set` or `remove`.

### Why not a C runtime table like legacy's Swiss table

- **Simpler:** a runtime Dict needs emitted per-instantiation C that calls the specialized `hash` and `==`, ARC hooks for each key and value type, and a new builtin. A new builtin needs a bootstrap rotation.
- **Ownership is free:** the Blorp version gets value semantics and ownership from List.
- **No SIMD:** Swiss tables pay off through SIMD group probes, which are out of scope.
- **Reversible:** the opaque type keeps a later switch, if measurement justifies it, local to `dict.brp`.

## Phases

Each phase lands green on its own, with self-compile allocations, `-O0`/`-O2` instructions and production lines recorded against its base. Each updates `blorp_2/README.md`, `standard_library/README.md`, `grammar.ebnf` and the grammar tests where it changes them. New suites are added to the Makefile's `TARGET_COMPONENT_SOURCES`.

| Phase | Content | Ends with |
| --- | --- | --- |
| 0, spike (done) | A prototype `dict.brp`, a `dict_ops` port and measurements: [report](../benchmarks/results/blorp2-dict-spike-2026-11-02.md). The prototype, the port and the unit suite are on branch `blorp2-dict-spike` (`f342a8039`), the starting point for phase 1. | The phase 1 ceilings below |
| 1, Dict (done) | `dict.brp` with `DictKey`, the operations, equality; `DictKey` for `Int`, and `Hashable`/`DictKey` for `String` and `Bool`; and the probing, churn, compaction, linearity and ownership tests: [results](../benchmarks/results/blorp2-dict-phase1-2026-11-02.md). Equality needed trait implementations on generic opaque types (83bc73dac) and so a seed that has them. | Dict usable through calls |
| 2, literals (done) | Lexer, parser, AST, checking rewrite, grammar and tests, as in Literals: [results](../benchmarks/results/blorp2-dict-phase2-2026-11-02.md) | `{}` and `{k => v}` work |
| 3, HashMap (done) | The six `HashMap` users moved to `Dict`, keeping their Int keys, and `utils/hash_map.brp` and its suite were deleted. The README, `ROADMAP.md` and standard library README no longer describe it: [results](../benchmarks/results/blorp2-dict-phase3-2026-11-02.md) | No stopgap map |
| 4, names (done) | `utils/names.brp` becomes a `Dict[String, NameId]`. An id is its spelling's position in `keys()`, since names are never removed, so the separate `spellings` List and the bucket functions are deleted: [results](../benchmarks/results/blorp2-dict-phase4-2026-11-02.md) | No bucket table |
| 5, record keys | Written `Hashable`/`DictKey` for `TypeHead` and the opaque ids. `model.brp`'s `implementation_table` becomes a Dict keyed by `TypeHead`. Specialize's **sealed** instance tables become Dicts keyed by their full keys. Its **slot** tables keep `IndexedList`, because their digests deliberately hash only the head while `resolve_partial` rewrites pending references inside the stored key. Replace the squashed pair keys where a written hash is cheap. | Fewer digests and hints |
| later | `Set`; `update`/`update_or` once a List take-or-update builtin exists; set-shaped scans moved where measured or where the change deletes code | |

## Ceilings

These are set before implementation. A miss means stop and rescope.

- **Phase 1,** from phase 0's numbers (the prototype is the baseline; derivations are in the report). Instructions are per operation, net of process start:

  | Measure | Ceiling | Measured in phase 0 |
  | --- | --- | --- |
  | Build linearity | instructions per key at 65,536 keys at most 1.15× that at 4,096; at most 1.02 allocations per key | 1.01×; 1.013 |
  | `set`, `remove` | at most 1,400 instructions and 1.02 allocations each | 1,182 and 1,166 |
  | Lookup hit, miss | at most 230 and 185 instructions, no allocations; a hit at most 2× today's `HashMap` hit (113, so 226) | 196 and 154 |
  | Slot spread | sequential keys and strides of 7 and 1,024 average fewer than 8 probes per miss | identity hashing: 133 k instructions per miss |
  | String keys | at most 1.2× the Int cost per mixed operation; hashing allocates nothing | 1.11×; 0 |
  | Churn | rebuilds at most 3 × cycles / live + 1 for live above 24, at most cycles / 8 below; at most 3,100 instructions per remove-then-set cycle; at most 2.1 allocations per cycle for live of 1,000 or more, 2.6 below | 273 at live 1,000; 2,904 instructions and 2.5 allocations at live 10; 2.02 at live 1,000 |
  | `dict_ops` | at most 4,300 M instructions, 3.1 M allocations, 1.5 MB peak heap | 3,843 M; 3,017,317; 1.34 MB |
  | Against legacy | at most 7× on the `dict_ops` sections other than iterate, taken together | about 5.9× (the remove section alone is 8.0×) |
  | Prelude | accepted 2026-11-02 at +0.82% `-O2` and +1.84% `-O0` self-compile instructions, +0.36% strict allocations, against a 0.5% instruction ceiling: checking `dict.brp` in every compilation costs about what any 295 lines does, and phases 3 to 5 import it into the compiler anyway | — |
  | `dict.brp` | at most 300 lines, including equality, `entries` and `is_empty` | 258 without them, so the margin is small |

  The provisional "within 4× legacy" passed only because legacy's iterate allocates a tuple per entry. "No slower than `HashMap`" compared against the no-collision case of a map whose build and misses are 100× to 1,000× slower, so the table above replaces both.
- **Phases 3 to 5, per step:**
  - self-compile `-O2` instructions rise by at most 0.5%;
  - strict allocations rise by at most 1%;
  - phases 3 and 4 remove more production lines than they add. Phase 5's sealed-table and implementation-table steps should too; the written `Hashable` implementations are counted.

## Testing

- **Semantics,** e2e with strict accounting, for Int keys, String keys and a key with written implementations coarser than its representation (case-insensitive):
  - order through replace, remove and set again;
  - a missing key in `get`, `get_or` and `remove`;
  - empty and literal construction, including a repeated literal key;
  - equality that ignores order;
  - value semantics: a copy of the Dict is unaffected by updates to the original.
- **Probing and rebuild:**
  - a constant `Hashable`;
  - strides of 1,024 and of 7;
  - absent sequential Int keys looked up within a step or instruction budget, which fails with `HASH_SPREAD` set to 1;
  - removing every key, then reuse;
  - the compaction boundary;
  - a churn loop of remove and set that stays within an allocation bound.
- **Ownership:** a witness that each update on a unique Dict takes the last owner of each field List, failing when consumption is broken. Plus the 65,536-entry linearity guard.
- **Literals:**
  - parser tests for each braced form, `{}`, and `=>` outside a Dict, keeping today's message;
  - check tests for an empty literal without an expected type, mismatched entry types, and a non-`DictKey` key reaching the declaration-bound error.

## Decisions

- **D1, resolved:** `set` only; `insert` is deferred.
- **D2, resolved:** no Float keys, as in Rust. The comparison below is the rationale.
- **D3, resolved:** a `DictKey` bundle trait over `Hashable + Equatable`. Hashable stays independent.
- **D4, resolved:** no `for` over a Dict for now.
- **D5, resolved:** unseeded, deterministic hashes.
- **D6, resolved:** the prelude imports `dict: Dict`, the type and its receiver methods only. Literal lowering finds `empty`, `with_capacity` and `set` by identity, in the module that declares the prelude's `Dict`.

**D2: Float keys elsewhere.** These are the standard semantics of each language:

| Language | Float keys | NaN | −0.0 and 0.0 |
| --- | --- | --- | --- |
| Rust | Not allowed: `f64` implements neither `Eq` nor `Hash`. Callers wrap it (`ordered-float`) or key by `to_bits()`. | — | — |
| Python | Allowed | Lookup checks identity first, so the *same* NaN object is found, but a fresh `float('nan')` isn't, and repeated NaN keys pile up | Same key: equal, with equal hashes |
| Go | Allowed | Every NaN set adds a new entry that `m[k]` can never read | Same key |
| Swift | Allowed (`Double: Hashable`) | Never found again; the documentation warns about it | Same key |
| Java (`HashMap<Double, V>`) | Allowed | One key: `Double.equals` compares canonical bits | **Different** keys |
| JavaScript (`Map`) | Allowed | One key: SameValueZero | Same key |

Each language that allows Float keys either loses NaN keys or uses a key equality that differs from its `==`. Blorp 2's Float `==` makes NaN unequal to itself, and a second equality just for keys would be a new concept. Excluding Float keys, as Rust does, is the safe and predictable choice. An opaque wrapper gives any of the other behaviours explicitly.

## Risks

- **Updating a value in place.** A value read with `get` is a second reference, so changing a `Dict[K, List[V]]` value copies that List. Making it in place needs a List take-or-update-at-index builtin, which needs a bootstrap rotation. Until then, multimap callers pay the copy, as they do now.
- **String hashing goes byte by byte through `byte_at`,** which returns an `Option[Int]`. Phase 0 measures whether that allocates. If it does, String keys may need a `string.hash` builtin, which needs a rotation, before the ceilings hold.
- **One record allocation per update until O3.** This is measured in phase 0.
- **`{}` and empty records:** if empty records are ever added, `{}` stays a Dict, as legacy Blorp decided, and they need another spelling.
