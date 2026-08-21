# Preset Location Metadata Implementation Plan

## Objective

Implement opt-in, per-preset origin-time location across every Capture source, with `{location}` entry formatting and location metadata as independent outputs, while preserving exact retry snapshots, local-first privacy, existing Capture Bar behavior, and backward compatibility.

## Product decisions

1. Support every Capture source: iOS/iPadOS composer and deep links, Share Extension, App Intents/Shortcuts, immediate voice and keyboard-driven recording, widgets/controls, Apple Watch Capture delivery, and macOS. Watch Recording Only remains a privacy-minimizing raw audio export with no Markdown metadata surface and does not request location.
2. Exact precision is the default. City precision is configurable and emits locality-level labels plus coordinates rounded to two decimal places. Every URL and derived field uses the same privacy-adjusted coordinates.
3. When location is unavailable, ask where an interactive surface exists. The prompt may persist “Always send without location when unavailable” per preset. Unattended `.ask` requests retain an origin-time unavailable outcome and wait for a decision; they never reacquire a later location.
4. Per-entry inline fields are supported. Document frontmatter can retain multiple locations using an idempotent YAML collection keyed by Capture request ID.
5. Support both a structured field builder and an advanced YAML template. Advanced output is validated, bounded, and merged without replacing unrelated frontmatter.
6. Reverse-geocoded labels, coordinates, and provider URLs are supported. Labels use Apple’s system reverse geocoder only, require no paid API/key, run only when configured metadata needs them, and fail softly to coordinate-only metadata.
7. Location acquisition and metadata output are separate choices. `{location}` can use an opted-in snapshot without writing a frontmatter collection or inline fields; pre-existing enabled policies preserve their historical metadata behavior.

## Milestones and acceptance

### 1. Core schema and formatter

- Add backward-compatible, Codable preset/profile policy with acquisition enabled state, independently enabled metadata output, precision, unavailable behavior, output mode, structured fields, collection key, and advanced template.
- Add typed, Codable origin-time location outcome and privacy-adjusted snapshot.
- Add deterministic, locale-independent formatter for coordinates, city precision, labels, Apple Maps, Google Maps, OpenStreetMap, RFC 5870 geo URI, accuracy, timestamp, source, and request ID.
- Add key/template validation, duplicate/collision handling, bounded output, and safe optional-label behavior.
- Missing policy decodes disabled; existing requests/presets remain valid.

### 2. iPhone/iPad foreground

- Quick Capture and composer-opening deep links acquire one location at Send before prepared-request persistence.
- Prepared requests and retries reuse the exact resolved outcome.
- Immediate voice captures acquire at recording stop, not after transcription/delivery.
- Present retry/send-without/cancel behavior while preserving the draft.
- Persist “always send without location” per preset and provide a settings reset.

### 3. Extensions and automation

- Share Extension acquires at its Send action.
- App Intents/Shortcuts acquire during invocation when authorized/capable.
- Widget/control/keyboard paths acquire at invocation or recording stop in the owning process.
- Noninteractive unavailable outcomes are durable and never replaced by a later fix.

### 4. Apple Watch

- Add one-shot Watch-origin location acquisition at recording stop for recordings routed through normal Capture delivery; skip acquisition for raw audio Recording Only output.
- Transfer the privacy-adjusted outcome and preset snapshot with the recording.
- The phone renders/transfers the stored Watch outcome and never substitutes phone location.
- Add Watch permission copy and unavailable-state UI/queue behavior.

### 5. macOS

- Add location entitlement and usage description.
- Add preset configuration and preview parity.
- Acquire at Send or recording stop and use the same snapshot/formatter/failure policy.

### 6. Frontmatter engine and configuration UI

- Structured builder supports coordinates, latitude, longitude, place, city, region, country, Apple/Google/OpenStreetMap URLs, geo URI, accuracy, timestamp, source, and ID.
- Advanced YAML template supports nested mapping/list-item output with live validation and preview.
- Document collection append is idempotent by Capture ID and preserves unrelated frontmatter/comments/order.
- Inline output stays attached to the captured entry.
- Existing explicit Capture Bar Current Location remains independent body-link insertion.
- Preset settings expose `Use Current Location` separately from `Write Location Metadata`; token-driven one-tap enablement turns on acquisition without silently changing note metadata.

### 7. Privacy, docs, and validation

- Update location purpose strings and localizations for opt-in preset acquisition.
- Update README and website docs with origin-time, reverse-geocoding network, provider-link disclosure, precision, pending/failed retention, and no-background-tracking behavior.
- Completed inbox/history tombstones contain no coordinates, labels, URLs, or location templates.
- Validate denied/restricted/not-determined, timeout, cancellation, reduced accuracy, offline geocoding, background transitions, relaunch/retry, every source, every format, and exact/city behavior.

## Verification surface

