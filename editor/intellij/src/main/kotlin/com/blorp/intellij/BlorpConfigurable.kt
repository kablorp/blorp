package com.blorp.intellij

import com.intellij.openapi.options.BoundConfigurable
import com.intellij.openapi.project.Project
import com.intellij.ui.dsl.builder.bindText
import com.intellij.ui.dsl.builder.panel

class BlorpConfigurable(private val project: Project) : BoundConfigurable("Blorp") {

    override fun createPanel() = panel {
        row("Blorp executable path:") {
            textField()
                .bindText(
                    { BlorpSettings.getInstance(project).serverPath },
                    { BlorpSettings.getInstance(project).serverPath = it }
                )
                .comment("Path to the blorp compiler binary. Leave blank or \"blorp\" to use the project bin/blorp when present, then PATH.")
        }
    }
}
