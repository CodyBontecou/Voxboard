import com.android.build.api.dsl.ApplicationExtension
import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.tasks.testing.Test
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.gradle.kotlin.dsl.withType

class AndroidTestConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) = with(target) {
        pluginManager.withPlugin("com.android.application") {
            extensions.configure<ApplicationExtension> {
                testOptions.unitTests.isIncludeAndroidResources = false
            }
        }
        pluginManager.withPlugin("com.android.library") {
            extensions.configure<LibraryExtension> {
                testOptions.unitTests.isIncludeAndroidResources = false
            }
        }
        dependencies {
            add("testImplementation", "junit:junit:4.13.2")
        }
        tasks.withType<Test>().configureEach {
            useJUnit()
        }
    }
}
