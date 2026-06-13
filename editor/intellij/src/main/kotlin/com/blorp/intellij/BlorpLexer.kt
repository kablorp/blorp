package com.blorp.intellij

import com.intellij.lexer.LexerBase
import com.intellij.psi.TokenType
import com.intellij.psi.tree.IElementType
import com.intellij.psi.tree.IFileElementType

object BlorpTokenTypes {
    val FILE = IFileElementType(BlorpLanguage)
    val IDENTIFIER = IElementType("IDENTIFIER", BlorpLanguage)
    val KEYWORD = IElementType("KEYWORD", BlorpLanguage)
    val COMMENT = IElementType("COMMENT", BlorpLanguage)
    val STRING = IElementType("STRING", BlorpLanguage)
    val NUMBER = IElementType("NUMBER", BlorpLanguage)
    val SYMBOL = IElementType("SYMBOL", BlorpLanguage)
}

class BlorpLexer : LexerBase() {
    private var buffer: CharSequence = ""
    private var endOffset: Int = 0
    private var tokenStart: Int = 0
    private var tokenEnd: Int = 0
    private var tokenType: IElementType? = null

    override fun start(buffer: CharSequence, startOffset: Int, endOffset: Int, initialState: Int) {
        this.buffer = buffer
        this.endOffset = endOffset
        this.tokenStart = startOffset
        locateToken()
    }

    override fun getState(): Int = 0

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
        if (tokenStart >= endOffset) {
            tokenType = null
            tokenEnd = tokenStart
            return
        }

        val char = buffer[tokenStart]
        when {
            char.isWhitespace() -> scanWhitespace()
            isLineCommentStart(tokenStart) -> scanLineComment()
            char == '"' || char == '\'' -> scanQuotedString(char)
            char == '#' && tokenStart + 1 < endOffset && BlorpIdentifiers.isStart(buffer[tokenStart + 1]) ->
                scanDimensionIdentifier()
            BlorpIdentifiers.isStart(char) -> scanIdentifierOrKeyword()
            char in '0'..'9' -> scanNumber()
            else -> {
                tokenEnd = tokenStart + 1
                tokenType = BlorpTokenTypes.SYMBOL
            }
        }
    }

    private fun scanWhitespace() {
        var end = tokenStart + 1
        while (end < endOffset && buffer[end].isWhitespace()) {
            end += 1
        }
        tokenEnd = end
        tokenType = TokenType.WHITE_SPACE
    }

    private fun scanLineComment() {
        var end = tokenStart + 2
        while (end < endOffset && buffer[end] != '\n' && buffer[end] != '\r') {
            end += 1
        }
        tokenEnd = end
        tokenType = BlorpTokenTypes.COMMENT
    }

    private fun scanQuotedString(quote: Char) {
        var end = tokenStart + 1
        var escaped = false
        while (end < endOffset) {
            val char = buffer[end]
            end += 1
            if (escaped) {
                escaped = false
            } else if (char == '\\') {
                escaped = true
            } else if (char == quote) {
                break
            }
        }
        tokenEnd = end
        tokenType = BlorpTokenTypes.STRING
    }

    private fun scanDimensionIdentifier() {
        var end = tokenStart + 2
        while (end < endOffset && BlorpIdentifiers.isBody(buffer[end])) {
            end += 1
        }
        tokenEnd = end
        tokenType = BlorpTokenTypes.IDENTIFIER
    }

    private fun scanIdentifierOrKeyword() {
        var end = tokenStart + 1
        while (end < endOffset && BlorpIdentifiers.isBody(buffer[end])) {
            end += 1
        }
        tokenEnd = end
        tokenType =
            if (KEYWORDS.contains(buffer.subSequence(tokenStart, end).toString())) {
                BlorpTokenTypes.KEYWORD
            } else {
                BlorpTokenTypes.IDENTIFIER
            }
    }

    private fun scanNumber() {
        var end = tokenStart + 1
        while (end < endOffset && (buffer[end] in '0'..'9' || buffer[end] == '_')) {
            end += 1
        }
        tokenEnd = end
        tokenType = BlorpTokenTypes.NUMBER
    }

    private fun isLineCommentStart(offset: Int): Boolean =
        offset + 1 < endOffset && buffer[offset] == '-' && buffer[offset + 1] == '-'

    companion object {
        private val KEYWORDS = setOf(
            "as",
            "builtin",
            "concurrent",
            "detach",
            "else",
            "enum",
            "for",
            "foreign",
            "func",
            "if",
            "import",
            "in",
            "match",
            "private",
            "pure",
            "record",
            "resource",
            "struct",
            "trait",
            "type",
            "union",
            "var",
            "while",
            "with"
        )
    }
}
