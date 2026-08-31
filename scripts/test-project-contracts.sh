#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Voxboard.xcodeproj/project.pbxproj"

"$ROOT/scripts/validate-android-wear-m0.py"
python3 "$ROOT/Packages/contracts/scripts/convert_capabilities.py" --check
python3 "$ROOT/Packages/contracts/scripts/validate.py"
python3 "$ROOT/Packages/contracts/scripts/validate_toolchain.py"
python3 "$ROOT/Packages/contracts/scripts/validate_validation_definitions.py"
python3 -m unittest discover -s "$ROOT/Packages/contracts/tests"

python3 - "$ROOT" "$PROJECT" <<'PY'
from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
import json
import os
import struct
from urllib.parse import urlsplit
import json
import re
import sys

root = Path(sys.argv[1])
project_path = Path(sys.argv[2])
project = project_path.read_text()
errors: list[str] = []

purchase_source = (
    root / 'Packages/VoxboardShared/Sources/VoxboardShared/PurchaseAccess.swift'
).read_text()
storekit_config = json.loads((root / 'Voxboard/Voxboard.storekit').read_text())
storekit_products = {
    product['productID']: product
    for product in storekit_config.get('nonConsumableProducts', [])
}
expected_purchase_products = {
    'bontecou.Voxboard.unlock': False,
    'bontecou.Voxboard.family': True,
    'bontecou.Voxboard.familyUpgrade': True,
}
if set(storekit_products) != set(expected_purchase_products):
    errors.append(
        f'StoreKit product IDs are {sorted(storekit_products)}, '
        f'expected {sorted(expected_purchase_products)}'
    )
for product_id, family_sharable in expected_purchase_products.items():
    if product_id not in purchase_source:
        errors.append(f'PurchaseAccess does not recognize {product_id}')
    product = storekit_products.get(product_id)
    if product is not None and product.get('familySharable') is not family_sharable:
        errors.append(
            f'{product_id} familySharable={product.get("familySharable")}, '
            f'expected {family_sharable}'
        )

storekit_release_patch = (
    root / 'artifacts/releases/mac-family-restore-diagnostics.patch'
).read_text()
patched_paths = set(re.findall(r'^diff --git a/(.+?) b/', storekit_release_patch, flags=re.M))
expected_storekit_patch_paths = {
    'Packages/VoxboardShared/Sources/VoxboardShared/PurchaseAccess.swift',
    'Voxboard Mac/MacStoreManager.swift',
}
if patched_paths != expected_storekit_patch_paths:
    errors.append(
        f'independent Mac StoreKit patch changes {sorted(patched_paths)}, '
        f'expected only {sorted(expected_storekit_patch_paths)}'
    )

completion_audit_path = root / 'docs/recording-queue-storekit-completion-audit.md'
if not completion_audit_path.exists():
    errors.append('recording queue and StoreKit completion audit is missing')
else:
    completion_audit = completion_audit_path.read_text()
    for required in [
        'Overall status: **Not complete',
        '## Concrete objective',
        '## Requirement-to-artifact checklist',
        '## Constraint checklist',
        '## Verification surface',
        '## Unmet gates — completion is prohibited',
        'Physical-device recording matrix',
        'macOS signing and account matrix',
    ]:
        if required not in completion_audit:
            errors.append(f'completion audit is missing required gate {required}')
    for requirement_number in range(1, 11):
        if f'| {requirement_number} |' not in completion_audit:
            errors.append(f'completion audit does not map requirement {requirement_number}')

ios_runtime_evidence_path = root / 'artifacts/validation/ios-recording-queue-runtime-2026-08-11.md'
if not ios_runtime_evidence_path.exists():
    errors.append('iOS recording queue runtime evidence report is missing')
else:
    ios_runtime_evidence = ios_runtime_evidence_path.read_text()
    for required in [
        'Result: **PASS**',
        'Interrupted external WAV import',
        'Live claimed-job termination and relaunch recovery',
        'Runtime UI matrix',
        'adaptive two-column grid',
        'accessibility Dynamic Type sizes it switches to one column',
        'Vision OCR fails the harness',
        'does **not** claim to validate termination inside a production ASR backend',
        'does not cover physical microphone capture',
    ]:
        if required not in ios_runtime_evidence:
            errors.append(f'iOS runtime evidence is missing scope/evidence {required}')

ios_runtime_ui_paths = [
    root / 'artifacts/validation/ios-recording-queue-runtime-ui-failed-2026-08-11.png',
    root / 'artifacts/validation/ios-recording-queue-runtime-ui-failed-accessibility-2026-08-11.png',
    root / 'artifacts/validation/ios-recording-queue-runtime-ui-queued-2026-08-11.png',
    root / 'artifacts/validation/ios-recording-queue-runtime-ui-copy-2026-08-11.png',
]
for ios_runtime_ui_path in ios_runtime_ui_paths:
    if not ios_runtime_ui_path.exists():
        errors.append(f'iOS recording queue runtime UI evidence is missing: {ios_runtime_ui_path.name}')
        continue
    png = ios_runtime_ui_path.read_bytes()
    if len(png) < 24 or png[:8] != b'\x89PNG\r\n\x1a\n':
        errors.append(f'iOS recording queue runtime UI evidence is not a PNG: {ios_runtime_ui_path.name}')
    else:
        width, height = struct.unpack('>II', png[16:24])
        if width < 1_000 or height < 2_000:
            errors.append(
                f'iOS recording queue runtime UI evidence is too small: '
                f'{ios_runtime_ui_path.name} {width}x{height}'
            )

ios_runtime_test_path = root / 'scripts/test-ios-recording-queue-runtime.sh'
if not ios_runtime_test_path.exists():
    errors.append('isolated iOS recording queue runtime test is missing')
else:
    ios_runtime_test = ios_runtime_test_path.read_text()
    for required in [
        'simctl create',
        'simctl delete',
        'VOXBOARD_SHARED_CONTAINER_OVERRIDE',
        '--runtime-queue-validation --disable-release-notes',
        'recording_runtime_validation.wav',
        'VOXBOARD_IOS_RUNTIME_EVIDENCE_DIRECTORY',
        'content_size accessibility-extra-extra-large',
        'validate-recording-queue-screenshot.swift',
        '--runtime-queue-pause-after-claim',
        '--runtime-queue-activate-actions',
        'Runtime queue actions passed',
        'live claimed-job termination and relaunch recovery passed.',
        'queue action activation passed.',
        'Isolated iOS Simulator runtime queue validation passed.',
    ]:
        if required not in ios_runtime_test:
            errors.append(f'iOS queue runtime test is missing contract {required}')
    if not os.access(ios_runtime_test_path, os.X_OK):
        errors.append('iOS queue runtime test is not executable')

mac_runtime_evidence_path = root / 'artifacts/validation/mac-recording-queue-runtime-2026-08-11.md'
if not mac_runtime_evidence_path.exists():
    errors.append('macOS recording queue runtime evidence report is missing')
else:
    mac_runtime_evidence = mac_runtime_evidence_path.read_text()
    for required in [
        'Result: **PASS**',
        'Interrupted external WAV import',
        'Live claimed-job termination and relaunch recovery',
        'Two-process worker exclusion and failed-job retention',
        'Runtime UI rendering',
        'Vision OCR fails the harness',
        'Choose Preset, Reveal, Keep Audio, and Delete',
        'Process Now, Reveal, Keep Audio, and Delete',
        'completed deferred clipboard',
        'Copy, Reveal, Keep Audio, and Delete',
        'does **not** claim to validate termination inside a production ASR backend',
        'does not yet cover successful real microphone capture',
        'VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE=1',
        'BLOCKED',
    ]:
        if required not in mac_runtime_evidence:
            errors.append(f'macOS runtime evidence is missing scope/evidence {required}')

mac_runtime_ui_paths = [
    root / 'artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11.png',
    root / 'artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11-queued.png',
    root / 'artifacts/validation/mac-recording-queue-runtime-ui-2026-08-11-copy.png',
]
for mac_runtime_ui_path in mac_runtime_ui_paths:
    if not mac_runtime_ui_path.exists():
        errors.append(f'macOS recording queue runtime UI evidence is missing: {mac_runtime_ui_path.name}')
        continue
    png = mac_runtime_ui_path.read_bytes()
    if len(png) < 24 or png[:8] != b'\x89PNG\r\n\x1a\n':
        errors.append(f'macOS recording queue runtime UI evidence is not a PNG: {mac_runtime_ui_path.name}')
    else:
        width, height = struct.unpack('>II', png[16:24])
        if width < 800 or height < 400:
            errors.append(
                f'macOS recording queue runtime UI evidence is too small: '
                f'{mac_runtime_ui_path.name} {width}x{height}'
            )

screenshot_validator_path = root / 'scripts/validate-recording-queue-screenshot.swift'
if not screenshot_validator_path.exists():
    errors.append('recording queue semantic screenshot validator is missing')
else:
    screenshot_validator = screenshot_validator_path.read_text()
    for required in [
        'VNRecognizeTextRequest',
        'ios-failed-accessibility',
        'ios-copy-ready',
        'mac-copy-ready',
        'Forbidden:',
    ]:
        if required not in screenshot_validator:
            errors.append(f'recording queue screenshot validator is missing {required}')
    if not os.access(screenshot_validator_path, os.X_OK):
        errors.append('recording queue screenshot validator is not executable')

mac_runtime_test_path = root / 'scripts/test-mac-recording-queue-runtime.sh'
if not mac_runtime_test_path.exists():
    errors.append('isolated macOS recording queue runtime test is missing')
