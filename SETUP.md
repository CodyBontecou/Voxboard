# Vox.md — Setup Guide

Vox.md is a local-first iOS/macOS voice and Markdown capture app. On iOS 26, voice transcription defaults to Apple's on-device Speech framework. Whisper and Parakeet remain optional model downloads.

## What's configured

- **Main iOS app, keyboard, widgets, share extension, Watch app, and macOS app**
- **VoxboardShared Swift package** for IPC, local model inference, persistence, and exports
- **App Group:** `group.bontecou.Voxboard`
- **Microphone and background-audio configuration**
- **Apple Speech backend:** weak-linked and runtime-gated to supported iOS 26 devices/locales
- **Optional local engines:** whisper.cpp and FluidAudio/Parakeet

Vox.md does not bundle Whisper or Parakeet model weights. Local model downloads only begin after the user taps **Download Model**.

## Xcode setup

### 1. Enable App Groups

For the **Voxboard** and **Voxboard Keyboard** targets:

1. Open **Signing & Capabilities**.
2. Add **App Groups**.
3. Enable `group.bontecou.Voxboard`, or replace it consistently in the entitlements and `AppConstants.swift`.

### 2. Resolve packages

Open `Voxboard.xcodeproj` in Xcode 26.2 or newer. Xcode should resolve KeyboardKit, FluidAudio, ExportKit, and the local `VoxboardShared` package automatically.

### 3. Verify model packaging

The app bundles the whisper.cpp inference framework so downloaded Whisper models can run, but it must not contain `ggml-base.bin` or any other model weights.

After building, verify:

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*Voxboard.app/ggml-*.bin' -print
```

The command should return nothing.

## First run

1. Build and run **Voxboard** on a physical iPhone.
2. Grant microphone permission.
3. Leave **Models → Automatic** selected.
4. On a supported iOS 26 device, Vox.md prepares Apple's system-managed language asset and uses Apple Speech.
5. On older or unsupported devices/locales, open **Models** and opt into a Whisper or Parakeet download.

Apple's language assets are retained and updated by iOS. They are not stored in the Vox.md app bundle or App Group model directory.

## Enable the keyboard

1. Open **Settings → General → Keyboard → Keyboards → Add New Keyboard**.
2. Select **Vox.md Keyboard**.
3. Enable **Allow Full Access**.
4. Open Vox.md from the keyboard once so the main app can start listening and prepare the selected transcription backend.

The keyboard sends recording commands and backend IDs to the main app. It does not load Speech, Whisper, or Parakeet itself.

## Transcription routing

When **Automatic** is selected:

1. Vox.md tries Apple Speech if iOS 26, the device, and the selected locale support it.
2. If Apple Speech is unavailable or fails before producing a transcript, Vox.md can use a model the user previously downloaded.
3. If no backend is available, Vox.md preserves the recording and directs the user to Models.

When a local model is selected explicitly, Vox.md bypasses Apple Speech and uses that model.

## Build and test

```bash
swift test --package-path Packages/VoxboardShared

xcodebuild \
  -project Voxboard.xcodeproj \
  -scheme Voxboard \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/VoxboardDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  build
```

Test Apple Speech on a physical supported iOS 26 device. Simulator availability does not represent physical-device model availability.

## Troubleshooting

**“Apple Speech is unavailable for this device or language”**

Choose a supported language or download an optional Whisper/Parakeet fallback in Models.

**The keyboard says to open Vox.md**

Launch the main app, grant microphone permission, and wait for backend preparation to complete.

**A local model does not appear in the keyboard**

Finish its download in the main app, then reopen or refresh the keyboard.

**A downloaded model is using too much memory**

Select Automatic, Whisper Tiny/Base, or delete larger local model weights from Models.
