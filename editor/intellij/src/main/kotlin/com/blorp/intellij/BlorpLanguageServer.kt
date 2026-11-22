package com.blorp.intellij

import com.intellij.execution.configurations.GeneralCommandLine
import com.intellij.openapi.diagnostic.Logger
import com.intellij.openapi.project.Project
import com.redhat.devtools.lsp4ij.LanguageServerFactory
import com.redhat.devtools.lsp4ij.server.OSProcessStreamConnectionProvider
import com.redhat.devtools.lsp4ij.server.StreamConnectionProvider

/** The server id `plugin.xml` registers the factory, the language mapping and the colours under. */
internal const val BLORP_SERVER_ID = "blorp"

internal class BlorpLanguageServerFactory : LanguageServerFactory {
    override fun createConnectionProvider(project: Project): StreamConnectionProvider =
        BlorpServerConnection(project)
}

private class BlorpServerConnection(project: Project) : OSProcessStreamConnectionProvider() {
    init {
        val blorpPath = resolveBlorpPath(
            BlorpSettings.getInstance(project).serverPath,
            project.basePath,
        )
        // LSP4IJ reports a failed start in its Language Servers tool window; this adds the balloon
        // with a way to the setting.
        launchProblem(blorpPath)?.let { notifyLaunchFailed(project, it) }
        LOG.info("Launching Blorp LSP: $blorpPath lsp")
        commandLine = GeneralCommandLine(blorpPath, "lsp").withWorkDirectory(project.basePath)
    }

    private companion object {
        val LOG = Logger.getInstance(BlorpServerConnection::class.java)
    }
}