else:
    mac_runtime_test = mac_runtime_test_path.read_text()
    for required in [
        'VOXBOARD_SHARED_CONTAINER_OVERRIDE',
        '--runtime-queue-validation',
        'recording_runtime_validation.wav',
        'VOXBOARD_RUNTIME_SCREENSHOT_OUTPUT',
        '--localization-screenshot 06-recording-queue',
        'COPY_SCREENSHOT_OUTPUT',
        'validate-recording-queue-screenshot.swift',
        '"delivery"] = {"clipboard": {}}',
        '--runtime-queue-pause-after-claim',
        'Isolated macOS live claimed-job termination and relaunch recovery passed.',
        'Isolated macOS two-process worker lease passed.',
        'VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE',
        'codesign --force --deep --sign -',
        'runtime-microphone.entitlements',
        'com.apple.security.device.audio-input',
        '--runtime-microphone-capture',
        'Isolated real macOS microphone capture and durable queue handoff passed.',
        'RUNTIME_ROOT="$(mktemp -d "$RUNTIME_PARENT/mac.XXXXXX")"',
        'realpath "$RUNTIME_ROOT"',
        'Refusing symlinked runtime validation parent',
        'attemptCount',
    ]:
        if required not in mac_runtime_test:
            errors.append(f'macOS queue runtime test is missing contract {required}')
    if not os.access(mac_runtime_test_path, os.X_OK):
        errors.append('macOS queue runtime test is not executable')
    if 'VOXBOARD_MAC_APP' in mac_runtime_test:
        errors.append('macOS queue runtime test must not accept caller-supplied apps')

app_constants_source = (root / 'Packages/VoxboardShared/Sources/VoxboardShared/AppConstants.swift').read_text()
ios_app_source = (root / 'Voxboard/VoxboardApp.swift').read_text()
ios_recorder_source = (root / 'Voxboard/PersistentRecorder.swift').read_text()
mac_app_source = (root / 'Voxboard Mac/VoxboardMacApp.swift').read_text()
mac_recorder_source = (root / 'Voxboard Mac/MacRecorder.swift').read_text()
debug_hook_contracts = [
    (
        'AppConstants',
        app_constants_source,
        '#if DEBUG\n    public static let debugSharedContainerOverrideEnvironmentKey =',
        '"VOXBOARD_SHARED_CONTAINER_OVERRIDE"',
        'environment[debugSharedContainerOverrideEnvironmentKey]',
    ),
    (
        'VoxboardApp',
        ios_app_source,
        '#if DEBUG\n    private static let runtimeQueueValidationArgument =',
        '"--runtime-queue-validation"',
        'arguments.contains(Self.runtimeQueueValidationArgument)',
    ),
    (
        'PersistentRecorder',
        ios_recorder_source,
        '#if DEBUG\n    private static let runtimeQueuePauseAfterClaimArgument =',
        '"--runtime-queue-pause-after-claim"',
        'arguments.contains(\n                PersistentRecorder.runtimeQueuePauseAfterClaimArgument',
    ),
    (
        'VoxboardMacApp',
        mac_app_source,
        '#if DEBUG\n    private static let runtimeQueueValidationArgument =',
        '"--runtime-queue-validation"',
        'arguments.contains(Self.runtimeQueueValidationArgument)',
    ),
    (
        'MacRecorder',
        mac_recorder_source,
        '#if DEBUG\n    private static let runtimeQueuePauseAfterClaimArgument =',
        '"--runtime-queue-pause-after-claim"',
        'arguments.contains(\n                MacRecorder.runtimeQueuePauseAfterClaimArgument',
    ),
    (
        'MacRecorder microphone',
        mac_recorder_source,
        'private static let runtimeMicrophoneCaptureArgument =',
        '"--runtime-microphone-capture"',
        'arguments.contains(Self.runtimeMicrophoneCaptureArgument)',
    ),
]
for source_name, source, declaration, raw_value, use in debug_hook_contracts:
    if declaration not in source or use not in source or source.count(raw_value) != 1:
        errors.append(
            f'{source_name} runtime validation value must be declared only inside DEBUG '
            'and referenced through that unavailable-in-Release symbol'
        )

recording_queue_views = (root / 'Voxboard App Shared/RecordingQueueViews.swift').read_text()
action_debug_match = re.search(
    r'#if DEBUG\n(?P<body>.*?)\n    #endif\n\n    private func retryAllFailedJobs',
    recording_queue_views,
    flags=re.S,
)
if action_debug_match is None:
    errors.append('recording queue action validation task and method must share one DEBUG block')
else:
    action_debug_body = action_debug_match.group('body')
    required_guard = '''guard processInfo.arguments.contains("--runtime-queue-validation"),
                  processInfo.arguments.contains("--runtime-queue-activate-actions"),
                  let overridePath = processInfo.environment[
                    AppConstants.debugSharedContainerOverrideEnvironmentKey
                  ],
                  !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let overrideURL = Optional(
                    URL(fileURLWithPath: overridePath, isDirectory: true)
                        .standardizedFileURL
                  ),
                  overrideURL.path.hasPrefix(
                    URL(
                        fileURLWithPath: "/tmp/VoxQueueRuntimeValidation",
                        isDirectory: true
                    ).standardizedFileURL.path + "/"
                  ),
                  AppConstants.sharedContainerURL?.standardizedFileURL.path
                    == overrideURL.path else { return }'''
    for required in [
        required_guard,
        '.task {',
        'private func activateRuntimeValidationActions(',
        'private func activateExtendedRuntimeValidationActions()',
        '"--runtime-queue-activate-extended-actions"',
        'await queue.retry(failed)',
        'await queue.processNow(queued)',
        'await queue.updateRetention(queued, policy: .permanent)',
        'await queue.acknowledgeCopiedResult(copyReady)',
        'await queue.discard(currentQueued)',
        'let retryAllJobs = queue.retryAllEligibleJobs.filter {',
        '"runtime-retry-one.wav"',
        '"runtime-retry-two.wav"',
        '$0.originalFilename.map(retryFilenames.contains) == true',
        '$0.originalFilename == "runtime-timed.wav"',
        '$0.originalFilename == "runtime-delete-after.wav"',
        'await queue.updateRetention(\n            timed,\n            policy: .timed(',
        'await queue.updateRetention(\n            deleteAfterSuccess,\n            policy: .deleteAfterSuccess',
    ]:
        if required not in action_debug_body:
            errors.append(
                f'recording queue action validation DEBUG/isolation block is missing {required}'
            )
if recording_queue_views.count('"--runtime-queue-activate-actions"') != 1:
    errors.append('recording queue action activation argument must appear once inside its DEBUG hook')

ios_runtime_harness = (root / 'scripts/test-ios-recording-queue-runtime.sh').read_text()
for required in [
    'expected.write_text(json.dumps(created_ids, indent=2, sort_keys=True))',
    'set(retry_ids) != {expected["retry-one"], expected["retry-two"]}',
    'retention_ids != [expected["timed"], expected["delete-after"]]',
]:
    if required not in ios_runtime_harness:
        errors.append(f'iOS extended action harness is missing exact fixture-ID check {required}')

for required in [
    '#if os(macOS)\n        HStack(spacing: 12)',
    'LazyVGrid(',
    'GridItem(.adaptive(minimum: 135)',
    'dynamicTypeSize.isAccessibilitySize',
    'return [GridItem(.flexible())]',
    '.navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)',
]:
    if required not in recording_queue_views:
        errors.append(f'recording queue compact action layout is missing {required}')

storekit_preflight_path = root / 'scripts/preflight-mac-family-restore-release.sh'
if not storekit_preflight_path.exists():
    errors.append('independent Mac StoreKit release preflight script is missing')
else:
    storekit_preflight = storekit_preflight_path.read_text()
    for required in [
        'mac-family-restore-diagnostics.patch',
        'CODE_SIGNING_ALLOWED=NO',
        'asc iap list',
        'asc builds list',
        'Apple Distribution',
        'no local provisioning profile',
        'Release upload is intentionally not attempted',
        'Never feed an untrusted or stale patch into a build',
        'set +e',
    ]:
        if required not in storekit_preflight:
            errors.append(f'Mac StoreKit preflight is missing safety contract {required}')
    for forbidden in ['asc builds upload', 'asc publish', '--confirm', 'git worktree prune']:
        if forbidden in storekit_preflight:
            errors.append(f'Mac StoreKit preflight must remain read-only: {forbidden}')
    if not os.access(storekit_preflight_path, os.X_OK):
        errors.append('Mac StoreKit preflight script is not executable')

widget_bundle_id = 'bontecou.Voxboard.Voxboard-Widget'
blocks = re.findall(
    r'\b[0-9A-F]+ /\* (?:Debug|Release) \*/ = \{\n\s*isa = XCBuildConfiguration;\n\s*buildSettings = \{(?P<body>.*?)\n\s*\};\n\s*name = (?:Debug|Release);\n\s*\};',
    project,
    flags=re.S,
)
widget_blocks = [body for body in blocks if widget_bundle_id in body]
if len(widget_blocks) != 2:
    errors.append(f'expected 2 widget build configurations, found {len(widget_blocks)}')

expected_entitlements = 'CODE_SIGN_ENTITLEMENTS = "Voxboard Widget/VoxboardWidget.entitlements";'
for index, body in enumerate(widget_blocks, start=1):
    if expected_entitlements not in body:
        errors.append(f'widget configuration {index} does not use VoxboardWidget.entitlements')
    match = re.search(r'IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);', body)
    if match is None:
        errors.append(f'widget configuration {index} has no explicit iOS deployment target')
    elif match.group(1).strip() != '17.6':
        errors.append(
            f'widget configuration {index} deployment target is {match.group(1).strip()}, expected 17.6'
        )

