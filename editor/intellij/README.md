# Blorp for CLion

A minimal plugin: the `.brp` file type, a launcher for `blorp lsp`, one setting and the colours
for the server's semantic tokens. The language client is LSP4IJ (Red Hat's LSP plugin), which
supplies the semantic-token colours, diagnostics, Go to Declaration and Find Usages. The plugin
has no highlighter of its own: its lexer and flat parser only split a file into word-sized
elements, which LSP4IJ's word pick lands on, and make Blorp appear in New Scratch File.

## Prerequisite

Install LSP4IJ first: Settings > Plugins > Marketplace > "LSP4IJ". The plugin depends on it
(`com.redhat.devtools.lsp4ij`; built and tested against 0.30.1). The Language Servers tool
window (bottom bar) lists the Blorp server and shows its log and traces.

## Build

Needs the `blorp` binary at `blorp/build/blorp` (the plugin finds it there). Build
it optimized, since an editor waits on it (about 0.35 s against 5 s at -O0 for
the compiler's own `main.brp`):

    make -C blorp compiler TEST_COMPILER_FLAGS=-O2

Build the plugin against an installed CLion. The path comes from the `clionPath`
Gradle property; without it Gradle downloads the published CLion (large). Gradle also
downloads LSP4IJ 0.30.1 (about 4.7 MB) from the JetBrains Marketplace.
CLion 2026.3 needs JDK 25, so use its bundled runtime as the Gradle JVM:

    cd editor/intellij
    export JAVA_HOME=~/Applications/CLion.app/Contents/jbr/Contents/Home
    ./gradlew -PclionPath=$HOME/Applications/CLion.app test buildPlugin

The navigation test runs that `blorp/build/blorp` as the server, so build
the compiler first. The zip is `build/distributions/blorp-intellij-0.0.1.zip`. Gradle may still
download the Gradle distribution, the IntelliJ Platform and Kotlin Gradle
plugins, and Kotlin 2.3.

## Install

CLion: Settings > Plugins > gear > Install Plugin from Disk, pick the zip,
restart.

## Colours

LSP4IJ's default mapping leaves a parameter and the type beside it the same plain
text colour in Darcula, Dark, Light and Default, whose bundled schemes colour neither
`DEFAULT_CLASS_NAME` nor `DEFAULT_PARAMETER`. The plugin maps the server's token types
(`BlorpSemanticTokensColors.kt`, an LSP4IJ colours provider) to keys those schemes do colour, read from CLion's
`DefaultColorSchemesManager.xml` (Default, Darcula) and `themes/expUI` (New UI Dark and Light):

| Token | Key | Darcula | New UI Dark | New UI Light | Default |
|---|---|---|---|---|---|
| type, interface, enum | `TYPE_PARAMETER_NAME_ATTRIBUTES` | 507874 teal | 16BAAC teal | 007e8a teal | 20999d teal |
| typeParameter | `METADATA` | bbb529 | b3ae60 | 9e880d | 808000 |
| parameter | `INSTANCE_FIELD` | 9876aa purple | c77dbb purple | 871094 purple | 660e7a bold purple |
| property | `STATIC_FIELD` | 9876aa italic | c77dbb italic | 871094 italic | 660e7a italic |
| enumMember | `CONSTANT` | 9876aa italic | c77dbb italic | 871094 italic | 660e7a bold italic |
| function, method | `FUNCTION_DECLARATION` | ffc66d | 56a8f5 | 00627a | plain |
| library function | `STATIC_METHOD` | ffc66d italic | 57aaf7 italic | 00627a italic | italic |
| keyword | `KEYWORD` | cc7832 | cf8e6d | 0033b3 | 000080 bold |
| comment, string, number | `LINE_COMMENT`, `STRING`, `NUMBER` | | | | |
| namespace, variable, operator | plain text | | | | |

`TYPE_PARAMETER_NAME_ATTRIBUTES` is not a `DefaultLanguageHighlighterColors` key (Java
names it) but every bundled scheme colours it teal, and nothing else standard does. Colours
repeat only between kinds that are not neighbours. There is no settings page: change a
colour in Settings > Editor > Color Scheme for the key above.

## Go to Declaration and Find Usages

Both come from LSP4IJ; the plugin has no handler of its own. LSP4IJ asks the server for the
definition through a declaration handler, which CLion consults under any action, so Cmd-B and
Cmd-click work under CLion's C/C++ engine, into the library too. The lexer splits a string's
`${` and `}` into single-character tokens so that LSP4IJ's word pick lands on a name inside a
hole.

Library files (Cmd-click `print`) open read-only, as `blorp-library:` documents whose text LSP4IJ
fetches from the server with `workspace/textDocumentContent`; they get the lexer's colours only,
and LSP4IJ's own tokens request for them is checked by hand in CLion.

Known limits:

- Until the server has started, Cmd-click finds nothing.
- On a declaration's own name, Cmd-B and Cmd-click report "Cannot find declaration to go to"
  instead of listing usages. Find Usages (Alt+F7) is the way to list them; Navigate > Declaration or Usages has not been checked under LSP4IJ.
- Alt+F7 listed no usages in one CLion 2026.3 run, though LSP4IJ's Find Usages works in the
  test sandbox with CLion's plugins loaded (also when started from a declaration under the
  C/C++ engine's wrapper action). If it recurs, see LSP4IJ's Language Servers window for a
  `textDocument/references` request.

## Setting

Settings > Languages & Frameworks > Blorp > "Blorp executable path". The launcher
runs `<path> lsp` in the project's base directory.

- Blank (the default): `blorp/build/blorp` under the project if executable, else `blorp` on PATH.
- A bare name such as `blorp`: looked up on PATH (use this to ignore the project build).
- A relative path such as `build/blorp`: taken from the project root.
- An absolute path: used as given.

## Manual checklist

Install LSP4IJ and this plugin, then open this repository in CLion. Tick each item that
passes; write down what you saw for any that fail.

- [ ] Open `blorp/src/main.brp`. Pass: the editor tab and Project view show the Blorp icon and the Blorp file type, and the Language Servers window lists Blorp as started.
- [ ] In `blorp/src/main.brp`, pass: keywords, comments, strings and numbers each have a colour, and names are coloured rather than plain text.
- [ ] In the same file, pass: a function parameter, a local, a record field, a function name, a type name and a library name each show a visibly different colour, and a parameter and the type after it (`name: Type`) differ.
- [ ] Add `x = 1 + "a"` inside a function of a scratch `.brp` file. Pass: a diagnostic appears; delete the line and type a character, and it disappears.
- [ ] Add a line `func (` (a syntax error). Pass: the rest of the file keeps its colours.
- [ ] Go to Declaration: Cmd-click `unknown_command` at line 64 of `blorp/src/main.brp`. Pass: the caret jumps to line 47. Cmd-B on `unknown_command` at line 119 also jumps to line 47. Cmd-click `print`. Pass: a read-only library file opens at its declaration.
- [ ] Cmd-click a name inside a string's `${ }` hole. Pass: it jumps to the declaration.
- [ ] Find Usages (Alt+F7) on `parse_help`: pass if the usages list opens with its call sites. Record what happens if it does not.
- [ ] Change the path setting from one working value to another. Pass without restarting CLion: the Language Servers window shows the server restarted, and colours return.
- [ ] Set the path to `/nonexistent/blorp` and Apply. Pass: a balloon "The Blorp language server did not start" names it, and its "Open Blorp settings" link opens the Blorp settings page. Then set a working path, Apply, and pass: the server starts again.
- [ ] File > New > Scratch File. Pass: Blorp is in the language list, and the new scratch file gets colours and diagnostics once it has text.
