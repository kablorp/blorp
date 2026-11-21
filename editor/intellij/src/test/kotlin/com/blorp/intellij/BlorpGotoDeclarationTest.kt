package com.blorp.intellij

import com.intellij.codeInsight.navigation.actions.GotoDeclarationOrUsageHandler2
import com.intellij.codeInsight.navigation.actions.GotoDeclarationOrUsageHandler2.GTDUOutcome
import com.intellij.concurrency.installThreadContext
import com.intellij.openapi.actionSystem.ex.ActionContextElement
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.runReadActionBlocking
import com.intellij.platform.lsp.api.LspClientManager
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.testFramework.fixtures.TempDirTestFixture
import com.intellij.testFramework.fixtures.impl.TempDirTestFixtureImpl
import com.intellij.openapi.vfs.newvfs.impl.VfsRootAccess
import java.nio.file.Files
import java.nio.file.Path

/**
 * Go to Declaration against the repository's own `blorp lsp` build (`make -C blorp compiler`).
 * In CLion, Cmd-B and Cmd-click run under the C/C++ engine's wrapper action, not under
 * `GotoDeclaration`; the Navigate menu runs `GotoDeclaration` itself.
 */
class BlorpGotoDeclarationTest : BasePlatformTestCase() {
    private val source = """
        pure func helper(x: Int) -> Int:
            x + 1

        func main():
            print("${'$'}{helper(2)}")
    """.trimIndent() + "\n"

    private val helperUse = source.lastIndexOf("helper")

    // The server reads imports and the library from disk, so the files must be real.
    override fun createTempDirTestFixture(): TempDirTestFixture = TempDirTestFixtureImpl()

    override fun setUp() {
        super.setUp()
        // The server writes the library it serves under /tmp (a link to /private/tmp on macOS).
        VfsRootAccess.allowRootAccess(testRootDisposable, "/tmp", "/private/tmp")
    }

    override fun tearDown() {
        try {
            LspClientManager.getInstance(project).stopClients(BlorpLspIntegrationProvider::class.java)
        } finally {
            super.tearDown()
        }
    }

    // One test, one server: the light project outlives a test, and so does its base
    // directory setting, so a second test's server would start in a deleted folder.
    fun testShortcutsUnderTheCppEngineWrapperReachTheDeclaredNames() {
        val file = myFixture.configureByText("main.brp", source)
        assertEquals(emptyList<PsiElement>(), targetsAt(file, helperUse))

        startServer(file)
        assertEquals(GTDUOutcome.GTD, outcomeUnder(CPP_ENGINE_SHORTCUT_ACTION, file, helperUse))
        // On the declaration the handler steps aside, so the menu still lists usages.
        assertEquals(GTDUOutcome.SU, outcomeUnder(NAVIGATE_MENU_ACTION, file, source.indexOf("helper")))

        val local = targetsAt(file, helperUse).single()
        assertEquals("main.brp", local.containingFile.name)
        assertEquals(source.indexOf("helper"), local.textOffset)
        val library = targetsAt(file, source.indexOf("print")).single()
        assertEquals("print", library.text)
        val libraryPath = library.containingFile.virtualFile.path
        assertTrue(libraryPath, libraryPath.contains("/blorp-lsp-"))
    }

    private fun startServer(file: PsiFile) {
        val binary = System.getProperty("blorp.binary")
        check(binary != null && Files.isExecutable(Path.of(binary))) {
            "no blorp build at $binary: run make -C blorp compiler"
        }
        BlorpSettings.getInstance(project).serverPath = binary
        LspClientManager.getInstance(project)
            .ensureClientStarted(BlorpLspIntegrationProvider::class.java, BlorpLspClientDescriptor(project))
        // No API says when the server has the open document; the Navigate menu's own
        // path answering is the signal.
        waitUntil { outcomeUnder(NAVIGATE_MENU_ACTION, file, helperUse) == GTDUOutcome.GTD }
    }

    // Off the UI thread and in a read action, as CLion runs Go to Declaration.
    private fun outcomeUnder(actionId: String, file: PsiFile, offset: Int): GTDUOutcome? {
        val editor = myFixture.editor
        val outcome = ApplicationManager.getApplication().executeOnPooledThread<GTDUOutcome?> {
            installThreadContext(ActionContextElement(actionId, "keyboard shortcut", 0, null), replace = true) {
                GotoDeclarationOrUsageHandler2.testGTDUOutcomeInNonBlockingReadAction(editor, file, offset)
            }
        }
        return PlatformTestUtil.waitForFuture(outcome, SERVER_READY_TIMEOUT_MS)
    }

    private fun targetsAt(file: PsiFile, offset: Int): List<PsiElement> {
        val editor = myFixture.editor
        val targets = ApplicationManager.getApplication().executeOnPooledThread<List<PsiElement>> {
            runReadActionBlocking {
                BlorpGotoDeclarationHandler()
                    .getGotoDeclarationTargets(file.findElementAt(offset), offset, editor)
                    ?.toList()
                    .orEmpty()
            }
        }
        return PlatformTestUtil.waitForFuture(targets, SERVER_READY_TIMEOUT_MS)
    }

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + SERVER_READY_TIMEOUT_MS
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "blorp lsp did not answer within $SERVER_READY_TIMEOUT_MS ms" }
            PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
            Thread.sleep(POLL_MS)
        }
    }

    private companion object {
        const val NAVIGATE_MENU_ACTION = "GotoDeclaration"

        // The action id CLion 2026.3 reports while its C/C++ engine runs a shortcut
        // (seen in idea.log for Cmd-B and Cmd-click).
        const val CPP_ENGINE_SHORTCUT_ACTION =
            "com.jetbrains.rider.actions.RiderActionUpdateInterceptor\$RiderBackendCompositeAction"

        const val SERVER_READY_TIMEOUT_MS = 30_000L
        const val POLL_MS = 50L
    }
}