if 'CODE_SIGN_ENTITLEMENTS = "Voxboard WidgetExtension.entitlements";' in project:
    errors.append('widget target still references the legacy root entitlement file')
legacy_widget_entitlements = root / 'Voxboard WidgetExtension.entitlements'
if legacy_widget_entitlements.exists():
    errors.append('legacy root widget entitlement file still exists')
if '/* Voxboard WidgetExtension.entitlements */' in project:
    errors.append('Xcode project still contains the legacy widget entitlement file reference')

expected_group = 'group.bontecou.Voxboard'
entitlement_paths = [
    root / 'Voxboard/Voxboard.entitlements',
    root / 'Voxboard Keyboard/VoxboardKeyboard.entitlements',
    root / 'Voxboard Widget/VoxboardWidget.entitlements',
    root / 'Voxboard Share Extension/VoxboardShare.entitlements',
    root / 'Voxboard Mac/VoxboardMac.entitlements',
]
for path in entitlement_paths:
    content = path.read_text()
    if expected_group not in content:
        errors.append(f'{path.relative_to(root)} does not use {expected_group}')
    if 'group.bontecou.VoxVault' in content:
        errors.append(f'{path.relative_to(root)} still uses the legacy VoxVault App Group')

mac_entitlements = (root / 'Voxboard Mac/VoxboardMac.entitlements').read_text()
if not re.search(
    r'<key>\s*com\.apple\.security\.network\.client\s*</key>\s*<true\s*/>',
    mac_entitlements,
):
    errors.append('macOS app must allow outgoing network connections for model downloads')

main_target_matches = re.findall(
    r'PRODUCT_BUNDLE_IDENTIFIER = bontecou\.Voxboard;.*?IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);',
    project,
    flags=re.S,
)
if not main_target_matches or any(value.strip() != '17.6' for value in main_target_matches):
    errors.append('main app deployment target contract is not iOS 17.6')

share_bundle_id = 'bontecou.Voxboard.ShareExtension'
share_blocks = [body for body in blocks if share_bundle_id in body]
if len(share_blocks) != 2:
    errors.append(f'expected 2 share-extension build configurations, found {len(share_blocks)}')
for index, body in enumerate(share_blocks, start=1):
    if 'CODE_SIGN_ENTITLEMENTS = "Voxboard Share Extension/VoxboardShare.entitlements";' not in body:
        errors.append(f'share configuration {index} does not use the shared App Group entitlement')
    if 'INFOPLIST_FILE = "Voxboard Share Extension/Info.plist";' not in body:
        errors.append(f'share configuration {index} does not use the checked-in extension Info.plist')
    if 'IPHONEOS_DEPLOYMENT_TARGET = 17.6;' not in body:
        errors.append(f'share configuration {index} deployment target is not 17.6')

if 'Voxboard Share Extension.appex in Embed Foundation Extensions' not in project:
    errors.append('main app does not embed the share extension')
if 'productName = VoxboardCaptureCore;' not in project:
    errors.append('share extension is not linked to the capture core package product')

share_info = (root / 'Voxboard Share Extension/Info.plist').read_text()
for required in [
    'com.apple.share-services',
    'NSExtensionActivationSupportsText',
    'NSExtensionActivationSupportsWebURLWithMaxCount',
    'NSExtensionActivationSupportsImageWithMaxCount',
    'NSExtensionActivationSupportsFileWithMaxCount',
]:
    if required not in share_info:
        errors.append(f'share extension Info.plist is missing {required}')

main_info = (root / 'Voxboard/Info.plist').read_text()
for required in [
    'NSCameraUsageDescription',
    'NSPhotoLibraryUsageDescription',
    'NSMicrophoneUsageDescription',
    'NSLocationWhenInUseUsageDescription',
]:
    if required not in main_info:
        errors.append(f'main app Info.plist is missing {required}')

location_purpose_contracts = [
    (
        root / 'Voxboard/Info.plist',
        root / 'Voxboard/InfoPlist.xcstrings',
        'NSLocationWhenInUseUsageDescription',
        'Vox.md gets your location once when you insert a map link, or when you send or stop recording with a location-enabled Capture Preset.',
    ),
    (
        root / 'Voxboard Share Extension/Info.plist',
        root / 'Voxboard Share Extension/InfoPlist.xcstrings',
        'NSLocationWhenInUseUsageDescription',
        'When location metadata is enabled for a Capture Preset, Vox.md gets one location when you send shared content.',
    ),
    (
        root / 'Voxboard Watch/Info.plist',
        root / 'Voxboard Watch/InfoPlist.xcstrings',
        'NSLocationWhenInUseUsageDescription',
        'When location is enabled for a Capture Preset, Vox.md gets one location from this Apple Watch when recording stops.',
    ),
    (
        root / 'Voxboard Mac/Info.plist',
        root / 'Voxboard Mac/InfoPlist.xcstrings',
        'NSLocationUsageDescription',
        'When location is enabled for a Capture Preset, Vox.md gets one location when you send or stop a recording.',
    ),
]
expected_location_locales = {
    'ar', 'bn', 'de', 'en', 'es', 'fr', 'hi', 'id', 'it', 'ja', 'ko', 'nl',
    'pl', 'pt-BR', 'ru', 'ta', 'th', 'tr', 'uk', 'ur', 'vi', 'zh-Hans', 'zh-Hant',
}
for plist_path, catalog_path, key, english_value in location_purpose_contracts:
    plist = plist_path.read_text()
    if key not in plist or f'<string>{english_value}</string>' not in plist:
        errors.append(f'{plist_path.relative_to(root)} has stale location purpose copy')
    catalog = json.loads(catalog_path.read_text())
    entry = catalog.get('strings', {}).get(key, {})
    localizations = entry.get('localizations', {})
    if set(localizations) != expected_location_locales:
        errors.append(f'{catalog_path.relative_to(root)} lacks complete location purpose locale coverage')
    english_unit = localizations.get('en', {}).get('stringUnit', {})
    if english_unit.get('value') != english_value:
        errors.append(f'{catalog_path.relative_to(root)} location purpose English does not match Info.plist')
    untranslated = [
        locale for locale, value in localizations.items()
        if locale != 'en' and value.get('stringUnit', {}).get('value') == english_value
    ]
    if untranslated:
        errors.append(
            f'{catalog_path.relative_to(root)} labels English location purpose copy as translated: {untranslated}'
        )

widget_bundle = (root / 'Voxboard Widget/VoxboardWidgetBundle.swift').read_text()
if 'VoxboardCaptureWidget()' not in widget_bundle:
    errors.append('widget bundle does not expose the Quick Capture widget')

capture_widget = (root / 'Voxboard Widget/VoxboardCaptureWidget.swift').read_text()
for required in [
    '.systemMedium',
    '.systemLarge',
    'captureURL(action: "photos")',
    'captureURL(action: "camera")',
    'captureURL(action: "files")',
    'captureURL(action: "link")',
    'captureURL(action: "scan")',
    'captureURL(action: "sketch")',
    'captureURL(action: "screenshots")',
    'captureURL(action: "voice")',
]:
    if required not in capture_widget:
        errors.append(f'Quick Capture widget is missing actionable contract {required}')

app_source = (root / 'Voxboard/VoxboardApp.swift').read_text()
if 'url.absoluteString' in app_source:
    errors.append('app URL handling can persist private deep-link query values')

root_view_source = (root / 'Voxboard/Views/RootView.swift').read_text()
if re.search(r'case[^\n]*\blisten\b', root_view_source) or 'case .listen:' in root_view_source:
    errors.append('Listen must not remain a top-level app destination')
for required in [
    'case capture',
    'case settings',
    'persistentRecorder: persistentRecorder',
    'pendingKeyboardLaunch: $pendingKeyboardLaunch',
]:
    if required not in root_view_source:
        errors.append(f'inline Capture recording integration is missing {required}')
for removed_destination in ['case .model:', 'case .presets:', 'case .vox:', 'tab_model', 'tab_presets', 'tab_vox']:
    if removed_destination in root_view_source:
        errors.append(f'Models and Capture Presets must live under Settings, not app navigation: {removed_destination}')
settings_source = (root / 'Voxboard/Views/MetaSettingsView.swift').read_text()
for required in ['customizationSection', 'ModelTabView()', 'CapturePresetSettingsView()']:
    if required not in settings_source:
        errors.append(f'Settings customization navigation is missing {required}')
flow_settings_source = (root / 'Voxboard/Views/FlowSettingsView.swift').read_text()
recording_only_settings_gate = '''            if flow.watchOutputMode != .recordingOnly {
                voiceProcessingSection
                postProcessingSection
                ownedDestinationSection
                if flow.captureDestinationID == nil {
                    fileExportSection
                }
                if showsFrontmatterSection {
                    frontmatterSection
                    locationMetadataSection
                }
                audioExportSection
            }'''
if recording_only_settings_gate not in flow_settings_source:
    errors.append('Recording Only Apple Watch presets must hide transcript workflow settings')
if (root / 'Voxboard/Views/HomeView.swift').exists():
    errors.append('the standalone Home/Listen recording view must be removed')
if (root / 'Voxboard/Views/CaptureHistoryView.swift').exists():
    errors.append('the separate Capture history view must be removed in favor of unified history')
for required in ['case "listen":', 'rootDestination = .capture', 'pendingKeyboardLaunch = true']:
    if required not in app_source:
        errors.append(f'legacy recording launch routing is missing {required}')

analytics_source = (
    root / 'Packages/VoxboardShared/Sources/VoxboardShared/Analytics/OnboardingAnalyticsClient.swift'
).read_text()
release_default = re.search(r'#else\s+(true|false)\s+#endif', analytics_source)
if release_default is None or release_default.group(1) != 'false':
    errors.append('release analytics must remain disabled by default')