- `swift test --package-path Packages/VoxboardShared`
- `bash scripts/test-project-contracts.sh` (including host Python 3.9 via postponed annotation evaluation)
- `xcodebuild` build/test for iOS app + tests, macOS app, Share Extension, Watch targets, widgets, and intents as available on the host
- Focused inspection of queued request JSON versus completed tombstones
- Manual/sample rendering of document frontmatter collection, inline fields, and advanced template
- Manual URL construction/opening checks for Apple, Google, OpenStreetMap, and `geo:` formats

## Milestone 7 progress and evidence

Implemented documentation and privacy copy now distinguishes the independent Capture Bar map-link action, opt-in per-preset origin-time acquisition, `{location}` template links, and separately opt-in metadata output. It covers every source, Exact versus City, structured/advanced and frontmatter/inline output, unavailable decisions, recovery retention, reverse-geocoder and provider-link disclosure, scrubbing, and the no-background-tracking boundary.

Purpose copy is present in the iOS, Share Extension, Watch, and Mac Info.plists and each matching string catalog has real locale-specific values for all 23 locales already supported by those catalogs. The shared runtime catalog also contains the location configuration, prompt, validation, accessibility, and Watch status keys in all 23 locales. Project contracts require matching English Info.plist/catalog values, complete purpose-string locale coverage without English values mislabeled as translations, and the core documentation disclosures. No App Store privacy collection category was added because location is not collected by the developer or analytics.

Automated evidence from this implementation pass:

- `swift test --package-path Packages/VoxboardShared`: 543 XCTest cases and 4 Swift Testing cases passed with zero failures.
- Full iOS simulator `VoxboardTests` suite, including immutable recording-time preset snapshots, keyboard preset routing, configuration preview, and Watch location payload/tombstone behavior: 52 tests passed with zero failures.
- Signing-disabled iOS app/test, Share Extension, Keyboard, iOS Widget, macOS app, Watch app, and Watch Widget builds succeeded after the final review fixes.
- All four purpose-string catalogs parse as JSON and contain 23 locale entries; all four Info.plists pass `plutil -lint`.
- `website/index.html`, `website/docs/index.html`, and `website/privacy.html` parse with Python’s HTML parser; focused stale-claim grep and `git diff --check` pass.
- Direct `scripts/test-project-contracts.sh` execution passes under the available Apple Python 3.9.6 after the embedded verifier enabled postponed annotation evaluation; no contract was weakened.
- Physical-device permission prompts, denied/restricted/reduced-accuracy states, offline reverse geocoding, background transitions, Watch-to-phone transfer, provider-link opening, and relaunch behavior remain manual device checks. No such check is marked complete below.

## Completion audit checklist

- [x] Milestone 1 implemented and directly tested by package schema/formatter tests
- [x] Milestone 2 implemented with automated coverage and a signing-disabled iOS simulator build/test gate
- [x] Milestone 3 implemented with automated coverage and signing-disabled extension/widget/keyboard build gates
- [x] Milestone 4 implemented with automated coverage and signing-disabled Watch/Watch-widget build gates
- [x] Milestone 5 implemented with automated coverage and a signing-disabled macOS build gate
- [x] Milestone 6 implemented and directly tested by renderer/editor/configuration tests
- [x] Milestone 7 documentation, privacy copy, localization, and static validation implemented
- [x] Existing Capture Bar action preserved independently in source, UI copy, and documentation
- [x] Legacy preset/request decoding verified by package tests
- [x] Origin-time semantics traced for every source and covered by durable snapshot/no-reacquisition tests; physical-device interruption behavior remains listed below
- [x] Durable unattended decisions and retry paths have automated no-reacquisition coverage
- [x] Per-preset “send without location” preference reset is exposed on iOS and Mac
- [x] Multiple frontmatter locations append idempotently in package tests
- [x] Advanced templates cannot replace unrelated frontmatter in package tests
- [x] Completed Capture and Watch tombstones are scrubbed in automated tests; completed history remains coarse
- [x] Full package tests pass (543 XCTest + 4 Swift Testing tests, zero failures)
- [x] Direct project contract script passes under host Python 3.9.6; focused catalog, plist, HTML, docs, and stale-copy checks pass
- [x] All relevant Xcode targets compile in signing-disabled simulator/macOS build gates
- [x] Final documentation/localization diff reviewed against this checklist

## Device-only release validation not claimed by this local implementation audit

The implementation and all host-available gates are complete. The following require signed physical devices, real permission state changes, or external apps/services and remain release-validation surfaces rather than passing evidence here:

- [ ] iOS, Share Extension, Watch, and Mac permission prompts plus denied/restricted/reduced-accuracy transitions on hardware
- [ ] Offline Apple reverse-geocoder behavior and background termination/relaunch crash injection on hardware
- [ ] Real WatchConnectivity transfer/relaunch behavior between Watch and iPhone
- [ ] Provider-link opening in installed Apple Maps, Google Maps/browser, OpenStreetMap/browser, and a registered `geo:` handler
