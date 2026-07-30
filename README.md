# Vox.md

> **Open source, local-first quick capture for Obsidian and Markdown on iPhone, iPad, Mac, and Apple Watch.**

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017.6%2B%20%7C%20macOS%2014%2B%20%7C%20watchOS%2010%2B-lightgrey)](#tech-stack)
[![Swift](https://img.shields.io/badge/swift-5-orange)](#tech-stack)

Vox.md turns text, voice, links, photos, scans, sketches, and files into Markdown notes without sending captured content to a Vox.md service. Capture Presets control how each capture is processed, formatted, and delivered. A preset can create a note, update an existing file, write to a rolling note, insert beneath a heading, and manage metadata and attachments.

Capture from the main app, the Vox.md keyboard, Share Sheet, widgets, Control Center, Live Activities, Shortcuts, deep links, Mac keyboard shortcuts, or Apple Watch. Voice transcription runs on device with Apple Speech, Whisper, or Parakeet. Apple Intelligence processing also stays on device when it is available.

**[🌐 Website](https://vox.isolated.tech/)** · **[📚 Documentation](https://vox.isolated.tech/docs/)** · **[🤖 llms.txt](https://vox.isolated.tech/llms.txt)** · **[📲 Download](https://apps.apple.com/us/app/voxboard/id6758967337)** · **[🛠 Contribute](CONTRIBUTING.md)** · **[💬 Discussions](https://github.com/CodyBontecou/Voxboard/discussions)** · **[👥 Discord](https://discord.gg/RaQYS4t6gn)** · **[⭐ Star this repo](https://github.com/CodyBontecou/Voxboard)**

## Vox.md 2.0

<table>
  <tr>
    <td width="25%" align="center"><img src="artifacts/app-store-raw-light/01-quick-capture.png" alt="Quick Capture with Markdown, voice, photo, and sketch attachments"><br><sub><b>Quick Capture</b></sub></td>
    <td width="25%" align="center"><img src="artifacts/app-store-raw-light/02-capture-presets.png" alt="Reusable Capture Presets"><br><sub><b>Capture Presets</b></sub></td>
    <td width="25%" align="center"><img src="artifacts/app-store-raw-light/03-preset-configuration.png" alt="Capture Preset destination and metadata settings"><br><sub><b>Preset routing</b></sub></td>
    <td width="25%" align="center"><img src="artifacts/app-store-raw-light/04-live-recording.png" alt="Live voice recording inside Quick Capture"><br><sub><b>Live recording</b></sub></td>
  </tr>
</table>

<table>
  <tr>
    <td width="33%" align="center"><img src="artifacts/app-store-raw-light/05-keyboard-anywhere.png" alt="Vox.md voice keyboard in another app"><br><sub><b>Voice keyboard</b></sub></td>
    <td width="33%" align="center"><img src="artifacts/app-store-raw-light/06-privacy-on-device.png" alt="On-device transcription and privacy settings"><br><sub><b>On-device privacy</b></sub></td>
    <td width="33%" align="center"><img src="artifacts/app-store-raw-light/07-capture-bar-customization.png" alt="Customizable Capture Bar controls"><br><sub><b>Custom Capture Bar</b></sub></td>
  </tr>
</table>

## At a glance

| Capability | What Vox.md does |
|---|---|
| Capture | Accepts Markdown, voice, links, photos, screenshots, files, document scans, journal-page OCR, and PencilKit sketches. |
| Process locally | Transcribes with Apple Speech or optional Whisper and Parakeet models. Supported devices can use Apple Intelligence for cleanup, titles, tags, checklists, meeting notes, and custom instructions. |
| Route with presets | Sends each capture to its own Obsidian vault or Files destination with templates, metadata, attachment rules, and new, existing, or rolling-note targets. |
| Capture anywhere | Works from iPhone, iPad, Mac, Apple Watch, the iOS keyboard, Share Sheet, widgets, Control Center, Live Activities, Shortcuts, and deep links. |
| Recover safely | Saves drafts, attachments, and pending deliveries locally so failed writes can be retried without losing the capture or creating duplicates. |

## Features

### Universal Quick Capture
Capture typed Markdown, links, photos, selected screenshots, camera images, arbitrary files, document scans with on-device OCR and PDF generation, PencilKit sketches, journal pages extracted to Markdown, and voice attachments. Drafts and staged attachments are saved locally before export, so a permission or sync failure can be retried instead of losing the capture. With Automatic on supported iOS 26 devices, voice recordings show finalized and tentative Apple Speech text while recording. Whisper and Parakeet transcribe after recording stops. The audio remains usable if transcription is unavailable or fails.

The composer is a selection-aware Markdown editor with undo, bold, italic, headings, hashtags, tasks, bullets, links, wiki links, due-date tokens, timestamps, case transformations, and paste controls. The Capture Bar can be reordered and trimmed to the actions you use. Location is an explicit one-shot action that inserts a Google Maps link; Vox.md does not monitor location or keep separate coordinate history.

Each Capture Preset owns one destination in an Obsidian vault or Files folder. Destinations can create new notes, target existing notes, or use daily, weekly, monthly, quarterly, or yearly rolling notes. Presets also control append or prepend placement, heading insertion, multiline YAML or Markdown entry formatting, templates, attachment subfolders, retry protection, and resolved path previews.

### Capture Presets
A Capture Preset describes both the intent of a capture and where it belongs. The same Journal, Tasks, Meeting, or Inbox preset can accept typed Markdown, links, photos, files, OCR scans, sketches, and voice. Each preset includes its destination, placement, entry formatting, metadata, empty-composer prompt, optional on-device processing, and voice behavior. Metadata can be note-level YAML frontmatter or queryable inline fields scoped to each rolling-note entry. A one-capture note, placement, or template override never mutates the preset.

Capture processing is opt-in for typed and mixed Markdown so existing presets never rewrite user-authored text unexpectedly. When enabled, text-bearing payloads keep their association with audio or scans, Apple Intelligence runs locally when available, and deterministic/original-text fallbacks keep delivery working offline. The exact processed request is persisted before writing so retries do not rerun AI against changed settings.

Quick Capture is available from the app, the Share Sheet, actionable Home Screen and Lock Screen widgets, Control Center, App Shortcuts for text, link, file, screenshot, and voice input, and preset-aware deep links. Capture history stores coarse preset, source, destination, and delivery metadata only. It does not store note text, URLs, coordinates, bookmarks, absolute paths, or attachment filenames. Pending and failed inbox items retain the content required for recovery. After delivery, Vox.md replaces each request with an ID-and-timestamp-only idempotency tombstone and sanitizes legacy completed requests on upgrade.

### Voice Keyboard
Add the Vox.md keyboard to iOS and dictate into any text field — Messages, Notes, Safari, or any app that accepts a keyboard. With Automatic on supported iOS 26 devices, finalized Apple Speech phrases stream into the active field while you speak; tentative words stay in the toolbar until Apple finalizes them. Whisper and Parakeet selections insert the completed transcript after recording stops. Parakeet users can optionally download the small on-device Voice Pause Detection companion to stop and transcribe keyboard segments after a configurable pause.

### On-Device Transcription
Speech recognition runs locally. On supported iOS 26 devices, Automatic uses Apple's `SpeechAnalyzer` and system-managed `SpeechTranscriber` assets. Whisper (`whisper.cpp`) and Core ML/FluidAudio-backed Parakeet models remain optional downloads and explicit overrides or fallbacks. No app-managed speech model weights ship in the app bundle. Audio, transcripts, capture drafts, and templates stay on the device.

### One-Shot Recording + Keyboard Listening
Tap **Start Recording** in the app, from Shortcuts, or from a widget to record one segment, process it locally, and automatically return the microphone session to idle. Keyboard users can still open Vox.md from the keyboard to start persistent listening, then mark recording segments from any text field.

### Apple Watch
Record voice notes from your wrist, pause and resume a recording, and choose which Capture Preset should handle it. Recordings stay in a durable Watch queue until they can sync to iPhone, where they can be processed, reassigned, retried, or discarded. A preset can run the normal local transcription and Markdown delivery flow or use Recording Only to keep the audio without transcribing it. The Watch widget provides quick access and reflects ready, recording, paused, syncing, and queued states.

### Model Picker
Automatic is the default on iOS and uses Apple Speech when the device and selected language support it. Users can optionally download and explicitly select Whisper Tiny, Base, Small, Medium, Large v3 Turbo, or Parakeet v2/v3. Downloaded models can also serve as Automatic's fallback.

### Transcript History
Every transcription is stored locally in the shared App Group container. Search raw text, cleaned text, titles, tags, and categories; edit saved transcripts; delete filtered selections safely; and share or export previous captures. Cross-process writes are coordinated so app and extension updates do not silently overwrite one another.

### Private Activity Stats
Stats shows lifetime recording and capture totals, recorded time, attachment counts, a seven-day activity chart, and a source breakdown for the app, keyboard, Share Sheet, widgets, Shortcuts, and Apple Watch. The ledger stays on device and excludes captured content, filenames, and destinations.

### File Export
Automatically save transcripts after each session as TXT, Markdown, or YAML. Choose a destination folder, use filename templates, append to a single file, render Markdown templates, and enable Obsidian-friendly frontmatter.

### Apple Intelligence Enrichment
On iOS 26+ devices and macOS 26+ Macs with Apple Intelligence, eligible Capture Presets can generate titles, tags, categories, cleaned-up text, checklists, meeting-note structure, and custom transformations — still locally on-device through Apple's Foundation Models framework.

### Widgets & Live Activities
Open a durable Quick Capture draft or start and monitor recording from widgets, Live Activities, the lock screen, and Dynamic Island. The widget target shares state through the same private App Group container.

### macOS Companion
The Mac app has Capture, History, and Settings workspaces plus menu-bar operation. Record or import audio and video, choose Apple Speech, Whisper, or Parakeet, manage complete Capture Presets, browse transcript history, and export TXT, Markdown, JSON, or YAML with optional audio attachments. Global shortcuts can start a temporary transcription or run a specific preset from anywhere while Vox.md is open. Mac App Shortcuts also expose text, link, file, screenshot, voice, and Quick Capture actions. Apple Intelligence enrichment is available on capable Macs running macOS 26 or later.

The Mac drains the same durable retry inbox as iOS and can reroute failed captures after folder permissions change. It uses the shared model, history, and export stack with an Application Support fallback for unsigned development builds.

## Pricing

Vox.md includes **15 minutes of free transcription** and **10 successful Capture deliveries** so you can test the full flow. Failed writes and retries do not consume a Capture; voice transcripts routed to Markdown use only the transcription allowance.

Unlimited transcription and Capture are a one-time **$9.99** unlock. No subscription, no renewal, no ads. Users who bought the original paid app build are automatically grandfathered into unlimited access. The successful-Capture count is stored locally with an uninstall-resistant Keychain high-water mark so reinstalling on the same device does not reset the allowance.

## Tech Stack

- **Language:** Swift 5
- **UI:** SwiftUI
- **Transcription:** SpeechAnalyzer/SpeechTranscriber (iOS 26+), whisper.cpp, FluidAudio, Core ML
- **AI Enrichment:** Foundation Models / Apple Intelligence (iOS/macOS 26+)
- **Persistence:** App Group files + shared `UserDefaults`
- **Monetization:** StoreKit 2 one-time purchase
- **Minimum iOS / iPadOS:** 17.6
- **Minimum macOS:** 14.0
- **Minimum watchOS:** 10.0
- **Recommended Xcode:** 26.2+

### Frameworks Used

| Framework | Purpose |
|-----------|---------|
| AVFoundation | Microphone capture, voice attachments, playback, and background audio recording |
| Speech | Native, on-device Apple Speech transcription on supported iOS 26 devices |
| Vision / VisionKit | Document scanning and on-device journal-page OCR |
| PencilKit | In-capture sketches |
| CoreLocation | Explicit one-shot map-link insertion |
| PhotosUI | User-selected photos and screenshot-filtered input |
| AppIntents | App Shortcuts, Control Center actions, and preset-aware capture intents |
| KeyboardKit | Custom keyboard UI foundation |
| WidgetKit | Home Screen, Lock Screen, Control Center, and Apple Watch widgets |
| ActivityKit | Live Activities on the Lock Screen and Dynamic Island |
| WatchConnectivity | Preset state and queued recording transfer between Watch and iPhone |
| StoreKit 2 | Lifetime unlock purchase and restore |
| FoundationModels | On-device Apple Intelligence enrichment |
| UniformTypeIdentifiers | Folder and template file pickers |
| Core ML / Metal / Accelerate | Local speech model inference |

## Project Structure

```
Voxboard/
  Views/
    RootView.swift                  # Adaptive iOS and iPadOS shell
    QuickCaptureView.swift          # Multimodal composer and inline recording
    FlowSettingsView.swift          # Capture Presets, routing, metadata, and processing
    HistoryView.swift               # Searchable and editable transcript history
    StatsView.swift                 # Private local activity totals and charts
    WatchRecordingQueueView.swift   # Synced Watch recordings and recovery controls
    ModelTabView.swift              # Apple Speech and optional model management
  Capture/                          # Camera, document scan, OCR, and sketch adapters
  PersistentRecorder.swift          # Background recorder and segment capture
  TranscriptionServer.swift         # App and keyboard transcription pipeline
  AppleSpeechTranscriptionBackend.swift
  FoundationModelsBackend.swift
  LiveActivityController.swift
  VoxboardApp.swift

Voxboard App Shared/
  CaptureAppIntents.swift           # App Shortcuts and capture intents
  CaptureComposerViewModel.swift    # Durable capture drafts and delivery
  CaptureToolbarPreferences.swift   # Custom Capture Bar ordering and visibility
  VoxboardMacShortcutsProvider.swift

Voxboard Keyboard/                  # Dictation keyboard extension
Voxboard Share Extension/           # Share Sheet capture inbox
Voxboard Widget/                    # Widgets, controls, and Live Activities
Voxboard Watch/                     # Local recording, presets, queue, pause, and sync
Voxboard Watch Widget/              # Watch face recording entry and status
Voxboard Mac/                       # Capture workspace, global shortcuts, history, and settings

Packages/VoxboardShared/
  Sources/VoxboardCaptureCore/      # Presets, routing, Markdown edits, inbox, and retries
  Tests/VoxboardCaptureCoreTests/   # Framework-independent capture tests
  Sources/VoxboardShared/           # Models, transcription, history, export, usage, and Watch sync

Voxboard.xcodeproj                  # Main Xcode project
whisper.xcframework                 # Whisper inference engine; no model weights are bundled
artifacts/                          # Current App Store and Watch screenshot assets
fastlane/                           # App Store metadata and legacy screenshot assets
website/                            # Product site, docs, privacy policy, and terms
```

## Build Targets

| Target | Bundle ID | Platform |
|--------|-----------|----------|
| Voxboard | `bontecou.Voxboard` | iOS / iPadOS |
| Voxboard Keyboard | `bontecou.Voxboard.Voxboard-Keyboard` | iOS keyboard extension |
| Voxboard WidgetExtension | `bontecou.Voxboard.Voxboard-Widget` | iOS widgets / Live Activities / controls |
| Voxboard Share Extension | `bontecou.Voxboard.ShareExtension` | iOS share sheet |
| Voxboard Watch | `bontecou.Voxboard.watchkitapp` | watchOS app |
| Voxboard Watch WidgetExtension | `bontecou.Voxboard.watchkitapp.Widget` | watchOS widgets |
| Voxboard Mac | `bontecou.Voxboard` | macOS companion app |

## Setup

1. Clone the repo:
   ```bash
   git clone https://github.com/CodyBontecou/Voxboard.git
   cd Voxboard
   ```
2. Open `Voxboard.xcodeproj` in Xcode 26.2+.
3. Select the **Voxboard** scheme for iOS and iPadOS, **Voxboard Mac** for macOS, or **Voxboard Watch** for watchOS.
4. Set your development team for all targets.
5. Configure the App Group entitlement (`group.bontecou.Voxboard`) for your team or replace it with your own group ID in the targets and `AppConstants.swift`.
6. Build and run on a physical device. Keyboard, microphone, background audio, and model performance are best tested on hardware.

### Required Permissions

The app requests the following permissions/settings at runtime:

- **Microphone** — records speech for local transcription or a user-requested Capture voice attachment.
- **Camera / selected photos** — used only when explicitly adding local capture media, selected screenshots, or scans.
- **Location When In Use** — requested only after tapping the location tool to insert one map link; no continuous monitoring or separate location history.
- **Keyboard Full Access** — required by iOS for the keyboard extension to access the shared container and microphone workflow.
- **Background Audio** — keeps the listening session alive while you switch apps.

### Entitlements

- App Groups (`group.bontecou.Voxboard`) — shared models, transcripts, settings, durable capture inbox data, and IPC between the app, keyboard, widgets, and share extension.
- Background Modes: Audio — persistent listening while moving between apps.
- Live Activities — lock screen and Dynamic Island controls.

## URL Scheme

The app registers the `voxboard://` URL scheme:

- `voxboard://listen` — opens Vox.md and starts the keyboard launch/listening flow.
- `voxboard://record` — legacy keyboard record entry point, redirected to listening mode.
- `voxboard://widget-record` — legacy widget entry point for starting a recording preset.
- `voxboard://capture` — opens the durable Quick Capture composer.
- `voxboard://capture?action=photos|screenshots|camera|files|link|scan|sketch|voice` — opens the composer and requests that exact local input.
- `voxboard://capture?preset=...&text=...&url=...` — selects a Capture Preset, validates bounded input, and opens an incoming draft. Legacy `vox=` and `destination=` parameters remain accepted for existing links.
- `voxboard://capture-request?id=...` — claims an App Group inbox request from Shortcuts/share sheet.

## Contributing

Contributions are welcome — bug reports, feature ideas, docs fixes, accessibility improvements, and pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup notes and development guidelines.

If you want to chat about the project, design decisions, or what to build next, join the [Isolated Tech Discord](https://discord.gg/RaQYS4t6gn) or open a thread in [GitHub Discussions](https://github.com/CodyBontecou/Voxboard/discussions).

## License

Vox.md is licensed under the [GNU Affero General Public License v3.0](LICENSE). The AGPL ensures that any modified version of Vox.md — including ones run as a hosted service — must also be open source. This protects the privacy-first promise: nobody can take Vox.md, bolt on invasive tracking or cloud transcription, and ship it as a closed product.
