pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
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
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // Das Flutter-Paket maplibre_android (0.3.6) wendet dieses Plugin in seinem Gradle-Skript an, bringt es aber nicht mit: hier bereitstellen.
    // Es läuft nur in den Prüfaufgaben (ktlint) des Pakets, nicht im App-Build. Version 14.2.0 vom 12.03.2026, exakt gepinnt.
    id("org.jlleitschuh.gradle.ktlint") version "14.2.0" apply false
}

include(":app")
