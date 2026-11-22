import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release signing key. CI: the ANDROID_KEYSTORE_* secrets (see .github/workflows/desktop.yml). A local release
// build: a properties file named by YINGZHOU_SIGNING (keystore, alias, storePassword, keyPassword). Without either,
// release builds are signed with the debug key and cannot update an installed release.
val releaseSigning: Map<String, String>? = run {
    val env = System.getenv()
    val file = env["ANDROID_KEYSTORE_FILE"]
    if (!file.isNullOrBlank() && File(file).isFile) {
        return@run mapOf(
            "keystore" to file,
            "alias" to (env["ANDROID_KEY_ALIAS"] ?: ""),
            "storePassword" to (env["ANDROID_KEYSTORE_PASSWORD"] ?: ""),
            "keyPassword" to (env["ANDROID_KEY_PASSWORD"] ?: ""),
        )
    }
    val props = env["YINGZHOU_SIGNING"]?.let { File(it) }?.takeIf { it.isFile } ?: return@run null
    Properties().apply { props.inputStream().use { load(it) } }.let { p -> p.stringPropertyNames().associateWith { p.getProperty(it) } }
}

android {
    namespace = "tvbox.next.tvbox_client"
    // quickjs-kt-android requires compiling against API 37 (does not change minSdk/targetSdk).
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Never change it once released: Android treats another id as another app.
        applicationId = "io.github.sa1koro.yingzhou"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigning != null) {
            create("release") {
                storeFile = File(releaseSigning.getValue("keystore"))
                keyAlias = releaseSigning.getValue("alias")
                storePassword = releaseSigning.getValue("storePassword")
                keyPassword = releaseSigning.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            // Jar spiders link against host classes (OkHttp, Gson, Jsoup, com.github.catvod.*) by name.
            proguardFiles("proguard-rules.pro")
        }
    }

    sourceSets {
        getByName("main") {
            // TVBox host classes for jar spiders (com.github.catvod.*) and the jar runtime shared with the desktop engine.
            java.srcDirs("../../../engine/jar-host/java", "../../../engine/jar-host/kotlin")
        }
    }

    packaging {
        resources {
            excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/INDEX.LIST", "META-INF/io.netty.versions.properties", "META-INF/DEPENDENCIES")
        }
    }
}

dependencies {
    // Embedded engine (composite build of ../../engine).
    implementation("tvbox.engine:api:0.4.1468250")
    implementation("tvbox.engine:runtime-js:0.4.1468250")
    implementation("io.ktor:ktor-server-cio:3.6.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Host API for jar spiders: TVBox's OkHttp helper exposes androidx ArrayMap in its signatures.
    implementation("androidx.collection:collection:1.5.0")
    // Libraries jar spiders expect the host to provide.
    implementation("com.google.code.gson:gson:2.13.2")
    implementation("org.jsoup:jsoup:1.24.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // FileProvider: the share sheet for exports on Android 9 and earlier (already in the APK through Flutter's embedding).
    implementation("androidx.core:core:1.13.1")
    implementation("androidx.webkit:webkit:1.12.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
