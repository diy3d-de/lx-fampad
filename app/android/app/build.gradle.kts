import java.util.Properties

plugins {
    id("com.android.application")
    // AGP 9 mit android.builtInKotlin=false (siehe gradle.properties): Das Kotlin-Plugin muss hier ausdrücklich
    // angewendet werden, sonst wird MainActivity.kt nicht kompiliert. Version steht in settings.gradle.kts.
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Signatur: android/key.properties (nicht eingecheckt). Ohne Datei bricht jeder Release-Build ab (siehe unten);
// der Debug-Schlüssel wird nur für Debug-Builds verwendet.
// Wichtig: Signaturschlüssel und applicationId nie ändern, sonst lassen sich Updates nicht installieren.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.lx_labs.fampad"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.lx_labs.fampad"
        // Android 9 (API 28): Mindestversion für Passkeys über den Credential Manager
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!keyProps.isEmpty) {
            create("release") {
                fun prop(name: String): String =
                    keyProps.getProperty(name)?.takeIf { it.isNotBlank() }
                        ?: throw GradleException("android/key.properties: '$name' fehlt")
                storeFile = file(prop("storeFile"))
                storePassword = prop("storePassword")
                keyAlias = prop("keyAlias")
                keyPassword = prop("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // bewusst kein Rückfall auf den Debug-Schlüssel: ohne key.properties gibt es keine Signatur,
            // und der Build bricht unten mit einer klaren Meldung ab
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// Release-Builds (APK/Bundle) ohne android/key.properties abbrechen: eine mit dem Debug-Schlüssel signierte
// Release-APK ließe sich nie über die echte App aktualisieren.
gradle.taskGraph.whenReady {
    val releaseGebaut = allTasks.any {
        it.project == project && Regex("^(assemble|bundle|package|validateSigning)Release.*").matches(it.name)
    }
    if (releaseGebaut && keyProps.isEmpty) {
        throw GradleException(
            "Release-Build ohne Signatur: android/key.properties fehlt. " +
                "Lege die Datei mit storeFile, storePassword, keyAlias und keyPassword an (nicht einchecken).",
        )
    }
}

dependencies {
    implementation("androidx.core:core:1.16.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
