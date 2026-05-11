# Contributing to Voxboard

Thanks for your interest in contributing! Voxboard is open source under the [AGPL-3.0](LICENSE), and we welcome bug reports, feature ideas, design feedback, accessibility fixes, translations, and pull requests.

## Ways to contribute

- **File a bug** — open an issue with reproduction steps, iOS version, device, model selected, and whether you were using the main app, keyboard, widget, or Live Activity.
- **Propose a feature** — start a thread in [GitHub Discussions](https://github.com/CodyBontecou/Voxboard/discussions) before opening a large PR, so we can align on scope.
- **Improve docs** — setup notes, screenshots, troubleshooting, and clearer explanations are always appreciated.
- **Improve accessibility** — keyboard controls, widget states, labels, focus handling, and reduced-motion behavior are important.
- **Hang out** — join the [Isolated Tech Discord](https://discord.gg/RaQYS4t6gn) and say hi.

## Development setup

### Prerequisites

- macOS with **Xcode 26.2 or later** recommended
- Apple Developer account for device signing
- A physical iPhone or iPad for keyboard extension, microphone, background audio, widgets, and App Group testing

### Clone and open

```bash
git clone https://github.com/CodyBontecou/Voxboard.git
cd Voxboard
open Voxboard.xcodeproj
```

### Configure signing

There are three targets — set the Team and Bundle Identifier on each:

| Target | Default Bundle ID | Notes |
|---|---|---|
| `Voxboard` | `bontecou.Voxboard` | Main iOS app |
| `Voxboard Keyboard` | `bontecou.Voxboard.Voxboard-Keyboard` | Custom keyboard extension |
| `Voxboard WidgetExtension` | `bontecou.Voxboard.Voxboard-Widget` | Widgets and Live Activities |

For local development, change the bundle ID prefix to your own (for example, `com.yourname.voxboard`) on all targets so signing does not conflict with the published build.

### App Group entitlement

The app, keyboard, and widget share models, transcripts, settings, and IPC files through an App Group. Update the App Group identifier on each target's **Signing & Capabilities** tab to match your team prefix (for example, `group.com.yourname.voxboard`). Then update the matching string in `Packages/VoxboardShared/Sources/VoxboardShared/AppConstants.swift`.

### Build & run

1. Select the **Voxboard** scheme.
2. Choose your physical device.
3. Press ⌘R to build and run.
4. Grant microphone permission.
5. Enable the keyboard in **Settings → General → Keyboard → Keyboards → Add New Keyboard → Voxboard**.
6. Enable **Allow Full Access** for the keyboard so it can participate in the microphone/shared-container workflow.
7. Open a text field, switch to Voxboard, start listening from the app if prompted, and test a record/stop transcription segment.

## Testing notes

- Test the main app and keyboard extension together; many flows depend on App Group shared state.
- Test on hardware before opening a PR. The simulator does not fully represent keyboard, microphone, Live Activity, or background audio behavior.
- For UI changes, include before/after screenshots.
- For transcription changes, specify the model and language you tested.
- For file export changes, verify TXT, Markdown, YAML, append mode, and template mode when relevant.

## Code style

- **SwiftUI-first** — prefer SwiftUI unless UIKit is required by an extension point.
- **Privacy by default** — do not add analytics, telemetry, cloud transcription, or network calls that ship user voice data off-device.
- **On-device first** — keep inference and enrichment local whenever possible.
- **Accessibility matters** — maintain labels, hints, hit targets, keyboard navigation, and reduced-motion fallbacks.
- **Match existing patterns** — read nearby files before introducing new services, shared keys, or UI components.

## Pull request workflow

1. Fork the repo and create a feature branch off `main`.
2. Keep PRs focused — one logical change per PR.
3. Explain why the change is needed and how you tested it.
4. Include screenshots or screen recordings for UI changes.
5. Confirm the app builds and the keyboard flow works on a physical device.

## Code of conduct

Be kind. Assume good faith. Disagree with ideas, not people. If something feels off, email cody@isolated.tech.

## License

By contributing to Voxboard you agree that your contribution will be licensed under the [AGPL-3.0](LICENSE).
