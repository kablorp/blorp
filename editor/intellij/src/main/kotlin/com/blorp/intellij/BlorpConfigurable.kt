package com.blorp.intellij

import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.project.Project
import com.intellij.platform.lsp.api.LspClientManager
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel

class BlorpConfigurable(private val project: Project) : BoundConfigurable("Blorp") {

    /** Applies a changed path now: the running server is stopped and restarted for open files. */
    override fun apply() {
        val pathBefore = BlorpSettings.getInstance(project).serverPath
        super.apply()
        if (BlorpSettings.getInstance(project).serverPath != pathBefore) {
            LspClientManager.getInstance(project).stopAndRestartClientsIfNeeded(BlorpLspIntegrationProvider::class.java)
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
