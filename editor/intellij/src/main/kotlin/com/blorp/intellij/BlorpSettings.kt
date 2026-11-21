package com.blorp.intellij

import com.intellij.openapi.components.PersistentStateComponent
import com.intellij.openapi.components.Service
import com.intellij.openapi.components.State
import com.intellij.openapi.components.Storage
import com.intellij.openapi.project.Project

@Service(Service.Level.PROJECT)
@State(
    name = "BlorpSettings",
    storages = [Storage("blorp.xml")]
)
class BlorpSettings : PersistentStateComponent<BlorpSettings.State> {
    /** An empty path means: the project's build output, else `blorp` on PATH. */
    data class State(var serverPath: String = "")

    private var myState = State()

    override fun getState(): State = myState

    override fun loadState(state: State) {
        myState = state
    }

    var serverPath: String
        get() = myState.serverPath
        set(value) { myState.serverPath = value }

    companion object {
        fun getInstance(project: Project): BlorpSettings =
            project.getService(BlorpSettings::class.java)
    }
}
