# blorp Standard Library

## Core Types
| Module | Description |
|--------|-------------|
| `option` | `Option[T]` — `Some(value)` or `None` |
| `result` | `Result[T, E]` — `Ok(value)` or `Err(error)` |
| `traits` | Core trait definitions (Stringable, Equatable, Orderable, etc.) |
| `bytes` | Immutable binary buffer with COW |
| `fixed` | Fixed-point decimal arithmetic |
| `range` | First-class half-open integer ranges |
| `tuple` | Tuple trait implementations |
| `ptr` | Opaque pointer type for C interop |
| `void` | Unit type |
| `units` | Zero-cost unit types (radians, dB, coordinates) |
| `prelude` | Compiler-injected core imports |

## Collections
| Module | Description |
|--------|-------------|
| `list` | Dynamic array with ARC/COW — the workhorse collection |
| `parallel_list` | Scoped combinators for `List.parallel()` |
| `dict` | Ordered hash map with COW |
| `set` | Hash set with COW |
| `heap` | Min-heap priority queue |
| `deque` | Double-ended queue |
| `sorted_map` | Sorted key-value map |
| `graph` | Directed weighted graph |
| `stream` | Lazy, composable sequences |
| `cache` | LRU cache with fixed capacity |

## Strings & Text
| Module | Description |
|--------|-------------|
| `string` | Core string operations, capacity-aware construction/appends, split, trim, replace, hex, binary formatting |
| `slice` | Zero-copy string views |
| `parser` | Parser combinator library |
| `regex` | POSIX Extended regular expressions |
| `html` | HTML escaping/unescaping |
| `term` | ANSI terminal colors, styles, tables, progress bars |

## Serialization & Formats
| Module | Description |
|--------|-------------|
| `codec` | Universal serialization framework (Value type, decoders, Encodable trait) |
| `codec_bridge` | Bridge JSON/TOML/CSV to codec.Value |
| `yaml` | Strict practical YAML subset parser and encoder |
| `toml` | Strict TOML subset parser and accessor |
| `csv` | CSV parser and formatter |
| `xml` | Strict simple XML element parser |
| `json` | JSON value type, strict parser, and encoder |

## Numeric & Math
| Module | Description |
|--------|-------------|
| `math` | Mathematical constants and cross-type helpers |
| `tensor` | Generic N-dimensional array operations |
| `vector` | 1D tensor operations and factories |
| `matrix` | 2D tensor operations (matmul, transpose) |
| `stats` | Statistical functions (mean, stddev, percentile, regression) |
| `dsp` | Signal processing (biquad filters, window functions, convolution) |
| `fft` | Fast Fourier Transform (Cooley-Tukey radix-2) |
| `noise` | Value and Perlin noise (1D/2D/3D) for procedural generation |

## Type Implementations
| Module | Description |
|--------|-------------|
| `int` | Integer traits, checked/saturating arithmetic, GCD, LCM, factorial |
| `float` | Float math functions (trig, log, exp, rounding) and traits |
| `bool` | Boolean trait implementations |
| `char` | Character trait implementations |
| `int8`, `int16`, `int32`, `int128` | Sized signed integer traits |
| `uint8`, `uint16`, `uint32`, `uint64`, `uint128` | Sized unsigned integer traits |
| `float32`, `float16` | Sized float trait implementations |

## System & I/O
| Module | Description |
|--------|-------------|
| `io` | Console I/O (print, eprintln, read_line, input, EOF-aware helpers) |
| `file` | Typed file API foundation (`IOError`; resource handle anchors; scoped handles in progress) |
| `system` | File I/O, directory ops, exec |
| `process` | Safe process spawning with output capture |
| `path` | File path manipulation (pure string operations) |
| `time` | Date/time (POSIX microseconds, calendar, formatting, arithmetic) |
| `debug` | Debug logging with levels |
| `memory` | Memory statistics and leak detection |
| `instrumentation` | Scheduler stats, timing, and optimizer-barrier helpers for profiling and benchmarks |
| `log` | Structured logging with JSON output |
| `rate_limit` | Pure token-bucket and fixed-window rate limiters |
| `channel` | Bounded channels and `ConcurrencyError` declarations |

## Cryptography
| Module | Description |
|--------|-------------|
| `crypto_random` | Cryptographically secure random bytes |
| `hash` | FNV-1a, SHA-256, MD5 hash functions |

## Testing & Random
| Module | Description |
|--------|-------------|
| `test` | TestSuite framework with assertions (assert_eq, assert_some, etc.) |
| `property` | Property-based testing with generators and shrinking |
| `random` | PRNG (impure global + pure SplitMix64) |

## Networking (`net/`)
| Module | Description |
|--------|-------------|
| `net/tcp` | TCP sockets (listen, accept, connect, send, recv) |
| `net/http` | Pure HTTP/1.1 request/response parsing |
| `net/url` | URL parsing |
| `net/mime` | MIME type detection |

## Spatial & Physics
| Module | Description |
|--------|-------------|
| `geometry` | 2D/3D vector math, shapes, collision detection |
| `geographic` | Geographic coordinates (WGS84), distance |
| `geojson` | GeoJSON RFC 7946 parsing and encoding |
| `physics` | 2D physics primitives (Euler/Verlet integration) |

## Utilities
| Module | Description |
|--------|-------------|
| `argparse` | Declarative CLI argument parser |
| `uuid` | UUID v4 generation and validation |
| `validation` | Error-accumulating data validation |

Native-backed packages such as `pkg/tui`, `pkg/compress`, `pkg/crypto`,
`pkg/sqlite`, `pkg/audio/neural_amp`, and the `pkg/net/` modules live under
`pkg/`, not `std/`.
