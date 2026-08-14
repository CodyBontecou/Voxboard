#!/usr/bin/env python3
"""Inspect source-built M2 native leaves and emit a canonical typed candidate receipt."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path

ABIS = {
    "arm64-v8a": ("AArch64", "android-core-arm64-uncompressed", "arm64"),
    "armeabi-v7a": ("ARM", "android-core-armv7-uncompressed", "armv7"),
    "x86_64": ("Advanced Micro Devices X86-64", "android-core-x86_64-uncompressed", "x86_64"),
    "x86": ("Intel 80386", "android-core-x86-uncompressed", "x86"),
}
SYMBOL = "uniffi_vox_core_uniffi_fn_func_core_build_info"
ANDROID_CHECKS = ("architecture", "binaryFormat", "definedUniFFISymbols", "dependencyAllowlist")
APPLE_CHECKS = (*ANDROID_CHECKS, "deploymentTarget", "archiveMembers", "xcframeworkMetadata")
HEADER_SOURCES = {
    "cHeader": "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h",
    "moduleMap": "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap",
}


def run(*arguments: str) -> str:
    return subprocess.run(arguments, text=True, capture_output=True, check=True).stdout


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def required_sysctl(name: str) -> str:
    value = run("sysctl", "-n", name).strip()
    if not value:
        raise SystemExit(f"required build-host fact is empty: {name}")
    return value


def build_host() -> dict[str, object]:
    try:
        cpu = required_sysctl("machdep.cpu.brand_string")
    except subprocess.CalledProcessError:
        cpu = required_sysctl("hw.model")
    logical = os.cpu_count()
    memory = int(required_sysctl("hw.memsize"))
    values = {
        "osName": platform.system(),
        "osVersion": platform.mac_ver()[0] or platform.release(),
        "architecture": platform.machine(),
        "cpuModel": cpu,
        "logicalCPUCount": logical,
        "totalMemoryBytes": memory,
    }
    if not logical or logical < 1 or memory < 1 or any(
        not values[key] for key in ("osName", "osVersion", "architecture", "cpuModel")
    ):
        raise SystemExit("required build-host identity is unavailable")
    return values


def check_records(codes: tuple[str, ...]) -> list[dict[str, str]]:
    return [{"code": code, "result": "passed"} for code in sorted(codes)]


def exact_directory(path: Path, expected: set[str], label: str) -> None:
    try:
        entries = list(path.iterdir())
    except OSError as error:
        raise SystemExit(f"{label} is unreadable: {error}") from error
    if path.is_symlink() or not path.is_dir() or {entry.name for entry in entries} != expected:
        raise SystemExit(f"{label} inventory mismatch")
    if any(entry.is_symlink() for entry in entries):
        raise SystemExit(f"{label} contains a symlink")


def header_descriptor(
    path: Path,
    external_root: Path,
    target_scope: str,
    kind: str,
    repository_root: Path,
) -> dict[str, object]:
    source_relative = HEADER_SOURCES[kind]
    source = (repository_root / source_relative).resolve(strict=True)
    if path.read_bytes() != source.read_bytes():
        raise SystemExit(f"XCFramework {kind} differs from tracked generated source")
    return {
        "targetScope": target_scope,
        "kind": kind,
        "relativeArtifactPath": path.relative_to(external_root).as_posix(),
        "repositorySourcePath": source_relative,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def leaf(
    artifact_id: str,
    path: Path,
    external_root: Path,
    gate_id: str,
    target_scope: str,
    architectures: list[str],
    binary_format: str,
    checks: tuple[str, ...],
) -> dict[str, object]:
    size = path.stat().st_size
    if size < 1:
        raise SystemExit("native package leaf is empty")
    return {
        "artifactID": artifact_id,
        "relativeArtifactPath": path.relative_to(external_root).as_posix(),
        "gateID": gate_id,
        "targetScope": target_scope,
        "architectures": architectures,
        "format": binary_format,
        "bytes": size,
        "sha256": sha256(path),
        "inspectionChecks": check_records(checks),
        "baseline": None,
    }


def ndk_tools() -> tuple[Path, Path]:
    ndk = Path(
        os.environ.get(
            "ANDROID_NDK_HOME",
            str(Path.home() / "Library/Android/sdk/ndk/27.1.12297006"),
        )
    )
    candidates = (
        ndk / "toolchains/llvm/prebuilt/darwin-x86_64/bin",
        ndk / "toolchains/llvm/prebuilt/darwin-aarch64/bin",
    )
    tool = next((candidate for candidate in candidates if candidate.is_dir()), None)
    if tool is None:
        raise SystemExit("governed Android NDK tools are unavailable")
    return tool / "llvm-readelf", tool / "llvm-nm"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--android", type=Path, required=True)
    parser.add_argument("--xcframework", type=Path, required=True)
    parser.add_argument("--external-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--toolchain-manifest", type=Path, required=True)
    parser.add_argument("--build-recipe", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    args = parser.parse_args()

    external_root = args.external_root.resolve(strict=True)
    repository_root = args.repository_root.resolve(strict=True)
    readelf, nm = ndk_tools()
    leaves: list[dict[str, object]] = []
    for abi, (machine, gate, architecture) in ABIS.items():
        path = (args.android / abi / "libvox_core_uniffi.so").resolve(strict=True)
        header = run(str(readelf), "-h", str(path))
        dynamic = run(str(readelf), "-d", str(path))
        symbols = run(str(nm), "-D", "--defined-only", str(path))
        machine_match = re.search(r"Machine:\s+(.+)", header)
        defined = {line.split()[-1] for line in symbols.splitlines() if line.split()}
        dependencies = set(re.findall(r"\(NEEDED\).*Shared library: \[([^]]+)\]", dynamic))
        if (
            machine_match is None
            or machine_match.group(1).strip() != machine
            or re.search(r"Type:\s+DYN", header) is None
            or SYMBOL not in defined
            or not dependencies
            or not dependencies <= {"libc.so", "libdl.so"}
        ):
            raise SystemExit(f"Android package inspection failed: {abi}")
        leaves.append(
            leaf(
                f"android-{abi}-libvox-core-uniffi",
                path,
                external_root,
                gate,
                abi,
                [architecture],
                "elf-shared-object",
                ANDROID_CHECKS,
            )
        )

    xcframework_root = args.xcframework.resolve(strict=True)
    exact_directory(
        xcframework_root,
        {"Info.plist", "ios-arm64", "ios-arm64_x86_64-simulator"},
        "XCFramework root",
    )
    info_path = (xcframework_root / "Info.plist").resolve(strict=True)
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    expected = (
        ("ios-arm64", ["arm64"], "xcframework-ios-device-arm64"),
        (
            "ios-arm64_x86_64-simulator",
            ["arm64", "x86_64"],
            "xcframework-ios-simulator-arm64-x86_64",
        ),
    )
    libraries = info.get("AvailableLibraries") if isinstance(info, dict) else None
    if (
        not isinstance(libraries, list)
        or len(libraries) != 2
        or set(info) != {"AvailableLibraries", "CFBundlePackageType", "XCFrameworkFormatVersion"}
        or info.get("CFBundlePackageType") != "XFWK"
        or info.get("XCFrameworkFormatVersion") != "1.0"
    ):
        raise SystemExit("XCFramework metadata inspection failed")
    apple_bytes = 0
    headers: list[dict[str, object]] = []
    for identifier, architectures, scope in expected:
        entry = next(
            (item for item in libraries if item.get("LibraryIdentifier") == identifier),
            None,
        )
        expected_keys = {
            "BinaryPath", "HeadersPath", "LibraryIdentifier", "LibraryPath",
            "SupportedArchitectures", "SupportedPlatform",
        }
        if "simulator" in identifier:
            expected_keys.add("SupportedPlatformVariant")
        if (
            entry is None
            or set(entry) != expected_keys
            or entry.get("LibraryPath") != "libVoxCoreFFI.a"
            or entry.get("BinaryPath") != entry.get("LibraryPath")
            or entry.get("HeadersPath") != "Headers"
            or set(entry.get("SupportedArchitectures", [])) != set(architectures)
            or len(entry.get("SupportedArchitectures", [])) != len(architectures)
            or entry.get("SupportedPlatform") != "ios"
            or entry.get("SupportedPlatformVariant") != ("simulator" if "simulator" in identifier else None)
        ):
            raise SystemExit(f"missing or malformed XCFramework leaf: {identifier}")
        slice_root = xcframework_root / identifier
        exact_directory(slice_root, {"libVoxCoreFFI.a", "Headers"}, f"XCFramework slice {identifier}")
        header_root = slice_root / "Headers"
        exact_directory(header_root, {"VoxCoreFFI.h", "module.modulemap"}, f"XCFramework headers {identifier}")
        header_path = (header_root / "VoxCoreFFI.h").resolve(strict=True)
        modulemap_path = (header_root / "module.modulemap").resolve(strict=True)
        headers.extend(
            (
                header_descriptor(header_path, external_root, scope, "cHeader", repository_root),
                header_descriptor(modulemap_path, external_root, scope, "moduleMap", repository_root),
            )
        )
        path = (slice_root / "libVoxCoreFFI.a").resolve(strict=True)
        actual_architectures = run("xcrun", "lipo", "-archs", str(path)).split()
        global_symbols = run("xcrun", "nm", "-gU", str(path))
        archive_members: list[str] = []
        if len(architectures) == 1:
            archive_members.extend(run("xcrun", "ar", "-t", str(path)).splitlines())
        else:
            with tempfile.TemporaryDirectory(prefix="vox-m2-inspector-") as temporary:
                for architecture in architectures:
                    thin = Path(temporary) / f"{architecture}.a"
                    run("xcrun", "lipo", str(path), "-thin", architecture, "-output", str(thin))
                    members = run("xcrun", "ar", "-t", str(thin)).splitlines()
                    if not members:
                        raise SystemExit(f"Apple package archive is empty: {identifier}/{architecture}")
                    archive_members.extend(members)
        deployment = run("xcrun", "otool", "-l", str(path))
        if (
            set(actual_architectures) != set(architectures)
            or f"_{SYMBOL}" not in global_symbols
            or not archive_members
            or "minos 17.6" not in deployment
        ):
            raise SystemExit(f"Apple package inspection failed: {identifier}")
        item = leaf(
            f"apple-{identifier}-libvox-core-ffi",
            path,
            external_root,
            "apple-xcframework-per-slice",
            scope,
            architectures,
            "apple-static-library",
            APPLE_CHECKS,
        )
        apple_bytes += int(item["bytes"])
        leaves.append(item)

    receipt = {
        "schemaVersion": 1,
        "format": "vox-m2-native-package-inspection-v1",
        "comparisonMode": "initialCandidate",
        "sourceRevision": args.source_revision,
        "sourceTreeState": "clean",
        "toolchainManifestSha256": sha256(args.toolchain_manifest),
        "buildRecipeSha256": sha256(args.build_recipe),
        "inspectorSha256": sha256(Path(__file__)),
        "buildHost": build_host(),
        "buildConfiguration": "release-stripped",
        "featureSet": "default-features",
        "candidateLeaves": leaves,
        "appleAggregateBytes": apple_bytes,
        "xcframeworkMetadata": {
            "relativeArtifactPath": info_path.relative_to(external_root).as_posix(),
            "bytes": info_path.stat().st_size,
            "sha256": sha256(info_path),
        },
        "xcframeworkHeaders": headers,
        "retention": {"kind": "notRetained"},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(canonical_bytes(receipt))
    print("M2 native package inspection completed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
