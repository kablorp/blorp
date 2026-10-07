package com.blorp.intellij

import com.intellij.testFramework.fixtures.BasePlatformTestCase

class BlorpLexerTest : BasePlatformTestCase() {
    fun testEnumIsAnIdentifier() {
        val lexer = BlorpLexer()
        lexer.start("enum")
        assertEquals(BlorpTokenTypes.IDENTIFIER, lexer.tokenType)
    }

    fun testStructIsAnIdentifier() {
        val lexer = BlorpLexer()
        lexer.start("struct")
        assertEquals(BlorpTokenTypes.IDENTIFIER, lexer.tokenType)
    }

    fun testFixedRemainsAnIdentifierInTheFallbackLexer() {
        val lexer = BlorpLexer()
        lexer.start("fixed: Int = 1")
        assertEquals(BlorpTokenTypes.IDENTIFIER, lexer.tokenType)
        lexer.start("func bump(fixed: Int)")
        lexer.advance()
        lexer.advance()
        lexer.advance()
        lexer.advance()
        assertEquals(BlorpTokenTypes.IDENTIFIER, lexer.tokenType)
        // TextMate recognizes the contextual modifier in declarations.
        lexer.start("fixed record")
        assertEquals(BlorpTokenTypes.IDENTIFIER, lexer.tokenType)
        lexer.advance()
        lexer.advance()
        assertEquals(BlorpTokenTypes.KEYWORD, lexer.tokenType)
    }
}
