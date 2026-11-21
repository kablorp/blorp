package com.blorp.intellij

import com.intellij.openapi.editor.DefaultLanguageHighlighterColors as Colors
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.platform.lsp.api.customization.LspSemanticTokensSupport
import com.intellij.psi.PsiFile

/**
 * The platform's default mapping sends both `type` and `parameter` to keys that Darcula, Dark,
 * Light and Default leave uncoloured, so a parameter and the type beside it render the same.
 * This one picks keys those schemes colour (see the README, "Colours"): types teal, type
 * parameters olive, parameters purple, properties italic purple, functions gold or blue, library
 * functions italic. Colours repeat between kinds that are never neighbours.
 */
internal class BlorpSemanticTokensSupport : LspSemanticTokensSupport() {
    /**
     * The platform asks for tokens only for files whose language is plain text or TextMate.
     * Blorp has its own language (it needs a parser definition), so it must opt in or the
     * server is never asked and nothing is coloured.
     */
    override fun shouldAskServerForSemanticTokens(psiFile: PsiFile): Boolean =
        psiFile.language == BlorpLanguage || super.shouldAskServerForSemanticTokens(psiFile)

    override fun getTextAttributesKey(tokenType: String, modifiers: List<String>): TextAttributesKey =
        blorpTextAttributesKey(tokenType, modifiers)
}

/** Defined by the platform's bundled schemes (teal in all four) under this name. */
private val TYPE_NAME: TextAttributesKey = TextAttributesKey.createTextAttributesKey("TYPE_PARAMETER_NAME_ATTRIBUTES")

private const val DEFAULT_LIBRARY = "defaultLibrary"
private const val DOCUMENTATION = "documentation"

internal fun blorpTextAttributesKey(tokenType: String, modifiers: List<String>): TextAttributesKey =
    when (tokenType) {
        "type", "interface", "enum", "struct" -> TYPE_NAME
        "typeParameter" -> Colors.METADATA
        "parameter" -> Colors.INSTANCE_FIELD
        "property" -> Colors.STATIC_FIELD
        "enumMember" -> Colors.CONSTANT
        "function", "method" ->
            if (DEFAULT_LIBRARY in modifiers) Colors.STATIC_METHOD else Colors.FUNCTION_DECLARATION
        "keyword" -> Colors.KEYWORD
        "comment" -> if (DOCUMENTATION in modifiers) Colors.DOC_COMMENT else Colors.LINE_COMMENT
        "string" -> Colors.STRING
        "number" -> Colors.NUMBER
        "operator" -> Colors.OPERATION_SIGN
        else -> Colors.IDENTIFIER // namespace, variable
    }
