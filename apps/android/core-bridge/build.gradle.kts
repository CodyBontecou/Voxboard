plugins {
    id("vox.android.library")
    id("vox.android.test")
}

val repositoryRoot = rootProject.projectDir.parentFile.parentFile
val generatedKotlin = repositoryRoot.resolve("Packages/vox-core-rust/generated/kotlin")
val nativeBuildScript = repositoryRoot.resolve("Packages/vox-core-rust/scripts/build-android-cdylibs.sh")
val nativeWorkspace = repositoryRoot.resolve("Packages/vox-core-rust")

android {
    namespace = "md.vox.android.corebridge"

    sourceSets.getByName("main").kotlin.directories.add(generatedKotlin.absolutePath)
    sourceSets.getByName("debug").jniLibs.srcDir(layout.buildDirectory.dir("generated/vox-native/debug/jniLibs").get().asFile)
    sourceSets.getByName("release").jniLibs.srcDir(layout.buildDirectory.dir("generated/vox-native/release/jniLibs").get().asFile)
    packaging.jniLibs.excludes += setOf(
        "**/armeabi/libjnidispatch.so",
        "**/mips/libjnidispatch.so",
        "**/mips64/libjnidispatch.so",
    )
    sourceSets.getByName("androidTest").assets.srcDirs(
        repositoryRoot.resolve("Packages/contracts/fixtures/core-api"),
        repositoryRoot.resolve("Packages/contracts/fixtures/capture-preparation-input"),
    )
}

val sourceRevision = providers.exec {
    commandLine("git", "-C", repositoryRoot, "rev-parse", "HEAD")
}.standardOutput.asText.map { it.trim() }

fun registerNativeBuild(name: String, profile: String) = tasks.register<Exec>(name) {
    group = "build"
    description = "Source-builds the governed four-ABI Vox core ($profile)."
    val output = layout.buildDirectory.dir("generated/vox-native/$profile/jniLibs")
    inputs.file(nativeBuildScript)
    inputs.files(
        fileTree(nativeWorkspace) {
            include(
                "Cargo.toml",
                "Cargo.lock",
                "rust-toolchain.toml",
                ".cargo/**/*",
                "uniffi*.toml",
                "crates/**/*.rs",
                "crates/**/Cargo.toml",
            )
        },
    )
    inputs.property("sourceRevision", sourceRevision)
    outputs.dir(output)
    environment("VOX_CORE_SOURCE_REVISION", sourceRevision.get())
    commandLine(nativeBuildScript, profile, output.get().asFile)
}

val buildVoxDebugNative = registerNativeBuild("buildVoxDebugNative", "debug")
val buildVoxReleaseNative = registerNativeBuild("buildVoxReleaseNative", "release")
tasks.configureEach {
    when (name) {
        "mergeDebugJniLibFolders" -> dependsOn(buildVoxDebugNative)
        "mergeReleaseJniLibFolders" -> dependsOn(buildVoxReleaseNative)
    }
}

dependencies {
    implementation(variantOf(libs.jna) { artifactType("aar") })
    implementation(libs.androidx.annotation)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
}
