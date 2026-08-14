plugins {
    id("vox.android.library")
    id("vox.android.test")
}

android {
    namespace = "md.vox.android.data"
}

dependencies {
    implementation(project(":capture-domain"))
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    implementation(libs.datastore.preferences)
    implementation(libs.work.runtime.ktx)
}
