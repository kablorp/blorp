package com.blorp.intellij

import com.intellij.execution.configurations.GeneralCommandLine
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
        if (file.extension == "brp") {
            serverStarter.ensureServerStarted(BlorpLspServerDescriptor(project))
        }
    }
}

private class BlorpLspServerDescriptor(project: Project) :
    ProjectWideLspServerDescriptor(project, "Blorp") {

    override fun isSupportedFile(file: VirtualFile) = file.extension == "brp"

    override fun createCommandLine(): GeneralCommandLine {
        val commandLine = GeneralCommandLine(resolveBlorpPath(), "lsp")
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
}
