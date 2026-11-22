package com.blorp.intellij

import com.intellij.openapi.vfs.VirtualFile

internal fun VirtualFile.isBlorpSourceFile(): Boolean = isBlorpSourceName(name)

// Ignoring case, as the platform matches the file type's `extensions="brp"`.
internal fun isBlorpSourceName(fileName: String): Boolean =
    fileName.endsWith(".brp", ignoreCase = true)
