# Vox.md localization remediation checkpoint

Status: source/runtime remediation is implemented and builds. The complete
local screenshot matrix has been captured and technically audited. App Store
Connect has not been mutated. Native linguistic review remains the release and
upload blocker.

## Locale reconciliation

All target columns below have complete runtime catalog coverage. `Proposed`
means a local, non-uploaded metadata/IAP draft exists. Screenshot coverage is
complete for the 25 ASC locales in the local matrix.

| Runtime | ASC locale(s) | iOS | Keyboard | Watch | Mac | App Info/version | IAP | Screenshots |
|---|---|---:|---:|---:|---:|---|---|---:|
| ar | ar-SA | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| bn | — | 100% | 100% | 100% | 100% | Binary only | — | — |
| de | de-DE | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| en | en-US, en-AU, en-CA, en-GB | 100% | 100% | 100% | 100% | Proposed | Proposed | 80/80 |
| es | es-ES, es-MX | 100% | 100% | 100% | 100% | Proposed | Proposed | 40/40 |
| fr | fr-FR, fr-CA | 100% | 100% | 100% | 100% | Proposed | Proposed | 40/40 |
| hi | hi | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| id | id | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| it | it | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| ja | ja | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| ko | ko | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| nl | nl-NL | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| pl | pl | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| pt-BR | pt-BR | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| ru | ru | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| ta | — | 100% | 100% | 100% | 100% | Binary only | — | — |
| th | th | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| tr | tr | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| uk | uk | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| ur | — | 100% | 100% | 100% | 100% | Binary only | — | — |
| vi | vi | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| zh-Hans | zh-Hans | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |
| zh-Hant | zh-Hant | 100% | 100% | 100% | 100% | Proposed | Proposed | 20/20 |

Safe-default exclusions retained unchanged: `ca`, `cs`, `da`, `el`, `fi`,
`he`, `hr`, `hu`, `ms`, `no`, `pt-PT`, `ro`, `sk`, and `sv`.

## Current authenticated ASC state

- App ID `6758967337`; primary locale `en-US`; App Info ID
  `a7b2be21-9f93-410f-bccf-52dfcc8dab70`; App Info has only `en-US`.
- iOS 2.0.6 ID `8b2ed115-6327-4caf-9043-67ff2d829647`,
  `READY_FOR_SALE`; only `en-US`; 7 iPhone, 5 iPad, and 3 Watch screenshots.
- macOS 2.0.3 ID `ad8dee0d-ab84-4ff8-afab-e90325982d37`,
  `READY_FOR_SALE`; only `en-US`; 5 desktop screenshots.
- Three approved non-consumables and no subscriptions:
  - `bontecou.Voxboard.unlock`, IAP version
    `a108be0e-e6e2-480f-83b0-da67ed65502a`.
  - `bontecou.Voxboard.family`, IAP version
    `2e05f441-c3be-4b61-8fcb-2cdcf5442363`.
  - `bontecou.Voxboard.familyUpgrade`, IAP version
    `c522045e-5bd4-4ea9-81ce-fae24a06845a`.

## Source and runtime result

- Shared `Localizable.xcstrings` is now a resource of iOS, Mac, Watch, Watch
  widget, iOS widget, keyboard, and share targets as applicable.
- Target-specific `InfoPlist.xcstrings` catalogs cover all seven shipped
  products/extensions.
- Active user-visible dynamic errors, statuses, panels, paywalls, permission
  text, accessibility labels, widgets, Watch, Mac, and share surfaces use
  localizable strings.
- A deterministic reviewed-override layer covers 86 high-risk source phrases
  across all 22 non-English runtime locales (1,892 localized values). It
  includes Watch state, Capture Preset, model, Settings, dynamic built-in
  preset, and screenshot-visible explanatory copy.
- Built-in preset names, prompts, processing modes, model descriptions, and the
  default waveform label now localize at display time without rewriting the
  stored source values. Whitespace-only Mac drafts now use the semantic empty
  state instead of suppressing its prompt.
- Remaining `Voxboard` occurrences are technical bundle IDs, app-group/URL
  identifiers, source/test names, logs, and historical design assets. Product
  IDs and entitlements are unchanged.
- Strict audit: 1,389 shared keys plus 36 target-specific keys; 23/23 locales;
  zero missing/empty/non-translated entries, token mismatches, invalid control
  characters, or repeated-output degeneration groups.