share_source = (root / 'Voxboard Share Extension/ShareViewController.swift').read_text()
for required in [
    'CaptureInputBudget()',
    'reserveSharedItems(providers.count)',
    'reserveText(characters:',
    'reserveAsset(bytes:',
    'removeStagingDirectory()',
    'isQueuedForLater',
    'cancellationRequested',
    '.disabled(model.isQueuedForLater)',
]:
    if required not in share_source:
        errors.append(f'share extension hardening is missing {required}')
if 'providers.prefix(' in share_source:
    errors.append('share extension silently truncates shared providers instead of rejecting overflow')

quick_capture_source = (root / 'Voxboard/Views/QuickCaptureView.swift').read_text()
multimodal_capture_source = (root / 'Voxboard/Capture/MultimodalCaptureViews.swift').read_text()
watch_queue_source = (root / 'Voxboard/Views/WatchRecordingQueueView.swift').read_text()
quick_capture_ui_source = quick_capture_source + multimodal_capture_source + watch_queue_source
watch_bridge_source = (root / 'Voxboard Watch Shared/WatchPhoneBridge.swift').read_text()
watch_controller_source = (root / 'Voxboard/WatchRecordingController.swift').read_text()
watch_pipeline_source = (root / 'Voxboard/WatchRecordingPipeline.swift').read_text()
watch_inbox_source = (root / 'Voxboard/WatchRecordingInbox.swift').read_text()
watch_background_lease_source = (root / 'Voxboard/WatchRecordingBackgroundLease.swift').read_text()
watch_background_tests_source = (root / 'VoxboardTests/WatchRecordingBackgroundLeaseTests.swift').read_text()
watch_app_delegate_source = (root / 'Voxboard/VoxboardAppDelegate.swift').read_text()
watch_recorder_source = (root / 'Voxboard Watch/WatchLocalRecorder.swift').read_text()
watch_queue_store_source = (
    root / 'Voxboard Watch Shared/WatchLocalRecordingQueueStore.swift'
).read_text()
watch_view_source = (root / 'Voxboard Watch/WatchRecorderView.swift').read_text()

watch_receive_marker = 'nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile)'
watch_receive_start = watch_controller_source.find(watch_receive_marker)
watch_receive_end = watch_controller_source.find('\n}\n\nnonisolated enum WatchRecordingPayloadKey', watch_receive_start)
if watch_receive_start < 0 or watch_receive_end < 0:
    errors.append('iPhone Watch file receive callback could not be inspected')
else:
    watch_receive_source = watch_controller_source[watch_receive_start:watch_receive_end]
    lease_begin = watch_receive_source.find('WatchRecordingBackgroundLease.begin(')
    inbox_enqueue = watch_receive_source.find('WatchRecordingInbox.shared.enqueue(')
    main_actor_handoff = watch_receive_source.find('Task { @MainActor')
    if lease_begin < 0 or inbox_enqueue < 0 or lease_begin >= inbox_enqueue:
        errors.append('Watch file receive must acquire its background lease before durable inbox enqueue')
    if main_actor_handoff < 0 or main_actor_handoff <= inbox_enqueue:
        errors.append('Watch file receive must enqueue synchronously before its MainActor handoff')
    for required in [
        'backgroundLease.end(.enqueueFailed)',
        'backgroundLease.end(.pipelineUnavailable)',
        'pipeline.recordingDidArrive(',
        'backgroundLease: backgroundLease',
    ]:
        if required not in watch_receive_source:
            errors.append(f'Watch file receive background lease handoff is missing {required}')

for required in [
    'activeBackgroundLease',
    'pendingBackgroundLease',
    'func backgroundLeaseDidExpire(_ token: UUID)',
    'processingTask?.cancel()',
    'completedLease?.end(.completed)',
    'WatchRecordingBackgroundExecutionPolicy.shouldStart(',
]:
    if required not in watch_pipeline_source:
        errors.append(f'Watch background pipeline ownership is missing {required}')
if 'beginBackgroundTaskIfNeeded' in watch_pipeline_source:
    errors.append('Watch pipeline must not retain the old late background-task acquisition path')
if '@UIApplicationDelegateAdaptor(VoxboardAppDelegate.self)' not in app_source:
    errors.append('iOS must install its WatchConnectivity application delegate before scene presentation')
for required in [
    'didFinishLaunchingWithOptions',
    'WatchRecordingController.shared.activateForBackgroundDelivery()',
]:
    if required not in watch_app_delegate_source:
        errors.append(f'iOS background WatchConnectivity launch hook is missing {required}')
if 'func activateForBackgroundDelivery()' not in watch_controller_source:
    errors.append('Watch controller must expose early application-delegate activation')
for required in [
    'private func wakeCompanionForQueuedRecording(using session: WCSession)',
    'session.sendMessage(payload)',
    'wakeCompanionForQueuedRecording(using: session)',
]:
    if required not in watch_bridge_source:
        errors.append(f'Watch completed-file wake hint is missing {required}')
if 'Open Vox.md to review a Watch recording delivery problem.' not in watch_pipeline_source:
    errors.append('Watch recording failure notifications must use privacy-safe generic copy')
if 'content.body = message' in watch_pipeline_source:
    errors.append('Watch recording failure notifications must not expose folder/provider errors')
for required in [
    'nonisolated final class WatchRecordingBackgroundLease',
    'private let lock = NSLock()',
    'case expired',
    'expirationCallback(token)',
    'service.end(identifier)',
]:
    if required not in watch_background_lease_source:
        errors.append(f'Watch background lease safety is missing {required}')
watch_sidecar_write = watch_inbox_source.find('try saveSidecarUnlocked(newItem)')
watch_durable_move = watch_inbox_source.rfind('try FileManager.default.moveItem(at: fileURL, to: destination)')
if watch_sidecar_write < 0 or watch_durable_move < 0 or watch_sidecar_write >= watch_durable_move:
    errors.append('Watch inbox must journal metadata before moving the temporary WCSession file')
watch_filename_reservation = watch_pipeline_source.find('updated.reservedOutputFilename = reservedFilename')
watch_files_copy = watch_pipeline_source.find('try exporter.copy(')
if watch_filename_reservation < 0 or watch_files_copy < 0 or watch_filename_reservation >= watch_files_copy:
    errors.append('Recording Only delivery must persist its filename reservation before copying to Files')
if 'force-quitting Vox.md prevents background delivery' not in flow_settings_source:
    errors.append('Recording Only settings must disclose force-quit background delivery limits')
for required in [
    'testExpirationDuringBeginEndsReturnedIdentifier',
    'testInvalidIdentifierNeverAttemptsUIKitEnd',
    'testBackgroundExecutionPolicyRequiresForegroundOrActiveLease',
    'testRecordingOnlyPipelineCopiesQueuedWatchFileWithoutUIResume',
]:
    if required not in watch_background_tests_source:
        errors.append(f'Watch background delivery test coverage is missing {required}')
if not (root / 'Voxboard.xcodeproj/xcshareddata/xcschemes/VoxboardTests.xcscheme').exists():
    errors.append('Watch background delivery tests must have a shared Xcode scheme')
for protocol_key in [
    'presetSummaries',
    'presetSelectionAvailable',
    'requestedPresetID',
    'presetSelectionRequestID',
    'presetSelectionEpoch',
    'presetSelectionSequence',
    'presetSelectionResult',
    'stateEpoch',
]:
    declaration = f'static let {protocol_key} = "{protocol_key}"'
    if declaration not in watch_bridge_source or declaration not in watch_controller_source:
        errors.append(f'Watch preset protocol key is not mirrored by Watch and iPhone: {protocol_key}')
for source_name, source in [
    ('Watch bridge', watch_bridge_source),
    ('iPhone Watch controller', watch_controller_source),
]:
    if 'case selectPreset' not in source:
        errors.append(f'{source_name} is missing the selectPreset command')
for required in [
    'WatchConfirmedPresetStore',
    'PendingWatchPresetSelection',
    'remoteSnapshotIsCurrent',
    'resendPendingPresetSelectionIfNeeded',
]:
    if required not in watch_bridge_source:
        errors.append(f'Watch preset selection safety is missing {required}')
for required in [
    'let epoch: Int64',
    'let sequence: Int64',
    'Int64(now.timeIntervalSince1970 * 1_000)',
]:
    if required not in watch_bridge_source:
        errors.append(f'Watch preset counters must remain arm64_32-safe: {required}')
if 'Int(Date().timeIntervalSince1970 * 1_000)' in watch_bridge_source:
    errors.append('Watch preset epoch overflows 32-bit Int on physical Watch hardware')
for required in [
    'WatchLocalRecordingQueueStore',
    'loadRecoveringInterruptedCapture',
    'saveActiveRecording',
    'index-corrupt-',
]:
    if required not in watch_queue_store_source:
        errors.append(f'Watch queue compatibility store is missing {required}')
if 'typealias QueuedRecording = WatchLocalQueuedRecording' not in watch_recorder_source:
    errors.append('Watch recorder is not consuming the compatibility queue model')

for required in [
    'hasPresetSelectionAvailabilityPayload',
    'selectedPresetSnapshot != nil',
]:
    if required not in watch_recorder_source:
        errors.append(f'Watch local recording preset guard is missing {required}')
for required in [
    'WatchCapturePresetPickerView',
    'bridge.selectPreset(id:',
    'Finish the current recording before changing presets.',
]:
    if required not in watch_view_source:
        errors.append(f'Watch Capture Preset picker is missing {required}')
