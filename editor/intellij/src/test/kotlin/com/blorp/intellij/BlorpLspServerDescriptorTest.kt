package com.blorp.intellij

import com.intellij.testFramework.fixtures.BasePlatformTestCase
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class BlorpLspServerDescriptorTest : BasePlatformTestCase() {
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
