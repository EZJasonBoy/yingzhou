plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// JS spiders on QuickJS (quickjs-kt bundles natives for Windows/macOS/Linux and has an Android artifact).
dependencies {
    api(project(":core"))
    implementation(libs.quickjs.kt)
    implementation(libs.jsoup)
    implementation(libs.gson)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
    testImplementation(libs.okhttp.mockwebserver)
}
