package com.blorp.intellij

import com.intellij.openapi.vfs.newvfs.impl.VfsRootAccess
import com.intellij.testFramework.PlatformTestUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase
import com.intellij.testFramework.fixtures.TempDirTestFixture
import com.intellij.testFramework.fixtures.impl.TempDirTestFixtureImpl
import com.redhat.devtools.lsp4ij.LanguageServerManager
import java.nio.file.Files
import java.nio.file.Path

/**
 * A test case that runs the repository's own `blorp lsp` build (`make -C blorp compiler`)
 * through LSP4IJ. A JVM runs one server-starting test: the light project outlives a test, and
 * so does its base directory setting, so a later test's server would start in a deleted folder.
 * Server features share that one test (see BlorpNavigationTest).
 */
abstract class BlorpServerTestCase : BasePlatformTestCase() {
    // The server reads imports and the library from disk, so the files must be real.
    override fun createTempDirTestFixture(): TempDirTestFixture = TempDirTestFixtureImpl()

    override fun setUp() {
        super.setUp()
        // The server writes the library it serves under /tmp (a link to /private/tmp on macOS).
        VfsRootAccess.allowRootAccess(testRootDisposable, "/tmp", "/private/tmp")
    }

    override fun tearDown() {
        try {
            LanguageServerManager.getInstance(project).stop(BLORP_SERVER_ID)
        } finally {
            super.tearDown()
        }
    }

    protected fun blorpBinary(): String {
        val binary = System.getProperty("blorp.binary")
        check(binary != null && Files.isExecutable(Path.of(binary))) {
            "no blorp build at $binary: run make -C blorp compiler"
        }
        return binary
    }

    protected fun startServer(path: String = blorpBinary()) {
        BlorpSettings.getInstance(project).serverPath = path
        LanguageServerManager.getInstance(project).start(BLORP_SERVER_ID)
    }

    // No API says when the server has the open document, so tests poll for an answer.
    protected fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + SERVER_READY_TIMEOUT_MS
        while (!condition()) {
            check(System.currentTimeMillis() < deadline) { "blorp lsp did not answer within $SERVER_READY_TIMEOUT_MS ms" }
            PlatformTestUtil.dispatchAllEventsInIdeEventQueue()
            Thread.sleep(POLL_MS)
        }
    }

    protected companion object {
        const val SERVER_READY_TIMEOUT_MS = 30_000L
        const val POLL_MS = 50L
    }
}
