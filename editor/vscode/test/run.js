'use strict';

// Runs test/suite.js inside an installed VS Code, against a copy of the
// fixture folder whose settings point at this checkout's `blorp/build/blorp`.
// The user data and extensions folders are fresh, so no installed extension
// or setting takes part. Exits with VS Code's status.

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const MACOS_VSCODE = '/Applications/Visual Studio Code.app/Contents/MacOS/Code';
// Long enough for VS Code's start and the checks' analyses at -O0.
const VSCODE_TIMEOUT_MS = 5 * 60 * 1000;
const vscodeBinary = process.env.VSCODE_BINARY || MACOS_VSCODE;
const extensionRoot = path.resolve(__dirname, '..');
const server = path.resolve(extensionRoot, '..', '..', 'blorp', 'build', 'blorp');
if (!fs.existsSync(server)) {
    console.error(`${server} does not exist; build it with make -C blorp compiler`);
    process.exit(1);
}

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'blorp-vscode-test-'));
const workspace = path.join(scratch, 'workspace');
fs.cpSync(path.join(__dirname, 'fixture'), workspace, { recursive: true });
fs.mkdirSync(path.join(workspace, '.vscode'));
fs.writeFileSync(
    path.join(workspace, '.vscode', 'settings.json'),
    JSON.stringify({ 'blorp.server.path': server }, null, 2),
);

// VS Code refuses to start as a GUI when this is set, which a parent tool may do.
const environment = { ...process.env };
delete environment.ELECTRON_RUN_AS_NODE;

const result = spawnSync(
    vscodeBinary,
    [
        workspace,
        `--extensionDevelopmentPath=${extensionRoot}`,
        `--extensionTestsPath=${path.join(__dirname, 'suite.js')}`,
        `--user-data-dir=${path.join(scratch, 'user-data')}`,
        `--extensions-dir=${path.join(scratch, 'extensions')}`,
        '--disable-workspace-trust',
        '--skip-welcome',
        '--skip-release-notes',
        '--new-window',
    ],
    { stdio: 'inherit', env: environment, timeout: VSCODE_TIMEOUT_MS },
);
fs.rmSync(scratch, { recursive: true, force: true });
if (result.error) {
    console.error(`could not run ${vscodeBinary} to the end: ${result.error.message}; set VSCODE_BINARY`);
}
process.exit(result.status ?? 1);