- 354 source-identical values remain in the review report. They are primarily
  protected names, file/format tokens, placeholders, proper names, and accepted
  technical loanwords. Native reviewers must confirm locale-specific loanword
  choices before release.

Audit artifact: `artifacts/localization/runtime-audit.json`.

## Build and test evidence

- Apple `xcstringstool`: 9 catalogs compiled to 207 products (9 × 23).
- iOS aggregate Debug on the exact iPhone simulator: passed; includes keyboard,
  widget, share extension, and embedded Watch app.
- Watch Debug on the exact Watch simulator: passed.
- Mac arm64 Debug: passed.
- `VoxboardTests` generic iOS Simulator `build-for-testing`: passed.
- `VoxboardShared` package: 502 tests passed (498 XCTest + 4 Swift Testing).
- Mac Catalyst execution of `VoxboardTests` is not a valid substitute: its
  host is the iOS `Voxboard` app and Xcode cannot resolve the host modules.
- Existing warnings remain for Swift 6 concurrency, deprecated audio APIs,
  and the unrelated Mac `NSControl`/`NSProgressIndicator` cast.

## Metadata and IAP proposal

Proposal root: `artifacts/localization/metadata-proposal/`.

- 25 supported ASC locales are present; the 14 metadata-only locale folders in
  the original Fastlane tree were not changed or deleted.
- App names/subtitles and version description, keywords, promotional text,
  release notes, support URL, and marketing URL satisfy current Apple limits.
- The current comprehensive `en-US` description is authoritative. Stale
  non-English voice-keyboard-only descriptions were not reused as source.
- iOS and Mac proposal matrices are identical: all 25 safe-default ASC locales.
- IAP proposals satisfy 30-character display-name and 45-character description
  limits. Proposed English source copy:
  - Individual: `Vox.md Individual Unlimited` — `Unlimited Capture and transcription`.
  - Family: `Vox.md Family Unlimited` — `Unlimited access with Family Sharing`.
  - Upgrade: `Vox.md Family Upgrade` — `Add Family Sharing to Unlimited`.
- Non-English descriptions, promotional text, release notes, and all three IAP
  products now use the reviewed remediation copy instead of the defective raw
  machine translations. Other proposal fields remain draft material, and none
  of the marketing copy is native-reviewed or upload-ready until a fluent
  reviewer signs off each locale.

Apple currently limits name/subtitle to 30 characters, promotional text to
170, description to 4,000, keywords to 100 UTF-8 bytes, IAP display name to 30,
and IAP description to 45.

## Screenshot pipeline and blocker

`scripts/localization/screenshot_matrix.py` generates and audits a deterministic
500-shot matrix. It launches an already-booted simulator with forced
`-AppleLanguages`/`-AppleLocale`, refuses to boot devices, waits for rendered
content, detects near-blank and accidental duplicate frames, and builds
per-locale/platform contact sheets using Pillow. Mac frames use a DEBUG-only,
app-owned view-cache capture path, so the desktop and unrelated private content
are never captured.

- Manifest: `artifacts/localization/screenshots/manifest.json`.
- Audit: `artifacts/localization/screenshots/audit.json`.
- Expected: 500 raw images and 100 contact sheets.
- Current: 500 raw images and 100 contact sheets.
- Audit: 0 missing, 0 near-blank, and 0 duplicate story groups.
- Dimensions: 175 iPhone at 1320×2868; 125 iPad at 2064×2752;
  75 Watch at 416×496; 125 Mac at 2360×1520.

Representative visual review covered all four platforms plus Arabic RTL,
Japanese Watch, German and Arabic Mac, Traditional Chinese and Thai iPad, and
Hindi and Japanese iPhone. The review exposed and then verified fixes for mixed
English built-in preset values, semantically wrong Watch states and preset
explanations, model/settings helper text, and a Mac whitespace-only empty-state
defect. The final sampled frames contain no launch-white screens, private data,
or obvious clipping. A fluent reviewer must still approve every non-English
locale before any screenshot, metadata, or IAP localization is uploaded.

### Localized App Store compositions

`scripts/localization/generate_localized_app_store_images.cjs` composes the
reviewed localized captures and copy into variants of the live English App
Store visual system. It writes a non-uploaded 21-locale matrix to
`artifacts/localization/app-store-generated/`:

- 147 iPhone images at 1320×2868.
- 105 iPad images at 2048×2732.
- 63 Watch images at 416×496.
- 105 Mac images at 1440×900.
- Manifest: `artifacts/localization/app-store-generated/manifest.json`.
- Live English references, downloaded read-only from App Store Connect:
  `artifacts/localization/app-store-english-reference/`.

The compositor uses the English warm-white iPhone, black monospaced iPad, and
dark-grid Mac treatments. Watch images are resized localized captures without
an added marketing overlay. Exact overlay copy comes from the reviewed
metadata/screenshot override sources plus concise locale-specific labels; it
does not use image-model-generated text or redraw the app UI. Captures recorded
in a disabled/faded transition state are replaced with a clear capture of the
same localized screen where possible; three remaining sources receive a
documented highlight-contrast recovery, and framed UI gets a mild post-resize
sharpening pass. All 84
locale/device directories pass `asc screenshots validate` with no errors or
warnings. The generated images still require fluent visual review before any
App Store Connect upload.

## Exact mutation plan (not executed)

Do not run this section until screenshots are complete, native review is signed
off, editable version IDs are confirmed, and the user approves this exact plan.
The current live versions are `READY_FOR_SALE`; if Apple rejects adding version
localizations, stop and request user-provided next iOS/Mac version numbers.

For each locale under the proposal root:

```bash
asc app-setup info set \
  --app 6758967337 \
  --app-info a7b2be21-9f93-410f-bccf-52dfcc8dab70 \
  --locale "$LOCALE" \
  --name "$NAME" \
  --subtitle "$SUBTITLE" \
  --privacy-policy-url "https://vox.isolated.tech/privacy.html"

asc localizations create \
  --version "$EDITABLE_IOS_VERSION_ID" \
  --locale "$LOCALE" \
  --description "$DESCRIPTION" \
  --keywords "$KEYWORDS" \
  --promotional-text "$PROMOTIONAL_TEXT" \
  --whats-new "$WHATS_NEW" \
  --support-url "https://vox.isolated.tech/" \
  --marketing-url "https://vox.isolated.tech/"

asc localizations create \
  --version "$EDITABLE_MAC_VERSION_ID" \
  --locale "$LOCALE" \
  --description "$DESCRIPTION" \
  --keywords "$KEYWORDS" \
  --promotional-text "$PROMOTIONAL_TEXT" \
  --whats-new "$WHATS_NEW" \
  --support-url "https://vox.isolated.tech/" \
  --marketing-url "https://vox.isolated.tech/"
```

Use `asc localizations update` instead of `create` for any localization that
appears in the immediate preflight query.

For each IAP version and locale:

```bash
asc iap versions localizations create \
  --version-id "$IAP_VERSION_ID" \
  --locale "$LOCALE" \
  --name "$IAP_DISPLAY_NAME" \
  --description "$IAP_DESCRIPTION"
```

Use `asc iap versions localizations update --localization-id "$ID"` for
existing `en-US` IAP localizations.

After contact-sheet approval, validate and upload without submitting/releasing:

```bash
asc screenshots upload --app 6758967337 --version-id "$EDITABLE_IOS_VERSION_ID" --path "$SCREENSHOT_ROOT" --device-type APP_IPHONE_69
asc screenshots upload --app 6758967337 --version-id "$EDITABLE_IOS_VERSION_ID" --path "$SCREENSHOT_ROOT" --device-type APP_IPAD_PRO_3GEN_129
asc screenshots upload --app 6758967337 --version-id "$EDITABLE_IOS_VERSION_ID" --path "$SCREENSHOT_ROOT" --device-type APP_WATCH_SERIES_10
asc screenshots upload --app 6758967337 --version-id "$EDITABLE_MAC_VERSION_ID" --platform MAC_OS --path "$SCREENSHOT_ROOT" --device-type APP_DESKTOP
```

Then re-query App Info, both versions, every screenshot set, all three IAP
versions/localizations, and subscriptions. Do not submit or release.

## Risk and rollback

- Highest risk: non-native machine translation and screenshot layout/RTL.
- Current live versions may not accept new version localizations; no new version
  number has been invented.
- The legacy Fastlane uploader contains stale assumptions and must not be used
  as an approval shortcut.
- Rollback before ASC writes is `git revert`/discarding this branch. After
  approved ASC writes, revert localized fields to the preflight snapshot and
  remove only newly created localizations/screenshots. Product IDs, pricing,
  entitlements, submissions, and releases are outside the mutation plan.