for required in [
    'CaptureFilePicker(',
    'UIDocumentPickerViewController(',
    'contentTypes: [.data]',
    'reserveSharedItems(urls.count)',
    'matching: .screenshots',
    'CaptureRoutePickerView(viewModel: viewModel)',
    'capture_destination_banner',
    'HistoryView(viewModel: viewModel)',
    'locationRequestTask?.cancel()',
    'voiceCaptureButton',
    'voiceCaptureDetailsBar',
    'Long-press for detailed recording controls.',
    'capture_recording_details',
    'capture_voice_recording',
    'Add to Draft',
    'Send Immediately',
    'capture_vox_selector',
    'Use Preset destination defaults',
    'Attach audio to Capture',
    'capture_keyboard_listening',
    'capture_audio_import',
    'Watch Recordings',
]:
    if required not in quick_capture_ui_source:
        errors.append(f'Quick Capture hardening is missing {required}')

capture_route_picker_source = (root / 'Voxboard/Capture/CaptureRoutePickerView.swift').read_text()
for required in [
    'Set Up Destination',
    'CaptureDestinationEditorView(',
    'viewModel.saveSelectedPresetDestination(destination)',
]:
    if required not in capture_route_picker_source:
        errors.append(f'inline Capture destination setup is missing {required}')

quick_capture_view_model_source = (root / 'Voxboard App Shared/CaptureComposerViewModel.swift').read_text()
for required in [
    'saveSelectedPresetDestination',
    'CapturePresetStore.saveFlows',
    'refreshVoxProfiles()',
]:
    if required not in quick_capture_view_model_source:
        errors.append(f'Capture Preset destination persistence is missing {required}')

history_view_source = (root / 'Voxboard/Views/HistoryView.swift').read_text()
for required in ['UnifiedHistoryItem', 'viewModel.historyRecords', 'Search history', 'viewModel.clearHistory()']:
    if required not in history_view_source:
        errors.append(f'unified Capture and transcript history is missing {required}')

composer_source = (root / 'Voxboard/Capture/MarkdownComposerTextView.swift').read_text()
for required in ['accessibilityLabel = String(localized: "Capture note")', 'quick_capture_text', 'selectedRange']:
    if required not in composer_source:
        errors.append(f'selection-aware Markdown composer is missing {required}')

toolbar_source = '\n'.join(
    (root / path).read_text()
    for path in [
        'Voxboard/Capture/CaptureEditorToolbar.swift',
        'Voxboard App Shared/CaptureToolbarPreferences.swift',
    ]
)
for required in ['Set due date', 'Internal link', 'Insert current location', 'Change text case']:
    if required not in toolbar_source:
        errors.append(f'capture Markdown utility toolbar is missing {required}')

location_source = (
    root / 'Packages/VoxboardShared/Sources/VoxboardShared/CaptureLocationService.swift'
).read_text()
for required in ['requestLocation()', 'withTaskCancellationHandler', 'CaptureLocationError.timedOut']:
    if required not in location_source:
        errors.append(f'one-shot location service is missing {required}')
for forbidden in ['startUpdatingLocation()', 'startMonitoringSignificantLocationChanges()']:
    if forbidden in location_source:
        errors.append(f'one-shot location service must not call {forbidden}')

persistent_recorder_source = (root / 'Voxboard/PersistentRecorder.swift').read_text()
for required in [
    'case captureDraft(attachAudio: Bool)',
    'case runVox(flowID: String)',
    'captureDraftEventHandler?(.audio',
    'captureDraftEventHandler?(.transcript',
]:
    if required not in persistent_recorder_source:
        errors.append(f'Capture recording completion routing is missing {required}')
voice_session_source = (root / 'Voxboard/Capture/QuickCaptureVoiceSession.swift').read_text()
for required in [
    'CaptureVoiceLifecycle()',
    'beginInterruptionObservation',
    'expectedGeneration:',
    'transcriptionFinished(generation:',
    'persistCurrentRecording(generation:',
    'discardStagedRecording()',
    'purgeStaleTemporaryAudio()',
]:
    if required not in voice_session_source:
        errors.append(f'capture voice lifecycle hardening is missing {required}')

history_source = (
    root / 'Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureHistoryStore.swift'
).read_text()
for required in [
    'public struct CaptureHistoryRecord',
    'relativeNotePath',
    'attachmentCount',
    'failureCategory',
]:
    if required not in history_source:
        errors.append(f'privacy-limited capture history is missing {required}')

secure_io = (root / 'Packages/VoxboardShared/Sources/VoxboardCaptureCore/SecureCaptureFileIO.swift').read_text()
if 'O_NOFOLLOW' not in secure_io or 'renameat(' not in secure_io:
    errors.append('descriptor-relative symlink-safe capture writes are missing')
voice_exporter = (
    root / 'Packages/VoxboardShared/Sources/VoxboardShared/TranscriptCaptureDestinationExporter.swift'
).read_text()
for required in [
    'let requestID = transcript.id',
    'try await inbox.enqueue(request)',
    'attachmentsFolderNameOverride',
    'audioPreparationFailed',
    'Never construct a reduced transcript-only retry',
]:
    if required not in voice_exporter:
        errors.append(f'durable idempotent voice delivery is missing {required}')

inbox_source = (
    root / 'Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureInbox.swift'
).read_text()
for required in [
    'CaptureCompletionReceipt',
    'sanitizeLegacyCompletedRequests()',
    'privacy-safe tombstone',
]:
    if required not in inbox_source:
        errors.append(f'completed inbox privacy hardening is missing {required}')

if 'URLQueryItem(name: "source", value: "widget")' not in capture_widget:
    errors.append('Quick Capture widget does not retain widget provenance')
if 'URLQueryItem(name: "preset", value: voxID)' not in capture_widget:
    errors.append('Quick Capture widget does not retain its selected Capture Preset context')
quick_capture_model = (root / 'Voxboard App Shared/CaptureComposerViewModel.swift').read_text()
for required in [
    'initialLoadTask',
    'draft.selectDestination(destinationID)',
    'requestCaptureSource',
    'appendRecordedTranscript',
    'stageRecordedAudio',
]:
    if required not in quick_capture_model:
        errors.append(f'Quick Capture cold-launch routing hardening is missing {required}')

intent_source = (root / 'Voxboard App Shared/CaptureAppIntents.swift').read_text()
shortcut_source = (root / 'Voxboard/VoxboardShortcutsProvider.swift').read_text()
if '@available(iOS 18.0, *)' in intent_source or '@available(iOS 18.0, *)' in shortcut_source:
    errors.append('capture App Intents must remain available on the supported iOS 17.6 deployment target')

shared_capture_model = root / 'Voxboard App Shared/CaptureComposerViewModel.swift'
if not shared_capture_model.exists():
    errors.append('the durable Capture composer model is not in the shared app source group')
if project.count('AA8000012FB00000AABB0001 /* Voxboard App Shared */') < 3:
    errors.append('the shared Capture app source group is not attached to both iOS and macOS targets')

mac_workspace = root / 'Voxboard Mac/MacCaptureWorkspaceView.swift'
mac_editor = root / 'Voxboard Mac/MacMarkdownComposerTextView.swift'
mac_root = (root / 'Voxboard Mac/MacRootView.swift').read_text()
if not mac_workspace.exists() or 'MacCaptureWorkspaceView.swift in Sources' not in project:
    errors.append('capture-first macOS workspace is missing from the Mac target')
if not mac_editor.exists() or 'MacMarkdownComposerTextView.swift in Sources' not in project:
    errors.append('native macOS Markdown composer is missing from the Mac target')
for required in [
    'case capture = "Capture"',
    'case models = "Transcription Models"',
    'case presets = "Capture Presets"',
    'case templates = "Entry Templates"',
    'static let workDestinations: [MacDestination] = [.capture, .queue, .history]',
    'static let configureDestinations: [MacDestination] = [.models, .presets, .templates]',
    'MacNavigationState',
    '@Observable',
    '@State private var navigationState: MacNavigationState',
    'openSettings: { openSettings() }',
    'openModels: { navigationState.select(.models) }',
    'MacCaptureWorkspaceView(',
    'MacHistoryView(viewModel: quickCaptureViewModel)',
    'case .models:\n            MacModelView()',
    'case .presets:\n            MacCapturePresetSettingsView()',
    'case .templates:\n            MacEntryTemplateLibraryView()',
]:
    if required not in mac_root:
        errors.append(f'macOS capture-first navigation is missing {required}')
for removed_destination in [
    'case listen =',
    'case model =',
    'case settings =',
    'selection = .settings',
    'showsModels',
    'showModels',
]:
    if removed_destination in mac_root:
        errors.append(f'legacy macOS primary navigation must be removed: {removed_destination}')
model_view_start = mac_root.find('private struct MacModelView: View')
model_view_end = mac_root.find('// MARK: - Capture Presets', model_view_start)
model_view_source = mac_root[model_view_start:model_view_end]
for required in [
    '.navigationTitle("Transcription Models")',
    'modelErrorBanner(error)',
    'Button("Dismiss")',
    'Button("Select")',
    'Button("Remove")',
    'Text("Use Existing…")',
    'Text("Download")',
]:
    if required not in model_view_source:
        errors.append(f'direct macOS Models destination is missing {required}')
if '.alert(' in model_view_source:
    errors.append('macOS model failures must remain inline instead of presenting an alert')
language_index = model_view_source.find('languageSection')
whisper_index = model_view_source.find('modelSection("02", "Whisper Models"')
if model_view_start < 0 or model_view_end < 0 or not (0 <= language_index < whisper_index):
    errors.append('macOS Models must keep Language visible before the model lists')
if mac_root.count('case .models:\n            MacModelView()') != 1:
    errors.append('macOS Models must have exactly one production selectedDetail destination')
