package com.blorp.intellij

import com.intellij.psi.TokenType
import com.intellij.psi.tree.IElementType
import kotlin.test.Test
import kotlin.test.assertEquals

class BlorpLexerTest {
    private fun tokens(text: String): List<Pair<IElementType, String>> {
        val lexer = BlorpLexer()
        lexer.start(text)
        val result = mutableListOf<Pair<IElementType, String>>()
        while (lexer.tokenType != null) {
            result += lexer.tokenType!! to text.substring(lexer.tokenStart, lexer.tokenEnd)
            lexer.advance()
        }
        return result
    }

    private fun words(text: String) =
        tokens(text).filter { it.first == BlorpTokenTypes.WORD }.map { it.second }

    @Test
    fun identifiersAreOneWordSizedTokenEach() {
        assertEquals(listOf("func", "parse_help", "args", "Int"), words("func parse_help(args) -> Int:"))
    }

    @Test
    fun numbersAndPunctuationSplitFromWords() {
        assertEquals(
            listOf(
                BlorpTokenTypes.WORD to "x",
                TokenType.WHITE_SPACE to " ",
                BlorpTokenTypes.PUNCTUATION to "=",
                TokenType.WHITE_SPACE to " ",
                BlorpTokenTypes.NUMBER to "1_000",
                BlorpTokenTypes.PUNCTUATION to "+",
                BlorpTokenTypes.WORD to "y2",
            ),
            tokens("x = 1_000+y2"),
        )
    }

    @Test
    fun commentRunsToLineEndAndStopsBeforeTheNewline() {
        assertEquals(
            listOf(
                BlorpTokenTypes.WORD to "a",
                TokenType.WHITE_SPACE to " ",
                BlorpTokenTypes.COMMENT to "-- note \"x\"",
                TokenType.WHITE_SPACE to "\n",
                BlorpTokenTypes.WORD to "b",
            ),
            tokens("a -- note \"x\"\nb"),
        )
    }

    @Test
    fun arrowIsNotAComment() {
        assertEquals(
            listOf(BlorpTokenTypes.PUNCTUATION to "-", BlorpTokenTypes.PUNCTUATION to ">"),
            tokens("->"),
        )
    }

    @Test
    fun stringSkipsEscapedQuotesAndKeepsItsWordsInside() {
        assertEquals(
            listOf(BlorpTokenTypes.STRING to "\"say \\\"hi\\\"\"", BlorpTokenTypes.WORD to "after"),
            tokens("\"say \\\"hi\\\"\"after"),
        )
    }

    @Test
    fun unterminatedStringStopsAtTheLineEnd() {
        assertEquals(
            listOf(
                BlorpTokenTypes.STRING to "\"open",
                TokenType.WHITE_SPACE to "\n",
                BlorpTokenTypes.WORD to "next",
            ),
            tokens("\"open\nnext"),
        )
    }

    @Test
    fun holeIsLexedAsCodeBetweenStringPieces() {
        assertEquals(
            listOf(
                BlorpTokenTypes.STRING to "\"a \${",
                BlorpTokenTypes.WORD to "name",
                BlorpTokenTypes.STRING to "} b\"",
                BlorpTokenTypes.WORD to "after",
            ),
            tokens("\"a \${name} b\"after"),
        )
    }

    @Test
    fun recordBracesAndPlainStringsInsideAHoleDoNotEndIt() {
        assertEquals(
            listOf(
                BlorpTokenTypes.STRING to "\"\${",
                BlorpTokenTypes.WORD to "show",
                BlorpTokenTypes.PUNCTUATION to "{",
                BlorpTokenTypes.STRING to "\"}\"",
                BlorpTokenTypes.PUNCTUATION to "}",
                BlorpTokenTypes.STRING to "}\"",
            ),
            tokens("\"\${show{\"}\"}}\""),
        )
    }

    @Test
    fun unclosedHoleEndsAtTheLineEnd() {
        assertEquals(
            listOf(
                BlorpTokenTypes.STRING to "\"\${",
                BlorpTokenTypes.WORD to "x",
                TokenType.WHITE_SPACE to "\n",
                BlorpTokenTypes.STRING to "\"y\"",
            ),
            tokens("\"\${x\n\"y\""),
        )
    }

    @Test
    fun lexingRestartedInsideAHoleMatchesAFullPass() {
        val text = "\"\${f{a}} \${g}\" z"
        val lexer = BlorpLexer()
        lexer.start(text)
        val full = mutableListOf<Triple<Int, Int, IElementType?>>()
        while (lexer.tokenType != null) {
            full += Triple(lexer.tokenStart, lexer.state, lexer.tokenType)
            lexer.advance()
        }
        for ((start, state, _) in full) {
            lexer.start(text, start, text.length, state)
            val restarted = mutableListOf<Triple<Int, Int, IElementType?>>()
            while (lexer.tokenType != null) {
                restarted += Triple(lexer.tokenStart, lexer.state, lexer.tokenType)
                lexer.advance()
            }
            assertEquals(full.dropWhile { it.first < start }, restarted, "restarted at $start")
        }
    }

    @Test
    fun everyCharacterIsCoveredEvenInBrokenText() {
        val text = "func ( \"x é \u0000 --"
        assertEquals(text, tokens(text).joinToString("") { it.second })
    }
}
