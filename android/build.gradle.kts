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

subprojects {
    afterEvaluate {
        // flutter_js 0.8.7 在它自己的 build.gradle 里把 Kotlin jvmTarget 写死成 1.8，
        // 而它的 Java 编译任务是 11，AGP/KGP 的 JVM target 一致性校验会让
        // :flutter_js:compileReleaseKotlin 失败。等它配置完成后把 Kotlin target
        // 覆盖成与 Java 一致的 11；app 模块自己用的是 17，不受影响。
        if (name == "flutter_js") {
            tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java)
                .configureEach {
                    compilerOptions.jvmTarget.set(
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11,
                    )
                }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
