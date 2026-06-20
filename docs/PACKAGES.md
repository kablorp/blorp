# Source Packages

Blorp source packages are portable source bundles. They are for sharing Blorp
code without native headers, link flags, build scripts, generated files,
install hooks, FFI declarations, or dependency solving.

The current package command validates local package directories, prints their
canonical content hash, creates deterministic artifacts, installs verified
artifacts into the local cache, and vendors cached packages:

```bash
blorp package check path/to/package
blorp package hash path/to/package
blorp package pack path/to/package -o json-1.2.0.blorpkg
blorp package status
blorp package fetch
blorp package fetch blake3:8f4e2c1a9b0d7e6f json-1.2.0.blorpkg
blorp package fetch json
blorp package vendor
blorp package vendor blake3:8f4e2c1a9b0d7e6f vendor/json
blorp package vendor json
```

Root projects can make a checked local source package available under an import
alias from `blorp.toml`:

```toml
[packages]
json = { path = "vendor/json", hash = "blake3:8f4e2c1a9b0d7e6f", from = ["https://example.com/json-1.2.0.blorpkg", "artifacts/json-1.2.0.blorpkg"] }
json_legacy = { path = "vendor/json-0.9" }
json_cached = { hash = "blake3:8f4e2c1a9b0d7e6f", from = ["https://example.com/json-1.2.0.blorpkg", "artifacts/json-1.2.0.blorpkg"] }
```

The table form is also accepted:

```toml
[packages.json]
path = "vendor/json"
hash = "8f4e2c1a9b0d7e6f"
from = ["https://example.com/json-1.2.0.blorpkg", "artifacts/json-1.2.0.blorpkg"]
```

The path is relative to the `blorp.toml` file. A package alias must define
`path`, `hash`, or both. A `path` alias reads that local package directory. A
hash-only alias reads the verified package from the local package cache. In
both cases, the package directory must contain `package.toml` and `src/`, and
its `std` compatibility must match the compiler's current package epoch.
`from` lists artifact locations used by `blorp package fetch` and
`blorp package fetch <alias>`;
relative local artifact paths are resolved relative to `blorp.toml`.
Unsupported keys are rejected instead of being ignored. The alias is not
registered unless every exported module has a corresponding `.brp` file under
the package `src/` tree.

`hash` pins are BLAKE3 content hashes. The `blake3:` prefix is optional, pins
are case-insensitive, and aliases may use a 16-to-64-character hexadecimal
prefix. `blorp package hash` prints the full 64-character hash.

A source package has this shape:

```text
package.toml
src/
  package_name.brp
  package_name/
    helper.brp
```

`package.toml` uses a narrow manifest format:

```toml
[package]
name = "json"
version = "0.1.0"
license = "MIT"

[compat]
std = "preview-1"

[exports]
modules = ["json", "json/parser"]
```

Only `[package]`, `[compat]`, and `[exports]` are accepted. A normal source
package cannot declare dependencies of its own.

## Package Policy

`blorp package check` enforces the portable-source boundary:

- `package.toml` must declare a package name, `std` compatibility, and at
  least one exported module.
- Exported modules must be valid module paths inside the package namespace.
  For package `json`, exported modules must be `json` or `json/...`.
- Exported module files must exist under `src/`.
- Package source may import current `std` modules.
- Package source may import its own modules by canonical package path, such as
  `json/parser`.
- Relative imports are allowed only when they resolve to a `.brp` file under
  the package `src/` directory.
- Package source may not import arbitrary root-project local modules.
- Package source must typecheck with the current compiler and standard library.
- `foreign` declarations are rejected.
- `builtin` function bodies, builtin expressions, builtin types, and builtin
  records are rejected.

The repository's internal `pkg/...` modules are not this source-package system.
They remain compiler-distributed modules and native-backed bindings, not a
userland dependency lane.

## Content Hashes

Package hashes are content-addressable. The hash includes `package.toml` and all
`.brp` files under `src/`, sorted by package-relative path and length-delimited
with their exact bytes. It does not include the package checkout directory,
absolute paths, file permissions, modification times, or other filesystem
metadata.

That means two checkouts with the same package contents produce the same hash,
and any manifest, source path, or source byte change produces a different hash.
Comments and whitespace are included because they are source bytes. Hash pins
are verified before the package alias is registered.

## Artifacts And Cache

`blorp package pack` writes a deterministic `.blorpkg` artifact. The artifact is
a Blorp-owned source archive, not tar or zip, so no external archive metadata can
change the package identity.

`blorp package status` reads the nearest `blorp.toml` from the current working
directory and reports whether each package alias is local, cached, missing, or
invalid. It exits successfully only when all declared package aliases are usable
from local source paths or the verified cache.

`blorp package fetch` reads the nearest `blorp.toml` from the current working
directory and fetches every package alias that has both `hash` and `from`.
Path-only aliases are local packages and are skipped. `blorp package fetch
<alias>` fetches one alias from that same config. `blorp package fetch <hash>
<from>...` tries each explicit artifact location until one installs
successfully. In all forms, fetched artifacts are unpacked into a staging
directory, checked as normal source packages, hashed, and accepted only if the
content hash matches the requested hash. Locations may be local paths,
`file://` URLs, `http://` URLs, or `https://` URLs.
HTTP(S) fetching uses `curl` as a transport helper; downloaded bytes are still
trusted only after package validation and hash verification.

The package cache is content-addressed under:

```text
~/.cache/blorp/packages/blake3/<first-16-hex>/
```

Set `BLORP_PACKAGE_CACHE` to use a different cache root. Cache entries store the
full hash in `HASH`; if two full hashes ever collide on the same 16-character
directory prefix, the cache reports the conflict instead of overwriting an
existing package.

## Vendor Directories

Vendoring is useful when a project wants dependency contents to be local,
reviewable, offline, and independent of network or registry availability during
builds. With hash-pinned source packages, a `vendor/` directory also gives CI a
simple invariant: the imported code is exactly the reviewed content in the repo.

`blorp package vendor` reads the nearest `blorp.toml` and copies each
cache-backed package alias to `vendor/<alias>` next to that config file. Local
path aliases are already vendored or otherwise local, so they are skipped.
`blorp package vendor <alias>` vendors one configured alias to `vendor/<alias>`.
These config-driven forms are safe to rerun: an existing `vendor/<alias>` is
accepted only when its package content hash still matches the configured pin.
Use `blorp package vendor <hash> <path>` or `blorp package vendor <alias>
<path>` to choose an explicit destination; explicit destinations must not
already exist.

Vendoring does not rewrite `blorp.toml`. After vendoring, projects that want
the repo to use checked-in dependency source should keep or paste package
entries with `path = "vendor/<alias>"` and the reviewed hash.

Vendoring should not be mandatory for every workflow. It is the conservative
path for projects that value checked-in dependencies, hermetic builds, and easy
source inspection.

## Imports

Root project code imports the project alias:

```blorp
import:
	json: parse
	json_legacy as OldJson
```

The alias does not need to match the package's `[package].name`. When an alias
differs, the compiler maps the alias to the package's exported module names.
For example, alias `json_legacy` can point at a package whose manifest name is
`json`.

Only exported modules can be imported through the root-project alias. If
package `json` contains `json/internal.brp` but does not list `json/internal`
in `[exports].modules`, root project code cannot import `json/internal`.

Inside package source, imports must stay within `std` and that package's own
source tree. Package source cannot import root-project local modules, `pkg/...`
modules, or other `[packages]` aliases.
