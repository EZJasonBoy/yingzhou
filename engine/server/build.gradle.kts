plugins {
    alias(libs.plugins.kotlin.jvm)
    application
}

dependencies {
    implementation(project(":api"))
    implementation(libs.ktor.server.cio)
    runtimeOnly(libs.logback)
}

application {
    mainClass.set("tvbox.engine.server.MainKt")
    applicationName = "tvbox-engine"
}
