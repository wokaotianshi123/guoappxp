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
        // 官方仓库全部保留在最后兜底，镜像只是排在前面「先试」。
        // 之所以要镜像：GitHub Actions 的 runner 是共享出口 IP，Maven Central 经常
        // 直接回 429 Too Many Requests；Gradle 一旦收到 429 就会把这个仓库整场
        // 标记为不可用（日志里是「Repository ... is disabled due to earlier error」），
        // 后续所有依赖解析连锁失败，表现为完全不相干的「找不到插件」。
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2/") {
            name = "CentralMirror"
        }
        maven("https://maven.aliyun.com/repository/public") { name = "AliyunPublic" }
        maven("https://maven.aliyun.com/repository/gradle-plugin") { name = "AliyunPlugin" }
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    id("com.chaquo.python") version "17.1.0" apply false
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}

include(":app")
