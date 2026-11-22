package com.blorp.intellij

import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.project.Project
import com.redhat.devtools.lsp4ij.LanguageServerManager
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel

class BlorpConfigurable(private val project: Project) : BoundConfigurable("Blorp") {

    /** Applies a changed path now: a running server is restarted. */
    override fun apply() {
        val pathBefore = BlorpSettings.getInstance(project).serverPath
        super.apply()
        if (BlorpSettings.getInstance(project).serverPath != pathBefore) {
            // stop() returns before the server has stopped, so a start right after it finds the
            // old server still running. A forced restart chains the start on the stop and builds
            // a new connection, which reads the new path. It leaves a server that is not running alone.
            LanguageServerManager.getInstance(project)
                .start(BLORP_SERVER_ID, LanguageServerManager.StartOptions().setForceRestart(true))
        }
    }

    override fun createPanel() = panel {
        row("Blorp executable path:") {
            textField()
                .bindText(
                    { BlorpSettings.getInstance(project).serverPath },
                    { BlorpSettings.getInstance(project).serverPath = it }
                )
                .comment("Path to the blorp binary; a relative path is taken from the project root, and a bare name such as blorp is looked up on PATH. Leave blank to use blorp/build/blorp under the project when it is executable, else blorp on PATH.")
        }
    }
}
