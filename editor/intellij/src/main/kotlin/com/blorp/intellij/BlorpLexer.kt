package com.blorp.intellij

import com.intellij.lexer.LexerBase
import com.intellij.psi.TokenType
import com.intellij.psi.tree.IElementType
import com.intellij.psi.tree.IFileElementType

object BlorpTokenTypes {
    val FILE = IFileElementType(BlorpLanguage)
    val WORD = IElementType("BLORP_WORD", BlorpLanguage)
    val NUMBER = IElementType("BLORP_NUMBER", BlorpLanguage)
    val STRING = IElementType("BLORP_STRING", BlorpLanguage)
    val COMMENT = IElementType("BLORP_COMMENT", BlorpLanguage)
    val PUNCTUATION = IElementType("BLORP_PUNCTUATION", BlorpLanguage)
}

/**
 * Splits text into word-sized leaves and nothing more: the PSI needs an identifier-sized
 * element at each offset so editor features have something to attach to. It does no
 * colouring (the server's semantic tokens do) and never fails: every character belongs to
 * some token, so a broken file still splits the same way.
 *
 * A quoted string splits at its `${expression}` holes, as the server's lexer does: one
 * string token ends with `${`, the next starts with the hole's closing `}`, and the hole
 * between is lexed as code, so a name inside it is a leaf of its own. A hole holds one
 * expression on one line and no interpolated string, so the only state is how many record
 * braces the open hole has opened.
 *
 * Keywords are ordinary WORD tokens, and block documentation and `|` strings are not
 * recognised; their text splits into words and punctuation, which is harmless here.
 */
class BlorpLexer : LexerBase() {
    private var buffer: CharSequence = ""
    private var endOffset = 0
    private var tokenStart = 0
    private var tokenEnd = 0
    private var tokenType: IElementType? = null
    private var tokenState = 0

    // The record braces open in the current hole of a quoted string; null outside a hole.
    private var holeBraces: Int? = null

    override fun start(buffer: CharSequence, startOffset: Int, endOffset: Int, initialState: Int) {
        this.buffer = buffer
        this.endOffset = endOffset
        tokenStart = startOffset
        holeBraces = if (initialState == 0) null else initialState - 1
        locateToken()
    }

    // 0 outside a hole, else 1 more than the hole's open braces, as at the token's start.
    override fun getState(): Int = tokenState

    override fun getTokenType(): IElementType? = tokenType

    override fun getTokenStart(): Int = tokenStart

    override fun getTokenEnd(): Int = tokenEnd

    override fun advance() {
        tokenStart = tokenEnd
        locateToken()
    }

    override fun getBufferSequence(): CharSequence = buffer

    override fun getBufferEnd(): Int = endOffset

    private fun locateToken() {
        val braces = holeBraces
        tokenState = if (braces == null) 0 else braces + 1
        if (tokenStart >= endOffset) {
            tokenType = null
            tokenEnd = tokenStart
            return
        }
        val first = buffer[tokenStart]
        when {
            first.isWhitespace() -> {
                val end = scanWhile(1) { it.isWhitespace() }
                if ('\n' in buffer.subSequence(tokenStart, end)) holeBraces = null
                token(TokenType.WHITE_SPACE, end)
            }
            startsLineComment(tokenStart) -> token(BlorpTokenTypes.COMMENT, scanLine())
            braces == 0 && first == '}' -> token(BlorpTokenTypes.STRING, scanStringPiece())
            braces != null && (first == '{' || first == '}') -> {
                holeBraces = if (first == '{') braces + 1 else braces - 1
                token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
            }
            first == '"' && braces == null -> token(BlorpTokenTypes.STRING, scanStringPiece())
            first == '"' || first == '\'' -> token(BlorpTokenTypes.STRING, scanQuoted(first))
            isWordStart(first) -> token(BlorpTokenTypes.WORD, scanWhile(1) { isWordPart(it) })
            first in '0'..'9' -> token(BlorpTokenTypes.NUMBER, scanWhile(1) { it in '0'..'9' || it == '_' })
            else -> token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
        }
    }

    private fun token(type: IElementType, end: Int) {
        tokenType = type
        tokenEnd = end
    }

    private inline fun scanWhile(skip: Int, accepts: (Char) -> Boolean): Int {
        var end = tokenStart + skip
        while (end < endOffset && accepts(buffer[end])) end += 1
        return end
    }

    private fun scanLine(): Int = scanWhile(2) { it != '\n' }

    /**
     * A string piece, from its opening quote or its hole's closing brace, ends at the
     * closing quote, just after a `${` (opening a hole), or at the line end when unterminated.
     */
    private fun scanStringPiece(): Int {
        var end = tokenStart + 1
        holeBraces = null
        while (end < endOffset && buffer[end] != '\n') {
            val char = buffer[end]
            end += 1
            when {
                char == '\\' && end < endOffset && buffer[end] != '\n' -> end += 1
                char == '"' -> return end
                char == '$' && end < endOffset && buffer[end] == '{' -> {
                    holeBraces = 0
                    return end + 1
                }
            }
        }
        return end
    }

    /** A span without holes ends at its closing quote, or at the line end when unterminated. */
    private fun scanQuoted(quote: Char): Int {
        var end = tokenStart + 1
        while (end < endOffset && buffer[end] != '\n') {
            val char = buffer[end]
            end += 1
            if (char == '\\' && end < endOffset && buffer[end] != '\n') end += 1
            else if (char == quote) break
        }
        return end
    }

    private fun startsLineComment(offset: Int): Boolean =
        offset + 1 < endOffset && buffer[offset] == '-' && buffer[offset + 1] == '-'

    private fun isWordStart(char: Char) = char == '_' || char in 'a'..'z' || char in 'A'..'Z'

    private fun isWordPart(char: Char) = isWordStart(char) || char in '0'..'9'
}
