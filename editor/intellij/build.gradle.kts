import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.1.0"
    id("org.jetbrains.intellij.platform") version "2.11.0"
}

group = "com.blorp"
version = "0.0.1"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        clion("2025.3.2")
        bundledPlugin("org.jetbrains.plugins.textmate")
        testFramework(TestFrameworkType.Platform)
    }

    testImplementation(kotlin("test"))
    testImplementation("junit:junit:4.13.2")
    testRuntimeOnly("org.junit.vintage:junit-vintage-engine:5.10.1")
}

kotlin {
    jvmToolchain(21)
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = "253"
        }
    }
    pluginVerification {
        ides {
            recommended()
        }
    }
    instrumentCode = false
    buildSearchableOptions = false
}

tasks.test {
    useJUnitPlatform()
}
