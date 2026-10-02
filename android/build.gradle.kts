// 根工程构建脚本 —— 对齐 Flutter 3.47.6 官方模板。
//
// 迁移说明（Phase 1，2026-10-02）：
//   旧写法在此版本已不可用：
//     - buildscript { classpath 'com.android.tools.build:gradle:7.3.0' }  → AGP 版本改由
//       settings.gradle.kts 的 plugins {} 块声明；
//     - ext.kotlin_version = '1.7.10'                                     → 同上，改为 2.4.0；
//     - apply plugin: 'com.android.application' / apply from: flutter.gradle → imperative 写法已移除，
//       改为 app/build.gradle.kts 里的 declarative plugins {}。
//   本文件按官方 android-kotlin.tmpl/build.gradle.kts.tmpl 保留仓库源与 buildDir 重定向。
//
// 未使用 `flutter create .`，以免覆盖 AndroidManifest.xml 中项目特有的
// Android TV / Leanback / MediaSession 声明。

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
