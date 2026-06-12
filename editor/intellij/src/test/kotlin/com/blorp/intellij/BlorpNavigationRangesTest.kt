package com.blorp.intellij

import com.intellij.openapi.util.TextRange
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class BlorpNavigationRangesTest {
    @Test
    fun `relative module path is a navigation target from punctuation`() {
        val source =
            """
            import:
                ./helpers/math: triple
            """.trimIndent()
        val pathStart = source.indexOf("./helpers/math")
        val pathEnd = pathStart + "./helpers/math".length

        assertEquals(
            TextRange(pathStart, pathEnd),
            BlorpNavigationRanges.importTargetRangeAt(source, pathStart)
        )
        assertEquals(
            TextRange(pathStart, pathEnd),
            BlorpNavigationRanges.importTargetRangeAt(source, pathStart + 1)
        )
    }

    @Test
    fun `later relative module path in multiline import block is a navigation target`() {
        val source =
            """
            import:
                ./left/maker:
                    make as make_left
                ./right/maker:
                    make
            """.trimIndent()
        val pathStart = source.indexOf("./right/maker")
        val pathEnd = pathStart + "./right/maker".length

        assertEquals(
            TextRange(pathStart, pathEnd),
            BlorpNavigationRanges.importTargetRangeAt(source, pathStart)
        )
    }

    @Test
    fun `parent relative module path with alias is a navigation target`() {
        val source =
            """
            import:
                ../../../tools/formatter/document_layout as Layout
            """.trimIndent()
        val pathStart = source.indexOf("../../../tools")
        val pathEnd = pathStart + "../../../tools/formatter/document_layout".length

        assertEquals(
            TextRange(pathStart, pathEnd),
            BlorpNavigationRanges.importTargetRangeAt(source, pathStart + 4)
        )
    }

    @Test
    fun `import items still use identifier navigation ranges`() {
        val source =
            """
            import:
                ./helpers/math: triple
            """.trimIndent()
        val itemStart = source.indexOf("triple")

        assertEquals(
            TextRange(itemStart, itemStart + "triple".length),
            BlorpNavigationRanges.importTargetRangeAt(source, itemStart + 2)
        )
    }

    @Test
    fun `multiline relative import items are navigation targets`() {
        val source = "import:\n\t./document_layout:\n\t\tDoc,\n\t\tlayout,\n"
        val itemStart = source.indexOf("Doc")

        assertEquals(
            TextRange(itemStart, itemStart + "Doc".length),
            BlorpNavigationRanges.importTargetRangeAt(source, itemStart + 1)
        )
    }

    @Test
    fun `later tab-indented relative module path is a navigation target`() {
        val source =
            "import:\n" +
                "\t./document_layout:\n" +
                "\t\tDoc,\n" +
                "\t./expression_documents:\n" +
                "\t\tExpression,\n"
        val pathStart = source.indexOf("./expression_documents")
        val pathEnd = pathStart + "./expression_documents".length

        assertEquals(
            TextRange(pathStart, pathEnd),
            BlorpNavigationRanges.importTargetRangeAt(source, pathStart + 1)
        )
    }

    @Test
    fun `path-like text outside imports is not a module path target`() {
        val source =
            """
            func main(args: List[String]) -> Int:
                ./helpers/math
                0
            """.trimIndent()
        val pathStart = source.indexOf("./helpers/math")

        assertNull(BlorpNavigationRanges.importTargetRangeAt(source, pathStart))
    }
}
