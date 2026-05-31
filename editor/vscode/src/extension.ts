import {
  ExtensionContext,
  workspace,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";
import { accessSync, constants } from "fs";
import { join } from "path";

let client: LanguageClient | undefined;

function workspaceRoot(): string | undefined {
  return workspace.workspaceFolders?.[0]?.uri.fsPath;
}

function isExecutable(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveBlorpPath(configured: string): string {
  const configuredPath = configured.trim();
  if (configuredPath !== "" && configuredPath !== "blorp") {
    return configuredPath;
  }

  const root = workspaceRoot();
  if (root !== undefined) {
    const projectBinary = join(root, "blorp");
    if (isExecutable(projectBinary)) {
      return projectBinary;
    }
  }

  return "blorp";
}

export function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("blorp");
  const command = resolveBlorpPath(config.get<string>("serverPath", "blorp"));
  const cwd = workspaceRoot();

  const serverOptions: ServerOptions = {
    command,
    args: ["lsp"],
    transport: TransportKind.stdio,
    options: cwd === undefined ? undefined : { cwd },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "blorp" }],
  };

  client = new LanguageClient("blorp", "Blorp Language Server", serverOptions, clientOptions);
  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
