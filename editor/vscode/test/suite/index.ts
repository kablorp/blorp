import * as assert from "assert";
import * as fs from "fs/promises";
import * as os from "os";
import * as path from "path";
import * as vscode from "vscode";

const RETRY_DELAY_MS = 100;
const DEFAULT_TIMEOUT_MS = 10000;

async function eventually<T>(
  description: string,
  probe: () => Promise<T | undefined> | T | undefined,
  timeoutMs = DEFAULT_TIMEOUT_MS
): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown;

  while (Date.now() < deadline) {
    try {
      const result = await probe();
      if (result !== undefined) {
        return result;
      }
    } catch (error) {
      lastError = error;
    }

    await new Promise((resolve) => setTimeout(resolve, RETRY_DELAY_MS));
  }

  const suffix = lastError === undefined ? "" : ` Last error: ${String(lastError)}`;
  throw new Error(`Timed out waiting for ${description}.${suffix}`);
}

async function writeFixture(name: string, source: string): Promise<vscode.Uri> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "blorp-vscode-e2e-"));
  const file = path.join(dir, name);
  await fs.writeFile(file, source, "utf8");
  return vscode.Uri.file(file);
}

async function openBlorpDocument(uri: vscode.Uri): Promise<vscode.TextDocument> {
  const document = await vscode.workspace.openTextDocument(uri);
  await vscode.window.showTextDocument(document);
  assert.strictEqual(document.languageId, "blorp");
  await eventually("Blorp extension activation", () => {
    const extension = vscode.extensions.all.find(
      (candidate) => candidate.packageJSON.name === "blorp-lang"
    );
    return extension?.isActive ? true : undefined;
  });
  return document;
}

async function testDiagnostics(): Promise<void> {
  const uri = await writeFixture(
    "diagnostics.brp",
    [
      'x: Int = "hello"',
      "",
      "func main(args: List[String]) -> Int:",
      "    0",
      "",
    ].join("\n")
  );

  await openBlorpDocument(uri);
  const diagnostics = await eventually("type diagnostics", () => {
    const current = vscode.languages.getDiagnostics(uri);
    return current.length > 0 ? current : undefined;
  });

  assert.ok(
    diagnostics.some((diagnostic) => diagnostic.message.length > 0),
    "expected at least one diagnostic message"
  );
}

export async function run(): Promise<void> {
  await testDiagnostics();
}
