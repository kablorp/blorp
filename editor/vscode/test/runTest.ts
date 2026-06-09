import { runTests } from "@vscode/test-electron";
import * as path from "path";

async function main(): Promise<void> {
  const extensionDevelopmentPath = path.resolve(__dirname, "..", "..");
  const extensionTestsPath = path.resolve(__dirname, "suite", "index");
  const workspacePath = path.resolve(extensionDevelopmentPath, "..", "..");

  await runTests({
    extensionDevelopmentPath,
    extensionTestsPath,
    launchArgs: [workspacePath, "--disable-workspace-trust"],
  });
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
