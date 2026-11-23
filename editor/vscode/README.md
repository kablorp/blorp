# Blorp for VS Code

A VS Code extension that starts `blorp lsp` and gives it every Blorp file. The
extension only starts the server. Every feature comes from the server, through
Microsoft's language client
([`vscode-languageclient`](https://www.npmjs.com/package/vscode-languageclient)
11.0.1):

- colours, from semantic tokens;
- diagnostics;
- Go to Definition, into the standard library too;
- Find All References.

Library files open read-only under `blorp-library:` URIs, with their colours.
Editors built on VS Code, such as VSCodium or Cursor, run the extension the
same way.

## Build and install

Build the server at `-O2`. The default `-O0` build answers several times more
slowly:

```sh
make -C blorp compiler TEST_COMPILER_FLAGS=-O2
```

Then install the client:

```sh
cd editor/vscode && npm ci
```

In VS Code, run **Developer: Install Extension from Location…** and choose
`editor/vscode`. Open the repository's folder: the extension starts
`blorp/build/blorp` from it. In a multi-root workspace the first folder
counts.

To try a change to the extension without installing it, open a window with it
loaded:

```sh
code --extensionDevelopmentPath=editor/vscode .
```

## Setting

**Blorp › Server: Path** (`blorp.server.path`) is the `blorp` binary to run as
`blorp lsp`.

- **Blank** means `blorp/build/blorp` in the workspace folder when it exists,
  else `blorp` on `PATH`.
- **A relative path with a directory part**, such as `build/blorp`, is taken
  from the workspace folder.
- **A bare name** is looked up on `PATH`.

Changing it restarts the server. If the server does not start, VS Code shows
the error, and the next change of the setting tries again.

## Known limits

The server's limits, which `blorp/README.md` describes under "The language
server", apply:

- definitions inside a library file go nowhere, since a library file gets
  colours only;
- Go to Definition on a type built into the language, such as `Int`, goes
  nowhere;
- uses in a module that imports the open file are not found.

## Test

```sh
cd editor/vscode && npm test
```

`test/run.js` runs `test/suite.js` in the installed VS Code, against a copy of
`test/fixture` and this checkout's `blorp/build/blorp`. It uses fresh user data
and extensions folders, and a VS Code window opens while it runs. It checks:

- colours in a user file and in a library file;
- Go to Definition, locally and into the library;
- the library file's text;
- Find All References;
- the definition on a declaration, which makes Cmd-click list references;
- a diagnostic, with its message and range;
- a restart when the server path changes, also after a failed start.

`VSCODE_BINARY` names another VS Code binary. The default is
`/Applications/Visual Studio Code.app/Contents/MacOS/Code`.
