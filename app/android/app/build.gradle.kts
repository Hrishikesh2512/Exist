import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The server address is baked in at build time (--dart-define=API_URL=...). Plain http is only
// allowed for local test builds; a launch build with https blocks unencrypted traffic.
val dartDefines: Map<String, String> =
    ((project.findProperty("dart-defines") as String?) ?: "")
        .split(",")
        .filter { it.isNotBlank() }
        .mapNotNull { runCatching { String(Base64.getDecoder().decode(it)) }.getOrNull() }
        .mapNotNull { d -> d.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] } }
        .toMap()
val apiUrl = dartDefines["API_URL"] ?: "http://10.0.2.2:8080"

android {
    namespace = "edu.exist.exist"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "edu.exist.exist"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // BLE advertising sets (two broadcasts at once)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["usesCleartextTraffic"] = apiUrl.startsWith("http://").toString()
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
