package com.blorp.intellij

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.platform.lsp.api.LspServerSupportProvider
import com.intellij.platform.lsp.api.LspServerSupportProvider.LspServerStarter
import com.intellij.platform.lsp.api.ProjectWideLspServerDescriptor
import java.nio.file.Files
import java.nio.file.Path

internal class BlorpLspServerSupportProvider : LspServerSupportProvider {
    override fun fileOpened(
        project: Project,
        file: VirtualFile,
        serverStarter: LspServerStarter
    ) {
        if (file.isBlorpSourceFile()) {
            LOG.info("Starting Blorp LSP support for ${file.path}")
            serverStarter.ensureServerStarted(BlorpLspServerDescriptor(project))
        }
    }

    companion object {
        private val LOG = Logger.getInstance(BlorpLspServerSupportProvider::class.java)
    }
}

private class BlorpLspServerDescriptor(project: Project) :
    ProjectWideLspServerDescriptor(project, "Blorp") {

    override fun isSupportedFile(file: VirtualFile) = file.isBlorpSourceFile()

    override fun createCommandLine(): GeneralCommandLine {
        val blorpPath = resolveBlorpPath()
        LOG.info("Launching Blorp LSP: $blorpPath lsp")
        val commandLine = GeneralCommandLine(blorpPath, "lsp")
        this.project.basePath?.let { commandLine.withWorkDirectory(it) }
        return commandLine
    }

    private fun resolveBlorpPath(): String {
        val configured = BlorpSettings.getInstance(this.project).serverPath.trim()
        if (configured.isNotEmpty() && configured != "blorp") {
            return configured
        }

        val projectBinary = this.project.basePath?.let { Path.of(it, "blorp") }
        if (projectBinary != null &&
            Files.isRegularFile(projectBinary) &&
            Files.isExecutable(projectBinary)
        ) {
            return projectBinary.toString()
        }

        return "blorp"
    }

    companion object {
        private val LOG = Logger.getInstance(BlorpLspServerDescriptor::class.java)
    }
}

private fun VirtualFile.isBlorpSourceFile(): Boolean =
    extension.equals("brp", ignoreCase = true)
