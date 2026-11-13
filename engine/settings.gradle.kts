pluginManagement {
    repositories {
        gradlePluginPortal()
        mavenCentral()
        google()
    }
}

dependencyResolutionManagement {
    repositories {
        mavenCentral()
        google()
    }
}

rootProject.name = "tvbox-engine"

include(":core", ":api", ":server", ":runtime-js", ":runtime-jar")
