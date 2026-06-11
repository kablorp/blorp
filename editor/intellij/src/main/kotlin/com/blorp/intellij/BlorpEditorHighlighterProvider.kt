package com.blorp.intellij

import com.intellij.openapi.editor.colors.EditorColorsScheme
import com.intellij.openapi.editor.highlighter.EditorHighlighter
import com.intellij.openapi.fileTypes.EditorHighlighterProvider
import com.intellij.openapi.fileTypes.FileType
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import org.jetbrains.plugins.textmate.language.syntax.highlighting.TextMateEditorHighlighterProvider

class BlorpEditorHighlighterProvider : EditorHighlighterProvider {
    override fun getEditorHighlighter(
        project: Project?,
        fileType: FileType,
        virtualFile: VirtualFile?,
        colors: EditorColorsScheme
    ): EditorHighlighter =
        TEXTMATE_PROVIDER.getEditorHighlighter(project, fileType, virtualFile, colors)

    companion object {
        private val TEXTMATE_PROVIDER = TextMateEditorHighlighterProvider()
    }
}
