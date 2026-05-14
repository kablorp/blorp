package com.blorp.intellij

import com.intellij.openapi.components.*
import com.intellij.openapi.project.Project

@Service(Service.Level.PROJECT)
@State(
    name = "BlorpSettings",
    storages = [Storage("blorp.xml")]
)
class BlorpSettings : PersistentStateComponent<BlorpSettings.State> {
    data class State(var serverPath: String = "blorp")

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
