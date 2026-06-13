package com.blorp.intellij

import com.intellij.psi.PsiFileFactory
import com.intellij.testFramework.fixtures.BasePlatformTestCase

class BlorpPsiImportElementTest : BasePlatformTestCase() {
    fun testRelativeImportPathAndItemHavePsiElements() {
        val source = "import:\n\t./document_layout:\n\t\tDoc,\n"
        val file =
            PsiFileFactory.getInstance(project)
                .createFileFromText("sample.brp", BlorpFileType.INSTANCE, source)

        fun elementTextAt(needle: String, offsetInNeedle: Int): String? {
            val offset = source.indexOf(needle) + offsetInNeedle
            return file.findElementAt(offset)?.text
        }

        assertEquals(".", elementTextAt("./document_layout", 0))
        assertEquals("/", elementTextAt("./document_layout", 1))
        assertEquals("document_layout", elementTextAt("document_layout", 2))
        assertEquals("Doc", elementTextAt("Doc", 1))
    }
}
