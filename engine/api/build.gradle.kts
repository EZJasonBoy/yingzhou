plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

// HTTP routes shared by the standalone server and the Android-embedded engine.
dependencies {
    api(project(":core"))
    api(libs.ktor.server.core)
    implementation(libs.ktor.server.content.negotiation)
    implementation(libs.ktor.server.status.pages)
    implementation(libs.ktor.server.cors)
    // The LAN remote control: screens and controllers meet over WebSockets (remote/RemoteHub.kt).
    implementation(libs.ktor.server.websockets)
    implementation(libs.ktor.serialization.json)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
    testImplementation(libs.ktor.server.test.host)
    testImplementation(libs.ktor.server.cio)
    testImplementation(libs.okhttp.mockwebserver)
}