if 'case "04-models":\n            NavigationStack { MacModelView() }' not in mac_root:
    errors.append('macOS Models localization story must keep rendering the direct model surface')
if mac_root.count('MacModelView()') != 2:
    errors.append('macOS Models must have only the production destination and DEBUG screenshot call sites, never a sheet')
if mac_root.count('case .presets:\n            MacCapturePresetSettingsView()') != 1:
    errors.append('macOS Capture Presets must have exactly one production selectedDetail destination')
if 'case "05-presets":\n            NavigationStack { MacCapturePresetSettingsView() }' not in mac_root:
    errors.append('macOS Capture Presets localization story must keep rendering the direct library surface')
if mac_root.count('MacCapturePresetSettingsView()') != 2:
    errors.append('macOS Capture Presets must have only the production destination and DEBUG screenshot call sites, never a sheet')
if mac_root.count('case .templates:\n            MacEntryTemplateLibraryView()') != 1:
    errors.append('macOS Entry Templates must have exactly one production selectedDetail destination')
preset_view_start = mac_root.find('private struct MacCapturePresetSettingsView: View')
preset_view_end = mac_root.find('private struct MacCapturePresetEditor: View', preset_view_start)
preset_view_source = mac_root[preset_view_start:preset_view_end]
for required in [
    'HStack(spacing: 0)',
    'List(selection: $selectedFlowId)',
    '.frame(width: 260)',
    'MacCapturePresetEditor(preset: $flows[index]',
    'Text("Select a Capture Preset")',
]:
    if required not in preset_view_source:
        errors.append(f'direct macOS Capture Presets list/detail is missing {required}')
for removed in ['@Environment(\\.dismiss)', 'Button("Done")', '.sheet(', 'NavigationStack']:
    if removed in preset_view_source:
        errors.append(f'direct macOS Capture Presets must not retain modal library semantics: {removed}')
settings_destination_start = mac_root.find('private enum MacSettingsDestination')
settings_view_start = mac_root.find('struct MacSettingsView: View', settings_destination_start)
settings_view_end = mac_root.find('private enum MacPaywallPresentation', settings_view_start)
settings_destination_source = mac_root[settings_destination_start:settings_view_start]
settings_view_source = mac_root[settings_view_start:settings_view_end]
settings_cases = ['case access', 'case general', 'case shortcuts', 'case diagnostics', 'case about']
settings_case_indexes = [settings_destination_source.find(case) for case in settings_cases]
if any(index < 0 for index in settings_case_indexes) or settings_case_indexes != sorted(settings_case_indexes):
    errors.append('macOS Settings category order must be Access, General, Shortcuts, Diagnostics, About')
for required in [
    'NavigationSplitView',
    'List(selection: $selectedDestination)',
    'ForEach(MacSettingsDestination.allCases)',
    'case .access:',
    'case .general:',
    'case .shortcuts:',
    'case .diagnostics:',
    'case .about:',
    'MacPaywallView(context: .settings, embeddedInSettings: true)',
    'MacHotKeyRecorderView(',
    'onCancel: { editingHotKeyTarget = nil }',
    'MacDebugLogView()',
    'mode.apply()',
    'await reloadHotKeyConfiguration()',
    'await storeManager.prepareForPurchases()',
]:
    if required not in settings_view_source:
        errors.append(f'dedicated macOS Settings hierarchy is missing {required}')
for removed in [
    'showCapturePresets',
    'showEntryTemplates',
    'MacCapturePresetSettingsView()',
    'MacEntryTemplateLibraryView()',
    'showPaywall',
    'showDebug',
    '.sheet(',
    'MacHotKeyRecorderSheet',
]:
    if removed in settings_view_source:
        errors.append(f'macOS Settings must not retain duplicate or modal primary routing: {removed}')
paywall_view_start = mac_root.find('struct MacPaywallView: View', settings_view_end)
paywall_view_end = mac_root.find('private struct MacDebugLogView: View', paywall_view_start)
paywall_view_source = mac_root[paywall_view_start:paywall_view_end]
for required in [
    'embeddedInSettings: Bool',
    'presentation = embeddedInSettings ? .embeddedSettings : .modal',
    'if presentation == .modal',
    'await storeManager.restore()',
    'await storeManager.purchase(product, context: context)',
    'await storeManager.prepareForPurchases()',
]:
    if required not in paywall_view_source:
        errors.append(f'macOS embedded Access purchase surface is missing {required}')
hotkey_recorder_start = mac_root.find('private struct MacHotKeyRecorderView: View', settings_view_start)
hotkey_recorder_end = mac_root.find('private struct MacHotKeyCaptureView', hotkey_recorder_start)
hotkey_recorder_source = mac_root[hotkey_recorder_start:hotkey_recorder_end]
for required in ['let onCancel: () -> Void', 'onCancel()', 'onSave(capturedShortcut)', 'conflictingBindingName']:
    if required not in hotkey_recorder_source:
        errors.append(f'inline macOS shortcut recorder is missing {required}')
for removed in ['@Environment(\\.dismiss)', 'dismiss()', '.sheet(']:
    if removed in hotkey_recorder_source:
        errors.append(f'inline macOS shortcut recorder retains modal semantics: {removed}')
debug_view_start = mac_root.find('private struct MacDebugLogView: View', paywall_view_start)
debug_view_end = mac_root.find('private extension CapturePresetProcessingMode', debug_view_start)
debug_view_source = mac_root[debug_view_start:debug_view_end]
for required in ['Button("Clear")', 'Button("Refresh"', 'Button("Copy"', 'Reveal Data Folder', 'KeyboardDebugLog.shared.read()']:
    if required not in debug_view_source:
        errors.append(f'embedded macOS Diagnostics is missing {required}')
for removed in ['@Environment(\\.dismiss)', 'Button("Done")', '.frame(width: 760', '.sheet(']:
    if removed in debug_view_source:
        errors.append(f'embedded macOS Diagnostics retains modal semantics: {removed}')
if mac_app_source.count('Settings {') != 1:
    errors.append('macOS must retain exactly one native SwiftUI Settings scene')
settings_scene_start = mac_app_source.find('        Settings {')
settings_scene_end = mac_app_source.find('        MenuBarExtra(', settings_scene_start)
settings_scene_source = mac_app_source[settings_scene_start:settings_scene_end]
if 'MacSettingsView(recorder: recorder)' not in settings_scene_source or 'NavigationStack' in settings_scene_source:
    errors.append('the native macOS Settings scene must host MacSettingsView directly')
mac_template_source = (root / 'Voxboard Mac/MacEntryTemplateLibraryView.swift').read_text()
for required in [
    'List(selection: $selectedTemplateID)',
    'MacEntryTemplateEditor(',
    'drafts.append(template)',
    'selectedTemplateID = template.id',
    'CapturePresetStore.clearCaptureEntryTemplate(id)',
]:
    if required not in mac_template_source:
        errors.append(f'direct macOS Entry Templates list/detail is missing {required}')
for removed in ['.sheet(', '@Environment(\\.dismiss)', 'templateToEdit', 'isAdding']:
    if removed in mac_template_source:
        errors.append(f'macOS Entry Templates must edit inline instead of in sheets: {removed}')
history_view_start = mac_root.find('struct MacHistoryView: View')
history_view_end = mac_root.find('private enum MacUnifiedHistoryItem', history_view_start)
history_view_source = mac_root[history_view_start:history_view_end]
for required in [
    '@State private var selectedItemID: UUID?',
    'List(selection: $selectedItemID)',
    'private var historyDetail: some View',
    'MacTranscriptDetailView(',
    'MacCaptureHistoryDetailView(',
    'MacCaptureDeliveryMetadataView',
    'selectFallback(removing:',
    'reconcileSelection(requiringVisibleItem:',
    '.confirmationDialog(',
    'await viewModel.retryFailedInbox()',
    'await viewModel.clearHistory()',
]:
    if required not in history_view_source:
        errors.append(f'persistent macOS History list/detail is missing {required}')
for removed in ['selectedTranscript', '.sheet(', '@Environment(\\.dismiss)', 'Button("Done")']:
    if removed in history_view_source:
        errors.append(f'macOS History detail must remain embedded instead of modal: {removed}')
transcript_detail_start = mac_root.find('private struct MacTranscriptDetailView: View')
transcript_detail_end = mac_root.find('private struct MacCaptureHistoryDetailView: View', transcript_detail_start)
transcript_detail_source = mac_root[transcript_detail_start:transcript_detail_end]
for required in [
    'let delivery: CaptureHistoryRecord?',
    'Button("Copy Cleaned")',
    'Button("Copy Raw")',
    'transcriptSection(String(localized: "Raw Transcript")',
    'MacCaptureDeliveryMetadataView(record: delivery',
    'speakerDiarizationSkipReason',
    'ForEach(tags, id: \\.self)',
]:
    if required not in transcript_detail_source:
        errors.append(f'embedded macOS transcript detail is missing {required}')
for removed in ['@Environment(\\.dismiss)', 'Button("Done")', '.sheet(']:
    if removed in transcript_detail_source:
        errors.append(f'embedded macOS transcript detail retains modal semantics: {removed}')
history_item_start = mac_root.find('private enum MacUnifiedHistoryItem: Identifiable')
history_item_end = mac_root.find('private enum MacHistoryRevealError', history_item_start)
history_item_source = mac_root[history_item_start:history_item_end]
for required in [
    'var id: UUID',
    'case .transcript(let transcript, _): transcript.id',
    'case .capture(let record): record.requestID',
]:
    if required not in history_item_source:
        errors.append(f'macOS History selection identity is not stable: {required}')
