package com.blorp.intellij

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import com.intellij.openapi.vfs.VirtualFile
import com.intellij.openapi.vfs.VirtualFileManager
import com.intellij.platform.lsp.api.LspServerSupportProvider
import com.intellij.platform.lsp.api.LspServerSupportProvider.LspServerStarter
import com.intellij.platform.lsp.api.ProjectWideLspServerDescriptor
import org.eclipse.lsp4j.ClientCapabilities
import org.eclipse.lsp4j.DeclarationCapabilities
import org.eclipse.lsp4j.DefinitionCapabilities
import org.eclipse.lsp4j.TextDocumentClientCapabilities
import org.eclipse.lsp4j.TypeDefinitionCapabilities
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.Paths

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

internal class BlorpLspServerDescriptor(project: Project) :
    ProjectWideLspServerDescriptor(project, "Blorp") {

    override fun isSupportedFile(file: VirtualFile) = file.isBlorpSourceFile()

    override fun findFileByUri(fileUri: String): VirtualFile? =
        super.findFileByUri(fileUri)
            ?: VirtualFileManager.getInstance().findFileByUrl(fileUri)
            ?: refreshLocalFileByUri(fileUri)

    override val clientCapabilities: ClientCapabilities
        get() {
            val capabilities = super.clientCapabilities
            val textDocument = capabilities.textDocument ?: TextDocumentClientCapabilities()
                .also { capabilities.textDocument = it }

            val definition = textDocument.definition ?: DefinitionCapabilities()
                .also { textDocument.definition = it }
            definition.linkSupport = true

            val declaration = textDocument.declaration ?: DeclarationCapabilities()
                .also { textDocument.declaration = it }
            declaration.linkSupport = true

            val typeDefinition = textDocument.typeDefinition ?: TypeDefinitionCapabilities()
                .also { textDocument.typeDefinition = it }
            typeDefinition.linkSupport = true

            return capabilities
        }

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

    private fun refreshLocalFileByUri(fileUri: String): VirtualFile? {
        val uri = runCatching { URI(fileUri) }.getOrNull() ?: return null
        if (uri.scheme != "file") {
            return null
        }

        val path = runCatching { Paths.get(uri) }.getOrNull() ?: return null
        return LocalFileSystem.getInstance().refreshAndFindFileByNioFile(path)
    }

    companion object {
        private val LOG = Logger.getInstance(BlorpLspServerDescriptor::class.java)
    }
}

internal fun VirtualFile.isBlorpSourceFile(): Boolean =
    extension.equals("brp", ignoreCase = true)
