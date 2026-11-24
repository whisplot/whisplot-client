pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            // Flutter writes UTF-8 paths; java.util.Properties InputStream uses
            // Latin-1. Normalize once so Android/Gradle also handle Chinese paths.
            file("local.properties").reader(Charsets.UTF_8).use { properties.load(it) }
            file("local.properties").outputStream().use {
                properties.store(it, "Local SDK paths; generated, never commit")
            }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
    id("com.google.gms.google-services") version "4.4.4" apply false
}

include(":app")
