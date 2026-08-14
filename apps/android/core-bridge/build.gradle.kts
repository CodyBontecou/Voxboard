plugins {
    id("vox.android.library")
    id("vox.android.test")
}

android {
    namespace = "md.vox.android.corebridge"
}

dependencies {
    implementation(libs.jna)
}
