package com.blorp.intellij

import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BlorpLauncherTest {
    @Test
    fun configuredPathWinsOverProjectBuild() {
        assertEquals("/custom/blorp", resolveBlorpPath("/custom/blorp", "/work") { true })
    }

    @Test
    fun configuredPathIsTrimmed() {
        assertEquals("/custom/blorp", resolveBlorpPath("  /custom/blorp ", "/work") { false })
    }

    @Test
    fun blankConfigurationUsesExecutableProjectBuild() {
        val expected = Path.of("/work", "blorp", "build", "blorp")
        assertEquals(expected.toString(), resolveBlorpPath("", "/work") { it == expected })
    }

    @Test
    fun whitespaceOnlyConfigurationFallsBack() {
        val expected = Path.of("/work", "blorp", "build", "blorp")
        assertEquals(expected.toString(), resolveBlorpPath("   ", "/work") { it == expected })
        assertEquals("blorp", resolveBlorpPath("   ", "/work") { false })
    }

    @Test
    fun bareNameForcesPathLookupEvenWithProjectBuild() {
        assertEquals("blorp", resolveBlorpPath("blorp", "/work") { true })
    }

    @Test
    fun relativeConfiguredPathResolvesUnderProjectBase() {
        assertEquals(
            Path.of("/work", "build", "blorp").toString(),
            resolveBlorpPath("build/blorp", "/work") { false },
        )
    }

    @Test
    fun relativeConfiguredPathStaysWithoutProjectBase() {
        assertEquals("build/blorp", resolveBlorpPath("build/blorp", null) { false })
    }

    @Test
    fun missingProjectBuildFallsBackToPath() {
        assertEquals("blorp", resolveBlorpPath("", "/work") { false })
    }

    @Test
    fun missingProjectFallsBackToPath() {
        assertEquals("blorp", resolveBlorpPath("", null) { true })
    }

    @Test
    fun recognisesBlorpSourceNames() {
        assertTrue(isBlorpSourceName("main.brp"))
        assertTrue(isBlorpSourceName("Main.BRP"))
        assertFalse(isBlorpSourceName("main.brp.txt"))
        assertFalse(isBlorpSourceName("brp"))
    }

    @Test
    fun existingExecutablePathHasNoLaunchProblem() {
        assertNull(launchProblem("/work/blorp/build/blorp", isExecutable = { true }))
    }

    @Test
    fun missingBinaryPathNamesThePathInItsProblem() {
        val problem = launchProblem("/nonexistent/blorp", isExecutable = { false })
        assertNotNull(problem)
        assertTrue("/nonexistent/blorp" in problem)
    }

    @Test
    fun bareNameOnPathHasNoLaunchProblem() {
        assertNull(launchProblem("blorp", isExecutable = { false }, findOnPath = { Path.of("/usr/local/bin", it) }))
    }

    @Test
    fun bareNameMissingFromPathNamesItsProblem() {
        val problem = launchProblem("blorp", isExecutable = { false }, findOnPath = { null })
        assertNotNull(problem)
        assertTrue("blorp" in problem && "PATH" in problem)
    }
}
