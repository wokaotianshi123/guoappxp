import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

// PY 沙箱：内嵌 CPython（Chaquopy）。pip 依赖与 moytv 保持一致，
// py 蜘蛛常用的 requests / bs4 / lxml / pycryptodome 都能直接 import。
chaquopy {
    defaultConfig {
        version = "3.11"
        System.getenv("CHAQUOPY_BUILD_PYTHON")?.takeIf { it.isNotBlank() }
            ?.let { buildPython(it) }
        pip {
            install("requests")
            install("pycryptodome")
            install("beautifulsoup4")
            install("lxml")
            install("pyquery")
        }
    }
}

// 安卓包名走单独入口，不复用 PACKAGE_NAME：后者同时决定 Windows / iOS / macOS 的
// bundle id 与 Windows 的 userdata 目录，改它会把老用户的本地数据“搬走”。
// 需要换包名时设 ANDROID_PACKAGE_NAME，或直接改下面的默认值。
val appPackageName = System.getenv("ANDROID_PACKAGE_NAME")?.trim()?.takeIf { it.isNotEmpty() }
    ?: "com.guoguo.app"

val releaseKey = rootProject.file("key.properties")
val releaseProperties = Properties()
if (releaseKey.exists()) {
    releaseKey.inputStream().use { releaseProperties.load(it) }
} else {
    mapOf(
        "storeFile" to "ANDROID_KEYSTORE_PATH",
        "storePassword" to "ANDROID_KEYSTORE_PASSWORD",
        "keyAlias" to "ANDROID_KEY_ALIAS",
        "keyPassword" to "ANDROID_KEY_PASSWORD",
    ).forEach { (key, name) -> System.getenv(name)?.let { releaseProperties[key] = it } }
}
val hasReleaseKey = releaseProperties.getProperty("storeFile") != null

android {
    namespace = "com.guoapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = appPackageName
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "小果影视"
        manifestPlaceholders["appBanner"] = "@drawable/tv_banner"
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                val rawStore = requireNotNull(releaseProperties.getProperty("storeFile"))
                storeFile = if (file(rawStore).exists()) file(rawStore) else rootProject.file(rawStore)
                storePassword = requireNotNull(releaseProperties.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseProperties.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseProperties.getProperty("keyPassword"))
            }
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
        }
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
            // TVBox 的 spider jar 运行时靠 DexClassLoader 继承
            // com.github.catvod.crawler.Spider，不 keep 会在真机上报
            // "Class not found using the boot class loader"。
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        getByName("profile") {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // TVBox spider jar 通过 DexClassLoader 在运行时链接这些库（R8 看不到引用，
    // 所以 proguard-rules.pro 里同时 keep），缺失会报 NoClassDefFoundError。
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.jsoup:jsoup:1.17.2")
}

flutter { source = "../.." }

tasks.withType<JavaCompile>().configureEach {
    if (name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val generated = registrant.readText()
                val integrationPlugin = Regex(
                    """(?s)    try \{\s*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s*\} catch \(Exception e\) \{[^}]*\}\s*"""
                )
                val release = generated.replace(integrationPlugin, "")
                if (release != generated) registrant.writeText(release)
            }
        }
    }
}
