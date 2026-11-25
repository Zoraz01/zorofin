import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties on a developer machine, or the
// ZOROFIN_KEYSTORE_* variables in CI. Without either, release builds use the
// debug key so `flutter run --release` still works. See
// docs/TV_DEVICE_TESTING.md for creating the key.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
fun signingValue(property: String, env: String): String? =
    keyProperties.getProperty(property) ?: System.getenv(env)?.takeIf { it.isNotBlank() }
val releaseStore = signingValue("storeFile", "ZOROFIN_KEYSTORE_PATH")

// Keep the existing Fire TV/sideload APK compatible. Google Play's dedicated
// TV track instead requires Leanback; opt in per build without another app ID.
// google-play-mobile is the phone and tablet bundle for Play's default track:
// Leanback stays optional, and release signing is required as for TV.
val zorofinDistribution = providers.gradleProperty("zorofinDistribution")
    .orElse("universal-tv").get()
require(zorofinDistribution in setOf("universal-tv", "google-play-tv", "google-play-mobile")) {
    "zorofinDistribution must be universal-tv, google-play-tv or google-play-mobile"
}
if (zorofinDistribution.startsWith("google-play-")) {
    require(!releaseStore.isNullOrBlank() &&
        !signingValue("storePassword", "ZOROFIN_KEYSTORE_PASSWORD").isNullOrBlank() &&
        !signingValue("keyAlias", "ZOROFIN_KEY_ALIAS").isNullOrBlank() &&
        !signingValue("keyPassword", "ZOROFIN_KEY_PASSWORD").isNullOrBlank()) {
        "$zorofinDistribution requires the existing release signing configuration"
    }
}

android {
    namespace = "org.zorofin.zorofin_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.zorofin.tv"
        manifestPlaceholders["zorofinLeanbackRequired"] =
            (zorofinDistribution == "google-play-tv").toString()
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = signingValue("storePassword", "ZOROFIN_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ZOROFIN_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ZOROFIN_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
