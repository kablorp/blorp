package com.blorp.intellij

import com.intellij.codeInsight.navigation.actions.GotoDeclarationHandler
import com.intellij.codeInsight.navigation.actions.GotoDeclarationOrUsageHandler2
import com.intellij.codeInsight.navigation.actions.GotoDeclarationOrUsageHandler2.GTDUOutcome
import com.intellij.concurrency.installThreadContext
import com.intellij.find.findUsages.FindUsagesOptions
import com.intellij.openapi.actionSystem.ex.ActionContextElement
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.application.runReadActionBlocking
import com.intellij.psi.PsiFile
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.usages.PsiElementUsageTarget
import com.intellij.usages.UsageInfo2UsageAdapter
import com.intellij.util.ui.UIUtil
import com.redhat.devtools.lsp4ij.usages.LSPUsageSearcher
import com.redhat.devtools.lsp4ij.usages.LSPUsageTargetProvider
import java.nio.file.Files
import java.nio.file.Path
import javax.swing.JTextField

/**
 * The server features through LSP4IJ against the real server, in one test (a JVM runs one
 * server-starting test; see [BlorpServerTestCase]): Go to Declaration, Find Usages, and the
 * restart when the path setting changes.
 *
 * Go to Declaration: any action id other than `GotoDeclaration` exercises LSP4IJ's declaration
 * handler path; the id used is the C/C++ engine's wrapper, which is the one users hit with
 * Cmd-B and Cmd-click in CLion.
 */
class BlorpNavigationTest : BlorpServerTestCase() {
    private val source = """
        pure func helper(x: Int) -> Int:
            x + 1

        func main():
            print("${'$'}{helper(2)}")
    """.trimIndent() + "\n"

    private val helperDeclaration = source.indexOf("helper")
    private val helperUse = source.lastIndexOf("helper")

    fun testNavigationAndRestartOnPathChange() {
        val file = myFixture.configureByText("main.brp", source)
        startServer()
        waitUntil { outcomeUnder(NAVIGATE_MENU_ACTION, file, helperUse) == GTDUOutcome.GTD }

        assertEquals(GTDUOutcome.GTD, outcomeUnder(CPP_ENGINE_SHORTCUT_ACTION, file, helperUse))
        val local = targetsUnder(CPP_ENGINE_SHORTCUT_ACTION, file, helperUse).single()
        assertEquals("main.brp", local.fileName)
        assertEquals(helperDeclaration, local.offset)

        val library = targetsUnder(CPP_ENGINE_SHORTCUT_ACTION, file, source.indexOf("print")).single()
        assertEquals("output.brp", library.fileName)
        assertTrue(library.path, library.path.contains("/blorp-lsp-"))

        // The use sits inside a string's `${}` hole, the hardest place for LSP4IJ's word pick.
        myFixture.editor.caretModel.moveToOffset(helperUse)
        val usages = usageOffsets()
        // The declaration is listed as a declaration and again as a definition of the use.
        assertEquals(listOf(helperDeclaration, helperDeclaration, helperUse), usages.sorted())

        assertChangingThePathRestartsTheServer()
    }

    // The new path must start a new server process: each wrapper script logs its own start.
    private fun assertChangingThePathRestartsTheServer() {
        val directory = Files.createTempDirectory("blorp-restart")
        fun wrapper(name: String): Pair<Path, Path> {
            val log = directory.resolve("$name.log")
            val script = directory.resolve("$name.sh")
            Files.writeString(script, "#!/bin/sh\necho started >> '$log'\nexec '${blorpBinary()}' \"$@\"\n")
            script.toFile().setExecutable(true)
            return script to log
        }
        val (scriptB, logB) = wrapper("b")
        val configurable = BlorpConfigurable(project)
        val field = UIUtil.findComponentOfType(configurable.createComponent()!!, JTextField::class.java)!!
        configurable.reset()
        field.text = scriptB.toString()
        configurable.apply()
        waitUntil { Files.exists(logB) }
        configurable.disposeUIResources()
    }

    // LSP4IJ's own target provider and searcher, asked as Find Usages asks them.
    private fun usageOffsets(): List<Int> {
        val offsets = ApplicationManager.getApplication().executeOnPooledThread<List<Int>> {
            val element = runReadActionBlocking {
                val targets = LSPUsageTargetProvider().getTargets(myFixture.editor, myFixture.file)
                (targets?.singleOrNull() as? PsiElementUsageTarget)?.element
            }
            check(element != null && element.textRange.substring(source) == "helper") {
                "usage target is '${element?.text}', not the name"
            }
            val found = mutableListOf<Int>()
            LSPUsageSearcher().processElementUsages(element, { usage ->
                runReadActionBlocking { found += (usage as UsageInfo2UsageAdapter).navigationOffset }
                true
            }, FindUsagesOptions(project))
            found
        }
        return PlatformTestUtil.waitForFuture(offsets, SERVER_READY_TIMEOUT_MS)
    }

    private class Target(val path: String, val offset: Int) {
        val fileName get() = path.substringAfterLast('/')
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

    private fun targetsUnder(actionId: String, file: PsiFile, offset: Int): List<Target> {
        val editor = myFixture.editor
        val targets = ApplicationManager.getApplication().executeOnPooledThread<List<Target>> {
            installThreadContext(ActionContextElement(actionId, "keyboard shortcut", 0, null), replace = true) {
                runReadActionBlocking {
                    GotoDeclarationHandler.EP_NAME.extensionList.flatMap { handler ->
                        handler.getGotoDeclarationTargets(file.findElementAt(offset), offset, editor)
                            .orEmpty()
                            .map { Target(it.containingFile.virtualFile.path, it.textOffset) }
                    }
                }
            }
        }
        return PlatformTestUtil.waitForFuture(targets, SERVER_READY_TIMEOUT_MS)
    }

    private companion object {
        const val NAVIGATE_MENU_ACTION = "GotoDeclaration"

        // The action id CLion 2026.3 reports while its C/C++ engine runs a shortcut
        // (seen in idea.log for Cmd-B and Cmd-click).
        const val CPP_ENGINE_SHORTCUT_ACTION =
            "com.jetbrains.rider.actions.RiderActionUpdateInterceptor\$RiderBackendCompositeAction"
    }
}
