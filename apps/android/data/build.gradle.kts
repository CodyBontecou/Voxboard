plugins {
    id("vox.android.library")
    id("vox.android.test")
}

android {
    namespace = "md.vox.android.data"
}

dependencies {
    implementation(project(":capture-domain"))
    compileOnly(libs.room.runtime)
    compileOnly(libs.room.ktx)
    compileOnly(libs.datastore.preferences)
    compileOnly(libs.work.runtime.ktx)
}
