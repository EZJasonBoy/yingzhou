plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// Python spiders in a Python process of their own (desktop / NAS; the Android app has no Python).
dependencies {
    api(project(":core"))
    implementation(libs.gson)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
    testImplementation(libs.okhttp.mockwebserver)
    testImplementation(project(":api"))
    testImplementation(libs.ktor.server.test.host)
}
