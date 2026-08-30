package com.blorp.intellij

import com.intellij.testFramework.fixtures.BasePlatformTestCase
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class BlorpLspServerDescriptorTest : BasePlatformTestCase() {
    fun testResolveBlorpPathPrefersExplicitConfiguration() {
        assertEquals(
            "/custom/blorp",
            resolveBlorpPath("/custom/blorp", "/workspace") { false }
        )
    }

    fun testResolveBlorpPathPrefersExecutableProjectBinary() {
        val expected = Path.of("/workspace", "bin", "blorp")
        assertEquals(
            expected.toString(),
            resolveBlorpPath("blorp", "/workspace") { it == expected }
        )
    }

    fun testResolveBlorpPathFallsBackToPath() {
        assertEquals("blorp", resolveBlorpPath("blorp", "/workspace") { false })
    }

    fun testFindFileByUriCanResolveUnopenedLocalBlorpFile() {
        val tempDir = Files.createTempDirectory("blorp-lsp-uri")
        val target = tempDir.resolve("relative_import_target.brp")

        try {
            Files.writeString(target, "func target() -> Int: 1\n")

            val descriptor = BlorpLspServerDescriptor(project)
            val virtualFile = descriptor.findFileByUri(target.toUri().toString())

            assertNotNull(virtualFile)
            assertEquals(target.toRealPath().toString(), Path.of(virtualFile!!.path).toRealPath().toString())
        } finally {
            Files.deleteIfExists(target)
            Files.deleteIfExists(tempDir)
        }
    }
}
