package com.blorp.intellij

import com.intellij.codeInsight.navigation.actions.GotoDeclarationHandler
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.platform.lsp.api.LspClientManager
import com.intellij.platform.lsp.api.LspServerState
import com.intellij.platform.lsp.util.getLsp4jPosition
import com.intellij.platform.lsp.util.getOffsetInDocument
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiManager
import org.eclipse.lsp4j.DefinitionParams
import org.eclipse.lsp4j.Location
import org.eclipse.lsp4j.LocationLink
import org.eclipse.lsp4j.Position
import org.eclipse.lsp4j.Range
import org.eclipse.lsp4j.jsonrpc.messages.Either

/**
 * Go to Declaration (Cmd-B, Cmd-click) for Blorp, asked of `blorp lsp` directly.
 *
 * CLion's LSP support answers Go to Declaration only while the running action's id is
 * exactly `GotoDeclaration`. CLion's C/C++ engine runs the keyboard and mouse shortcuts
 * inside its own wrapper action, so they reach the LSP support under another id and get
 * "Cannot find declaration to go to", while Cmd-hover and the Navigate menu work. The
 * platform asks declaration handlers whatever the action, so this one sends the definition
 * request itself. Drop it once CLion's LSP support answers the wrapped shortcuts.
 */
internal class BlorpGotoDeclarationHandler : GotoDeclarationHandler {
    override fun getGotoDeclarationTargets(sourceElement: PsiElement?, offset: Int, editor: Editor): Array<PsiElement>? {
        val source = sourceElement?.containingFile ?: return null
        val file = source.virtualFile?.takeIf { it.isBlorpSourceFile() } ?: return null
        val client = LspClientManager.getInstance(source.project)
            .getClients(BlorpLspIntegrationProvider::class.java)
            .firstOrNull { it.state == LspServerState.Running } ?: return null
        val request = DefinitionParams(client.getDocumentIdentifier(file), getLsp4jPosition(editor.document, offset))
        // Waits as CLion's own LSP definition request does: up to 10 s, giving way when
        // CLion cancels the action's progress.
        val answer = client.sendRequestSync { it.textDocumentService.definition(request) } ?: return null
        val psiManager = PsiManager.getInstance(source.project)
        val targets = definitionTargets(answer, request).mapNotNull { target ->
            val targetFile = client.descriptor.findFileByUri(target.uri) ?: return@mapNotNull null
            val document = FileDocumentManager.getInstance().getDocument(targetFile) ?: return@mapNotNull null
            val targetOffset = getOffsetInDocument(document, target.range.start) ?: return@mapNotNull null
            psiManager.findFile(targetFile)?.findElementAt(targetOffset)
        }
        return targets.takeIf { it.isNotEmpty() }?.toTypedArray()
    }
}

/**
 * Where a definition answer points, as locations of the declared names. A target the
 * request already stands on is dropped: the position is a declaration, not a use.
 */
internal fun definitionTargets(
    answer: Either<out List<Location>, out List<LocationLink>>,
    request: DefinitionParams,
): List<Location> {
    val targets = if (answer.isLeft) answer.left else answer.right.map { Location(it.targetUri, it.targetSelectionRange) }
    return targets.filterNot { it.uri == request.textDocument.uri && it.range.covers(request.position) }
}

// Inclusive at both ends: a position at a name's end is on the name.
private fun Range.covers(position: Position): Boolean =
    !position.isBefore(start) && !end.isBefore(position)

private fun Position.isBefore(other: Position): Boolean =
    line < other.line || (line == other.line && character < other.character)
