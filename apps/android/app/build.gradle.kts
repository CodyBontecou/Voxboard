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
