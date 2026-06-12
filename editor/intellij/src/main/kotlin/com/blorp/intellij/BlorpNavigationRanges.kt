package com.blorp.intellij

import com.intellij.openapi.util.TextRange

internal object BlorpNavigationRanges {
    fun targetRangeAt(text: CharSequence, offset: Int): TextRange? =
        importTargetRangeAt(text, offset) ?: identifierRangeAt(text, offset)

    fun importTargetRangeAt(text: CharSequence, offset: Int): TextRange? =
        importModulePathRangeAt(text, offset) ?: importIdentifierRangeAt(text, offset)

    fun identifierRangeAt(text: CharSequence, offset: Int): TextRange? {
        if (offset < 0 || offset >= text.length) {
            return null
        }

        if (text[offset] == '#') {
            if (offset + 1 >= text.length || !BlorpIdentifiers.isStart(text[offset + 1])) {
                return null
            }

            var end = offset + 2
            while (end < text.length && BlorpIdentifiers.isBody(text[end])) {
                end += 1
            }
            return TextRange(offset, end)
        }

        if (!BlorpIdentifiers.isBody(text[offset])) {
            return null
        }

        var start = offset
        while (start > 0 && BlorpIdentifiers.isBody(text[start - 1])) {
            start -= 1
        }
        if (start > 0 && text[start - 1] == '#') {
            start -= 1
        }

        if (text[start] == '#') {
            if (start + 1 >= text.length || !BlorpIdentifiers.isStart(text[start + 1])) {
                return null
            }
        } else if (!BlorpIdentifiers.isStart(text[start])) {
            return null
        }

        var end = offset + 1
        while (end < text.length && BlorpIdentifiers.isBody(text[end])) {
            end += 1
        }

        return TextRange(start, end)
    }

    private fun importModulePathRangeAt(text: CharSequence, offset: Int): TextRange? {
        if (offset < 0 || offset >= text.length) {
            return null
        }

        val lineStart = lineStartAt(text, offset)
        val lineEnd = lineEndAt(text, offset)
        val moduleStart = skipInlineWhitespace(text, lineStart, lineEnd)
        if (!lineIsInsideImportBlock(text, lineStart, moduleStart)) {
            return null
        }

        val moduleEnd = scanModulePathEnd(text, moduleStart, lineEnd)
        if (moduleEnd == moduleStart || offset < moduleStart || offset >= moduleEnd) {
            return null
        }

        if (!looksLikePathImport(text, moduleStart, moduleEnd)) {
            return null
        }

        val suffixStart = skipInlineWhitespace(text, moduleEnd, lineEnd)
        if (!validImportModuleSuffix(text, suffixStart, lineEnd)) {
            return null
        }

        return TextRange(moduleStart, moduleEnd)
    }

    private fun importIdentifierRangeAt(text: CharSequence, offset: Int): TextRange? {
        val range = identifierRangeAt(text, offset) ?: return null
        val lineStart = lineStartAt(text, offset)
        val lineEnd = lineEndAt(text, offset)
        val firstTokenStart = skipInlineWhitespace(text, lineStart, lineEnd)
        return if (lineIsInsideImportBlock(text, lineStart, firstTokenStart)) {
            range
        } else {
            null
        }
    }

    private fun lineStartAt(text: CharSequence, offset: Int): Int {
        var index = offset
        while (index > 0 && text[index - 1] != '\n') {
            index -= 1
        }
        return index
    }

    private fun lineEndAt(text: CharSequence, offset: Int): Int {
        var index = offset
        while (index < text.length && text[index] != '\n') {
            index += 1
        }
        if (index > offset && text[index - 1] == '\r') {
            index -= 1
        }
        return index
    }

    private fun skipInlineWhitespace(text: CharSequence, start: Int, end: Int): Int {
        var index = start
        while (index < end && (text[index] == ' ' || text[index] == '\t')) {
            index += 1
        }
        return index
    }

    private fun leadingWhitespaceLength(text: CharSequence, start: Int, end: Int): Int =
        skipInlineWhitespace(text, start, end) - start

    private fun lineIsInsideImportBlock(
        text: CharSequence,
        lineStart: Int,
        moduleStart: Int
    ): Boolean {
        var currentIndent = moduleStart - lineStart
        if (currentIndent <= 0) {
            return false
        }

        var previousEnd = lineStart - 1
        while (previousEnd >= 0) {
            if (text[previousEnd] == '\n') {
                previousEnd -= 1
                continue
            }
            if (text[previousEnd] == '\r') {
                previousEnd -= 1
            }

            var previousStart = previousEnd
            while (previousStart > 0 && text[previousStart - 1] != '\n') {
                previousStart -= 1
            }

            val trimmedStart = skipInlineWhitespace(text, previousStart, previousEnd + 1)
            if (trimmedStart <= previousEnd) {
                val previousIndent =
                    leadingWhitespaceLength(text, previousStart, previousEnd + 1)
                if (previousIndent < currentIndent) {
                    val previousLine =
                        text.subSequence(trimmedStart, previousEnd + 1)
                            .toString()
                            .trimEnd()
                    if (previousLine == "import:") {
                        return true
                    }
                    currentIndent = previousIndent
                }
            }

            previousEnd = previousStart - 1
        }

        return false
    }

    private fun scanModulePathEnd(text: CharSequence, start: Int, end: Int): Int {
        var index = start
        while (index < end && isModulePathChar(text[index])) {
            index += 1
        }
        return index
    }

    private fun isModulePathChar(char: Char): Boolean =
        BlorpIdentifiers.isBody(char) || char == '/' || char == '.' || char == '-'

    private fun looksLikePathImport(text: CharSequence, start: Int, end: Int): Boolean {
        val modulePath = text.subSequence(start, end).toString()
        return modulePath.startsWith("./") ||
            modulePath.startsWith("../") ||
            modulePath.contains("/")
    }

    private fun validImportModuleSuffix(
        text: CharSequence,
        suffixStart: Int,
        lineEnd: Int
    ): Boolean {
        if (suffixStart >= lineEnd) {
            return true
        }
        if (text[suffixStart] == ':') {
            return true
        }
        if (!startsWithWord(text, suffixStart, lineEnd, "as")) {
            return false
        }

        val aliasStart = skipInlineWhitespace(text, suffixStart + 2, lineEnd)
        if (aliasStart >= lineEnd || !BlorpIdentifiers.isStart(text[aliasStart])) {
            return false
        }

        var aliasEnd = aliasStart + 1
        while (aliasEnd < lineEnd && BlorpIdentifiers.isBody(text[aliasEnd])) {
            aliasEnd += 1
        }

        val afterAlias = skipInlineWhitespace(text, aliasEnd, lineEnd)
        return afterAlias >= lineEnd || text[afterAlias] == ':'
    }

    private fun startsWithWord(
        text: CharSequence,
        start: Int,
        end: Int,
        word: String
    ): Boolean {
        if (start + word.length > end) {
            return false
        }
        for (index in word.indices) {
            if (text[start + index] != word[index]) {
                return false
            }
        }
        val wordEnd = start + word.length
        return wordEnd >= end || !BlorpIdentifiers.isBody(text[wordEnd])
    }
}
