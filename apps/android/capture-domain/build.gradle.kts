plugins {
    id("vox.android.library")
    id("vox.android.test")
}

android {
    namespace = "md.vox.android.capturedomain"
}

dependencies {
    api(project(":core-bridge"))
}
