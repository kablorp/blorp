package com.blorp.intellij

import com.intellij.codeInsight.navigation.actions.GotoDeclarationHandler
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.editor.Document
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.fileEditor.OpenFileDescriptor
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.util.TextRange
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspServer
import com.intellij.platform.lsp.api.LspServerManager
import com.intellij.platform.lsp.api.LspServerState
import com.intellij.psi.PsiDocumentManager
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import com.intellij.psi.PsiManager
import com.intellij.psi.impl.FakePsiElement
import org.eclipse.lsp4j.DefinitionParams
import org.eclipse.lsp4j.Location
import org.eclipse.lsp4j.LocationLink
import org.eclipse.lsp4j.Position
import org.eclipse.lsp4j.Range
import org.eclipse.lsp4j.jsonrpc.messages.Either

class BlorpGotoDeclarationHandler : GotoDeclarationHandler {
    override fun getGotoDeclarationTargets(
        sourceElement: PsiElement?,
        offset: Int,
        editor: Editor
    ): Array<PsiElement>? {
        val document = editor.document
        val project = sourceElement?.project ?: editor.project ?: return null
        val sourceFile =
            sourceElement?.containingFile
                ?: PsiDocumentManager.getInstance(project).getPsiFile(document)
                ?: return null
        val virtualFile = sourceFile.virtualFile ?: FileDocumentManager.getInstance().getFile(document) ?: return null
        if (!virtualFile.isBlorpSourceFile()) {
            return null
        }

        val navigationOffset =
            navigationOffsetForTarget(sourceElement, document, offset)
                ?: run {
                    LOG.info(
                        "Blorp goto declaration rejected local target for ${virtualFile.path} at offset $offset"
                    )
                    return null
                }
        val position = lspPositionAtOffset(document, navigationOffset) ?: return null
        val serverManager = LspServerManager.getInstance(project)
        val servers = serverManager.getServersForProvider(BlorpLspServerSupportProvider::class.java)
            .filter { server ->
                server.state == LspServerState.Running &&
                    server.descriptor.isSupportedFile(virtualFile)
            }

        if (servers.isEmpty()) {
            LOG.info("Blorp goto declaration requested before LSP server was running for ${virtualFile.path}")
            serverManager.startServersIfNeeded(BlorpLspServerSupportProvider::class.java)
            return null
        }

        for (server in servers) {
            val result = requestDefinitions(server, virtualFile, position) ?: continue
            val targets = targetsFromDefinitionResult(
                server = server,
                sourceFile = virtualFile,
                sourceOffset = navigationOffset,
                sourcePsiFile = sourceFile,
                result = result
            )
            if (targets.isNotEmpty()) {
                LOG.info("Blorp goto declaration returned ${targets.size} target(s) for ${virtualFile.path}:${position.line}:${position.character}")
                return targets.toTypedArray()
            }
        }

        LOG.info("Blorp goto declaration returned no targets for ${virtualFile.path}:${position.line}:${position.character}")
        return null
    }

    private fun navigationOffsetForTarget(
        sourceElement: PsiElement?,
        document: Document,
        offset: Int
    ): Int? {
        val text = document.charsSequence
        if (text.isEmpty()) {
            return null
        }

        val safeOffset = offset.coerceIn(0, text.length)
        if (safeOffset < text.length) {
            if (BlorpNavigationRanges.importTargetRangeAt(text, safeOffset) != null) {
                return safeOffset
            }
            if (sourceElement == null) {
                return null
            }
            val targetRange = BlorpNavigationRanges.identifierRangeAt(text, safeOffset)
            if (targetRange != null && sourceElementIsWithin(sourceElement, targetRange)) {
                return safeOffset
            }
        }

        val previousOffset = safeOffset - 1
        if (previousOffset < 0) {
            return null
        }

        if (BlorpNavigationRanges.importTargetRangeAt(text, previousOffset) != null) {
            return previousOffset
        }
        if (sourceElement == null) {
            return null
        }

        val targetRange = BlorpNavigationRanges.identifierRangeAt(text, previousOffset) ?: return null
        return if (sourceElementIsWithin(sourceElement, targetRange)) {
            // Mouse offsets can land just after the painted glyph; only accept
            // that boundary case when JetBrains identified the exact token leaf.
            previousOffset
        } else {
            null
        }
    }

    private fun sourceElementIsWithin(sourceElement: PsiElement, targetRange: TextRange): Boolean {
        val sourceRange = sourceElement.textRange ?: return false
        return sourceRange.startOffset >= targetRange.startOffset &&
            sourceRange.endOffset <= targetRange.endOffset
    }

