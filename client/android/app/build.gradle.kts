plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "tvbox.next.tvbox_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
    implementation("tvbox.engine:api:0.1.0")
    implementation("tvbox.engine:runtime-js:0.1.0")
    implementation("io.ktor:ktor-server-cio:3.6.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Host API for jar spiders: TVBox's OkHttp helper exposes androidx ArrayMap in its signatures.
    implementation("androidx.collection:collection:1.5.0")
    // Libraries jar spiders expect the host to provide.
    implementation("com.google.code.gson:gson:2.13.2")
    implementation("org.jsoup:jsoup:1.24.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
