import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyPropertiesFile = rootProject.file("key.properties")
val releaseKeyProperties = Properties()
val hasReleaseSigning = releaseKeyPropertiesFile.isFile.also { available ->
    if (available) {
        releaseKeyPropertiesFile.inputStream().use { input ->
            releaseKeyProperties.load(input)
        }
    }
}
val requestedReleaseBuild = gradle.startParameter.taskNames.any { task ->
    task.contains("release", ignoreCase = true)
}

android {
    namespace = "com.readvibe.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "META-INF/DEPENDENCIES"
    }

    defaultConfig {
        // Stable application ID for the ReadVibe Android demo.
        applicationId = "com.readvibe.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Legacy .doc extraction uses Apache POI's HWPF implementation. Keep
        // the supported Android floor explicit instead of relying on a plugin
        // manifest to raise it implicitly.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                val storePath = releaseKeyProperties.getProperty("storeFile")
                    ?: throw GradleException("key.properties 缺少 storeFile")
                storeFile = rootProject.file(storePath)
                storePassword = releaseKeyProperties.getProperty("storePassword")
                    ?: throw GradleException("key.properties 缺少 storePassword")
                keyAlias = releaseKeyProperties.getProperty("keyAlias")
                    ?: throw GradleException("key.properties 缺少 keyAlias")
                keyPassword = releaseKeyProperties.getProperty("keyPassword")
                    ?: throw GradleException("key.properties 缺少 keyPassword")
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            if (!hasReleaseSigning && requestedReleaseBuild) {
                throw GradleException(
                    "缺少 android/key.properties；release 构建拒绝回退到 debug 签名"
                )
            }
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    implementation("org.apache.poi:poi-scratchpad:5.5.1")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // Bundled on-device model: scanned PDF OCR never uploads page images.
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
