import org.jetbrains.kotlin.gradle.dsl.JvmTarget

group = "io.flutter.plugins.videoplayer"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.13.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget(JavaVersion.VERSION_17.toString())
    }
}

android {
    namespace = "io.flutter.plugins.videoplayer"
    compileSdk = flutter.compileSdkVersion

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Zorofin: the app probes the FFmpeg decoder by name.
        consumerProguardFiles("consumer-rules.pro")
    }

    lint {
        checkAllWarnings = true
        warningsAsErrors = true
        disable.addAll(setOf("AndroidGradlePluginVersion", "InvalidPackage", "GradleDependency", "NewerVersionAvailable"))
        baseline = file("lint-baseline.xml")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    dependencies {
        val exoplayerVersion = "1.9.2"
        implementation("androidx.media3:media3-exoplayer:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-hls:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-dash:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-rtsp:${exoplayerVersion}")
        implementation("androidx.media3:media3-exoplayer-smoothstreaming:${exoplayerVersion}")
        // Zorofin: prebuilt FFmpeg audio decoders (GPL-3.0, Jellyfin project).
        // Media3 aligns its modules, so this runs on the ${exoplayerVersion} core.
        implementation("org.jellyfin.media3:media3-ffmpeg-decoder:1.9.0+1")
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            isReturnDefaultValues = true
            all {
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
                // The org.gradle.jvmargs property that may be set in gradle.properties does not impact
                // the Java heap size when running the Android unit tests. The following property here
                // sets the heap size to a size large enough to run the robolectric tests across
                // multiple SDK levels.
                it.jvmArgs("-Xmx4G")
            }
        }
    }
}
