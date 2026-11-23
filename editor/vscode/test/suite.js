'use strict';

// The extension's features through VS Code's own commands, against the real
// server, in the fixture workspace that test/run.js prepares. Each check
// reports PASS or FAIL; any FAIL fails the run.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');

const EXTENSION_ID = 'blorp.blorp';
const LIBRARY_ROOT = path.resolve(__dirname, '..', '..', '..', 'blorp', 'standard_library');
const PRINT_LIBRARY_PATH = '/io/console/output.brp';
// How long the server may take to publish a broken file's diagnostics, and a
// restarted client to answer, at -O0.
const DIAGNOSTICS_TIMEOUT_MS = 20000;
const RESTART_TIMEOUT_MS = 20000;
const POLL_INTERVAL_MS = 200;
const MISSING_SERVER = '/nonexistent/blorp';

async function openDocument(uri) {
    const document = await vscode.workspace.openTextDocument(uri);
    await vscode.window.showTextDocument(document);
    return document;
}

// The tokens of a document as { line, start, length, type, modifiers }, from
// the relative encoding of the protocol.
async function semanticTokens(uri) {
    const legend = await vscode.commands.executeCommand('vscode.provideDocumentSemanticTokensLegend', uri);
    const tokens = await vscode.commands.executeCommand('vscode.provideDocumentSemanticTokens', uri);
    assert.ok(legend && tokens, 'no semantic tokens');
    const decoded = [];
    let line = 0;
    let start = 0;
    for (let i = 0; i < tokens.data.length; i += 5) {
        const [deltaLine, deltaStart, length, type, modifierBits] = tokens.data.slice(i, i + 5);
        line += deltaLine;
        start = deltaLine === 0 ? start + deltaStart : deltaStart;
        const modifiers = legend.tokenModifiers.filter((_, bit) => modifierBits & (1 << bit));
        decoded.push({ line, start, length, type: legend.tokenTypes[type], modifiers });
    }
    return decoded;
}

function tokenAt(tokens, line, start) {
    return tokens.find((token) => token.line === line && token.start === start);
}

async function definitions(uri, position) {
    return vscode.commands.executeCommand('vscode.executeDefinitionProvider', uri, position);
}

function where(location) {
    return `${location.uri.scheme}:${location.uri.path}@${location.range.start.line}:${location.range.start.character}`;
}

// Waits until `probe` holds, polling, or fails after `timeoutMs`.
async function eventually(description, probe, timeoutMs) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (await probe()) {
            return;
        }
        await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    }
    throw new Error(`${description} within ${timeoutMs} ms`);
}

function diagnosticsOf(uri) {
    const current = vscode.languages.getDiagnostics(uri);
    if (current.length > 0) {
        return Promise.resolve(current);
    }
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
            subscription.dispose();
            reject(new Error(`no diagnostics within ${DIAGNOSTICS_TIMEOUT_MS} ms`));
        }, DIAGNOSTICS_TIMEOUT_MS);
        const subscription = vscode.languages.onDidChangeDiagnostics(() => {
            const published = vscode.languages.getDiagnostics(uri);
            if (published.length > 0) {
                clearTimeout(timer);
                subscription.dispose();
                resolve(published);
            }
        });
    });
}

