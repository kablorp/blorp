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
 * A quoted string splits at its `${expression}` holes, as the server's lexer does: a string
 * token ends before the hole, `$`, `{` and the closing `}` are one punctuation token each, and
 * the expression between is lexed as code, so a name inside it is a leaf of its own. The
 * single-character brackets matter to LSP4IJ, which picks the word at a caret from the
 * element before it and steps over a lone punctuation character to the name. A hole holds one
 * expression on one line and no interpolated string, so the state is where the lexer stands
 * in the hole's brackets, or how many record braces the open hole has opened.
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

    private var hole: HoleState = HoleState.OutsideHole

    override fun start(buffer: CharSequence, startOffset: Int, endOffset: Int, initialState: Int) {
        this.buffer = buffer
        this.endOffset = endOffset
        tokenStart = startOffset
        hole = HoleState.decode(initialState)
        locateToken()
    }

    // The hole state at the token's start, encoded by HoleState.encode.
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
        // A hole directly after a hole has no string text between them.
        if (hole == HoleState.ResumesString && startsHole(tokenStart)) hole = HoleState.AtDollar
        val state = hole
        tokenState = state.encode()
        if (tokenStart >= endOffset) {
            tokenType = null
            tokenEnd = tokenStart
            return
        }
        val first = buffer[tokenStart]
        when {
            state == HoleState.AtDollar -> {
                hole = HoleState.AtBrace
                token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
            }
            state == HoleState.AtBrace -> {
                hole = HoleState.Open(0)
                token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
            }
            state == HoleState.ResumesString && first != '\n' -> stringPiece(0)
            first.isWhitespace() -> {
                val end = scanWhile(1) { it.isWhitespace() }
                if ('\n' in buffer.subSequence(tokenStart, end)) hole = HoleState.OutsideHole
                token(TokenType.WHITE_SPACE, end)
            }
            startsLineComment(tokenStart) -> token(BlorpTokenTypes.COMMENT, scanLine())
            state == HoleState.Open(0) && first == '}' -> {
                hole = HoleState.ResumesString
                token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
            }
            state is HoleState.Open && (first == '{' || first == '}') -> {
                hole = HoleState.Open(state.braces + if (first == '{') 1 else -1)
                token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
            }
            first == '"' && state == HoleState.OutsideHole -> stringPiece(1)
            first == '"' || first == '\'' -> token(BlorpTokenTypes.STRING, scanQuoted(first))
            isWordStart(first) -> token(BlorpTokenTypes.WORD, scanWhile(1) { isWordPart(it) })
            first in '0'..'9' -> token(BlorpTokenTypes.NUMBER, scanWhile(1) { it in '0'..'9' || it == '_' })
            else -> token(BlorpTokenTypes.PUNCTUATION, tokenStart + 1)
        }
    }

    private fun stringPiece(skip: Int) {
        val piece = scanStringPiece(skip)
        token(BlorpTokenTypes.STRING, piece.end)
        hole = if (piece.opensHole) HoleState.AtDollar else HoleState.OutsideHole
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

    private fun startsHole(offset: Int): Boolean =
        offset + 1 < endOffset && buffer[offset] == '$' && buffer[offset + 1] == '{'

    private class StringPiece(val end: Int, val opensHole: Boolean)

    /**
     * A string piece, after [skip] characters (1 for the opening quote, 0 when resuming after
     * a hole's `}`), ends at the closing quote, just before a `${` (opening a hole), or at the
     * line end when unterminated.
     */
    private fun scanStringPiece(skip: Int): StringPiece {
        var end = tokenStart + skip
        while (end < endOffset && buffer[end] != '\n') {
            when {
                startsHole(end) -> return StringPiece(end, opensHole = true)
                buffer[end] == '\\' && end + 1 < endOffset && buffer[end + 1] != '\n' -> end += 2
                buffer[end] == '"' -> return StringPiece(end + 1, opensHole = false)
                else -> end += 1
            }
        }
        return StringPiece(end, opensHole = false)
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

/** Where the lexer stands relative to a quoted string's `${expression}` holes. */
internal sealed interface HoleState {
    data object OutsideHole : HoleState

    /** Just after a hole's closing `}`: the rest of the string follows. */
    data object ResumesString : HoleState

    /** Between a string piece and its hole: `$` is next. */
    data object AtDollar : HoleState

    /** `{` is next. */
    data object AtBrace : HoleState

    /** Inside the hole's code, with [braces] record braces open. */
    data class Open(val braces: Int) : HoleState

    /** The lexer's `Int` state: 0 outside, then the three marker states, then 4 + open braces. */
    fun encode(): Int = when (this) {
        OutsideHole -> 0
        ResumesString -> 1
        AtDollar -> 2
        AtBrace -> 3
        is Open -> OPEN_BASE + braces
    }

    companion object {
        private const val OPEN_BASE = 4

        fun decode(state: Int): HoleState = when (state) {
            0 -> OutsideHole
            1 -> ResumesString
            2 -> AtDollar
            3 -> AtBrace
            else -> Open(state - OPEN_BASE)
        }
    }
}
