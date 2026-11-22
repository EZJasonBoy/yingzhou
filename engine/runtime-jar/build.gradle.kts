plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Jar spiders on a desktop JVM: the spider jar's dex is converted to class files (dex2jar) and loaded on top of
// Android stubs (src/main/java, adapted from Win-box, MIT) and the TVBox host classes shared with the Android app.
sourceSets {
    main {
        java.srcDir("../jar-host/java")
        kotlin.srcDir("../jar-host/kotlin")
    }
}

dependencies {
    api(project(":core"))
    // Libraries spiders expect the host to provide (Android ships org.json and androidx.collection itself).
    api(libs.okhttp)
    api(libs.gson)
    api(libs.jsoup)
    api(libs.android.json)
    api(libs.androidx.collection)
    implementation(libs.dex2jar)
    implementation(libs.unidbg.android)
    implementation(libs.unidbg.unicorn)
    implementation(libs.asm)
    implementation(libs.asm.commons)
    implementation(libs.asm.tree)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
    testImplementation(libs.okhttp.mockwebserver)
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.compilerArgs.addAll(listOf("-nowarn", "-Xlint:none"))
}
