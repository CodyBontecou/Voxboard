# Featureset Baseline — Completion Audit

Objective: identify **every feature this app supports** from the codebase, in
detail, and structure it as a featureset baseline used to manage documentation.

Deliverables and their acceptance evidence:

| # | Deliverable | Acceptance evidence | State |
|---|---|---|---|
| D1 | Per-surface raw inventories (evidence layer) covering every app surface | `inventory/*.md` for all 10 lanes; each has feature sections `F-<LID>-NN`, file-by-file coverage checklist, Uncertainties section; `scripts/check_inventory.py` passes per lane | **DONE — 10/10 green, 335 features** |
| D2 | Full-surface coverage: every source directory in the 7 targets + shared packages + workers/website/apps inventoried | Lane scope lists map 1:1 to `find`-enumerated Swift files; no lane skipped | **DONE — 10/10** |
| D3 | Consolidated registry `featureset.md` grouping all features by category with platform, status, docs mapping | All inventory IDs appear in registry; categories 1–15 populated | **DONE — 15/15 categories, all lanes registered** |
| D4 | Documentation coverage mapping (baseline for managing docs) | Every registry entry carries a `docs:` disposition; gap register lists undocumented shipped features | **DONE — gap register: 3 real gaps found and closed in website docs on 2026-08-22 (`#mac-meeting`, `#stats`, `#capture-types` a11y note); 6 intentional, 3 legacy flagged** |
| D5 | Conventions + maintenance rules | `README.md` defines IDs, statuses, categories, regeneration policy | Done |
| D6 | Mechanical verification | `check_inventory.py` green across all inventories; spot-checks recorded below | **DONE — 10/10 green** |

## Verification log (spot-checks against source)

- mac-app.md F-MC-08/09/10 — verified against `MacKeyboardHintCenter.swift`,
  `VoxboardMacApp.swift` (⌃B keyCode 11, MenuBarExtra gating, 4 visibility
  modes). PASS.
- ios-ui.md F-IU-01 — verified against `RootView.swift` (destinations, DEBUG
  stories, pendings). PASS.
- ios-core.md F-IC-14/15/17 — verified against `TranscriptionServer.swift`,
  `FoundationModelsBackend.swift`, `LiveActivityController.swift` read in full
  by the orchestrator (60s stale guard, @Generable schema incl. dormant
  SmartFolder surface, endingActivityIDs dedup, setting gates). PASS.
- ios-core.md F-IC-30 — thin section rewritten by orchestrator from the
  16-line `VoxboardAppDelegate.swift`. PASS.
- composer F-CP-16/17 — verified against `CaptureAppIntents.swift` read in
  full by the orchestrator (7 intents, entity queries, unattended location
  policy incl. `.ask` foreground-decision persistence). PASS.
- capture-core F-CC-16/17 — verified against `CaptureModels.swift`/`CaptureVox.swift`
  anchors (payload kinds, route precedence, retry-marker default-off). PASS.
- First-hand anchors read by orchestrator (validation base):
  `CaptureModels.swift`, `CaptureVox.swift`, `CaptureInputLimits.swift`,
  `CaptureAppIntents.swift`, `TranscriptionBackend.swift`,
  `WhisperModelInfo.swift`, `UsageTracker.swift`, `RootView.swift`,
  `SpeakerDiarizationService.swift` (head), `AppLanguagePreference.swift`,
  `FoundationModelsBackend.swift`, `TranscriptionServer.swift`,
  `LiveActivityController.swift`, `VoxboardAppDelegate.swift`.

## Residual scope notes

- Android/Wear (F-AP) is recorded as planned/in-development capability and is
  explicitly separated from shipped features; it is not part of "shipped
  featureset" claims.
- Workers/website (F-WI) are supporting surfaces, labeled as such.
- Documentation claims verified against: `website/docs/index.html`,
  `website/docs/location/index.html`, `README.md`, `website/llms.txt`,
  `fastlane/metadata/en-US/*`.
