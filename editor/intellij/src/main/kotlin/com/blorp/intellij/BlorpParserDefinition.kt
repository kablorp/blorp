package com.blorp.intellij

import com.intellij.extapi.psi.ASTWrapperPsiElement
import com.intellij.extapi.psi.PsiFileBase
import com.intellij.lang.ASTNode
import com.intellij.lang.ParserDefinition
import com.intellij.lang.PsiBuilder
import com.intellij.lang.PsiParser
import com.intellij.lexer.Lexer
import com.intellij.openapi.project.Project
import com.intellij.psi.FileViewProvider
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.tree.IElementType
import com.intellij.psi.tree.IFileElementType
import com.intellij.psi.tree.TokenSet

/**
 * A flat PSI: the file holds the lexer's leaves directly, with no grammar. The server owns
 * all language meaning. The definition exists so that the file has word-sized elements, and
 * because the platform lists a language for New Scratch File only when it has one.
 */
class BlorpParserDefinition : ParserDefinition {
    override fun createLexer(project: Project?): Lexer = BlorpLexer()

    override fun createParser(project: Project?): PsiParser = FlatParser

    override fun getFileNodeType(): IFileElementType = BlorpTokenTypes.FILE

    override fun getCommentTokens(): TokenSet = TokenSet.create(BlorpTokenTypes.COMMENT)

    override fun getStringLiteralElements(): TokenSet = TokenSet.create(BlorpTokenTypes.STRING)

    override fun createElement(node: ASTNode): PsiElement = ASTWrapperPsiElement(node)

    override fun createFile(viewProvider: FileViewProvider): PsiFile = BlorpFile(viewProvider)
}

private object FlatParser : PsiParser {
    override fun parse(root: IElementType, builder: PsiBuilder): ASTNode {
        val marker = builder.mark()
        while (!builder.eof()) builder.advanceLexer()
        marker.done(root)
        return builder.treeBuilt
    }
}

private class BlorpFile(viewProvider: FileViewProvider) : PsiFileBase(viewProvider, BlorpLanguage) {
    override fun getFileType() = BlorpFileType.INSTANCE

    override fun toString(): String = "Blorp File"
}
