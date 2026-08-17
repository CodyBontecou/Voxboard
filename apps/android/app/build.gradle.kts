plugins {
    id("vox.android.application")
    id("vox.android.compose")
    id("vox.android.test")
}

android {
    namespace = "md.vox.android"

    defaultConfig {
        applicationId = "md.vox.android"
        versionCode = 1
        versionName = "0.1.0-foundation"
    }
    packaging.jniLibs.excludes += setOf(
        "**/armeabi/libjnidispatch.so",
        "**/mips/libjnidispatch.so",
        "**/mips64/libjnidispatch.so",
    )
}

dependencies {
    implementation(project(":capture-domain"))
    implementation(project(":data"))
    implementation(project(":platform-services"))

    implementation(platform(libs.compose.bom))
    implementation(libs.core.ktx)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.navigation.compose)
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)

    debugImplementation(libs.compose.ui.tooling)
}

val validateDebugArtifacts by tasks.registering(Exec::class) {
    group = "verification"
    description = "Validates the merged debug manifest and backup exclusion artifacts."
    dependsOn("processDebugManifest", "assembleDebug")
    val mergedManifest = layout.buildDirectory.file(
        "intermediates/merged_manifests/debug/processDebugManifest/AndroidManifest.xml",
    )
    inputs.file(mergedManifest)
    val debugApk = layout.buildDirectory.file("outputs/apk/debug/app-debug.apk")
    inputs.files(
        "src/main/res/xml/backup_rules.xml",
        "src/main/res/xml/data_extraction_rules.xml",
        debugApk,
    )
    commandLine(
        "python3",
        rootProject.file("scripts/validate-debug-artifacts.py"),
        "--manifest",
        mergedManifest.get().asFile,
        "--backup-rules",
        file("src/main/res/xml/backup_rules.xml"),
        "--data-extraction-rules",
        file("src/main/res/xml/data_extraction_rules.xml"),
        "--apk",
        debugApk.get().asFile,
    )
}

tasks.named("check") {
    dependsOn(validateDebugArtifacts)
}
