package com.blorp.intellij

import org.jetbrains.plugins.textmate.api.TextMateBundleProvider
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

class BlorpTextMateBundleProvider : TextMateBundleProvider {

    private val bundleDir: Path? by lazy { extractBundle() }

    override fun getBundles(): List<TextMateBundleProvider.PluginBundle> {
        val dir = bundleDir ?: return emptyList()
        return listOf(TextMateBundleProvider.PluginBundle("blorp", dir))
    }

    private fun extractBundle(): Path? {
        return try {
            val dir = Files.createTempDirectory("blorp-textmate")
            val syntaxesDir = dir.resolve("syntaxes")
            Files.createDirectories(syntaxesDir)

            copyResource("textmate/blorp/package.json", dir.resolve("package.json"))
            copyResource("textmate/blorp/language-configuration.json", dir.resolve("language-configuration.json"))
            copyResource("textmate/blorp/syntaxes/blorp.tmLanguage.json", syntaxesDir.resolve("blorp.tmLanguage.json"))

            dir
        } catch (e: Exception) {
            null
        }
    }

    private fun copyResource(resourcePath: String, target: Path) {
        val stream = javaClass.classLoader.getResourceAsStream(resourcePath)
            ?: throw IllegalStateException("Missing resource: $resourcePath")
        stream.use { Files.copy(it, target, StandardCopyOption.REPLACE_EXISTING) }
    }
}
