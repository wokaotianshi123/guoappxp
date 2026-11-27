allprojects {
    repositories {
        // 与 settings.gradle.kts 同一套顺序：官方仓库兜底，镜像排在前面先试。
        // 这里覆盖的是各 Flutter 插件（video_player、media_kit、flutter_js …）
        // 自己声明的依赖，量比插件本身大得多，是最容易被限流打中的一段。
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2/") {
            name = "CentralMirror"
        }
        maven("https://maven.aliyun.com/repository/public") { name = "AliyunPublic" }
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
