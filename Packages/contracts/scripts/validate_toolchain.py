#!/usr/bin/env python3
"""Stdlib-only strict M2 native and M3 Android application toolchain validator."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import xml.etree.ElementTree as ET

DEFAULT_ROOT = Path(__file__).resolve().parents[3]
EXPECTED_SCHEMA_CANONICAL_SHA256 = "4a6a94f75f173e23538d7e97f48cdc0349f280e45293712f9cf8908c835021ea"
EXPECTED_GOVERNED_PATHS = (
    "Packages/vox-core-rust/Cargo.lock",
    "Packages/vox-core-rust/uniffi.toml",
    "Packages/vox-core-rust/uniffi-bindgen.toml",
    "Packages/vox-core-rust/crates/vox-core-uniffi/uniffi.toml",
    "Packages/vox-core-rust/scripts/generate-swift-bindings.sh",
    "Packages/vox-core-rust/scripts/generate-kotlin-bindings.sh",
    "Packages/vox-core-rust/scripts/normalize-kotlin-bindings.py",
    "Packages/vox-core-rust/generated/kotlin/md/vox/core/vox_core_uniffi.kt",
    "Packages/vox-core-rust/scripts/check-bindings.sh",
    "Packages/vox-core-rust/scripts/build-android-cdylibs.sh",
    "Packages/vox-core-rust/scripts/build-apple-xcframework.sh",
    "Packages/vox-core-rust/scripts/merge-apple-staticlib.sh",
    "Packages/vox-core-rust/scripts/normalize-apple-xcframework.py",
    "Packages/vox-core-rust/scripts/inspect-native-packages.py",
    "Packages/vox-core-rust/scripts/normalize-generated-text.py",
    "Packages/vox-core-rust/crates/vox-core/tests/m2_core.rs",
    "Packages/VoxboardShared/Sources/VoxCoreGenerated/VoxCore.swift",
    "Packages/VoxboardShared/Sources/VoxCoreFFI/module.modulemap",
    ".github/workflows/android-ci.yml",
    ".github/workflows/contracts-ci.yml",
    "apps/android/build.gradle.kts",
    "apps/android/settings.gradle.kts",
    "apps/android/gradle/libs.versions.toml",
    "apps/android/gradle.properties",
    "apps/android/gradle/wrapper/gradle-wrapper.properties",
    "apps/android/gradle/wrapper/gradle-wrapper.jar",
    "apps/android/gradlew",
    "apps/android/gradlew.bat",
    "apps/android/build-logic/build.gradle.kts",
    "apps/android/build-logic/settings.gradle.kts",
    "apps/android/build-logic/src/main/kotlin/AndroidApplicationConventionPlugin.kt",
    "apps/android/build-logic/src/main/kotlin/AndroidLibraryConventionPlugin.kt",
    "apps/android/build-logic/src/main/kotlin/AndroidComposeConventionPlugin.kt",
    "apps/android/build-logic/src/main/kotlin/AndroidTestConventionPlugin.kt",
    "apps/android/build-logic/gradle.lockfile",
    "apps/android/app/build.gradle.kts",
    "apps/android/app/gradle.lockfile",
    "apps/android/app/src/main/kotlin/md/vox/android/VoxApplication.kt",
    "apps/android/scripts/validate-debug-artifacts.py",
    "apps/android/core-bridge/build.gradle.kts",
    "apps/android/core-bridge/gradle.lockfile",
    "apps/android/core-bridge/src/main/kotlin/md/vox/android/corebridge/CoreBridge.kt",
    "apps/android/core-bridge/src/main/kotlin/md/vox/android/corebridge/GeneratedNativeCoreAdapter.kt",
    "apps/android/core-bridge/src/test/kotlin/md/vox/android/corebridge/CoreBridgeTest.kt",
    "apps/android/core-bridge/src/androidTest/kotlin/md/vox/android/corebridge/GeneratedCoreBridgeInstrumentationTest.kt",
    "apps/android/capture-domain/build.gradle.kts",
    "apps/android/capture-domain/gradle.lockfile",
    "apps/android/data/build.gradle.kts",
    "apps/android/data/gradle.lockfile",
    "apps/android/capture-domain/src/main/kotlin/md/vox/android/capturedomain/DurableCapture.kt",
    "apps/android/capture-domain/src/main/kotlin/md/vox/android/capturedomain/CaptureDurability.kt",
    "apps/android/capture-domain/src/test/kotlin/md/vox/android/capturedomain/CaptureJournalReducerTest.kt",
    "apps/android/capture-domain/src/test/kotlin/md/vox/android/capturedomain/CaptureDurabilityPlannerTest.kt",
    "apps/android/data/src/main/kotlin/md/vox/android/data/CapturePackageCodec.kt",
    "apps/android/data/src/main/kotlin/md/vox/android/data/DurableCaptureStore.kt",
    "apps/android/data/src/main/java/md/vox/android/data/CaptureProjectionEntity.java",
    "apps/android/data/src/main/java/md/vox/android/data/CaptureProjectionDao.java",
    "apps/android/data/src/main/java/md/vox/android/data/CaptureDatabase.java",
    "apps/android/data/src/main/java/md/vox/android/data/CaptureLeaseEntity.java",
    "apps/android/data/src/main/java/md/vox/android/data/LeaseClockEntity.java",
    "apps/android/data/src/main/java/md/vox/android/data/InstallationIdentityEntity.java",
    "apps/android/data/src/main/java/md/vox/android/data/QuotaReservationEntity.java",
    "apps/android/data/src/main/java/md/vox/android/data/CaptureTombstoneEntity.java",
    "apps/android/data/src/main/java/md/vox/android/data/CaptureCoordinationDao.java",
    "apps/android/data/src/main/kotlin/md/vox/android/data/RoomCaptureIndex.kt",
    "apps/android/data/src/main/kotlin/md/vox/android/data/RoomCaptureCoordination.kt",
    "apps/android/data/src/main/kotlin/md/vox/android/data/RoomQuotaLedger.kt",
    "apps/android/data/src/main/kotlin/md/vox/android/data/CaptureDurabilityCoordinator.kt",
    "apps/android/data/src/test/kotlin/md/vox/android/data/CapturePackageFixtureConsumerTest.kt",
    "apps/android/data/src/test/kotlin/md/vox/android/data/DurableCapturePackageStoreTest.kt",
    "apps/android/data/src/androidTest/kotlin/md/vox/android/data/CaptureDatabaseInstrumentationTest.kt",
    "apps/android/data/schemas/md.vox.android.data.CaptureDatabase/1.json",
    "apps/android/data/schemas/md.vox.android.data.CaptureDatabase/2.json",
    "docs/architecture/adr-0021-android-journal-replacement-lease-quota-room-v2.md",
    "docs/architecture/adr-0022-android-lazy-uniffi-native-packaging.md",
    "apps/android/platform-services/build.gradle.kts",
    "apps/android/platform-services/gradle.lockfile",
    "apps/android/gradle/verification-metadata.xml",
    "apps/android/settings-gradle.lockfile",
)


def fail(message):
    raise SystemExit("Toolchain validation failed: " + message)


def load(path):
    try:
        return json.loads(path.read_text())
    except Exception as error:
        fail(f"{path}: {error}")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def exact(value, keys, label):
    if set(value) != set(keys):
        fail(f"{label} fields differ")


def version_catalog(text):
    section = None
    versions = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section == "versions":
            match = re.fullmatch(r'([a-z0-9-]+)\s*=\s*"([^"]+)"', line)
            if not match:
                fail("version catalog contains non-canonical version declaration")
            versions[match.group(1)] = match.group(2)
    return versions


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    arguments = parser.parse_args(argv)
    root = (arguments.root or DEFAULT_ROOT).resolve()
    manifest = load(root / "toolchains/android-wear-shared-core.json")
    schema = load(root / "toolchains/android-wear-shared-core.schema.json")
    schema_canonical = json.dumps(
        schema, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    if hashlib.sha256(schema_canonical).hexdigest() != EXPECTED_SCHEMA_CANONICAL_SHA256:
        fail("toolchain schema canonical hash drift")
    exact(
        manifest,
        [
            "$schema", "schemaVersion", "status", "rust", "uniffi",
            "androidNative", "androidApplication", "apple",
            "bindingGeneration", "governedImplementationFiles",
        ],
        "manifest",
    )
    if (manifest["$schema"], manifest["schemaVersion"], manifest["status"]) != (
        "android-wear-shared-core.schema.json", 2,
        "m3-android-application-toolchain-pinned",
    ):
        fail("manifest identity/status")
    if schema.get("properties", {}).get("schemaVersion", {}).get("const") != 2:
        fail("schema identity/version")

    expected_rust = {
        "toolchain": "1.97.1", "msrv": "1.87.0", "edition": "2024",
        "cargoResolver": "3", "profile": "minimal",
        "components": ["clippy", "rustfmt"],
        "targets": [
            "aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios",
            "aarch64-linux-android", "armv7-linux-androideabi",
            "x86_64-linux-android", "i686-linux-android",
        ],
        "rustToolchainPath": "Packages/vox-core-rust/rust-toolchain.toml",
    }
    if manifest["rust"] != expected_rust:
        fail("Rust pins differ")
    if manifest["uniffi"] != {
        "bindgenVersion": "0.32.0", "cliVersion": "0.32.0",
        "libraryVersion": "0.32.0",
    }:
        fail("UniFFI pins differ")
    targets = [
        {"abi": "arm64-v8a", "apiLevel": 28, "rustTarget": "aarch64-linux-android"},
        {"abi": "armeabi-v7a", "apiLevel": 28, "rustTarget": "armv7-linux-androideabi"},
        {"abi": "x86_64", "apiLevel": 28, "rustTarget": "x86_64-linux-android"},
        {"abi": "x86", "apiLevel": 28, "rustTarget": "i686-linux-android"},
    ]
    if manifest["androidNative"] != {
        "cargoNdkVersion": "4.1.2", "ndkRevision": "27.1.12297006",
        "targets": targets,
    }:
        fail("Android native pins differ")

    expected_android = {
        "namespace": "md.vox.android",
        "applicationID": "md.vox.android",
        "jdk": {
            "distribution": "temurin", "version": "17.0.20+8",
            "languageLevel": 17, "jvmTarget": "17",
        },
        "gradle": {
            "version": "9.3.1",
            "distributionURL": "https://services.gradle.org/distributions/gradle-9.3.1-bin.zip",
            "distributionSha256": "b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06",
            "wrapperJarPath": "apps/android/gradle/wrapper/gradle-wrapper.jar",
            "wrapperJarSha256": "b3a875ddc1f044746e1b1a55f645584505f4a10438c1afea9f15e92a7c42ec13",
        },
        "androidGradlePluginVersion": "9.1.1",
        "kotlin": {
            "version": "2.4.10", "builtIn": True,
            "composeCompilerPluginVersion": "2.4.10",
            "annotationProcessingPlugin": "com.android.legacy-kapt",
            "annotationProcessingPluginVersion": "9.1.1",
        },
        "sdk": {
            "compileSdk": 37, "buildToolsVersion": "36.0.0",
            "phoneMinSdk": 28, "phoneTargetSdk": 36,
            "wearMinSdk": 30, "wearTargetSdk": 35,
        },
        "androidCommandLineTools": {
            "archiveVersion": "15859902",
            "toolsVersion": "22.0",
            "linuxURL": "https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip",
            "linuxSha256": "4e4c464f145a7512b57d088ac6c278c03c9eea610886b35a5e0804e74eedf583",
        },
        "compose": {"bomVersion": "2026.08.00"},
        "dependencies": {
            "activityCompose": "1.13.0", "androidxAnnotation": "1.7.0",
            "androidxHilt": "1.4.0",
            "androidxTest": "1.7.0", "androidxTestExtJunit": "1.3.0",
            "composeBom": "2026.08.00", "coreKtx": "1.19.0",
            "coroutines": "1.11.0", "dataStore": "1.2.1",
            "daggerHilt": "2.60.1", "espresso": "3.7.0", "jna": "5.17.0",
            "junit4": "4.13.2", "lifecycle": "2.11.0",
            "navigationCompose": "2.9.8", "room": "2.8.4",
            "serialization": "1.11.0", "workManager": "2.11.2",
        },
        "configurationPaths": {
            "rootBuild": "apps/android/build.gradle.kts",
            "settings": "apps/android/settings.gradle.kts",
            "versionCatalog": "apps/android/gradle/libs.versions.toml",
            "gradleProperties": "apps/android/gradle.properties",
            "wrapperProperties": "apps/android/gradle/wrapper/gradle-wrapper.properties",
            "wrapperScript": "apps/android/gradlew",
            "wrapperBatchScript": "apps/android/gradlew.bat",
            "androidCI": ".github/workflows/android-ci.yml",
            "buildLogicBuild": "apps/android/build-logic/build.gradle.kts",
            "buildLogicSettings": "apps/android/build-logic/settings.gradle.kts",
            "artifactValidator": "apps/android/scripts/validate-debug-artifacts.py",
            "moduleBuilds": [
                "apps/android/app/build.gradle.kts",
                "apps/android/core-bridge/build.gradle.kts",
                "apps/android/capture-domain/build.gradle.kts",
                "apps/android/data/build.gradle.kts",
                "apps/android/platform-services/build.gradle.kts",
            ],
        },
        "dependencyMetadataPaths": {
            "verificationMetadata": "apps/android/gradle/verification-metadata.xml",
            "settingsLock": "apps/android/settings-gradle.lockfile",
            "buildLogicLock": "apps/android/build-logic/gradle.lockfile",
            "moduleLocks": [
                "apps/android/app/gradle.lockfile",
                "apps/android/core-bridge/gradle.lockfile",
                "apps/android/capture-domain/gradle.lockfile",
                "apps/android/data/gradle.lockfile",
                "apps/android/platform-services/gradle.lockfile",
            ],
        },
    }
    if manifest["androidApplication"] != expected_android:
        fail("Android application pins differ")

    if manifest["apple"] != {
        "deploymentTarget": "17.6", "packagingTool": "xcodebuild -create-xcframework",
        "swiftVersion": "6.3.3",
        "targets": ["aarch64-apple-ios", "aarch64-apple-ios-sim", "x86_64-apple-ios"],
        "xcodeBuild": "17F113", "xcodeVersion": "26.6",
    }:
        fail("Apple pins differ")
    binding = manifest["bindingGeneration"]
    exact(
        binding,
        [
            "swiftConfigPath", "kotlinConfigPath", "swiftScriptPath",
            "kotlinScriptPath", "swiftOutputPaths", "kotlinOutputPaths", "hashStatus",
        ],
        "bindingGeneration",
    )
    if binding["hashStatus"] != "governed-implemented":
        fail("binding hash status")
    expected_swift = [
        "Packages/vox-core-rust/generated/swift/VoxCore.swift",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap",
    ]
    expected_kotlin = [
        "Packages/vox-core-rust/generated/kotlin/md/vox/core/vox_core_uniffi.kt",
    ]
    if binding["swiftOutputPaths"] != expected_swift or binding["kotlinOutputPaths"] != expected_kotlin:
        fail("generated output inventory")

    governed = manifest["governedImplementationFiles"]
    governed_paths = [item.get("path") for item in governed]
    if governed_paths != list(EXPECTED_GOVERNED_PATHS):
        fail("governed implementation path inventory differs")
    for item in governed:
        exact(item, ["path", "sha256"], "governed file")
        path = root / item["path"]
        if not path.is_file():
            fail(f"governed file missing: {item['path']}")
        if digest(path) != item["sha256"]:
            fail(f"governed file hash drift: {item['path']}")
    for path in expected_swift + expected_kotlin:
        if not (root / path).is_file():
            fail(f"generated binding missing: {path}")

    for config_path in (
        "Packages/vox-core-rust/uniffi.toml",
        "Packages/vox-core-rust/uniffi-bindgen.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/uniffi.toml",
    ):
        config = (root / config_path).read_text()
        if "[bindings.kotlin]" not in config or "android_cleaner = true" not in config:
            fail(f"Android-safe UniFFI cleaner configuration drift: {config_path}")
    kotlin_binding = (root / "Packages/vox-core-rust/generated/kotlin/md/vox/core/vox_core_uniffi.kt").read_text()
    for declaration in (
        "internal open class CoreMaterializationSession",
        "internal data class CoreBuildInfo",
        "internal sealed class VoxCoreException",
        "internal fun `corePrepare`",
    ):
        if declaration not in kotlin_binding:
            fail(f"generated Kotlin module-internal surface drift: {declaration}")
    kotlin_declaration = (
        r"(?:(?:open|abstract|data|enum|sealed|value|annotation|inline|const|lateinit|suspend)\s+)*"
        r"(?:class|interface|object|fun|typealias|val|var)"
    )
    if re.search(rf"(?m)^(?:public\s+)?{kotlin_declaration}\b", kotlin_binding) or re.search(
        r"(?m)^\s+(?:@Throws\([^\n)]+::class\) )?(?:public )?fun `core[A-Za-z0-9]+`",
        kotlin_binding,
    ):
        fail("generated Kotlin exposes a public top-level declaration")

    cargo = (root / "Packages/vox-core-rust/Cargo.toml").read_text()
    lock = (root / "Packages/vox-core-rust/Cargo.lock").read_text()
    rust_toolchain = (root / expected_rust["rustToolchainPath"]).read_text()
    for needle in [
        'channel = "1.97.1"', 'profile = "minimal"',
        'components = ["clippy", "rustfmt"]',
    ]:
        if needle not in rust_toolchain:
            fail(f"rust-toolchain drift: {needle}")
    for needle in [
        'resolver = "3"', 'edition = "2024"', 'rust-version = "1.87.0"',
        'version = "=0.32.0"',
    ]:
        if needle not in cargo:
            fail(f"Cargo drift: {needle}")
    if 'name = "uniffi_bindgen"\nversion = "0.32.0"' not in lock:
        fail("UniFFI bindgen 0.32.0 absent from lock")

    android = expected_android["configurationPaths"]
    wrapper = (root / android["wrapperProperties"]).read_text()
    expected_wrapper = (
        "distributionBase=GRADLE_USER_HOME\n"
        "distributionPath=wrapper/dists\n"
        "distributionSha256Sum=b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06\n"
        "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.3.1-bin.zip\n"
        "networkTimeout=10000\n"
        "validateDistributionUrl=true\n"
        "zipStoreBase=GRADLE_USER_HOME\n"
        "zipStorePath=wrapper/dists\n"
    )
    if wrapper != expected_wrapper:
        fail("Gradle wrapper properties drift")
    wrapper_jar = root / expected_android["gradle"]["wrapperJarPath"]
    if digest(wrapper_jar) != expected_android["gradle"]["wrapperJarSha256"]:
        fail("Gradle wrapper JAR drift")
    if not os.access(root / android["wrapperScript"], os.X_OK):
        fail("Gradle wrapper script is not executable")

    catalog_text = (root / android["versionCatalog"]).read_text()
    expected_versions = {
        "agp": "9.1.1", "kotlin": "2.4.10", "compose-bom": "2026.08.00",
        "core": "1.19.0", "activity": "1.13.0", "lifecycle": "2.11.0",
        "navigation": "2.9.8", "room": "2.8.4", "datastore": "1.2.1",
        "work": "2.11.2", "hilt": "2.60.1", "androidx-hilt": "1.4.0",
        "coroutines": "1.11.0", "serialization": "1.11.0", "jna": "5.17.0",
        "androidx-annotation": "1.7.0", "androidx-test": "1.7.0", "androidx-test-ext-junit": "1.3.0",
        "espresso": "3.7.0", "junit4": "4.13.2",
    }
    if version_catalog(catalog_text) != expected_versions:
        fail("Android version catalog pins differ")
    forbidden = ("org.jetbrains.kotlin.android", "com.google.devtools.ksp", "+", "latest")
    lower_catalog = catalog_text.lower()
    if any(value.lower() in lower_catalog for value in forbidden):
        fail("Android version catalog contains forbidden floating or incompatible tooling")
    root_build = (root / android["rootBuild"]).read_text()
    for alias in (
        "android.application", "android.library", "android.legacy.kapt",
        "kotlin.compose", "kotlin.serialization", "hilt",
    ):
        if f"alias(libs.plugins.{alias}) apply false" not in root_build:
            fail(f"Android root plugin alias missing: {alias}")
    settings = (root / android["settings"]).read_text()
    if "RepositoriesMode.FAIL_ON_PROJECT_REPOS" not in settings:
        fail("Android repository policy drift")
    expected_modules = {
        'include(":app")', 'include(":core-bridge")',
        'include(":capture-domain")', 'include(":data")',
        'include(":platform-services")',
    }
    if not expected_modules.issubset(set(settings.splitlines())) or 'include(":wear")' in settings:
        fail("Android Phase 1 module inventory drift")
    if 'includeBuild("build-logic")' not in settings or "lockAllConfigurations()" not in root_build:
        fail("Android build logic or dependency locking drift")
    gradle_properties = (root / android["gradleProperties"]).read_text()
    if "android.suppressUnsupportedCompileSdk" in gradle_properties:
        fail("Android compile SDK compatibility warning is suppressed")

    build_logic = (root / android["buildLogicBuild"]).read_text()
    for needle in (
        'compileOnly("com.android.tools.build:gradle:9.1.1")',
        'id = "vox.android.application"', 'id = "vox.android.library"',
        'id = "vox.android.compose"', 'id = "vox.android.test"',
        "lockAllConfigurations()",
    ):
        if needle not in build_logic:
            fail(f"Android build logic drift: {needle}")
    convention_tokens = {
        "AndroidApplicationConventionPlugin.kt": (
            'pluginManager.apply("com.android.application")', "compileSdk = 37",
            'buildToolsVersion = "36.0.0"', "minSdk = 28", "targetSdk = 36",
        ),
        "AndroidLibraryConventionPlugin.kt": (
            'pluginManager.apply("com.android.library")', "compileSdk = 37",
            'buildToolsVersion = "36.0.0"', "minSdk = 28",
        ),
        "AndroidComposeConventionPlugin.kt": (
            'pluginManager.apply("org.jetbrains.kotlin.plugin.compose")',
            "buildFeatures.compose = true",
        ),
        "AndroidTestConventionPlugin.kt": (
            'add("testImplementation", "junit:junit:4.13.2")', "useJUnit()",
        ),
    }
    convention_root = root / "apps/android/build-logic/src/main/kotlin"
    for name, tokens in convention_tokens.items():
        text = (convention_root / name).read_text()
        if any(token not in text for token in tokens):
            fail(f"Android convention plugin drift: {name}")

    module_builds = {Path(path).parent.name: (root / path).read_text() for path in android["moduleBuilds"]}
    expected_graph = {
        "app": {"capture-domain", "data", "platform-services"},
        "capture-domain": {"core-bridge"},
        "data": {"capture-domain"},
        "platform-services": {"capture-domain"},
        "core-bridge": set(),
    }
    actual_graph = {}
    project_pattern = re.compile(r'project\s*\(\s*(?:path\s*=\s*)?"(:[a-z0-9-]+)"\s*\)')
    for module, text in module_builds.items():
        matches = project_pattern.findall(text)
        if len(matches) != len(re.findall(r"\bproject\s*\(", text)):
            fail(f"Android module graph has an unparsed project dependency: {module}")
        if len(matches) != len(set(matches)):
            fail(f"Android module graph has a duplicate project dependency: {module}")
        actual_graph[module] = {path.removeprefix(":") for path in matches}
    if actual_graph != expected_graph:
        fail(f"Android module graph differs: {actual_graph}")
    visiting = set()
    visited = set()
    def visit(module):
        if module in visiting:
            fail(f"Android module graph contains a cycle at {module}")
        if module in visited:
            return
        visiting.add(module)
        for dependency in actual_graph[module]:
            if dependency not in actual_graph:
                fail(f"Android module graph references unknown module: {dependency}")
            visit(dependency)
        visiting.remove(module)
        visited.add(module)
    for module in actual_graph:
        visit(module)
    app_build = module_builds["app"]
    for token in ("validateDebugArtifacts", 'dependsOn("processDebugManifest", "assembleDebug")', '"--apk"', 'tasks.named("check")'):
        if token not in app_build:
            fail(f"Android artifact validation task wiring drift: {token}")
    data_build = module_builds["data"]
    for dependency in ("libs.room.runtime", "libs.room.ktx"):
        if f"implementation({dependency})" not in data_build or f"compileOnly({dependency})" in data_build:
            fail(f"Android M3 Room runtime activation drift: {dependency}")
    for dependency in ("libs.datastore.preferences", "libs.work.runtime.ktx"):
        if f"compileOnly({dependency})" not in data_build:
            fail(f"Inactive Android framework must remain compileOnly: {dependency}")
    for token in ("libs.plugins.android.legacy.kapt", "kapt(libs.room.compiler)", "room.schemaLocation"):
        if token not in data_build:
            fail(f"Android Room compiler/schema governance drift: {token}")
    if any("org.jetbrains.kotlin.android" in text for text in module_builds.values()):
        fail("Android modules bypass AGP built-in Kotlin")
    domain_source = (root / "apps/android/capture-domain/src/main/kotlin/md/vox/android/capturedomain/DurableCapture.kt").read_text()
    if re.search(r"^import\s+(android|androidx)\.", domain_source, flags=re.MULTILINE):
        fail("capture-domain imports an Android framework type")
    store_source = (root / "apps/android/data/src/main/kotlin/md/vox/android/data/DurableCaptureStore.kt").read_text()
    for forbidden in ("renameTo(", ".writeText(", ".writeBytes(", "ContentResolver", "WorkManager", "DataStore"):
        if forbidden in store_source:
            fail(f"durable package store contains forbidden API/fallback: {forbidden}")
    for required in ("FileOutputStream", "stream.fd.sync()", "Os.fsync", "StandardCopyOption.ATOMIC_MOVE", "FileAlreadyExistsException"):
        if required not in store_source:
            fail(f"durable package store ordering primitive missing: {required}")
    database_source = "\n".join((root / path).read_text() for path in (
        "apps/android/data/src/main/java/md/vox/android/data/CaptureProjectionEntity.java",
        "apps/android/data/src/main/java/md/vox/android/data/CaptureProjectionDao.java",
        "apps/android/data/src/main/java/md/vox/android/data/CaptureDatabase.java",
        "apps/android/data/src/main/kotlin/md/vox/android/data/RoomCaptureIndex.kt",
    ))
    for forbidden in ("content", "url", "filename", "path", "uri", "document", "provider", "sha256"):
        if re.search(rf"(?:\bval\s+{forbidden}\w*\s*:|\b(?:String|long|int)\s+{forbidden}\w*\s*[;,)])", database_source, flags=re.IGNORECASE):
            fail(f"Room projection contains forbidden content/authority field: {forbidden}")
    for forbidden in ("fallbackToDestructiveMigration", "allowMainThreadQueries"):
        if forbidden in database_source:
            fail(f"Room database contains forbidden policy: {forbidden}")
    room_schema = load(root / "apps/android/data/schemas/md.vox.android.data.CaptureDatabase/1.json")
    entities = room_schema.get("database", {}).get("entities", [])
    expected_columns = ["requestID", "packageVersion", "journalVersion", "journalRevision", "state", "createdAtEpochMillis", "updatedAtEpochMillis"]
    if len(entities) != 1 or entities[0].get("tableName") != "capture_projection" or [field.get("columnName") for field in entities[0].get("fields", [])] != expected_columns:
        fail("Room content-free schema inventory drift")

    metadata = expected_android["dependencyMetadataPaths"]
    verification = (root / metadata["verificationMetadata"]).read_text()
    if "<verify-metadata>true</verify-metadata>" not in verification or "Generated by Gradle" not in verification:
        fail("Gradle dependency verification metadata drift")
    if 'name="gradle" version="9.1.1"' not in verification or re.search(r'version="9\.1\.0"', verification):
        fail("Gradle verification metadata has missing/stale AGP resolution")
    try:
        verification_root = ET.fromstring(verification)
    except ET.ParseError as error:
        fail(f"Gradle verification metadata XML is invalid: {error}")
    namespace = {"v": "https://schema.gradle.org/dependency-verification"}
    aapt_components = [
        component for component in verification_root.findall(".//v:component", namespace)
        if component.attrib == {
            "group": "com.android.tools.build",
            "name": "aapt2",
            "version": "9.1.1-14792394",
        }
    ]
    if len(aapt_components) != 1:
        fail("Gradle verification metadata has missing/duplicate pinned AAPT2 component")
    aapt_artifacts = {}
    for artifact in aapt_components[0].findall("v:artifact", namespace):
        checksums = artifact.findall("v:sha256", namespace)
        if len(checksums) != 1 or artifact.get("name") in aapt_artifacts:
            fail("Gradle verification metadata AAPT2 artifact checksum shape drift")
        aapt_artifacts[artifact.get("name")] = checksums[0].attrib
    expected_aapt = {
        "aapt2-9.1.1-14792394-osx.jar": {
            "value": "b58cb80ac24aa343d02316fa50a662e2710b2f9ea14fc7da6d08d9cd801cafa3",
            "origin": "Generated by Gradle",
        },
        "aapt2-9.1.1-14792394-linux.jar": {
            "value": "e7ae17af6e4093c771243e82d66462353de87befaac206bfb43e557ac1c34440",
            "origin": "Manually verified from pinned Google Maven URL",
        },
    }
    for artifact, expected_checksum in expected_aapt.items():
        if aapt_artifacts.get(artifact) != expected_checksum:
            fail(f"Gradle verification metadata AAPT2 artifact missing/drifted: {artifact}")
    linux_origin = "Downloaded from Maven Central and independently SHA-256 verified for Linux CI"
    expected_linux_metadata = (
        ("org.jetbrains.kotlinx", "kotlinx-coroutines-bom", "1.8.0", "kotlinx-coroutines-bom-1.8.0.pom", "1239e9dbe1397cd5971342956b2511bc3ace7b641842e4372a088dcfa8b9ad55"),
        ("com.google.guava", "guava-parent", "33.3.1-jre", "guava-parent-33.3.1-jre.pom", "55441db27e8869dfefe053059bdf478bdc7e95585642bf391f0023345fd56287"),
        ("org.junit", "junit-bom", "5.10.2", "junit-bom-5.10.2.module", "de23b114b3e4119a8fe6eb17bed5a3852816698bace67071579d6d927ebb080a"),
        ("org.junit", "junit-bom", "5.11.0-M2", "junit-bom-5.11.0-M2.module", "86477abcf490d6ca059aa9973cb108d22a506f49d1a5569bb32cc6cbf43c2cce"),
        ("org.junit", "junit-bom", "5.9.2", "junit-bom-5.9.2.module", "ab137ba5a8e32c9b066bf9126a1c76dd5614b724ba5c0b02549772b5e9f4cf1f"),
    )
    all_components = verification_root.findall(".//v:component", namespace)
    for group, name, version, artifact_name, checksum in expected_linux_metadata:
        components = [
            component for component in all_components
            if component.attrib == {"group": group, "name": name, "version": version}
        ]
        if len(components) != 1:
            fail(f"Gradle verification metadata lacks Linux-resolved component: {group}:{name}:{version}")
        artifacts = [
            artifact for artifact in components[0].findall("v:artifact", namespace)
            if artifact.attrib == {"name": artifact_name}
        ]
        if len(artifacts) != 1:
            fail(f"Gradle verification metadata lacks Linux-resolved artifact: {artifact_name}")
        checksums = artifacts[0].findall("v:sha256", namespace)
        if len(checksums) != 1 or checksums[0].attrib != {"value": checksum, "origin": linux_origin}:
            fail(f"Gradle verification metadata Linux-resolved checksum drift: {artifact_name}")
    for lock_path in [metadata["settingsLock"], metadata["buildLogicLock"], *metadata["moduleLocks"]]:
        lock = root / lock_path
        if not lock.is_file() or "empty=" not in lock.read_text():
            fail(f"Gradle dependency lock missing or malformed: {lock_path}")
        if re.search(r":9\.1\.0=", lock.read_text()):
            fail(f"Gradle dependency lock retains AGP 9.1.0: {lock_path}")
    if "com.android.tools.build:gradle:9.1.1=" not in (root / metadata["buildLogicLock"]).read_text():
        fail("Gradle build logic lock lacks AGP 9.1.1")

    workflow = (root / android["androidCI"]).read_text()
    command_line_tools = expected_android["androidCommandLineTools"]
    for needle in (
        "runs-on: ubuntu-24.04",
        "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd",
        "actions/setup-java@be666c2fcd27ec809703dec50e508c2fdc7f6654",
        "dtolnay/rust-toolchain@6c977a6ca4077a0ceb28ffbe03f59d46e9ac8772",
        "toolchain: 1.97.1",
        "targets: aarch64-linux-android,armv7-linux-androideabi,x86_64-linux-android,i686-linux-android",
        "cargo +1.97.1 install cargo-ndk --version 4.1.2 --locked",
        "java-version: '17.0.20+8'", "'platforms;android-37.0'",
        "'build-tools;36.0.0'", "'ndk;27.1.12297006'",
        command_line_tools["linuxURL"], command_line_tools["linuxSha256"],
        'cmdline-tools/22.0/bin/sdkmanager', "sha256sum --check --strict",
        "validate_toolchain.py", "test-project-contracts.sh",
        "'Packages/vox-core-rust/**'",
        "test lint assembleDebug assembleDebugAndroidTest :app:validateDebugArtifacts",
    ):
        if needle not in workflow:
            fail(f"Android CI drift: {needle}")
    if "ubuntu-latest" in workflow or "cmdline-tools/latest" in workflow:
        fail("Android CI contains a floating runner or command-line tools path")
    for workflow_label, workflow_text in (
        ("Android CI", workflow),
        ("Contracts CI", (root / ".github/workflows/contracts-ci.yml").read_text()),
    ):
        actions = re.findall(r"^\s*uses:\s*[^@\s]+@([^\s#]+)", workflow_text, flags=re.MULTILINE)
        if not actions:
            fail(f"{workflow_label} has no action references")
        for action in actions:
            if re.fullmatch(r"[0-9a-f]{40}", action) is None:
                fail(f"{workflow_label} action is not immutable: {action}")
    phase4_build = (root / "apps/android/core-bridge/build.gradle.kts").read_text()
    phase4_bridge = (root / "apps/android/core-bridge/src/main/kotlin/md/vox/android/corebridge/CoreBridge.kt").read_text()
    phase4_generated = (root / "apps/android/core-bridge/src/main/kotlin/md/vox/android/corebridge/GeneratedNativeCoreAdapter.kt").read_text()
    phase4_app = (root / "apps/android/app/src/main/kotlin/md/vox/android/VoxApplication.kt").read_text()
    for needle in (
        "Packages/vox-core-rust/generated/kotlin",
        "generated/vox-native/debug/jniLibs",
        "generated/vox-native/release/jniLibs",
        "build-android-cdylibs.sh",
    ):
        if needle not in phase4_build:
            fail(f"Android Phase 4 native packaging drift: {needle}")
    for needle in (
        "MAX_CONTROL_BYTES = 1_048_576",
        "MAX_CHUNK_BYTES = 1_048_576UL",
        "fun productionCoreBridge(): CoreBridge = LazyCoreBridge { GeneratedNativeCoreAdapter() }",
        "CoreAvailability.LAZY_NOT_PROBED",
    ):
        if needle not in phase4_bridge:
            fail(f"Android Phase 4 bridge policy drift: {needle}")
    if (
        "md.vox.core" not in phase4_generated
        or "withOwnedDirectBytes(bytes) { corePrepare(it) }" not in phase4_generated
        or "ByteBuffer.wrap" in phase4_generated
        or "bytes.fill(0)" not in phase4_generated
    ):
        fail("Android Phase 4 generated-only direct-buffer adapter drift")
    if "unwiredCoreBridge()" not in phase4_app or "productionCoreBridge" in phase4_app:
        fail("Android Phase 4 application wiring widened")
    adapter_path = root / "apps/android/core-bridge/src/main/kotlin/md/vox/android/corebridge/GeneratedNativeCoreAdapter.kt"
    production_source_paths = []
    android_root = root / "apps/android"
    for source_path in sorted(android_root.glob("*/src/*/**/*")):
        if not source_path.is_file() or source_path.suffix not in {".kt", ".java"}:
            continue
        relative_parts = source_path.relative_to(android_root).parts
        source_set = relative_parts[2].lower()
        if source_set.startswith("test") or "androidtest" in source_set or "unittest" in source_set:
            continue
        production_source_paths.append(source_path)
        if source_path != adapter_path and re.search(r"\bmd\.vox\.core\b", source_path.read_text()):
            fail(f"Android production source bypasses the handwritten core bridge: {source_path.relative_to(root)}")

    phase3_domain = (root / "apps/android/capture-domain/src/main/kotlin/md/vox/android/capturedomain/CaptureDurability.kt").read_text()
    phase3_store = (root / "apps/android/data/src/main/kotlin/md/vox/android/data/DurableCaptureStore.kt").read_text()
    phase3_database = (root / "apps/android/data/src/main/java/md/vox/android/data/CaptureDatabase.java").read_text()
    phase3_quota = (root / "apps/android/data/src/main/kotlin/md/vox/android/data/RoomQuotaLedger.kt").read_text()
    phase3_coordination = (root / "apps/android/data/src/main/kotlin/md/vox/android/data/RoomCaptureCoordination.kt").read_text()
    phase3_coordinator = (root / "apps/android/data/src/main/kotlin/md/vox/android/data/CaptureDurabilityCoordinator.kt").read_text()
    for needle in ("MIN_DURATION_MILLIS = 1_000L", "MAX_DURATION_MILLIS = 600_000L", "FREE_CAPACITY = 10"):
        if needle not in phase3_domain:
            fail(f"Android durability policy drift: {needle}")
    if phase3_store.count("StandardCopyOption.REPLACE_EXISTING") != 1:
        fail("Android replacement option must be journal-only")
    for needle in ("StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING", "beforePackageDirectorySync", "afterPackageDirectorySync"):
        if needle not in phase3_store:
            fail(f"Android journal replacement drift: {needle}")
    for needle in ("version = 2", "MIGRATION_1_2", '"capture-index-v1.db"', ".addMigrations(MIGRATION_1_2)"):
        if needle not in phase3_database:
            fail(f"Android Room v2 migration drift: {needle}")
    if "internal class RoomCaptureCoordination" not in phase3_coordination or "internal interface CaptureLeasePersistence" not in phase3_coordination:
        fail("Android raw Room lease coordination is not internal")
    if phase3_coordinator.count("store.withRootMutationLock") != 5 or "store.mutateJournal(command)" not in phase3_coordinator:
        fail("Android lease operations do not share the root mutation lock")
    if "internal fun mutateJournal(" not in phase3_store or "private fun mutateJournalUnderRootLock(" not in phase3_store:
        fail("Android journal mutation can bypass the internal fenced coordinator boundary")
    main_source = "\n".join(path.read_text() for path in production_source_paths)
    if len(re.findall(r"\bRoomCaptureCoordination\b", main_source)) != 1:
        fail("Android raw Room lease coordination has a production caller")
    if "internal fun commitTerminal" not in phase3_quota:
        fail("Android terminal quota primitive is not internal")
    if len(re.findall(r"\bmutateJournal\b", main_source)) != 2:
        fail("Android journal mutation has a production caller outside the fenced coordinator")
    if len(re.findall(r"\bcommitTerminal\b", main_source)) != 1:
        fail("Android terminal quota primitive has a production call site")
    tombstone = (root / "apps/android/data/src/main/java/md/vox/android/data/CaptureTombstoneEntity.java").read_text()
    for forbidden in ("text", "url", "filename", "logicalPath", "uri", "documentID", "artifactHash", "noteHash"):
        if re.search(rf"\b{re.escape(forbidden)}\b", tombstone, flags=re.IGNORECASE):
            fail(f"Android tombstone contains forbidden field: {forbidden}")

    artifact_validator = root / android["artifactValidator"]
    if not artifact_validator.is_file() or not os.access(artifact_validator, os.X_OK):
        fail("Android artifact validator is missing or not executable")

    print(
        "Toolchain validation passed: "
        f"{len(governed)} governed implementation hashes, UniFFI 0.32.0 bindings, "
        "Gradle 9.3.1/AGP 9.1.1/Kotlin 2.4.10/API 37 application pins, "
        "4 Android API-28 native and 3 iOS-17.6 targets."
    )


if __name__ == "__main__":
    main()