async function run() {
    const folder = vscode.workspace.workspaceFolders[0].uri;
    const main = await openDocument(vscode.Uri.joinPath(folder, 'main.brp'));
    await vscode.extensions.getExtension(EXTENSION_ID).activate();
    const text = main.getText();
    const helperDeclaration = main.positionAt(text.indexOf('helper'));
    const helperUse = main.positionAt(text.lastIndexOf('helper'));
    const printUse = main.positionAt(text.indexOf('print'));

    const results = [];
    async function check(name, body) {
        try {
            await body();
            results.push(`PASS ${name}`);
        } catch (error) {
            results.push(`FAIL ${name}: ${error.message}`);
        }
    }

    await check('a user file is coloured, with a declared function as a function declaration', async () => {
        const token = tokenAt(await semanticTokens(main.uri), helperDeclaration.line, helperDeclaration.character);
        assert.deepEqual(token, {
            line: 0, start: 10, length: 6, type: 'function', modifiers: ['declaration'],
        });
    });

    await check('Go to Definition on a use reaches the declaration', async () => {
        const found = await definitions(main.uri, helperUse);
        assert.deepEqual(found.map(where), [`file:${main.uri.path}@0:10`]);
    });

    let library;
    await check('Go to Definition on print reaches the library file under blorp-library:', async () => {
        const found = await definitions(main.uri, printUse);
        assert.equal(found.length, 1);
        assert.equal(found[0].uri.scheme, 'blorp-library');
        assert.equal(found[0].uri.path, PRINT_LIBRARY_PATH);
        library = found[0];
    });

    await check('the library file opens read-only as Blorp, with the library text', async () => {
        const document = await openDocument(library.uri);
        assert.equal(document.languageId, 'blorp');
        assert.equal(document.getText(), fs.readFileSync(path.join(LIBRARY_ROOT, PRINT_LIBRARY_PATH), 'utf8'));
        const declared = document.getText().split('\n')[library.range.start.line];
        assert.equal(declared.slice(library.range.start.character, library.range.end.character), 'print');
    });

    await check('the library file is coloured', async () => {
        const tokens = await semanticTokens(library.uri);
        const declared = (await vscode.workspace.openTextDocument(library.uri)).lineAt(library.range.start.line).text;
        assert.equal(tokenAt(tokens, 0, 0)?.type, 'comment');
        assert.deepEqual(tokenAt(tokens, library.range.start.line, declared.indexOf('func')), {
            line: library.range.start.line, start: declared.indexOf('func'), length: 4, type: 'keyword', modifiers: [],
        });
    });

    await check('Find All References from the declaration lists the declaration and the use', async () => {
        const found = await vscode.commands.executeCommand(
            'vscode.executeReferenceProvider', main.uri, helperDeclaration,
        );
        assert.deepEqual(found.map(where).sort(), [
            `file:${main.uri.path}@0:10`,
            `file:${main.uri.path}@${helperUse.line}:${helperUse.character}`,
        ].sort());
    });

    await check('Go to Definition on a declaration answers the declaration itself', async () => {
        // On that answer VS Code runs its alternative command, which lists the
        // references: Cmd-click on a declaration.
        const found = await definitions(main.uri, helperDeclaration);
        assert.deepEqual(found.map(where), [`file:${main.uri.path}@0:10`]);
    });

    await check('a broken file gets its diagnostic', async () => {
        const broken = await openDocument(vscode.Uri.joinPath(folder, 'broken.brp'));
        const published = await diagnosticsOf(broken.uri);
        const text = broken.getText();
        assert.equal(published.length, 1);
        assert.equal(
            published[0].message,
            "unknown value\nhelp: use this function's parameter name, a declared variant, or a call",
        );
        assert.deepEqual(published[0].range, new vscode.Range(
            broken.positionAt(text.indexOf('missing_name')),
            broken.positionAt(text.indexOf('missing_name') + 'missing_name'.length),
        ));
    });

    await check('a changed server path restarts the server, also after a failed start', async () => {
        const settings = vscode.workspace.getConfiguration('blorp');
        const server = settings.get('server.path');
        const answers = async () => (await definitions(main.uri, helperUse)).length === 1;
        await settings.update('server.path', MISSING_SERVER, vscode.ConfigurationTarget.Workspace);
        await eventually('the stopped server stopped answering', async () => !(await answers()), RESTART_TIMEOUT_MS);
        // The same binary under another spelling, so the setting changes.
        const respelled = [path.dirname(server), '.', path.basename(server)].join(path.sep);
        await settings.update('server.path', respelled, vscode.ConfigurationTarget.Workspace);
        await eventually('the restarted server answered', answers, RESTART_TIMEOUT_MS);
    });

    console.log(results.join('\n'));
    const failures = results.filter((line) => line.startsWith('FAIL'));
    if (failures.length > 0) {
        throw new Error(`${failures.length} of ${results.length} checks failed`);
    }
}

module.exports = { run };
