#!/usr/bin/env python3
"""Validate the Android/Wear M0 capability and provenance ledger.

The ledger is an inventory/evidence contract, not proof that future Android or Wear
implementations exist. Planned acceptance artifacts may be absent; verified artifacts
must exist. Source enum inventories are compared with Swift so newly shipped cases
cannot silently remain unmapped.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "docs/architecture/android-wear-m0-capabilities.json"
COMPATIBILITY_MATRIX = ROOT / "docs/architecture/android-wear-m0-compatibility-matrix.json"

OWNERS = {"shared", "native", "adjusted"}
PARITY = {
    "exact",
    "native-equivalent",
    "product-adjusted",
    "commercial-equivalent",
    "legacy-only",
    "explicit-non-goal",
}
SCOPES = {"parity", "legacy-codec", "non-goal"}
STATUSES = {"inventoried", "fixture-needed", "verified", "blocked"}
ACCEPTANCE_KINDS = {"unit", "fixture", "ui", "device", "provider", "account", "manual", "ci"}
ACCEPTANCE_STATUSES = {"planned", "verified", "blocked"}
PLATFORMS = {"iphone", "ipad", "watch", "macos", "android", "wear"}
REQUIRED_ATOMIC_CAPABILITIES = {
    "cap.entry.control-center",
    "cap.entry.live-activity",
    "cap.billing.family",
    "cap.billing.family-upgrade",
    "cap.billing.restore",
    "cap.billing.restore-diagnostics",
}
PERSISTED_ENUM_INVENTORIES = {
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CapturePayload"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CaptureAudioEmbedPlacement"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CaptureSource"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CaptureDeliveryKind"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CaptureRollingPeriod"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CaptureMissingHeadingBehavior"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CapturePlacement"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift", "CaptureNoteTarget"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureVox.swift", "CapturePresetMetadataScope"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureVox.swift", "CapturePresetProcessingMode"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureVox.swift", "CapturePresetProcessingState"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift", "CapturePresetKind"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift", "CapturePresetWatchOutputMode"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift", "CapturePresetAudioSaveMode"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift", "CapturePresetAudioEmbedPlacement"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobSource"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobDelivery"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobPhase"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobFailureStage"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "SourceAudioRetentionMode"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobProcessingPolicy"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobHandoffReadiness"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift", "RecordingJobExternalDeliveryArtifact"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/AppConstants.swift", "VoiceAutoStopCapturePath"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureDraftStore.swift", "CaptureDestinationSelectionMode"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureHistoryStore.swift", "CaptureHistoryOutcome"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureHistoryStore.swift", "CaptureHistoryFailureCategory"),
    ("Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureInbox.swift", "CaptureInboxState"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/TranscriptionIPC.swift", "Phase"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/TranscriptionIPC.swift", "Action"),
    ("Packages/VoxboardShared/Sources/VoxboardShared/TranscriptionIPC.swift", "Origin"),
    ("Voxboard/WatchRecordingInbox.swift", "WatchRecordingProcessingPhase"),
    ("Voxboard/WatchRecordingInbox.swift", "WatchRecordingFailureStage"),
    ("Voxboard Watch Shared/WatchLocalRecordingQueueStore.swift", "WatchLocalRecordingTransportState"),
    ("Voxboard Watch Shared/WatchPhoneBridge.swift", "WatchRecordingCommand"),
    ("Voxboard Watch Shared/WatchPhoneBridge.swift", "WatchPresetSelectionOutcome"),
}
PERSISTED_KEY_SOURCE_PATHS = {
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureVox.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/AppConstants.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/RecordingFlow.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/RecordingJobStore.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/UsageTracker.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/Analytics/CloudflareOnboardingAnalyticsTransport.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/Analytics/OnboardingAnalyticsClient.swift",
    "Packages/VoxboardShared/Sources/VoxboardShared/Analytics/OnboardingAnalyticsStorage.swift",
    "Voxboard App Shared/CaptureToolbarPreferences.swift",
    "Voxboard App Shared/InspirationQuoteService.swift",
    "Voxboard Watch Shared/WatchPhoneBridge.swift",
    "Voxboard/PersistentRecorder.swift",
    "Voxboard/ReviewPromptManager.swift",
    "Voxboard/StoreManager.swift",
    "Voxboard/WatchRecordingController.swift",
}
MILESTONE_RE = re.compile(r"^M(?:[0-9]|10)(?:/M(?:[0-9]|10))*$")
ID_RE = re.compile(r"^cap\.[a-z0-9]+(?:[.-][a-z0-9]+)*$")
DEP_RE = re.compile(r"^dep\.[a-z0-9]+(?:[.-][a-z0-9]+)*$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
COMPATIBILITY_DIMENSIONS = {
    "old",
    "missingFields",
    "unknownFields",
    "malformed",
    "futureVersion",
    "date",
    "data",
    "uuid",
    "enum",
    "crashRecovery",
}
COMPATIBILITY_STATUSES = {"executed", "notApplicable", "pending", "external"}
REQUIRED_SHARED_SCHEMES = {
    "Voxboard.xcscheme",
    "Voxboard Mac.xcscheme",
    "Voxboard Watch.xcscheme",
    "Voxboard Watch Tests.xcscheme",
    "VoxboardTests.xcscheme",
}

PERSISTED_KEY_NAME_RE = re.compile(
    r"(?:(?:public|private|fileprivate|internal|package|nonisolated|static)\s+)*"
    r"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*(?:Key|DefaultsKey|storageKey|flowsKey|IDsKey|IdKey)"
    r"|successfulTranscriptionCount|successfulCaptureCount|usageDayIdentifiers|lastPromptAttemptAt|pendingPrompt|confirmVoiceNoteBeforeAdding)"
    r"\s*(?::[^=\n]+)?=\s*\"([^\"]+)\""
)


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def find_matching_brace(source: str, opening: int) -> int:
    depth = 0
    in_string = False
    escaped = False
    line_comment = False
    block_comment = 0
    i = opening
    while i < len(source):
        c = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if c == "/" and nxt == "*":
                block_comment += 1
                i += 2
                continue
            if c == "*" and nxt == "/":
                block_comment -= 1
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
            i += 1
            continue
        if c == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if c == "/" and nxt == "*":
            block_comment = 1
            i += 2
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError("unbalanced Swift braces")


def swift_enum_cases(path: Path, enum_name: str) -> set[str]:
    source = path.read_text(encoding="utf-8")
    match = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^{{]*\{{", source)
    if not match:
        raise ValueError(f"enum {enum_name} not found")
    opening = source.find("{", match.start())
    closing = find_matching_brace(source, opening)
    body = source[opening + 1 : closing]

    cases: set[str] = set()
    depth = 1
    for raw_line in body.splitlines():
        stripped = raw_line.strip()
        if depth == 1 and stripped.startswith("case "):
            declaration = stripped[5:].split("//", 1)[0].strip()
            # Associated values can contain commas. All current audited associated
            # cases declare one case per line; comma-separated raw cases do not.
            if "(" in declaration:
                names = [declaration.split("(", 1)[0].strip()]
            else:
                names = [part.strip().split()[0] for part in declaration.split(",")]
            cases.update(name for name in names if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name))
        # Audited enum declarations do not place braces before a direct case on
        # the same line. Tracking after extraction avoids switch cases in methods.
    return cases


def swift_persisted_keys(path: Path) -> set[str]:
    source = path.read_text(encoding="utf-8")
    return {value for _, value in PERSISTED_KEY_NAME_RE.findall(source)}


def git_commit_exists(sha: str) -> bool:
    result = subprocess.run(
        ["git", "cat-file", "-e", f"{sha}^{{commit}}"],
        cwd=ROOT,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def validate(ledger_path: Path) -> list[str]:
    errors: list[str] = []
    try:
        data: dict[str, Any] = json.loads(ledger_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"cannot read ledger {ledger_path}: {exc}"]

    if data.get("schemaVersion") != 1:
        fail(errors, "schemaVersion must be 1")

    baseline = data.get("baseline")
    if not isinstance(baseline, dict):
        fail(errors, "baseline must be an object")
        baseline = {}
    for key in ("implementationParent", "planningBaseline", "healthMdPrecedent"):
        value = baseline.get(key)
        if not isinstance(value, str) or not SHA_RE.fullmatch(value):
            fail(errors, f"baseline.{key} must be a lowercase 40-character commit SHA")
        elif key != "healthMdPrecedent" and not git_commit_exists(value):
            fail(errors, f"baseline.{key} does not exist in this repository: {value}")
    targets = baseline.get("appleTargets")
    expected_targets = {"ios": "17.6", "macos": "14.0", "watchos": "10.0"}
    if targets != expected_targets:
        fail(errors, f"baseline.appleTargets must equal {expected_targets}")

    scheme_directory = ROOT / "Voxboard.xcodeproj/xcshareddata/xcschemes"
    committed_schemes = {path.name for path in scheme_directory.glob("*.xcscheme")}
    missing_schemes = REQUIRED_SHARED_SCHEMES - committed_schemes
    if missing_schemes:
        fail(errors, f"required shared Xcode schemes are missing: {sorted(missing_schemes)}")
    project = (ROOT / "Voxboard.xcodeproj/project.pbxproj").read_text()
    for required in ["Voxboard Watch Tests", "Voxboard Watch Tests.xctest"]:
        if required not in project:
            fail(errors, f"project is missing required Watch fixture test target token: {required}")
    workflow = (ROOT / ".github/workflows/apple-ci.yml").read_text()
    for required in ["Voxboard Watch Tests", "Run Watch codec tests", "xcode-version: '26.6'"]:
        if required not in workflow:
            fail(errors, f"Apple CI is missing required Watch fixture test token: {required}")

    dependencies = data.get("dependencyCatalog")
    dependency_ids: set[str] = set()
    if not isinstance(dependencies, list):
        fail(errors, "dependencyCatalog must be an array")
        dependencies = []
    for index, dependency in enumerate(dependencies):
        if not isinstance(dependency, dict):
            fail(errors, f"dependencyCatalog[{index}] must be an object")
            continue
        dep_id = dependency.get("id")
        if not isinstance(dep_id, str) or not DEP_RE.fullmatch(dep_id):
            fail(errors, f"dependencyCatalog[{index}].id is invalid: {dep_id!r}")
            continue
        if dep_id in dependency_ids:
            fail(errors, f"duplicate dependency id: {dep_id}")
        dependency_ids.add(dep_id)
        if not isinstance(dependency.get("description"), str) or not dependency["description"].strip():
            fail(errors, f"dependency {dep_id} needs a description")

    capabilities = data.get("capabilities")
    if not isinstance(capabilities, list):
        fail(errors, "capabilities must be an array")
        capabilities = []
    capability_ids: set[str] = set()
    capabilities_by_id: dict[str, dict[str, Any]] = {}
    for index, capability in enumerate(capabilities):
        prefix = f"capabilities[{index}]"
        if not isinstance(capability, dict):
            fail(errors, f"{prefix} must be an object")
            continue
        cap_id = capability.get("id")
        if not isinstance(cap_id, str) or not ID_RE.fullmatch(cap_id):
            fail(errors, f"{prefix}.id is invalid: {cap_id!r}")
            continue
        if cap_id in capability_ids:
            fail(errors, f"duplicate capability id: {cap_id}")
        capability_ids.add(cap_id)
        capabilities_by_id[cap_id] = capability

        for field in ("outcome", "milestone"):
            if not isinstance(capability.get(field), str) or not capability[field].strip():
                fail(errors, f"{cap_id}.{field} must be non-empty")
        if isinstance(capability.get("milestone"), str) and not MILESTONE_RE.fullmatch(capability["milestone"]):
            fail(errors, f"{cap_id}.milestone is invalid: {capability['milestone']!r}")
        if capability.get("owner") not in OWNERS:
            fail(errors, f"{cap_id}.owner is invalid")
        if capability.get("parity") not in PARITY:
            fail(errors, f"{cap_id}.parity is invalid")
        if capability.get("programScope") not in SCOPES:
            fail(errors, f"{cap_id}.programScope is invalid")
        if capability.get("status") not in STATUSES:
            fail(errors, f"{cap_id}.status is invalid")
        if capability.get("programScope") == "parity" and capability.get("parity") in {"legacy-only", "explicit-non-goal"}:
            fail(errors, f"{cap_id} is parity scope but has {capability.get('parity')} parity")
        if capability.get("programScope") == "non-goal" and capability.get("parity") != "explicit-non-goal":
            fail(errors, f"{cap_id} non-goal must use explicit-non-goal parity")

        platforms = capability.get("platforms")
        if not isinstance(platforms, list) or not platforms:
            fail(errors, f"{cap_id}.platforms must be a non-empty array")
        elif any(platform not in PLATFORMS for platform in platforms):
            fail(errors, f"{cap_id}.platforms contains an invalid platform")

        evidence = capability.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            fail(errors, f"{cap_id}.evidence must be non-empty")
        else:
            for evidence_index, item in enumerate(evidence):
                if not isinstance(item, dict):
                    fail(errors, f"{cap_id}.evidence[{evidence_index}] must be an object")
                    continue
                relative = item.get("path")
                symbol = item.get("symbol")
                if not isinstance(relative, str) or not relative or Path(relative).is_absolute() or ".." in Path(relative).parts:
                    fail(errors, f"{cap_id}.evidence[{evidence_index}].path must be a repository-relative path")
                    continue
                evidence_path = ROOT / relative
                if not evidence_path.is_file():
                    fail(errors, f"{cap_id} evidence file does not exist: {relative}")
                    continue
                if not isinstance(symbol, str) or not symbol:
                    fail(errors, f"{cap_id}.evidence[{evidence_index}].symbol must be non-empty")
                elif symbol not in evidence_path.read_text(encoding="utf-8", errors="ignore"):
                    fail(errors, f"{cap_id} evidence symbol {symbol!r} not found in {relative}")
        if capability.get("programScope") == "legacy-codec" and any(
            isinstance(item, dict)
            and item.get("path") == "docs/android-wear-shared-core-implementation-plan.md"
            for item in evidence or []
        ):
            fail(errors, f"{cap_id} legacy Apple evidence cannot cite the future implementation plan")

        cap_dependencies = capability.get("dependencies")
        if not isinstance(cap_dependencies, list):
            fail(errors, f"{cap_id}.dependencies must be an array")

        acceptance = capability.get("acceptance")
        if not isinstance(acceptance, list) or not acceptance:
            fail(errors, f"{cap_id}.acceptance must be non-empty")
        else:
            for acceptance_index, item in enumerate(acceptance):
                if not isinstance(item, dict):
                    fail(errors, f"{cap_id}.acceptance[{acceptance_index}] must be an object")
                    continue
                if item.get("kind") not in ACCEPTANCE_KINDS:
                    fail(errors, f"{cap_id}.acceptance[{acceptance_index}].kind is invalid")
                if item.get("status") not in ACCEPTANCE_STATUSES:
                    fail(errors, f"{cap_id}.acceptance[{acceptance_index}].status is invalid")
                assertion = item.get("assertion")
                if not isinstance(assertion, str) or not assertion.strip():
                    fail(errors, f"{cap_id}.acceptance[{acceptance_index}].assertion must be non-empty")
                evidence_path_value = item.get("evidencePath")
                if not isinstance(evidence_path_value, str) or not evidence_path_value or Path(evidence_path_value).is_absolute() or ".." in Path(evidence_path_value).parts:
                    fail(errors, f"{cap_id}.acceptance[{acceptance_index}].evidencePath must be repository-relative")
                elif item.get("status") == "verified" and not (ROOT / evidence_path_value).exists():
                    fail(errors, f"{cap_id} claims verified acceptance but evidence is absent: {evidence_path_value}")
        if isinstance(acceptance, list):
            acceptance_states = {
                item.get("status") for item in acceptance if isinstance(item, dict)
            }
            if capability.get("status") == "verified" and acceptance_states != {"verified"}:
                fail(errors, f"{cap_id} status is verified without exclusively verified acceptance")
            if "verified" in acceptance_states and capability.get("status") != "verified":
                fail(errors, f"{cap_id} has verified acceptance but capability status is not verified")

    for cap_id, capability in capabilities_by_id.items():
        for dependency in capability.get("dependencies", []):
            if dependency not in dependency_ids and dependency not in capability_ids:
                fail(errors, f"{cap_id} references unknown dependency {dependency!r}")

    if len(capabilities) < 150:
        fail(errors, f"capability ledger is unexpectedly small: {len(capabilities)} rows (minimum 150)")
    required_prefix_counts = {
        "cap.payload.": 8,
        "cap.editor.": 14,
        "cap.location.": 20,
        "cap.queue.": 15,
        "cap.watch.": 20,
        "cap.store.": 15,
    }
    for prefix, minimum in required_prefix_counts.items():
        count = sum(cap_id.startswith(prefix) for cap_id in capability_ids)
        if count < minimum:
            fail(errors, f"ledger has {count} {prefix} rows; expected at least {minimum}")
    missing_atomic = sorted(REQUIRED_ATOMIC_CAPABILITIES - capability_ids)
    if missing_atomic:
        fail(errors, f"ledger is missing required atomic shipped outcomes: {', '.join(missing_atomic)}")

    persisted_key_inventories = data.get("persistedKeyInventories")
    if not isinstance(persisted_key_inventories, list) or not persisted_key_inventories:
        fail(errors, "persistedKeyInventories must be a non-empty array")
        persisted_key_inventories = []
    inventoried_key_paths: set[str] = set()
    inventoried_persisted_key_count = 0
    for index, inventory in enumerate(persisted_key_inventories):
        prefix = f"persistedKeyInventories[{index}]"
        if not isinstance(inventory, dict):
            fail(errors, f"{prefix} must be an object")
            continue
        relative = inventory.get("path")
        mapping = inventory.get("keys")
        if not isinstance(relative, str) or not isinstance(mapping, dict):
            fail(errors, f"{prefix} needs path and keys")
            continue
        if relative in inventoried_key_paths:
            fail(errors, f"duplicate persisted key inventory path: {relative}")
        inventoried_key_paths.add(relative)
        source_path = ROOT / relative
        if not source_path.is_file():
            fail(errors, f"persisted key inventory path does not exist: {relative}")
            continue
        actual_keys = {
            key for key in swift_persisted_keys(source_path)
            if not key.startswith(("VOXBOARD_", "ONBOARDING_ANALYTICS_"))
        }
        mapped_keys = set(mapping)
        inventoried_persisted_key_count += len(mapped_keys)
        missing = sorted(actual_keys - mapped_keys)
        stale = sorted(mapped_keys - actual_keys)
        if missing:
            fail(errors, f"{relative} has unmapped persisted keys: {missing}")
        if stale:
            fail(errors, f"{relative} ledger has stale persisted keys: {stale}")
        for key, cap_ids in mapping.items():
            if not isinstance(key, str) or not key:
                fail(errors, f"{relative} has an invalid persisted key")
                continue
            if not isinstance(cap_ids, list) or not cap_ids:
                fail(errors, f"{relative}:{key} needs capability IDs")
                continue
            for cap_id in cap_ids:
                if cap_id not in capability_ids:
                    fail(errors, f"{relative}:{key} maps unknown capability {cap_id}")
    missing_key_sources = sorted(PERSISTED_KEY_SOURCE_PATHS - inventoried_key_paths)
    stale_key_sources = sorted(inventoried_key_paths - PERSISTED_KEY_SOURCE_PATHS)
    if missing_key_sources:
        fail(errors, f"persisted key source paths are not inventoried: {missing_key_sources}")
    if stale_key_sources:
        fail(errors, f"persisted key inventories include unapproved source paths: {stale_key_sources}")
    fixture_evidence_path = ROOT / "docs/architecture/android-wear-m0-fixture-evidence.md"
    if fixture_evidence_path.is_file() and str(inventoried_persisted_key_count) not in fixture_evidence_path.read_text():
        fail(errors, "fixture evidence must record the current total inventoried persisted-key count")

    inventories = data.get("sourceInventories")
    if not isinstance(inventories, list) or not inventories:
        fail(errors, "sourceInventories must be a non-empty array")
        inventories = []
    inventoried_enums: set[tuple[str, str]] = set()
    for index, inventory in enumerate(inventories):
        if not isinstance(inventory, dict):
            fail(errors, f"sourceInventories[{index}] must be an object")
            continue
        relative = inventory.get("path")
        enum_name = inventory.get("enum")
        mapping = inventory.get("cases")
        if not isinstance(relative, str) or not isinstance(enum_name, str) or not isinstance(mapping, dict):
            fail(errors, f"sourceInventories[{index}] needs path, enum, and cases")
            continue
        source_path = ROOT / relative
        if not source_path.is_file():
            fail(errors, f"source inventory path does not exist: {relative}")
            continue
        inventory_identity = (relative, enum_name)
        if inventory_identity in inventoried_enums:
            fail(errors, f"duplicate source inventory: {relative}:{enum_name}")
        inventoried_enums.add(inventory_identity)
        try:
            actual_cases = swift_enum_cases(source_path, enum_name)
        except ValueError as exc:
            fail(errors, f"cannot inspect {relative}:{enum_name}: {exc}")
            continue
        mapped_cases = set(mapping)
        missing = sorted(actual_cases - mapped_cases)
        stale = sorted(mapped_cases - actual_cases)
        if missing:
            fail(errors, f"{relative}:{enum_name} has unmapped cases: {missing}")
        if stale:
            fail(errors, f"{relative}:{enum_name} ledger has stale cases: {stale}")
        for case_name, cap_ids in mapping.items():
            if not isinstance(cap_ids, list) or not cap_ids:
                fail(errors, f"{relative}:{enum_name}.{case_name} needs capability IDs")
                continue
            for cap_id in cap_ids:
                if cap_id not in capability_ids:
                    fail(errors, f"{relative}:{enum_name}.{case_name} maps unknown capability {cap_id}")
    missing_persisted_enums = sorted(PERSISTED_ENUM_INVENTORIES - inventoried_enums)
    if missing_persisted_enums:
        fail(errors, f"persisted enum inventories are missing: {missing_persisted_enums}")

    try:
        matrix: dict[str, Any] = json.loads(COMPATIBILITY_MATRIX.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(errors, f"cannot read compatibility matrix: {exc}")
        matrix = {}
    if matrix.get("schemaVersion") != 1:
        fail(errors, "compatibility matrix schemaVersion must be 1")
    if set(matrix.get("dimensions", [])) != COMPATIBILITY_DIMENSIONS:
        fail(errors, "compatibility matrix dimensions do not match the required M0 dimensions")
    if set(matrix.get("statuses", [])) != COMPATIBILITY_STATUSES:
        fail(errors, "compatibility matrix statuses do not match the allowed statuses")
    matrix_formats = matrix.get("formats")
    if not isinstance(matrix_formats, list) or not matrix_formats:
        fail(errors, "compatibility matrix formats must be a non-empty array")
        matrix_formats = []
    matrix_ids: set[str] = set()
    covered_store_capabilities: set[str] = set()
    for index, item in enumerate(matrix_formats):
        prefix = f"compatibility formats[{index}]"
        if not isinstance(item, dict):
            fail(errors, f"{prefix} must be an object")
            continue
        format_id = item.get("id")
        cap_id = item.get("capabilityID")
        production = item.get("production")
        cells = item.get("dimensions")
        if not isinstance(format_id, str) or not format_id:
            fail(errors, f"{prefix}.id must be non-empty")
        elif format_id in matrix_ids:
            fail(errors, f"duplicate compatibility format id: {format_id}")
        else:
            matrix_ids.add(format_id)
        if cap_id not in capability_ids or not str(cap_id).startswith("cap.store."):
            fail(errors, f"{prefix}.capabilityID must map a persisted-store capability")
        else:
            covered_store_capabilities.add(cap_id)
        if not isinstance(production, list) or not production:
            fail(errors, f"{prefix}.production must be non-empty")
        else:
            for reference in production:
                if not isinstance(reference, str) or ":" not in reference:
                    fail(errors, f"{prefix} has invalid production reference {reference!r}")
                    continue
                relative, symbol = reference.split(":", 1)
                path = ROOT / relative
                if not path.is_file() or symbol not in path.read_text(encoding="utf-8", errors="ignore"):
                    fail(errors, f"{prefix} production reference does not resolve: {reference}")
        if not isinstance(cells, dict) or set(cells) != COMPATIBILITY_DIMENSIONS:
            fail(errors, f"{prefix}.dimensions must contain every required dimension exactly once")
            continue
        for dimension, cell in cells.items():
            if not isinstance(cell, dict) or cell.get("status") not in COMPATIBILITY_STATUSES:
                fail(errors, f"{prefix}.{dimension} has invalid status")
                continue
            rationale = cell.get("rationale")
            evidence_paths = cell.get("evidence")
            if not isinstance(rationale, str) or not rationale.strip():
                fail(errors, f"{prefix}.{dimension} needs a rationale")
            if not isinstance(evidence_paths, list):
                fail(errors, f"{prefix}.{dimension}.evidence must be an array")
                continue
            if cell.get("status") == "executed" and not evidence_paths:
                fail(errors, f"{prefix}.{dimension} executed status requires evidence")
            manifest_path = "Packages/VoxboardShared/Tests/Fixtures/Persistence/v1/manifest.json"
            manifest_only = bool(evidence_paths) and all(
                relative == manifest_path for relative in evidence_paths
            )
            if cell.get("status") == "executed" and manifest_only:
                fail(errors, f"{prefix}.{dimension} cannot use manifest-only behavioral evidence")
            for relative in evidence_paths:
                if not isinstance(relative, str) or Path(relative).is_absolute() or ".." in Path(relative).parts:
                    fail(errors, f"{prefix}.{dimension} has invalid evidence path")
                elif not (ROOT / relative).exists():
                    fail(errors, f"{prefix}.{dimension} evidence does not exist: {relative}")
    required_store_capabilities = {
        cap_id for cap_id in capability_ids if cap_id.startswith("cap.store.")
    }
    missing_matrix_stores = sorted(required_store_capabilities - covered_store_capabilities)
    if missing_matrix_stores:
        fail(errors, f"compatibility matrix misses store capabilities: {missing_matrix_stores}")
    matrix_pending_by_capability = {
        item.get("capabilityID")
        for item in matrix_formats
        if isinstance(item, dict)
        and isinstance(item.get("dimensions"), dict)
        and any(
            isinstance(cell, dict) and cell.get("status") == "pending"
            for cell in item["dimensions"].values()
        )
    }
    for cap_id in required_store_capabilities:
        status = capabilities_by_id.get(cap_id, {}).get("status")
        has_pending = cap_id in matrix_pending_by_capability
        if has_pending and status != "fixture-needed":
            fail(errors, f"{cap_id} has pending compatibility cells but is not fixture-needed")
        if not has_pending and status != "verified":
            fail(errors, f"{cap_id} has no pending compatibility cells but is not verified")

    claims = data.get("requiredClaims")
    if not isinstance(claims, list) or not claims:
        fail(errors, "requiredClaims must be a non-empty array")
        claims = []
    for index, claim in enumerate(claims):
        if not isinstance(claim, dict):
            fail(errors, f"requiredClaims[{index}] must be an object")
            continue
        relative = claim.get("path")
        text = claim.get("text")
        cap_ids = claim.get("capabilityIDs")
        if not isinstance(relative, str) or not isinstance(text, str) or not isinstance(cap_ids, list) or not cap_ids:
            fail(errors, f"requiredClaims[{index}] needs path, text, and capabilityIDs")
            continue
        claim_path = ROOT / relative
        if not claim_path.is_file() or text not in claim_path.read_text(encoding="utf-8", errors="ignore"):
            fail(errors, f"required claim text not found in {relative}: {text!r}")
        for cap_id in cap_ids:
            if cap_id not in capability_ids:
                fail(errors, f"required claim maps unknown capability {cap_id}")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    args = parser.parse_args()
    ledger = args.ledger if args.ledger.is_absolute() else ROOT / args.ledger
    errors = validate(ledger)
    if errors:
        print("Android/Wear M0 validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    data = json.loads(ledger.read_text(encoding="utf-8"))
    print(
        "Android/Wear M0 validation passed: "
        f"{len(data['capabilities'])} capabilities, "
        f"{len(data['sourceInventories'])} source inventories, "
        f"{len(data['persistedKeyInventories'])} persisted-key inventories, "
        f"{len(data['requiredClaims'])} required claims."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
