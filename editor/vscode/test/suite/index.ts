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

function positionOf(document: vscode.TextDocument, needle: string): vscode.Position {
  const index = document.getText().indexOf(needle);
  assert.notStrictEqual(index, -1, `fixture is missing ${needle}`);
  return document.positionAt(index);
}

function locationStartLine(location: vscode.DefinitionLink | vscode.Location): number {
  if ("targetRange" in location) {
    return location.targetRange.start.line;
  }

  return location.range.start.line;
}

function hoverText(hover: vscode.Hover): string {
  return hover.contents
    .map((content) => {
      if (typeof content === "string") {
        return content;
      }
      if (content instanceof vscode.MarkdownString) {
        return content.value;
      }
      return content.value;
    })
    .join("\n");
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

async function assertCleanDiagnostics(uri: vscode.Uri): Promise<void> {
  await eventually("clean diagnostics", () => {
    const diagnostics = vscode.languages.getDiagnostics(uri);
    return diagnostics.length === 0 ? true : undefined;
  });
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

async function testLanguageFeatures(): Promise<void> {
  const uri = await writeFixture(
    "features.brp",
    [
      "record Point {x: Int, y: Int}",
      "",
      "func identity[T](value: T) -> T:",
      "    value",
      "",
      "func main(args: List[String]) -> Int:",
      "    point: Point = {x = 1, y = 2}",
      "    identity(point).x",
      "",
    ].join("\n")
  );

  const document = await openBlorpDocument(uri);
  await assertCleanDiagnostics(uri);

  const pointType = positionOf(document, "Point =");
  const hovers = await eventually("type hover", async () => {
    const result = await vscode.commands.executeCommand<vscode.Hover[]>(
      "vscode.executeHoverProvider",
      uri,
      pointType
    );
    return result.length > 0 ? result : undefined;
  });
  assert.ok(
    hovers.some((hover) => hoverText(hover).includes("record Point {x: Int, y: Int}")),
    "expected record hover text for Point annotation"
  );

  const definitions = await vscode.commands.executeCommand<vscode.Location[]>(
    "vscode.executeDefinitionProvider",
    uri,
    pointType
  );
  assert.ok(
    definitions.some((definition) => locationStartLine(definition) === 0),
    "expected Point definition to resolve to the record declaration"
  );

  const completionPosition = pointType.translate(0, 2);
  const completions = await eventually("type completion", async () => {
    const result = await vscode.commands.executeCommand<vscode.CompletionList>(
      "vscode.executeCompletionItemProvider",
      uri,
      completionPosition
    );
    return result.items.length > 0 ? result : undefined;
  });
  assert.ok(
    completions.items.some((item) => item.label === "Point"),
    "expected Point in type-context completions"
  );

  const typeParamUse = positionOf(document, "value: T").translate(0, "value: ".length);
  const references = await vscode.commands.executeCommand<vscode.Location[]>(
    "vscode.executeReferenceProvider",
    uri,
    typeParamUse
  );
  assert.ok(references.length >= 3, "expected references for generic type parameter T");

  // VS Code does not expose a stable command-form document highlight provider
  // in every release. The LSP protocol fixture suite covers documentHighlight;
  // this extension-host E2E verifies that the extension starts the server and
  // routes representative editor commands through it.
}

export async function run(): Promise<void> {
  await testDiagnostics();
  await testLanguageFeatures();
}
