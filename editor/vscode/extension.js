'use strict';

// The Blorp extension: it starts `blorp lsp` and gives it every Blorp document,
// both the workspace's files and the standard library files the server serves
// under its own URI scheme. Every feature is the language client's own; the
// extension adds nothing on top of the protocol.

const fs = require('node:fs');
const path = require('node:path');
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

// The compiler's build output in a checkout of the Blorp repository.
const PROJECT_BUILD_BINARY = path.join('blorp', 'build', 'blorp');
// The name looked up on PATH when nothing else is configured or built.
const PATH_BINARY_NAME = 'blorp';
// The scheme the server lists in `workspace.textDocumentContent`. The client
// fetches such a document's text from the server and opens it read-only; the
// selector below gives it the server's features too.
const LIBRARY_SCHEME = 'blorp-library';
const SERVER_PATH_SETTING = 'server.path';

let client;
// Restarts run one after another, so two quick setting changes cannot
// interleave a stop with a start.
let restarting = Promise.resolve();

// The binary to run. A configured path wins: a relative one with a directory
// part is taken from the workspace folder, and a bare name is left for PATH.
// Otherwise the folder's build output, when it exists, else `blorp` on PATH.
// Without a workspace folder, a relative path is left to the process's working
// directory, and a failed start is the language client's error.
function resolveServerPath(configured, folder, isExecutable = isExecutableFile) {
    const configuredPath = configured.trim();
    if (configuredPath !== '') {
        // `/` separates directories on every platform Node runs on.
        const hasDirectory = configuredPath.includes('/') || configuredPath.includes(path.sep);
        const relativeWithDirectory = !path.isAbsolute(configuredPath) && hasDirectory;
        return relativeWithDirectory && folder ? path.join(folder, configuredPath) : configuredPath;
    }
    const projectBinary = folder ? path.join(folder, PROJECT_BUILD_BINARY) : undefined;
    return projectBinary && isExecutable(projectBinary) ? projectBinary : PATH_BINARY_NAME;
}

function isExecutableFile(file) {
    try {
        fs.accessSync(file, fs.constants.X_OK);
        return fs.statSync(file).isFile();
    } catch {
        return false;
    }
}

function newClient() {
    const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
    const configured = vscode.workspace.getConfiguration('blorp').get(SERVER_PATH_SETTING, '');
    const command = resolveServerPath(configured, folder);
    return new LanguageClient(
        'blorp',
        'Blorp',
        { command, args: ['lsp'], options: { cwd: folder } },
        {
            documentSelector: [
                { scheme: 'file', language: 'blorp' },
                { scheme: LIBRARY_SCHEME, language: 'blorp' },
            ],
        },
    );
}

// Stops the running client, which may have failed to start, then starts a new
// one with the current setting. A failure is shown, and the next change of the
// setting tries again.
function restart() {
    restarting = restarting.then(async () => {
        try {
            await client.stop();
        } catch {
            // A client that never started has nothing to stop.
        }
        client = newClient();
        try {
            await client.start();
        } catch (error) {
            vscode.window.showErrorMessage(`Blorp: the language server did not start: ${error.message}`);
        }
    });
    return restarting;
}

async function activate(context) {
    client = newClient();
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration((event) => {
            if (event.affectsConfiguration(`blorp.${SERVER_PATH_SETTING}`)) {
                restart();
            }
        }),
    );
    await client.start();
}

function deactivate() {
    return client?.stop();
}

module.exports = { activate, deactivate, resolveServerPath };
