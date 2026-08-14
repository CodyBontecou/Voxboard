#!/usr/bin/env python3
"""Stdlib-only strict M2 native and M3 Android application toolchain validator."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path

DEFAULT_ROOT = Path(__file__).resolve().parents[3]
EXPECTED_SCHEMA_CANONICAL_SHA256 = "01de5acdb619087f3c516c7040ee71289f55bbcdbc42cce0592e029f69ab7027"
EXPECTED_GOVERNED_PATHS = (
    "Packages/vox-core-rust/Cargo.lock",
    "Packages/vox-core-rust/uniffi.toml",
    "Packages/vox-core-rust/uniffi-bindgen.toml",
    "Packages/vox-core-rust/crates/vox-core-uniffi/uniffi.toml",
    "Packages/vox-core-rust/scripts/generate-swift-bindings.sh",
    "Packages/vox-core-rust/scripts/generate-kotlin-bindings.sh",
    "Packages/vox-core-rust/scripts/normalize-kotlin-bindings.py",
    "Packages/vox-core-rust/scripts/check-bindings.sh",
    "Packages/vox-core-rust/scripts/build-android-cdylibs.sh",
    "Packages/vox-core-rust/scripts/build-apple-xcframework.sh",
    "Packages/vox-core-rust/scripts/merge-apple-staticlib.sh",
    "Packages/vox-core-rust/scripts/normalize-apple-xcframework.py",
    "Packages/vox-core-rust/scripts/inspect-native-packages.py",
    "Packages/vox-core-rust/scripts/normalize-generated-text.py",
    "Packages/VoxboardShared/Sources/VoxCoreGenerated/VoxCore.swift",
    "Packages/VoxboardShared/Sources/VoxCoreFFI/module.modulemap",
    "apps/android/build.gradle.kts",
    "apps/android/settings.gradle.kts",
    "apps/android/gradle/libs.versions.toml",
    "apps/android/gradle.properties",
    "apps/android/gradle/wrapper/gradle-wrapper.properties",
    "apps/android/gradle/wrapper/gradle-wrapper.jar",
    "apps/android/gradlew",
    "apps/android/gradlew.bat",
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
        "androidGradlePluginVersion": "9.1.0",
        "kotlin": {
            "version": "2.4.10", "builtIn": True,
            "composeCompilerPluginVersion": "2.4.10",
            "annotationProcessingPlugin": "com.android.legacy-kapt",
            "annotationProcessingPluginVersion": "9.1.0",
        },
        "sdk": {
            "compileSdk": 37, "buildToolsVersion": "36.0.0",
            "phoneMinSdk": 28, "phoneTargetSdk": 36,
            "wearMinSdk": 30, "wearTargetSdk": 35,
        },
        "compose": {"bomVersion": "2026.08.00"},
        "dependencies": {
            "activityCompose": "1.13.0", "androidxHilt": "1.4.0",
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
        "agp": "9.1.0", "kotlin": "2.4.10", "compose-bom": "2026.08.00",
        "core": "1.19.0", "activity": "1.13.0", "lifecycle": "2.11.0",
        "navigation": "2.9.8", "room": "2.8.4", "datastore": "1.2.1",
        "work": "2.11.2", "hilt": "2.60.1", "androidx-hilt": "1.4.0",
        "coroutines": "1.11.0", "serialization": "1.11.0", "jna": "5.17.0",
        "androidx-test": "1.7.0", "androidx-test-ext-junit": "1.3.0",
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

    print(
        "Toolchain validation passed: "
        f"{len(governed)} governed implementation hashes, UniFFI 0.32.0 bindings, "
        "Gradle 9.3.1/AGP 9.1.0/Kotlin 2.4.10/API 37 application pins, "
        "4 Android API-28 native and 3 iOS-17.6 targets."
    )


if __name__ == "__main__":
    main()
