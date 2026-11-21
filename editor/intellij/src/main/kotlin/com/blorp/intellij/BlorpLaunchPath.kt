package com.blorp.intellij

import com.intellij.execution.configurations.PathEnvironmentVariableUtil
import java.nio.file.Files
import java.nio.file.Path

/** The compiler's own build output under a project checkout. */
internal val PROJECT_BUILD_BINARY: Path = Path.of("blorp", "build", "blorp")

private const val PATH_BINARY_NAME = "blorp"

private val isExecutableFile: (Path) -> Boolean = { Files.isRegularFile(it) && Files.isExecutable(it) }

/**
 * The binary the launcher runs. A configured path wins: absolute as given, relative with a
 * directory part (`build/blorp`) under the project base when there is one, and a bare name
 * (`blorp`) left for PATH lookup. A blank setting means this repository's build output under
 * the project base if executable, else `blorp` on PATH. Kept free of the IDE so a unit test
 * covers every branch.
 */
internal fun resolveBlorpPath(
    configured: String,
    projectBasePath: String?,
    isExecutable: (Path) -> Boolean = isExecutableFile,
): String {
    val configuredPath = configured.trim()
    if (configuredPath.isNotEmpty()) {
        val path = Path.of(configuredPath)
        return if (!path.isAbsolute && isFilePath(path) && projectBasePath != null) {
            Path.of(projectBasePath).resolve(path).toString()
        } else {
            configuredPath
        }
    }
    val projectBinary = projectBasePath?.let { Path.of(it).resolve(PROJECT_BUILD_BINARY) }
    if (projectBinary != null && isExecutable(projectBinary)) {
        return projectBinary.toString()
    }
    return PATH_BINARY_NAME
}

/**
 * Why the resolved binary cannot start, or null when it can. The platform only logs a failed
 * start, so the user would see nothing. A bare name is looked up on the PATH the server's
 * process inherits.
 */
internal fun launchProblem(
    resolvedPath: String,
    isExecutable: (Path) -> Boolean = isExecutableFile,
    findOnPath: (String) -> Path? = { PathEnvironmentVariableUtil.findFirst(it) },
): String? {
    val path = Path.of(resolvedPath)
    return when {
        !isFilePath(path) -> if (findOnPath(resolvedPath) == null) "$resolvedPath is not on PATH." else null
        isExecutable(path) -> null
        else -> "$resolvedPath does not exist or is not executable."
    }
}

private fun isFilePath(path: Path): Boolean = path.parent != null
