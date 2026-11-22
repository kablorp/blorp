package com.blorp.intellij

import com.intellij.openapi.editor.DefaultLanguageHighlighterColors as Colors
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.psi.PsiFile
import com.redhat.devtools.lsp4ij.features.semanticTokens.SemanticTokensColorsProvider

/**
 * Maps the server's token types to keys that Darcula, Dark, Light and Default colour: types
 * teal, type parameters olive, parameters purple, properties italic purple, functions gold or
 * blue, library functions italic (see the README, "Colours"). LSP4IJ's own default mapping
 * would leave a parameter and a type beside it the same plain colour.
 */
internal class BlorpSemanticTokensColors : SemanticTokensColorsProvider {
    override fun getTextAttributesKey(
        tokenType: String,
        tokenModifiers: List<String>,
        file: PsiFile,
    ): TextAttributesKey = blorpTextAttributesKey(tokenType, tokenModifiers)
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
