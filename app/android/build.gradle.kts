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
// `flutter_pcm_sound` pins `compileSdkVersion 33`, but the androidx libraries it
// pulls in (fragment 1.7.1, window 1.2.0) refuse to be consumed by anything
// compiled below 34, which fails the AAR metadata check for the whole build.
// Raise any plugin that lags onto the app's own level rather than dragging the
// app down to the oldest plugin's — a library's compileSdk is independent of the
// app's, and 36 is what Flutter already builds `:app` against.
//
// `evaluationDependsOn(":app")` below evaluates projects eagerly, so some are
// already past the point where `afterEvaluate` can be registered by the time
// this runs. Configure those directly instead of failing.
subprojects {
    fun raiseCompileSdk() {
        val android =
            extensions.findByType(com.android.build.gradle.BaseExtension::class.java) ?: return
        val current = android.compileSdkVersion?.substringAfter("android-")?.toIntOrNull() ?: 0
        if (current in 1 until 36) {
            android.compileSdkVersion(36)
        }
    }
    if (state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
