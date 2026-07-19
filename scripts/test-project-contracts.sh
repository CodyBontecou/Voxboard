#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Voxboard.xcodeproj/project.pbxproj"

python3 - "$ROOT" "$PROJECT" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
import re
import sys

root = Path(sys.argv[1])
project_path = Path(sys.argv[2])
project = project_path.read_text()
errors: list[str] = []

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
for required in [
    'allowedContentTypes: [.data]',
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
    'Send with Preset',
    'capture_vox_selector',
    'Use Preset destination defaults',
    'Attach audio to Capture',
    'capture_keyboard_listening',
    'capture_audio_import',
    'Watch Recordings',
]:
    if required not in quick_capture_source:
        errors.append(f'Quick Capture hardening is missing {required}')

capture_route_picker_source = (root / 'Voxboard/Capture/CaptureRoutePickerView.swift').read_text()
for required in [
    'Set Up Destination',
    'CaptureDestinationEditorView(',
    'viewModel.saveSelectedPresetDestination(destination)',
]:
    if required not in capture_route_picker_source:
        errors.append(f'inline Capture destination setup is missing {required}')

quick_capture_view_model_source = (root / 'Voxboard/Capture/QuickCaptureViewModel.swift').read_text()
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
        'Voxboard/Capture/CaptureToolbarPreferences.swift',
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
quick_capture_model = (root / 'Voxboard/Capture/QuickCaptureViewModel.swift').read_text()
for required in [
    'initialLoadTask',
    'draft.selectDestination(destinationID)',
    'requestCaptureSource',
    'appendRecordedTranscript',
    'stageRecordedAudio',
]:
    if required not in quick_capture_model:
        errors.append(f'Quick Capture cold-launch routing hardening is missing {required}')

intent_source = (root / 'Voxboard/Capture/CaptureAppIntents.swift').read_text()
shortcut_source = (root / 'Voxboard/VoxboardShortcutsProvider.swift').read_text()
if '@available(iOS 18.0, *)' in intent_source or '@available(iOS 18.0, *)' in shortcut_source:
    errors.append('capture App Intents must remain available on the supported iOS 17.6 deployment target')

mac_routes = root / 'Voxboard Mac/MacCaptureDestinationLibraryView.swift'
if not mac_routes.exists() or 'MacCaptureDestinationLibraryView.swift in Sources' not in project:
    errors.append('macOS capture-route management is missing from the Mac target')
mac_recorder = (root / 'Voxboard Mac/MacRecorder.swift').read_text()
if 'processPendingCaptureInbox' not in mac_recorder or 'CaptureInboxDeliveryService.drain' not in mac_recorder:
    errors.append('macOS durable capture inbox retry integration is missing')

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
    website_root / 'privacy.html',
    website_root / 'terms.html',
    website_root / 'blog/index.html',
    website_root / 'blog/best-voice-to-text-keyboard-iphone/index.html',
]

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

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
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
