# VoxVault — Setup Guide

Voice-to-text iOS keyboard powered by whisper.cpp (on-device transcription).

---

## What's Already Configured

The following has been set up via CLI:

- ✅ **Keyboard extension target** ("VoxVault Keyboard") — added in Xcode
- ✅ **SPM dependencies** in pbxproj — KeyboardKit (keyboard target), VoxVaultShared local package (both targets)
- ✅ **VoxVaultShared** local Swift package — shared code between app + extension, depends on whisper.cpp
- ✅ **App Group entitlements** — `group.bontecou.VoxVault` on both targets
- ✅ **Info.plist** — mic permission, `RequestsOpenAccess`, keyboard extension config
- ✅ **Base whisper model** — `ggml-base.bin` (141MB) downloaded and placed in `VoxVault/`
- ✅ **All source files** — app views, keyboard extension, shared whisper wrapper

## What You Need To Do in Xcode

### 1. Enable App Groups Capability

This must be done via Xcode's UI (creates the provisioning profile entitlement):

1. Select **VoxVault** target → **Signing & Capabilities** → **+ Capability** → **App Groups**
   - Add: `group.bontecou.VoxVault`

2. Select **VoxVault Keyboard** target → **Signing & Capabilities** → **+ Capability** → **App Groups**
   - Add: `group.bontecou.VoxVault`

### 2. Resolve Packages

After opening the project, Xcode should auto-resolve SPM packages. If not:

**File → Packages → Resolve Package Versions**

This will download:
- KeyboardKit (for the keyboard extension)
- whisper.cpp (via VoxVaultShared local package)

### 3. Verify Model Is Bundled

Check that `ggml-base.bin` appears in:
- **VoxVault target → Build Phases → Copy Bundle Resources**

With file-system sync, it should be auto-included since it's in the `VoxVault/` directory.

---

## Running & Testing

### First Run
1. Build and run the **VoxVault** scheme on a physical device
2. The app copies the bundled base model to the shared App Group container
3. Grant microphone permission when prompted

### Enable the Keyboard
1. **Settings → General → Keyboard → Keyboards → Add New Keyboard**
2. Select **VoxVault Keyboard**
3. Tap it → **Allow Full Access** (required for microphone in keyboard)

### Test the Keyboard
1. Open any text field (Notes, Messages, etc.)
2. Switch to VoxVault keyboard (globe icon)
3. Use `<` `>` arrows to select a model
4. Tap **Start** → speak → tap **Stop**
5. Text appears in the input field

---

## Architecture

```
VoxVault (Main App)
├── HomeView          — dark minimal UI, big record button
├── HistoryView       — scrollable transcript history
├── SettingsView      — model download/select, language

VoxVault Keyboard (Extension)
├── KeyboardViewController  — KeyboardKit standard keyboard
├── VoiceToolbarView        — [< 🎤 >] Model  [▶ Start]
├── VoiceKeyboardState      — recording + transcription state

Packages/VoxVaultShared (Local SPM)
├── AppConstants      — App Group IDs, shared paths
├── AudioRecorder     — 16kHz mono PCM recording
├── WhisperContext    — whisper.cpp C API wrapper
├── ModelManager      — model download, selection, language
├── TranscriptStore   — JSON persistence in App Group
├── Transcript        — data model
└── WhisperModelInfo  — model registry
```

**Data flow:**
1. User taps Start in keyboard toolbar
2. `AudioRecorder` captures 16kHz mono WAV via `AVAudioSession`
3. User taps Stop → `WhisperContext` transcribes on background thread
4. Text inserted via `textDocumentProxy.insertText()`
5. Transcript saved to shared JSON store

---

## Memory Considerations

Keyboard extensions have limited memory (~120-200MB on modern iPhones):

| Model | Size | Keyboard? |
|-------|------|-----------|
| Tiny  | 75 MB  | ✅ Recommended |
| Base  | 142 MB | ⚠️ Works on newer devices |
| Small | 466 MB | ❌ Too large |
| Medium+ | 1.5GB+ | ❌ Main app only |

If the keyboard crashes during transcription, switch to Tiny in Settings.

---

## Re-downloading the Model

If you need to re-download `ggml-base.bin` (e.g., after git clone):

```bash
curl -L -o VoxVault/ggml-base.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

---

## Troubleshooting

**"Open VoxVault to set up"** in keyboard toolbar:
→ Launch the main app at least once so it copies the model to the shared container.

**"Enable Full Access in Settings"**:
→ Settings → General → Keyboard → Keyboards → VoxVault Keyboard → Allow Full Access.

**Keyboard crashes on transcription**:
→ Switch to Tiny model in the app's Settings. Base model may exceed memory limits on older devices.

**whisper.cpp SPM doesn't compile**:
→ The whisper.cpp Package.swift evolves rapidly. Check the repo for the latest compatible version. As a fallback, compile whisper.cpp source files directly (see the `whisper.swiftui` example in the repo).
