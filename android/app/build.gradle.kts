// app 模块构建脚本 —— 对齐 Flutter 3.47.6 官方模板（android-kotlin.tmpl/app/build.gradle.kts.tmpl）。
//
// 迁移说明（Phase 1，2026-10-02）：
//   旧写法：apply plugin: 'com.android.application' / 'kotlin-android'
//           apply from: "$flutterRoot/packages/flutter_tools/gradle/flutter.gradle"
//           compileSdkVersion 34 / minSdkVersion 21 / targetSdkVersion 34
//           + dependencies { implementation kotlin-stdlib-jdk7 }
//   全部改为 declarative plugins {} + flutter.compileSdkVersion 等 flutter 扩展属性。
//
// 保留自项目：namespace / applicationId = com.feiniu.tv.music、release 用 debug 签名。
// minSdk 说明：原写死 21，低于 Flutter 3.47 的下限（flutter.minSdkVersion = 24），
//             沿用官方默认值 24；API 24（Android 7.0）已覆盖绝大多数 Android TV 盒子。
// 未改动 AndroidManifest.xml，Android TV / Leanback / MediaSession 声明全部保留。

plugins {
    id("com.android.application")
    // Flutter Gradle Plugin 必须在 Android / Kotlin 插件之后应用。
    // Kotlin 插件由 Flutter 插件通过 detectApplyingKotlinGradlePlugin 自动应用（官方模板即如此）。
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.feiniu.tv.music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.feiniu.tv.music"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Phase 1 调试期先用 debug 签名；发布前替换为正式签名。
            signingConfig = signingConfigs.getByName("debug")
            minifyEnabled = false
            shrinkResources = false
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
