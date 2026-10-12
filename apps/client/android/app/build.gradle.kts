plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseStore = System.getenv("VIORA_ANDROID_KEYSTORE")
val releaseAlias = System.getenv("VIORA_ANDROID_KEY_ALIAS")
val releaseStorePassword = System.getenv("VIORA_ANDROID_STORE_PASSWORD")
val releaseKeyPassword = System.getenv("VIORA_ANDROID_KEY_PASSWORD")
val hasReleaseSigning = listOf(releaseStore, releaseAlias, releaseStorePassword, releaseKeyPassword)
    .all { !it.isNullOrBlank() }
if (gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) } && !hasReleaseSigning) {
    throw GradleException("Release signing is required. Use scripts/build-android-release.ps1 with the owner's external signing profile.")
}

android {
    namespace = "dev.viora.viora_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.viora.viora_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = providers.gradleProperty("vioraVersionCode").orNull?.toInt() ?: flutter.versionCode
        versionName = providers.gradleProperty("vioraVersionName").orNull ?: flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("vioraRelease") {
                storeFile = file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("vioraRelease")
        }
    }
}

flutter {
    source = "../.."
}
