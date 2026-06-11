package com.blorp.intellij

import com.intellij.lang.Language
import com.intellij.openapi.fileTypes.LanguageFileType
import javax.swing.Icon

object BlorpLanguage : Language("Blorp")

class BlorpFileType private constructor() : LanguageFileType(BlorpLanguage) {
    override fun getName(): String = "Blorp"

    override fun getDescription(): String = "Blorp source file"

    override fun getDefaultExtension(): String = "brp"

    override fun getIcon(): Icon? = null

    companion object {
        @JvmField
        val INSTANCE = BlorpFileType()
    }
}
