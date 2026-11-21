package com.blorp.intellij

import com.intellij.lang.LanguageUtil
import com.intellij.testFramework.fixtures.BasePlatformTestCase

/**
 * Editor features such as Go to Declaration look for a reference at the element under the
 * caret. These pin what the flat PSI gives them: a word-sized leaf under the file, not one
 * plain-text blob.
 */
class BlorpPsiTest : BasePlatformTestCase() {
    private val source = "func parse_help(args) -> Int:\n    unknown_command(args, 42, \"x\") -- note\n"

    private fun leafAt(word: String) =
        myFixture.configureByText("main.brp", source).findElementAt(source.indexOf(word) + 1)

    fun testBrpFileIsABlorpPsiFile() {
        assertEquals("Blorp", myFixture.configureByText("main.brp", source).language.id)
    }

    fun testIdentifierOffsetHasAnIdentifierSizedLeaf() {
        assertEquals("parse_help", leafAt("parse_help")?.text)
        assertEquals("unknown_command", leafAt("unknown_command")?.text)
    }

    fun testLeafSitsDirectlyUnderTheFileSoOffsetsStayFileRelative() {
        val leaf = leafAt("unknown_command")!!
        assertSame(leaf.containingFile, leaf.parent)
    }

    fun testNumbersStringsAndCommentsAreSeparateLeaves() {
        assertEquals("42", leafAt("42")?.text)
        assertEquals("\"x\"", leafAt("\"x\"")?.text)
        assertEquals("-- note", leafAt("-- note")?.text)
    }

    fun testBlorpIsListedForNewScratchFile() {
        assertTrue(LanguageUtil.getFileLanguages().any { it.id == "Blorp" })
    }

    fun testServerIsAskedForSemanticTokensOfABrpFile() {
        val file = myFixture.configureByText("main.brp", source)
        assertTrue(BlorpSemanticTokensSupport().shouldAskServerForSemanticTokens(file))
    }
}
