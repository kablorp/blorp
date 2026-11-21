package com.blorp.intellij

import com.intellij.execution.ExecutionException
import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspIntegrationProvider
import com.intellij.platform.lsp.api.LspIntegrationProvider.LspClientStarter
import com.intellij.platform.lsp.api.ProjectWideLspClientDescriptor
import com.intellij.platform.lsp.api.customization.LspCustomization
import com.intellij.platform.lsp.api.customization.LspSemanticTokensCustomizer

internal class BlorpLspIntegrationProvider : LspIntegrationProvider {
    override fun fileOpened(project: Project, file: VirtualFile, clientStarter: LspClientStarter) {
        if (file.isBlorpSourceFile()) {
            clientStarter.ensureClientStarted(BlorpLspClientDescriptor(project))
        }
    }
}

internal class BlorpLspClientDescriptor(project: Project) :
    ProjectWideLspClientDescriptor(project, "Blorp") {

    override fun isSupportedFile(file: VirtualFile) = file.isBlorpSourceFile()

    override val lspCustomization: LspCustomization = object : LspCustomization() {
        override val semanticTokensCustomizer: LspSemanticTokensCustomizer = BlorpSemanticTokensSupport()
    }

    override fun createCommandLine(): GeneralCommandLine {
        val blorpPath = resolveBlorpPath(
            BlorpSettings.getInstance(project).serverPath,
            project.basePath,
        )
        launchProblem(blorpPath)?.let { problem ->
            notifyLaunchFailed(project, problem)
            throw ExecutionException(problem)
        }
        LOG.info("Launching Blorp LSP: $blorpPath lsp")
        val commandLine = GeneralCommandLine(blorpPath, "lsp")
        project.basePath?.let { commandLine.withWorkDirectory(it) }
        return commandLine
    }

    private companion object {
        val LOG = Logger.getInstance(BlorpLspClientDescriptor::class.java)
    }
}

internal fun VirtualFile.isBlorpSourceFile(): Boolean = isBlorpSourceName(name)

// Ignoring case, as the platform matches the file type's `extensions="brp"`.
internal fun isBlorpSourceName(fileName: String): Boolean =
    fileName.endsWith(".brp", ignoreCase = true)
