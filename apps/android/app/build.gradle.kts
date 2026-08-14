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
    dependsOn("processDebugManifest")
    val mergedManifest = layout.buildDirectory.file(
        "intermediates/merged_manifests/debug/processDebugManifest/AndroidManifest.xml",
    )
    inputs.file(mergedManifest)
    inputs.files(
        "src/main/res/xml/backup_rules.xml",
        "src/main/res/xml/data_extraction_rules.xml",
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
    )
}

tasks.named("check") {
    dependsOn(validateDebugArtifacts)
}
