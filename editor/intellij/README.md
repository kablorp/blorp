# Blorp for CLion

A minimal plugin: the `.brp` file type, a launcher for `blorp lsp`, and one setting.
The server supplies the colours (semantic tokens), diagnostics, definition and
references. The plugin has no highlighter: its lexer and flat parser only split a
file into word-sized elements, which Go to Declaration underlines and lands on,
and make Blorp appear in New Scratch File. The plugin colours nothing itself.

## Build

Needs the `blorp` binary at `blorp/build/blorp` (the plugin finds it there). Build
it optimized, since an editor waits on it (about 0.35 s against 5 s at -O0 for
the compiler's own `main.brp`):

    make -C blorp compiler TEST_COMPILER_FLAGS=-O2

Build the plugin against an installed CLion. The path comes from the `clionPath`
Gradle property; without it Gradle downloads the published CLion (large).
CLion 2026.3 needs JDK 25, so use its bundled runtime as the Gradle JVM:

    cd editor/intellij
    export JAVA_HOME=~/Applications/CLion.app/Contents/jbr/Contents/Home
    ./gradlew -PclionPath=$HOME/Applications/CLion.app test buildPlugin

The Go to Declaration test runs that `blorp/build/blorp` as the server, so build
the compiler first. The zip is `build/distributions/blorp-intellij-0.0.1.zip`. Gradle may still
download the Gradle distribution, the IntelliJ Platform and Kotlin Gradle
plugins, and Kotlin 2.3.

## Install

CLion: Settings > Plugins > gear > Install Plugin from Disk, pick the zip,
restart.

## Colours

The platform's default mapping leaves a parameter and the type beside it the same plain
text colour in Darcula, Dark, Light and Default, whose bundled schemes colour neither
`DEFAULT_CLASS_NAME` nor `DEFAULT_PARAMETER`. The plugin maps the server's token types
(`BlorpSemanticTokensSupport.kt`) to keys those schemes do colour, read from CLion's
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

## Go to Declaration

CLion's LSP support answers Go to Declaration only while the running action is
`GotoDeclaration`. CLion's C/C++ engine runs Cmd-B and Cmd-click inside its own
wrapper action, so through the LSP support alone they report "Cannot find
declaration to go to", while Cmd-hover and Navigate > Declaration work.
`BlorpGotoDeclarationHandler.kt` asks the server for the definition itself, as
CLion asks declaration handlers whatever the action. Remove it once CLion's LSP
support answers the wrapped shortcuts.

- Until the server has started, Cmd-click finds nothing.
- On a declaration's own name, Cmd-B and Cmd-click report "Cannot find
  declaration to go to" instead of listing usages: listing them is CLion's LSP
  support's job, which the wrapper blocks. Navigate > Declaration or Usages and
  Find Usages (Alt+F7) list them.

## Setting

Settings > Languages & Frameworks > Blorp > "Blorp executable path". The launcher
runs `<path> lsp` in the project's base directory.

- Blank (the default): `blorp/build/blorp` under the project if executable, else `blorp` on PATH.
- A bare name such as `blorp`: looked up on PATH (use this to ignore the project build).
- A relative path such as `build/blorp`: taken from the project root.
- An absolute path: used as given.

## Manual checklist

Open this repository in CLion. Tick each item that passes; write down what you saw
for any that fail.

- [ ] Open `blorp/src/main.brp`. Pass: the editor tab and Project view show the Blorp icon (a blue rounded square with a white b) and the Blorp file type (Settings > Editor > File Types lists `*.brp` under Blorp).
- [ ] Pass: `idea.log` (Help > Show Log in Finder) contains `Launching Blorp LSP: ... lsp`, and no launch error follows it.
- [ ] In `blorp/src/main.brp`, pass: keywords, comments, strings and numbers each have a colour, and names are coloured rather than plain text.
- [ ] In the same file, pass: a function parameter, a local, a record field, a function name, a type name and a library name (an imported function) each show a visibly different colour, and a parameter and the type written after it (`name: Type`) differ.
- [ ] Add `x = 1 + "a"` inside a function body of a scratch `.brp` file. Pass: a diagnostic appears on that line. Delete the line and type a character. Pass: the diagnostic disappears.
- [ ] In a scratch `.brp` file, add a line `func (` (a syntax error). Pass: the rest of the file keeps its colours.
- [ ] Open two files where the first imports the second. Edit the second (rename an exported function), then look at the first. Record whether the first file's colours or diagnostics update without editing it. (This answers the `workspace/semanticTokens/refresh` question; either answer is a result.)
- [ ] Go to Declaration: in `blorp/src/main.brp` Cmd-click `unknown_command` at line 64. Pass: the caret jumps to line 47. Cmd-click `parse_help` at line 107. Pass: it jumps to line 51. Put the caret on `unknown_command` at line 119 and press Cmd-B. Pass: it jumps to line 47. Cmd-click `print` in any file. Pass: a library file opens at its declaration. Also pass: holding Cmd over a name underlines it before the click.
- [ ] Find Usages (Alt+F7) on `parse_help`: pass if the usages list opens with its call sites.
- [ ] Change the path setting from one working value to another (for example blank, then an absolute path to the same binary). Pass without restarting CLion: `idea.log` shows a new `Launching Blorp LSP` line for the new path, and colours return.
- [ ] Set the path to `/nonexistent/blorp` and Apply. Pass: a balloon "The Blorp language server did not start" names `/nonexistent/blorp`, and its "Open Blorp settings" link opens the Blorp settings page. Then set a working path, Apply, and pass: the server starts without restarting CLion.
- [ ] File > New > Scratch File. Pass: Blorp is in the language list, and the new scratch file gets colours and diagnostics once it has text.
