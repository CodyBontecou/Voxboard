plugins {
    `kotlin-dsl`
}

group = "md.vox.android.buildlogic"

dependencyLocking {
    lockAllConfigurations()
}

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(17)
    }
}

dependencies {
    compileOnly("com.android.tools.build:gradle:9.1.0")
}

gradlePlugin {
    plugins {
        register("androidApplication") {
            id = "vox.android.application"
            implementationClass = "AndroidApplicationConventionPlugin"
        }
        register("androidLibrary") {
            id = "vox.android.library"
            implementationClass = "AndroidLibraryConventionPlugin"
        }
        register("androidCompose") {
            id = "vox.android.compose"
            implementationClass = "AndroidComposeConventionPlugin"
        }
        register("androidTest") {
            id = "vox.android.test"
            implementationClass = "AndroidTestConventionPlugin"
        }
    }
}
