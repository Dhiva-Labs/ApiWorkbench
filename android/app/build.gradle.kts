import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The upload key lives in android/key.properties, which is gitignored along
// with the keystore it points at. A fresh checkout or a CI runner has no
// release key and `flutter build apk --release` still has to work there, so
// the release build falls back to the debug key with a warning: a
// debug-signed bundle cannot be uploaded to Google Play.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties =
    Properties().apply {
        if (keystorePropertiesFile.exists()) {
            keystorePropertiesFile.inputStream().use { load(it) }
        }
    }
val hasUploadKey =
    keystorePropertiesFile.exists() &&
        keystoreProperties.getProperty("storeFile") != null &&
        rootProject.file(keystoreProperties.getProperty("storeFile")).exists()

android {
    namespace = "com.dhivalabs.api_workbench"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.dhivalabs.api_workbench"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasUploadKey) {
                    signingConfigs.getByName("upload")
                } else {
                    logger.warn(
                        "ApiWorkbench: android/key.properties not found — " +
                            "signing the release build with the debug key. " +
                            "The output is runnable but CANNOT be uploaded " +
                            "to Google Play.",
                    )
                    signingConfigs.getByName("debug")
                }
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
