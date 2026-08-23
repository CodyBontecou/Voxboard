# Vox.md Featureset Baseline

This directory is the authoritative product featureset: a complete, evidence-backed
inventory of every feature Vox.md supports, structured so documentation can be
planned, tracked, and audited against it.

## Why this exists

Feature descriptions previously lived in three places with different levels of
freshness (README, website docs, marketing copy) and nowhere completely. This
baseline is built **from the source code** — every feature entry cites the files
and types that implement it — so documentation drift becomes detectable: any doc
claim can be checked against a feature entry, and any feature entry without doc
coverage is a documented gap.

## Layout

```
docs/featureset/
  README.md                      # this file: conventions and how to use the baseline
  inventory/                     # raw per-surface deep inventories (evidence layer)
    ios-ui.md                    # iOS/iPadOS app UI (F-IU-*)
    ios-core.md                  # iOS engines/services (F-IC-*)
    composer-intents.md          # shared composer + App Intents (F-CP-*)
    capture-core.md              # framework-independent capture engine (F-CC-*)
    shared-package.md            # VoxboardShared package (F-SH-*)
    mac-app.md                   # macOS app (F-MC-*)
    watch.md                     # Apple Watch + watch widget (F-WT-*)
    keyboard-widget-share.md     # keyboard, widgets, controls, Live Activities,
                                 #   Share Extension (F-KW-*)
    android-port.md              # Android/Wear port status + contracts (F-AP-*)
    web-infra.md                 # workers, website, localization (F-WI-*)
  featureset.md                  # consolidated registry (the baseline itself)
```

- `inventory/*.md` files are generated from a full read of each surface's source
  (coverage checklists inside each file). They are evidence, not the product doc.
- `featureset.md` consolidates and cross-links every feature into one registry,
  organized by category, with platform coverage, status, and documentation mapping.

## Feature ID scheme

`F-<LID>-<NN>` where `<LID>` is the inventory lane ID:

| LID | Lane |
|-----|------|
| IU  | iOS/iPadOS app UI |
| IC  | iOS app core engines/services |
| CP  | Shared composer & App Intents layer |
| CC  | Capture core engine package |
| SH  | Shared package (models, transcripts, export, analytics…) |
| MC  | macOS app |
| WT  | Apple Watch |
| KW  | Keyboard / widgets / controls / Live Activities / Share Extension |
| AP  | Android/Wear port (planned capability) |
| WI  | Web, workers, localization (supporting surfaces) |

IDs are permanent. If a feature is removed, its ID is retired (status `legacy`),
never reused.

## Status vocabulary

| Status | Meaning |
|--------|---------|
| shipped | Reachable, working, user-visible (or load-bearing for such) today |
| gated   | Shipped but requires OS version, hardware, entitlement, or permission |
| experimental | Ships behind an opt-in or is explicitly labeled experimental |
| hidden  | Ships but not advertised (debug menus, power-user features) |
| legacy  | Compatibility fallback for migrated users; not for new users |
| planned | Designed/contracted but not shipped (e.g. Android/Wear milestones) |

Notes:
- "gated" still counts as shipped for docs purposes; docs must state the gate.
- Dormant code paths that no user can reach are `legacy` or removed from the
  registry; the inventory records them so they are not lost, but they do not
  become documentation requirements.

## Category taxonomy

The consolidated registry groups features by what the user is trying to do, not
by code module:

1. **Quick Capture & Input** — composer, input types (text, links, photos,
   camera, files, scans/OCR, journal pages, sketches, voice), editor commands,
   Capture Bar customization, drafts & recovery, input limits.
2. **Capture Presets & Routing** — preset model, destinations (vault/Files,
   new/existing/rolling notes), placement, entry formatting, templates, metadata
   (frontmatter & inline fields), per-capture overrides, retry/idempotency.
3. **Location** — per-preset opt-ins (Use Current Location / Write Location
   Metadata), precision (exact/city), `{location}` token, unavailable handling,
   privacy adjustments.
4. **Voice Recording & Transcription** — persistent recording, live speech,
   backends (Apple Speech/Whisper/Parakeet), model management, languages, VAD /
   pause detection, one-shot vs listening modes.
5. **AI Enrichment** — Apple Intelligence processing modes, deterministic
   fallbacks, custom instructions, speaker labels, meeting capture.
6. **Entry Points & System Integration** — app UI, keyboard, Share Extension,
   widgets, Lock Screen, Control Center controls, Live Activities, App
   Shortcuts, deep links, Mac global hotkeys, watch complication.
7. **Apple Watch** — local recording, preset selection, durable queue, phone
   sync, Recording Only.
8. **macOS Companion** — workspaces, menu bar, visibility modes, meeting
   capture, import, clipboard transcription, Mac specifics.
9. **History, Stats & Data Management** — transcript history, search, edit,
   delete, export (TXT/MD/JSON/YAML), attachments, activity stats, recovery.
10. **Monetization & Entitlements** — free allowances, lifetime unlock,
    restore, grandfathering, quota persistence.
11. **Settings & Preferences** — model picker, app language, appearance,
    toolbars, keybinds, visibility.
12. **Privacy & Data Handling** — on-device guarantees, tombstoning, history
    coarseness, scrubbing, local-first behavior.
13. **Localization & Accessibility** — supported languages, VoiceOver/
    accessibility behaviors, RTL, in-app language override.
14. **In-Development Platform (Android/Wear)** — milestone status, contracted
    capability, implemented-today split.
15. **Supporting Surfaces** — website/docs, workers (domain redirect,
    onboarding analytics), App Store metadata/localization.

## Documentation mapping (how to use this baseline)

Each feature in `featureset.md` carries a `Docs:` field tracking current
documentation coverage:

- `docs:website/docs` — covered on the website feature guide
- `docs:readme` — covered in the repo README
- `docs:appstore` — covered in App Store metadata
- `docs:none` — no documentation (gap; candidate for docs work)

The mapping is audited by comparing claims in each docs surface against the
registry. New features must be added to the registry in the same change that
ships them; doc updates then reference registry IDs in PR descriptions.

## Maintenance

- Inventories are regenerated when a lane's scope changes materially (new
  files, new surface) — regenerate that lane only; lane IDs keep their meaning.
- `featureset.md` is regenerated/updated from inventories; category structure
  changes require updating this README in the same change.
- The registry is the source of truth for "what is a shipped feature" disputes
  (e.g. dormant legacy screens are not shipped features — see website
  `llms.txt` scope notes, which this registry supersedes operationally).
- **CI enforcement:** `docs/featureset/scripts/check_inventory.py` runs in the
  contracts CI workflow on every change to `docs/featureset/**`. It fails the
  build if any inventory violates the six-field contract or if any inventory
  feature id is missing from `featureset.md`. `--lane <name>` skips the
  coverage check for single-lane iteration.
- **Contribution rule:** a PR that adds or changes a user-visible feature must
  add or update its registry entry and its lane inventory section in the same
  change; reviewers should treat a missing registry diff as incomplete.