    private fun requestDefinitions(
        server: LspServer,
        file: VirtualFile,
        position: Position
    ): Either<List<Location>, List<LocationLink>>? {
        val params = DefinitionParams(server.getDocumentIdentifier(file), position)
        return try {
            @Suppress("UNCHECKED_CAST")
            server.sendRequestSync(DEFINITION_REQUEST_TIMEOUT_MS) { languageServer ->
                languageServer.textDocumentService.definition(params)
            } as? Either<List<Location>, List<LocationLink>>
        } catch (t: Throwable) {
            LOG.warn("Blorp goto declaration LSP request failed for ${file.path}", t)
            null
        }
    }

    private fun targetsFromDefinitionResult(
        server: LspServer,
        sourceFile: VirtualFile,
        sourceOffset: Int,
        sourcePsiFile: PsiFile,
        result: Either<List<Location>, List<LocationLink>>
    ): List<PsiElement> {
        val targets = if (result.isLeft) {
            result.left.orEmpty().mapNotNull { location ->
                val range = location.range ?: return@mapNotNull null
                BlorpNavigationTarget(location.uri, range)
            }
        } else {
            result.right.orEmpty().mapNotNull { location ->
                val range = location.targetSelectionRange ?: return@mapNotNull null
                BlorpNavigationTarget(location.targetUri, range)
            }
        }

        return targets.mapNotNull { target ->
            psiElementForTarget(server, sourceFile, sourceOffset, sourcePsiFile, target)
        }
    }

    private fun psiElementForTarget(
        server: LspServer,
        sourceFile: VirtualFile,
        sourceOffset: Int,
        sourcePsiFile: PsiFile,
        target: BlorpNavigationTarget
    ): PsiElement? {
        val targetFile =
            server.descriptor.findFileByUri(target.uri)
                ?: run {
                    LOG.info("Blorp goto declaration could not resolve target URI ${target.uri}")
                    return null
                }
        val targetDocument =
            FileDocumentManager.getInstance().getDocument(targetFile)
                ?: run {
                    LOG.info("Blorp goto declaration target has no document: ${targetFile.path}")
                    return null
                }
        val targetOffset = offsetForPosition(targetDocument, target.range.start) ?: return null

        if (targetFile == sourceFile && targetOffset == sourceOffset) {
            return null
        }

        val psiFile = if (targetFile == sourceFile) {
            sourcePsiFile
        } else {
            PsiManager.getInstance(server.project).findFile(targetFile)
                ?: run {
                    LOG.info("Blorp goto declaration target has no PSI file: ${targetFile.path}")
                    return null
                }
        }

        return BlorpNavigationPsiElement(
            project = server.project,
            psiFile = psiFile,
            file = targetFile,
            offset = targetOffset,
            name = target.uri
        )
    }

    private fun lspPositionAtOffset(document: Document, offset: Int): Position? {
        if (document.textLength == 0) {
            return Position(0, 0)
        }

        val safeOffset = offset.coerceIn(0, document.textLength)
        val line = document.getLineNumber(safeOffset)
        val character = safeOffset - document.getLineStartOffset(line)
        return Position(line, character)
    }

    private fun offsetForPosition(document: Document, position: Position): Int? {
        val line = position.line
        if (line < 0 || line >= document.lineCount) {
            return null
        }

        val lineStart = document.getLineStartOffset(line)
        val lineEnd = document.getLineEndOffset(line)
        return (lineStart + position.character).coerceIn(lineStart, lineEnd)
    }

    private data class BlorpNavigationTarget(
        val uri: String,
        val range: Range
    )

    private class BlorpNavigationPsiElement(
        private val project: Project,
        private val psiFile: PsiFile,
        private val file: VirtualFile,
        private val offset: Int,
        private val name: String
    ) : FakePsiElement() {
        override fun getParent(): PsiElement = psiFile

        override fun getContainingFile(): PsiFile = psiFile

        override fun getProject(): Project = project

        override fun getManager(): PsiManager = psiFile.manager

        override fun getTextOffset(): Int = offset

        override fun getTextRange(): TextRange = TextRange(offset, offset)

        override fun getName(): String = name

        override fun navigate(requestFocus: Boolean) {
            OpenFileDescriptor(project, file, offset).navigate(requestFocus)
        }

        override fun canNavigate(): Boolean = true

        override fun canNavigateToSource(): Boolean = true

        override fun isValid(): Boolean = psiFile.isValid && file.isValid
    }

    companion object {
        private const val DEFINITION_REQUEST_TIMEOUT_MS = 3_000
        private val LOG = Logger.getInstance(BlorpGotoDeclarationHandler::class.java)
    }
}
