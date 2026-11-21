package com.blorp.intellij

import com.intellij.lang.Language
import com.intellij.openapi.fileTypes.LanguageFileType
import com.intellij.openapi.util.IconLoader
import javax.swing.Icon

object BlorpLanguage : Language("Blorp")

class BlorpFileType private constructor() : LanguageFileType(BlorpLanguage) {
    override fun getName(): String = "Blorp"

    override fun getDescription(): String = "Blorp source file"

    override fun getDefaultExtension(): String = "brp"

    override fun getIcon(): Icon = BlorpIcons.FILE

    companion object {
        @JvmField
        val INSTANCE = BlorpFileType()
    }
}

object BlorpIcons {
    @JvmField
    val FILE: Icon = IconLoader.getIcon("/icons/blorp.svg", BlorpIcons::class.java)
}