if 'screenshotFixture: .localization' not in mac_root:
    errors.append('macOS History localization story must render populated list/detail evidence')
mac_workspace_source = mac_workspace.read_text() if mac_workspace.exists() else ''
for required in [
    'mac_quick_capture_submit',
    'mac_capture_destination_banner',
    'MacCaptureRouteInspector',
    'dropDestination(for: URL.self)',
    'CaptureComposerTextEditor().applying',
    'Add to Draft',
    'Send Immediately',
    'Transcribe Audio or Video',
    'Take Photo',
    'Import Scan or PDF',
    'Sketch',
    'Due date',
    'Internal link',
]:

    if required not in mac_workspace_source:
        errors.append(f'macOS Capture workspace is missing {required}')

capture_load_index = mac_workspace_source.find('await viewModel.load()')
capture_ready_index = mac_workspace_source.find(
    'windowCoordinator.captureWorkspaceReady(token: windowToken)'
)
if capture_load_index < 0 or capture_ready_index < 0 or capture_load_index >= capture_ready_index:
    errors.append('macOS Capture readiness must be announced only after the cold-load barrier')
if 'guard !Task.isCancelled else { return }' not in mac_workspace_source[
    capture_load_index:capture_ready_index
]:
    errors.append('a cancelled macOS Capture mount must not leave stale workspace readiness')
if '.onChange(of: viewModel.requestedInput)' in mac_workspace_source:
    errors.append('shared macOS requested input must not be consumed by every mounted Capture window')
if 'notification.object == nil' in mac_workspace_source:
    errors.append('macOS Capture notifications must reject nil broadcast payloads')
if mac_workspace_source.count(
    'guard let targetToken = notification.object as? String,'
) < 3:
    errors.append('macOS Capture notification handlers must require typed target-window tokens')
show_capture_handler = mac_workspace_source.find(
    '.onReceive(NotificationCenter.default.publisher(for: .macShowCapture))'
)
choose_files_handler = mac_workspace_source.find(
    '.onReceive(NotificationCenter.default.publisher(for: .macChooseCaptureFiles))'
)
if (
    show_capture_handler < 0
    or choose_files_handler < 0
    or 'consumeRequestedInput()' not in mac_workspace_source[
        show_capture_handler:choose_files_handler
    ]
):
    errors.append('only the token-targeted macOS Capture focus event may consume requested input')

route_inspector_start = mac_workspace_source.find('struct MacCaptureRouteInspector: View')
text_inspector_start = mac_workspace_source.find('private struct MacCaptureTextInspectorView: View')
workspace_surface_source = mac_workspace_source[:route_inspector_start]
route_inspector_source = mac_workspace_source[route_inspector_start:text_inspector_start]
for required in [
    'private enum MacCaptureInspectorTool',
    'case route',
    'case webLink',
    'case internalLink',
    'case camera',
    'case sketch',
    'case dueDate',
    '.inspector(isPresented: inspectorPresentationBinding)',
    'selectedInspectorTool: MacCaptureInspectorTool?',
    'selectInspectorTool(.route)',
    'selectInspectorTool(.webLink)',
    'selectInspectorTool(.internalLink)',
    'selectInspectorTool(.camera)',
    'selectInspectorTool(.sketch)',
    'selectInspectorTool(.dueDate)',
    'MacCaptureTextInspectorView(',
    'MacCameraCaptureView(',
    'MacSketchEditor(',
    'MacCaptureDueDateInspectorView(',
]:
    if required not in workspace_surface_source:
        errors.append(f'macOS Capture trailing inspector/tool routing is missing {required}')
for removed in [
    'showsRouteInspector',
    'showsLinkPrompt',
    'showsCamera',
    'showsSketch',
    'showsInternalLinkPrompt',
    'showsDueDate',
    'MacCaptureDueDateSheet',
    '.alert(',
]:
    if removed in workspace_surface_source:
        errors.append(f'macOS Capture accessory tools must not retain primary modal state: {removed}')
if workspace_surface_source.count('.sheet(') != 1 or '.sheet(isPresented: $showsPaywall)' not in workspace_surface_source:
    errors.append('the StoreKit paywall must be the only app-authored sheet on the macOS Capture workspace')
for required in [
    'mac_capture_location_decision',
    'mac_capture_inbox_location_decision',
    'await viewModel.retryUnavailableLocation()',
    'sendWithoutUnavailableLocation(alwaysForPreset: false)',
    'sendWithoutUnavailableLocation(alwaysForPreset: true)',
    'await viewModel.cancelUnavailableLocation()',
    'await viewModel.sendInboxRequestWithoutLocation()',
    'sendInboxRequestWithoutLocation(alwaysForPreset: true)',
    'showsInboxDiscardConfirmation = true',
    '"Discard queued Capture?"',
    'await viewModel.discardInboxLocationRequest()',
]:
    if required not in workspace_surface_source:
        errors.append(f'inline macOS Capture location decisions are missing {required}')
for removed in ['.confirmationDialog(\n            "Location"', 'isPresented: Binding(\n                get: { viewModel.inboxLocationDecision != nil }']:
    if removed in workspace_surface_source:
        errors.append(f'macOS Capture location branching must be inline instead of a primary dialog: {removed}')
for required in [
    'NavigationStack',
    '.navigationDestination(isPresented: $isEditingDestination)',
    'embeddedInNavigation: true',
    'onClose: { isEditingDestination = false }',
    'viewModel.scheduleDraftSave()',
    'viewModel.useVoxRouteDefaults()',
    'chooseOneOffNote()',
    'viewModel.resolvedDestinationPreview',
]:
    if required not in route_inspector_source:
        errors.append(f'macOS Capture Route inspector hierarchy is missing {required}')
for removed in ['@Environment(\\.dismiss)', '.sheet(', 'Button("Done")', '.frame(minWidth: 620']:
    if removed in route_inspector_source:
        errors.append(f'macOS Capture Route inspector retains modal semantics: {removed}')
if 'case "07-capture-route-inspector"' not in mac_root or 'MacCaptureRouteInspector(viewModel: quickCaptureViewModel)' not in mac_root:
    errors.append('DEBUG story 07 must render the real Capture Route inspector without changing stories 01-06')

mac_routes = root / 'Voxboard Mac/MacCaptureDestinationLibraryView.swift'
if not mac_routes.exists() or 'MacCaptureDestinationLibraryView.swift in Sources' not in project:
    errors.append('macOS capture-route management is missing from the Mac target')
for filename in [
    'MacCameraCaptureView.swift',
    'MacDocumentScanProcessor.swift',
    'MacSketchEditor.swift',
    'MacEntryTemplateLibraryView.swift',
]:
    path = root / 'Voxboard Mac' / filename
    if not path.exists() or f'{filename} in Sources' not in project:
        errors.append(f'macOS native Capture input/settings adapter is missing: {filename}')
mac_route_source = mac_routes.read_text() if mac_routes.exists() else ''
for required in [
    'let embeddedInNavigation: Bool',
    'embeddedInNavigation: Bool = false',
    'if embeddedInNavigation',
    '.frame(minWidth: 680, minHeight: 620)',
    'Button("Cancel", action: close)',
]:
    if required not in mac_route_source:
        errors.append(f'macOS destination editor must preserve modal sizing while supporting inspector navigation: {required}')
mac_camera_source = (root / 'Voxboard Mac/MacCameraCaptureView.swift').read_text()
mac_sketch_source = (root / 'Voxboard Mac/MacSketchEditor.swift').read_text()
for filename, source, required in [
    ('MacCameraCaptureView.swift', mac_camera_source, ['let onClose: () -> Void', 'camera.capture(completion: onCapture)', 'mac_capture_camera_shutter']),
    ('MacSketchEditor.swift', mac_sketch_source, ['let onClose: () -> Void', 'onSave(drawingData, png)', 'mac_capture_sketch_add']),
]:
    if '@Environment(\\.dismiss)' in source or 'dismiss()' in source:
        errors.append(f'{filename} must close explicitly from the Capture inspector instead of dismissing a sheet')
    for value in required:
        if value not in source:
            errors.append(f'{filename} inspector adapter is missing {value}')
due_date_start = mac_workspace_source.find('private struct MacCaptureDueDateInspectorView: View')
due_date_source = mac_workspace_source[due_date_start:]
for required in ['let onClose: () -> Void', 'let onInsert: (Date, Bool) -> Void', 'Toggle("Include time"', 'Button("Insert Due Date")']:
    if required not in due_date_source:
        errors.append(f'macOS due-date inspector is missing {required}')
if '@Environment(\\.dismiss)' in due_date_source or 'dismiss()' in due_date_source:
    errors.append('macOS due-date tool must close explicitly from the Capture inspector')
mac_app = (root / 'Voxboard Mac/VoxboardMacApp.swift').read_text()
for required in [
    'quickCaptureViewModel',
    'await quickCaptureViewModel.processPendingInbox()',
    'case navigate(MacDestination)',
    'showMain(.navigate(.history))',
    'Settings {',
    'CommandMenu("Capture")',
    'MacWindowCoordinator',
    'applicationDidBecomeActive',
    'applicationShouldTerminate',
    'flushDraftForTermination()',
]:
    if required not in mac_app:
        errors.append(f'macOS durable Capture integration is missing {required}')
if '@State private var navigationState' in mac_app:
    errors.append('MacNavigationState must remain owned by each MacRootView, not the app scene')
for required in [
    'deliverPendingCaptureRequestIfReady(to: token)',
    'case .navigate(.capture), .chooseFiles:',
    'NotificationCenter.default.post(name: .macShowCapture, object: token)',
]:
    if required not in mac_app:
        errors.append(f'macOS Capture routing is missing its readiness-gated delivery: {required}')
