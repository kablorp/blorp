import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.3.20"
    id("org.jetbrains.intellij.platform") version "2.20.1"
}

group = "com.blorp"
version = "0.0.1"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

// -PclionPath=/path/to/CLion.app builds against an installed CLion (nothing large is
// downloaded); without it the published CLion release below is downloaded.
val clionPath: String? = providers.gradleProperty("clionPath").orNull
val publishedClionVersion = "2026.3"

dependencies {
    intellijPlatform {
        if (clionPath != null) {
            local(clionPath)
        } else {
            clion(publishedClionVersion)
        }
        testFramework(TestFrameworkType.Platform)
    }

    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testRuntimeOnly("org.junit.vintage:junit-vintage-engine:5.10.1")
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "263"
        }
    }
    instrumentCode = false
    buildSearchableOptions = false
}

tasks.test {
    useJUnitPlatform()
    // The Go to Declaration tests run the repository's own `blorp lsp` build
    // (`make -C blorp compiler`); a rebuilt server reruns them.
    val blorpBinary = layout.projectDirectory.file("../../blorp/build/blorp").asFile
    systemProperty("blorp.binary", blorpBinary.path)
    inputs.files(blorpBinary).optional()
}