if mac_app.count(
    'NotificationCenter.default.post(name: .macShowCapture, object: token)'
) != 1:
    errors.append('macOS Capture focus must have one readiness-gated production sender')
handle_url_start = mac_app.find('private func handleURL(_ url: URL)')
handle_url_end = mac_app.find(
    '@MainActor\n    private static func consumePendingQuickCaptureOpenIfNeeded',
    handle_url_start,
)
handle_url_source = mac_app[handle_url_start:handle_url_end]
capture_case_start = handle_url_source.find('case "capture", "capture-request":')
capture_case_end = handle_url_source.find('} catch {', capture_case_start)
capture_success_source = handle_url_source[capture_case_start:capture_case_end]
deep_link_mutation_index = capture_success_source.find(
    'await quickCaptureViewModel.handleDeepLink(action)'
)
deep_link_route_index = capture_success_source.find(
    'windowCoordinator.showMain(.navigate(.capture))'
)
if (
    handle_url_start < 0
    or handle_url_end < 0
    or capture_case_start < 0
    or capture_case_end < 0
    or deep_link_mutation_index < 0
    or deep_link_route_index < deep_link_mutation_index
):
    errors.append('macOS deep links must finish mutation/persistence before targeted Capture delivery')
startup_start = mac_app.find('private static func consumePendingQuickCaptureOpenIfNeeded')
startup_end = mac_app.find('private func configureGlobalHotKeys()', startup_start)
startup_source = mac_app[startup_start:startup_end]
startup_source_index = startup_source.find('quickCaptureViewModel.requestCaptureSource(source)')
startup_vox_index = startup_source.find('quickCaptureViewModel.requestVox(voxID)')
startup_input_index = startup_source.find('quickCaptureViewModel.requestedInput = input')
startup_route_index = startup_source.find('windowCoordinator.showMain(.navigate(.capture))')
if not (
    startup_start >= 0
    and startup_end >= 0
    and 0 <= startup_source_index < startup_vox_index < startup_input_index < startup_route_index
):
    errors.append('macOS startup handoff must apply source/Vox/input before targeted Capture delivery')
for removed_history_window in [
    'Window("Capture History", id: "history")',
    'historyWindow',
    'showHistory()',
]:
    if removed_history_window in mac_app:
        errors.append(
            f'macOS History must route through the main navigation state, found {removed_history_window}'
        )
mac_recorder = (root / 'Voxboard Mac/MacRecorder.swift').read_text()
for required in [
    'OnDeviceTranscriptionService',
    'case captureDraft(attachAudio: Bool)',
    'case runPreset(flow: CapturePreset)',
    'liveTranscript(sessionID: UUID, finalizedText:',
    'source: .mac',
]:
    if required not in mac_recorder:
        errors.append(f'macOS unified recording flow is missing {required}')
for forbidden in ['WhisperContext(', 'ParakeetContext.load(']:
    if forbidden in mac_recorder:
        errors.append(f'macOS recorder must use the shared transcription service, not {forbidden}')
for required in ['lastRecoveryAudioURL', 'hasDurableAudioCopy', 'audioWasRequested']:
    if required not in mac_recorder:
        errors.append(f'macOS recorder is missing durable audio handoff guard {required}')
audio_recorder = (root / 'Packages/VoxboardShared/Sources/VoxboardShared/AudioRecorder.swift').read_text()
if 'recording.wav' in audio_recorder or 'recording_\\(UUID().uuidString.lowercased())' not in audio_recorder:
    errors.append('shared audio recorder must use a session-unique file URL')
mac_info = (root / 'Voxboard Mac/Info.plist').read_text()
for required in ['<string>voxboard</string>', 'NSSpeechRecognitionUsageDescription']:
    if required not in mac_info:
        errors.append(f'macOS Capture deep-link/live-preview configuration is missing {required}')

template_model = (root / 'Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift').read_text()
template_ui = (root / 'Voxboard/Views/CaptureDestinationLibraryView.swift').read_text()
if (
    'CaptureEntryTemplate' not in template_model
    or 'entryTemplateID' not in template_model
    or 'resolvedDestination' not in template_model
    or 'CaptureEntryTemplateLibraryView' not in template_ui
):
    errors.append('live reusable entry-template model/UI contract is missing')

website_root = root / 'website'
website_css = website_root / 'geist.css'
website_pages = [
    website_root / 'index.html',
    website_root / 'docs/index.html',
    website_root / 'privacy.html',
    website_root / 'terms.html',
    website_root / 'blog/index.html',
    website_root / 'blog/best-voice-to-text-keyboard-iphone/index.html',
]

website_docs = website_root / 'docs/index.html'
if website_docs.exists():
    docs_html = website_docs.read_text()
    for section_id in [
        'getting-started',
        'quick-capture',
        'presets',
        'models',
        'keyboard',
        'system-integrations',
        'apple-watch',
        'mac',
        'history-settings',
        'troubleshooting',
    ]:
        if f'id="{section_id}"' not in docs_html:
            errors.append(f'website documentation is missing the {section_id} category')
    for required in [
        'id="preset-location"',
        'Exact (default)',
        'two decimal places',
        'Apple’s system reverse geocoder',
        'Always Send Without Location',
        'never reacquire a later location',
        'completed Watch queue items',
        'independent Capture Bar action',
    ]:
        if required not in docs_html:
            errors.append(f'website location documentation is missing {required}')

website_llms = website_root / 'llms.txt'
if not website_llms.exists():
    errors.append('website is missing its root llms.txt agent interface')
else:
    llms = website_llms.read_text()
    for required in [
        '# Vox.md',
        'https://vox.isolated.tech/docs/',
        '## Keyboard Safety Note',
        'Allow Full Access',
        'Per-preset location metadata is opt-in',
        'unattended Ask result is durable',
        'completed Watch queue items',
    ]:
        if required not in llms:
            errors.append(f'website llms.txt is missing {required}')

website_sitemap = website_root / 'sitemap.xml'
if not website_sitemap.exists():
    errors.append('website is missing sitemap.xml')
elif 'https://vox.isolated.tech/docs/' not in website_sitemap.read_text():
    errors.append('website sitemap does not include documentation')

for font_name in [
    'Geist-Regular.ttf',
    'Geist-Medium.ttf',
    'Geist-SemiBold.ttf',
    'GeistMono-Regular.ttf',
    'GeistMono-Medium.ttf',
    'LICENSE.txt',
]:
    if not (website_root / 'fonts' / font_name).exists():
        errors.append(f'website is missing bundled Geist font asset {font_name}')

if not website_css.exists():
    errors.append('website is missing its shared Geist stylesheet')
else:
    css = website_css.read_text()
    for required in [
        '--background-100: #ffffff',
        '--gray-1000: #171717',
        '--background-100: #000000',
        '--gray-1000: #ededed',
        '--font-sans: "Geist Sans"',
        '--font-mono: "Geist Mono"',
        '@media (prefers-color-scheme: dark)',
        '@media (prefers-reduced-motion: reduce)',
        ':focus-visible',
    ]:
        if required not in css:
            errors.append(f'website Geist stylesheet is missing {required}')
    for forbidden in ['JetBrains Mono', '#30D158', 'text-transform: uppercase']:
        if forbidden in css:
            errors.append(f'website Geist stylesheet still contains legacy styling {forbidden}')
    for asset in re.findall(r'url\(["\']?([^"\')]+)', css):
        parsed = urlsplit(asset)
        if parsed.scheme or asset.startswith('data:'):
            continue
        if not (website_css.parent / parsed.path).resolve().exists():
            errors.append(f'website stylesheet references missing asset {asset}')

class WebsiteHTMLContractParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.main_count = 0
        self.h1_count = 0
        self.ids: list[str] = []
        self.references: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        attributes = dict(attrs)
        if tag == 'main':
            self.main_count += 1
        if tag == 'h1':
            self.h1_count += 1
        if attributes.get('id'):
            self.ids.append(attributes['id'])
        for name in ['href', 'src']:
            if attributes.get(name):
                self.references.append(attributes[name])
        if attributes.get('srcset'):
            self.references.extend(
                candidate.strip().split()[0]
                for candidate in attributes['srcset'].split(',')
            )

for page in website_pages:
    if not page.exists():
        errors.append(f'website page is missing: {page.relative_to(root)}')
        continue
    html = page.read_text()
    parser = WebsiteHTMLContractParser()
    parser.feed(html)
    if '<style>' in html:
        errors.append(f'{page.relative_to(root)} contains a legacy inline stylesheet')
    if 'geist.css' not in html:
        errors.append(f'{page.relative_to(root)} does not load the shared Geist stylesheet')
    if parser.main_count != 1:
        errors.append(f'{page.relative_to(root)} must contain exactly one main landmark')
    if parser.h1_count != 1:
        errors.append(f'{page.relative_to(root)} must contain exactly one h1')
    duplicate_ids = {value for value in parser.ids if parser.ids.count(value) > 1}
    if duplicate_ids:
        errors.append(f'{page.relative_to(root)} has duplicate IDs: {sorted(duplicate_ids)}')
    for reference in parser.references:
        parsed = urlsplit(reference)
        if parsed.scheme or reference.startswith(('#', 'mailto:', 'tel:', 'data:')):
            continue
        referenced_path = (page.parent / parsed.path).resolve()
        if parsed.path.endswith('/'):
            referenced_path /= 'index.html'
        if not referenced_path.exists():
            errors.append(
                f'{page.relative_to(root)} references missing local asset {reference}'
            )

if errors:
    print('Project contract failures:', file=sys.stderr)
    for error in errors:
        print(f'  - {error}', file=sys.stderr)
    raise SystemExit(1)

print('Project contracts passed.')
PY
