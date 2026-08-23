# Web / Infra / Localization Inventory (LID = WI)

Scope: Cloudflare workers, website, App Store metadata via fastlane, `.strings` localization packages, and localization/analytics process docs. These are **supporting features**, not app features.

---

### F-WI-01 Domain Redirect Worker (voxboard.isolated.tech → vox.isolated.tech)
- Surface: Cloudflare Worker, `worker/domain-redirect/` — not user-visible in-app; affects legacy URLs.
- Summary: A tiny Cloudflare Worker that permanently (HTTP 308) redirects the former product hostname `voxboard.isolated.tech` to the canonical `vox.isolated.tech`, preserving path, query string, and forcing HTTPS and default port. Deployed as route `voxboard.isolated.tech/*` on the `isolated.tech` zone.
- Details:
  - `DESTINATION_HOST = "vox.isolated.tech"` (hardcoded).
  - Rewrites `protocol` → `https:`, clears port; preserves full path + query.
  - Returns `Response.redirect(destination, 308)` — permanent, method-preserving.
  - `wrangler.toml`: name `vox-domain-redirect`, compat date `2026-07-30`, route pattern `voxboard.isolated.tech/*`, zone `isolated.tech`.
  - README documents DNS prerequisite: proxied CNAME `vox → voxboard.pages.dev`; verify 308 on `/` and nested paths.
- Constraints: Requires the old proxied DNS record to remain in place.
- Evidence: `worker/domain-redirect/src/index.ts` (whole file, ~14 lines), `worker/domain-redirect/README.md`, `worker/domain-redirect/wrangler.toml`.
- Status: shipped

### F-WI-02 Onboarding Analytics Worker (event ingestion + validation)
- Surface: Cloudflare Worker + D1. Endpoints: `POST /v1/events`, `GET /health`, `OPTIONS` (CORS preflight); 404 `not_found` for anything else. Production: `https://voxboard-onboarding-analytics.costream.workers.dev`. No UI; queried via Wrangler CLI.
- Summary: Privacy-safe, allow-listed ingestion endpoint for onboarding/activation funnel events. Validates every event name, property key, and property value against fixed sets before inserting into D1 table `onboarding_events`. Deliberately rejects and never stores audio, transcripts, dictated text, keystrokes, file paths, template text, model paths, user names, emails, raw dates, IPs, user agents, or device names.
- Details — **event taxonomy (13 event names)**:
  - `onboarding_started`
  - `onboarding_step_viewed` (prop `onboardingStep`)
  - `onboarding_microphone_permission_completed` (prop `permissionStatus`)
  - `onboarding_model_setup_completed` (props `modelEngine`, `modelSizeBucket`)
  - `onboarding_keyboard_setup_started`
  - `onboarding_keyboard_setup_completed`
  - `onboarding_file_export_setup_completed` (props `fileExportFormat`, `fileExportMode`)
  - `onboarding_paywall_shown` (prop `paywallContext`)
  - `onboarding_purchase_started` (props `productId`, `paywallContext`)
  - `onboarding_purchase_finished` (prop `purchaseOutcome`)
  - `onboarding_restore_started`
  - `onboarding_restore_finished`
  - `onboarding_completed`
- Details — **property schemas (all string, allow-listed, all optional except eventName/installId/eventId)**:
  - `experimentId`: only `voxboard_onboarding_activation`; also must match `/^[a-z0-9._-]{1,80}$/`, must not contain raw date patterns, must not contain sensitive tokens (audio, transcript, keystroke, file, path, email, name, user, …).
  - `variantId`: only `baseline_v1` (same guardrails).
  - `appVersion`: regex `^\d+(\.\d+){0,3}$`; `buildNumber`: `^\d{1,12}$`.
  - `platform`: `ios` | `macos`.
  - `onboardingStep`: `welcome, microphone_access, model_setup, keyboard_enablement, file_export, unlock, ready`.
  - `permissionStatus`: `granted, denied, restricted, unavailable, unknown`.
  - `modelEngine`: `whisper, parakeet, apple_speech, unknown`.
  - `modelSizeBucket`: `bundled, under_100_mb, 100_500_mb, 500_mb_1_gb, 1_gb_plus, unknown`.
  - `fileExportFormat`: `txt, md, json, yaml, disabled, unknown`; `fileExportMode`: `append, new_file, disabled, unknown`.
  - `freeMinutesUsedBucket` / `freeMinutesRemainingBucket`: `0, 0_5_min, 5_15_min, 15_plus_min, unlimited, unknown`.
  - `freeCapturesUsedBucket` / `freeCapturesRemainingBucket`: `0, 1_3, 4_7, 8_9, 10_plus, unlimited, unknown` (added by migration 0002).
  - `paywallContext`: `onboarding, usage_meter, limit, recording, capture_limit, keyboard, widget, settings, restore, unknown`.
  - `productId`: only `bontecou.Voxboard.unlock`.
  - `purchaseOutcome`: `started, succeeded, failed, cancelled, pending`.
  - `errorCategory`: `network_unavailable, store_unavailable, user_cancelled, payment_not_allowed, verification_failed, configuration_unavailable, no_model, microphone_denied, not_unlocked, unknown`.
  - Unknown property key → whole batch rejected with `unknown_property:<key>`; unknown enum value → `unknown_property_value:<key>`.
- Details — **IDs, quotas, transport**:
  - `eventId`/`installId` must be UUIDv1-v5-shaped (`[0-9a-f]{8}-…-[89ab]…`, regex `INSTALL_ID_RE`), lowercased; install UUID is anonymous, app-generated.
  - Body limit 64 KiB (`MAX_BODY_BYTES`); over → `413 body_too_large` (checked both via content-length and re-encoded body).
  - Batch limit: default 50 (`DEFAULT_MAX_BATCH_SIZE`); env `MAX_BATCH_SIZE` clamped to ≤50; over → `batch_too_large`. Empty batch → `empty_batch`. Bad JSON → `invalid_json`.
  - Payload shape: `{ installId?, events: [...] }` or single event object; per-event installId can override batch installId.
  - Insert is `INSERT OR IGNORE` (idempotent on event `id`) via `env.DB.batch`.
  - Full normalized event also stored as `payload_json`; server adds `received_at` timestamp (SQLite `strftime` UTC).
  - Auth: optional `Bearer` token via env secret `INGEST_TOKEN`; **currently unset in production** so requests are accepted without Authorization (documented deliberately so the app doesn't embed a shared token). 401 `unauthorized` if configured and mismatched.
  - CORS: `*` origin, methods GET/POST/OPTIONS, headers authorization+content-type; `cache-control: no-store`. Trailing slashes normalized.
  - D1 database `voxboard-onboarding-analytics` id `af59f484-87cd-4f0b-b4ab-c5225125c50d` (account e4265f322e6380ee832b83ad45e3e8c0). Table columns mirror the allow-listed properties; 5 indexes (received_at, event_name+received_at, variant_id+received_at, install_id+event_name+received_at, onboarding_step+received_at).
  - Migrations: `0001_onboarding_events.sql`, `0002_capture_quota_buckets.sql` (adds capture buckets).
  - Test suite: `test/onboarding-analytics.test.mjs`.
- Constraints: App side (per README/docs): `Voxboard/Info.plist` sets `ONBOARDING_ANALYTICS_ENDPOINT_URL` so release builds send by default; debug builds disabled unless `ONBOARDING_ANALYTICS_ENABLED=1` (+ optional `ONBOARDING_ANALYTICS_TRANSPORT=offline`); events queued in UserDefaults with stable IDs, flushed async, failures never block app flows.
- Details: POST /v1/events validates against a fixed 13-name event enum plus coarse property whitelist (app version/build/platform, step, mic status, model bucket, export format/mode, usage buckets, paywall context, product ID, outcome, coarse error category); unknown names/properties rejected; optional INGEST_TOKEN; D1 storage; GET /health.
- Evidence: `worker/onboarding-analytics/src/index.ts` (all 399 lines; `EVENT_NAMES` L22-36, property sets L49-105, `ingestEvents` L128+, validation L255+), `migrations/0001_onboarding_events.sql`, `migrations/0002_capture_quota_buckets.sql`, `wrangler.toml`, `README.md`, `docs/onboarding-analytics.md`.
- Status: shipped

### F-WI-03 Website — Homepage (index.html)
- Surface: `https://vox.isolated.tech/` — marketing page.
- Summary: Product landing page "Vox.md: Quick Capture for Obsidian and Local Notes" with hero "Capture Now. File It Exactly Where It Belongs." Sections cover: getting it into notes before the moment passes; a capture tool for Markdown people; full capture workflow draft→destination; presets for intent and destination; built around files you can keep; a "Your Notes" privacy section; FAQ (vaults/files/privacy); and a closing CTA. Footer links include mailto Support `codybontecou@gmail.com`.
- Details: Uses `geist.css` and local Geist fonts; screenshot assets under `website/screenshots/` (+ `optimized/*.webp` variants at 360/640 widths).
- Constraints: static hosting; Cloudflare Web Analytics only on production hosts behind a fail-closed analytics-gate endpoint.
- Evidence: `website/index.html` (608 lines; h1/h2 structure verified), `website/geist.css`, `website/fonts/`.
- Status: shipped

### F-WI-04 Website — Documentation Hub (docs/index.html)
- Surface: `https://vox.isolated.tech/docs/` — "Vox.md Documentation: Complete Feature Guide" ("Everything You Can Do With Vox.md").
- Summary: The single comprehensive feature reference (738 lines). Section inventory (h2s): browse-docs jump table; Capture Into Markdown Without Building a New Notes Silo; One Durable Composer for Text, Media, Files, and Voice; Save the Entire Workflow Not Just a Folder (presets/routes); Choose a System Backend or an Optional Local Model; Dictate Into the Text Field You Are Already Editing (keyboard); Share Sheet/Home Screen/Lock Screen/Shortcuts entry points; Watch recording + iPhone delivery; macOS capture system; Recover Work, Control Local Data, and Unlock Unlimited Use; Common Setup and Delivery Problems (troubleshooting). This is the canonical doc-coverage map for product documentation.
- Constraints: `llms.txt` scope notes: documents reachable shipped behavior only; dormant legacy screens/internal Smart Folder flags are not shipped features.
- Details: 10 sections (Getting Started, Quick Capture, Presets, Models, Keyboard, System Integrations, Watch, Mac, History/Settings/Privacy, Troubleshooting) with sidebar navigation; updated 2026-08-21; llms.txt alternate link.
- Evidence: `website/docs/index.html` (738 lines).
- Status: shipped

### F-WI-05 Website — Location Deep-Dive (docs/location/index.html)
- Surface: `https://vox.isolated.tech/docs/location/` — "Current Location, {location}, and Metadata".
- Summary: Standalone guide for per-preset location acquisition vs. metadata output. Sections: acquisition ≠ output; setup per preset; smallest surface; `{location}` token use; structured fields opt-in; Exact vs City consistency; snapshot belongs to capture origin; per-preset unavailable-fix policy (retry/cancel/send once/Always Send Without Location); upgrade migration preserving prior behavior; one explicit snapshot never background tracking; troubleshooting.
- Details: 14 subsections covering acquisition-vs-output split, setup, configurations, token examples, metadata output, precision, capture-source timing, unavailable handling, migration, privacy, troubleshooting.
- Constraints: static page; content mirrors shipped code behavior.
- Evidence: `website/docs/location/index.html` (422 lines).
- Status: shipped

### F-WI-06 Website — Blog
- Surface: `https://vox.isolated.tech/blog/`.
- Summary: Blog index ("Notes on Faster Capture", latest posts section) plus one published post: `/blog/best-voice-to-text-keyboard-iphone/` — "Best Voice-to-Text Keyboard for iPhone" with sections: what matters, how Vox.md handles private dictation, use cases, how to choose, CTA. Post has local screenshot assets (`voxboard-history.png`, `voxboard-settings.png`, `voxboard-main.png`).
- Details: one long-form SEO post (`best-voice-to-text-keyboard-iphone`) plus blog index.
- Constraints: static hosting.
- Evidence: `website/blog/index.html` (198 lines), `website/blog/best-voice-to-text-keyboard-iphone/index.html` (354 lines).
- Status: shipped

### F-WI-07 Website — Privacy Policy & Terms (privacy.html, terms.html)
- Surface: `https://vox.isolated.tech/privacy.html`, `/terms.html`.
- Summary: Privacy Policy sections: Overview; Information We Do Not Collect; Privacy-Safe Onboarding Analytics (describes the F-WI-02 allow-list, explicitly excluding audio/transcripts/keystrokes/paths/emails/raw dates/IPs/device names); On-Device Processing; Keyboard Extension; Microphone Usage; Location Usage (reverse geocoder only when metadata output enabled; token-only skips; Apple/Google/OSM links disclose coords only when opened); Speech Models (opt-in downloads, no bundled weights); Third-Party Services; Data Storage & Deletion; Children's Privacy (<13); Changes; Contact. Terms sections: agreement, service description, license, speech models (Whisper MIT etc., "as is"), user responsibilities, accuracy disclaimer, IP, privacy, warranty disclaimer, liability limits, App Store terms, termination, changes, governing law, contact.
- Details: Contact email on both pages and homepage footer: `codybontecou@gmail.com`.
- Constraints: static pages; legal text only.
- Evidence: `website/privacy.html` (205 lines), `website/terms.html` (199 lines).
- Status: shipped

### F-WI-08 Website — llms.txt, sitemap.xml, robots.txt
- Surface: `https://vox.isolated.tech/llms.txt`, `/sitemap.xml`, `/robots.txt` — machine-facing docs.
- Summary: `llms.txt` (143 lines) is an LLM/agent-facing product fact sheet: canonical name Vox.md, website, App Store link, GitHub repo, `voxboard://` scheme, docs index (mirrors F-WI-04 sections), Product Facts (min versions iOS 17.6/macOS 14/watchOS 10; Control Center iOS 18; Apple Speech iOS 26; Apple Intelligence hardware), capture inputs and editor (limits: 100k chars, 10 shared items, 250 MB), transcription backends with model sizes (Whisper Tiny 75 MB → Large v3 Turbo 1.6 GB; Parakeet v2/v3 ~800 MB), keyboard Full Access safety note, App Intents + deep-link list (`voxboard://capture?action=…`, `voxboard://listen`), privacy/local-data notes (analytics disabled-by-default statement, tombstoning), pricing (free: 15 min + 10 successful deliveries; lifetime unlock; $9.99 fallback display), resources, and scope notes for agents.
- Details: `sitemap.xml` lists 7 URLs (/, /docs/, /docs/location/, /blog/, blog post, privacy, terms) with lastmods 2026-07-29/2026-08-21. `robots.txt` explicitly allows Googlebot, OAI-SearchBot, PerplexityBot, Claude-SearchBot, and `*`; sitemap URL declared.
- Constraints: static hosting; llms.txt must track shipped behavior only (its own scope notes).
- Evidence: `website/llms.txt`, `website/sitemap.xml`, `website/robots.txt`.
- Status: shipped

### F-WI-09 App Store Metadata Pipeline (fastlane)
- Surface: `fastlane/` — App Store Connect delivery, not in-app.
- Summary: fastlane `deliver` pipeline for app `bontecou.Voxboard` (ASC app id `6758967337`, hard-coded API key id T7KGDK4Y4V / issuer 6c3b3640-…). Lanes: `info` (inspect edit/live version, localizations, screenshot sets), `builds` (recent builds), `upload_metadata`, `upload_screenshots`, `upload_all`, `submit` (metadata+screenshots + submit_for_review, automatic_release, `add_id_info_uses_idfa: false`, `export_compliance_uses_encryption: false`). All deliver lanes target `app_version: "1.9.5"`.
- Details:
  - Metadata tree `fastlane/metadata/` has **38 locale folders** (ar-SA … zh-Hant). en-US has 12 files: name, subtitle, description, keywords, promotional_text, release_notes, marketing_url, support_url, privacy_url, primary_category (Productivity), secondary_category (Utilities), copyright. Most non-en-US locales have 11 files (no promotional_text, e.g. en-GB).
  - en-US name: "Vox.md - Quick Capture Notes"; subtitle "Capture Anything to Markdown"; keywords: `obsidian,vault,voice,typing,speech,text,keyboard,transcribe,dictation,offline,files,scanner,photos`; support/marketing URLs = `https://vox.isolated.tech/`; privacy URL = `https://vox.isolated.tech/privacy.html`.
  - Screenshots in `fastlane/screenshots/en-US` only (iPhone + `IPAD_PRO_3GEN_129` sets, "appstore-slide-N.png").
- Evidence: `fastlane/Fastfile` (whole file), `fastlane/metadata/**`, `fastlane/screenshots/en-US/`, `fastlane/README.md` (auto-generated).
- Constraints: localized App Store pricing/copy is authoritative over in-app fallback text; localized upload status per remediation doc.
- Status: shipped (note: remediation doc says upload of localized metadata was "proposed"/not executed at checkpoint — see Uncertainties)

### F-WI-10 App Store Strings Packages (localizations/, app-info-localizations/, localization-drafts/)
- Surface: App Store copy source-of-truth `.strings` files feeding the fastlane pipeline.
- Summary: Two parallel 38-locale `.strings` packages:
  - `localizations/<locale>.strings` — 5 keys each: `description`, `keywords`, `whatsNew`, `supportUrl`, `marketingUrl` (App Store version localization). en-US description is the comprehensive quick-capture description; en-US `whatsNew` covers Apple Watch recording/queue sync.
  - `app-info-localizations/<locale>.strings` — 3 keys each: `name`, `subtitle`, `privacyPolicyUrl` (ASC App Info localization).
  - 38 locales: ar-SA, ca, cs, da, de-DE, el, en-AU, en-CA, en-GB, en-US, es-ES, es-MX, fi, fr-CA, fr-FR, he, hi, hr, hu, id, it, ja, ko, ms, nl-NL, no, pl, pt-BR, pt-PT, ro, ru, sk, sv, th, tr, uk, vi, zh-Hans, zh-Hant.
  - `localization-drafts/summary.tsv` — per-locale length metrics (subtitle/keywords/description/whatsNew char counts) for the same 38 locales; `voxboard-all-locales.json` — combined draft export.
- Details: `localizations/` and `app-info-localizations/` each carry one `.strings` per locale with fixed key sets; drafts directory holds machine-readable review artifacts.
- Constraints: fastlane pipeline consumes these; Apple length limits apply per field.
- Evidence: `localizations/` (38 files, 10 lines each), `app-info-localizations/` (38 files), `localization-drafts/summary.tsv`, `localization-drafts/voxboard-all-locales.json`.
- Status: shipped (drafts = supporting artifacts)

### F-WI-11 App Store Privacy Declaration (app-store-privacy.json)
- Surface: App Store Connect App Privacy, root `app-store-privacy.json`.
- Summary: Published privacy declaration for analytics: Product Interaction → Analytics → Not Linked to You; Purchase History → Analytics → Not Linked to You; User ID (anonymous install UUID) → Analytics → Not Linked to You. First-party only, not used for tracking. Explicit instruction: do not mark audio, transcripts, keystrokes, contacts, location, diagnostics, or user content as collected.
- Details: three declared categories, all Analytics/Not Linked; the anonymous install UUID is the only identifier.
- Constraints: must stay in sync with the analytics worker's actual data contract.
- Evidence: `app-store-privacy.json`; mirrored in `docs/onboarding-analytics.md` ("Website and App Store privacy notes").
- Status: shipped

### F-WI-12 In-App Runtime Localization (process docs; surfaces = app UI)
- Surface: Documented in `docs/i18n-agent-prompt.md`, `docs/localization-glossary.md`, `docs/localization-remediation.md`; implementation lives in `*.xcstrings` catalogs (out of this inventory's file scope, summarized from docs).
- Summary: The app runtime is localized via Xcode String Catalogs across **23 locales** (22 non-English: es, zh-Hans, hi, ar, bn, pt-BR, ru, ja, zh-Hant, fr, de, ko, vi, tr, it, pl, id, uk, nl, th, ur, ta — plus en). 1,389 shared keys + 36 target-specific keys; 100% coverage in iOS/Keyboard/Watch/Mac catalogs; deterministic reviewed-override layer covers 86 high-risk phrases across 22 locales (1,892 values).
- Details:
  - `i18n-agent-prompt.md`: templated per-language agent workflow — branch `i18n/<code>`, translate `Voxboard/Localizable.xcstrings` and `Voxboard Keyboard/Localizable.xcstrings` (4 keyboard strings), register locale in Xcode project, no Swift changes. Documents printf specifier rules (`%.1f`, `%d`, `%@`, positional `%1$d`).
  - `localization-glossary.md`: term guide (Capture, Transcription, Recording, Notes, Clipboard, Keyboard Extension, Unlimited Access = one-time purchase never subscription, Family Sharing) and protected names (Vox.md, Apple Intelligence, Apple Speech, Whisper, whisper.cpp, Parakeet, FluidAudio, CoreML, Obsidian, Markdown, App Store, Apple Watch, iPhone, iPad, iOS, watchOS, macOS, M4A, WAV, TXT, JSON, YAML, SF Symbols, ZenQuotes). Machine translation baseline = Meta M2M100 1.2B (MIT), to be human-reviewed.
  - `localization-remediation.md`: locale reconciliation table — 22 runtime locales map to 25 ASC locales (en→4, es→2, fr→2); bn/ta/ur runtime-only ("Binary only"); 14 safe-default exclusions retained in fastlane tree (ca, cs, da, el, fi, he, hr, hu, ms, no, pt-PT, ro, sk, sv). Screenshot pipeline (`scripts/localization/screenshot_matrix.py`, 500-shot matrix; `generate_localized_app_store_images.cjs`, 21-locale App Store image matrix) and Apple limit rules (name/subtitle 30 chars, promo 170, description 4000, keywords 100 UTF-8 bytes, IAP name 30, IAP desc 45). Three IAPs: `bontecou.Voxboard.unlock`, `.family`, `.familyUpgrade`.
- Evidence: `docs/i18n-agent-prompt.md` (266 lines), `docs/localization-glossary.md` (25 lines), `docs/localization-remediation.md` (264 lines).
- Constraints: runtime catalogs (23 locales) vs ASC metadata locales (38 dirs / 25 mapped) intentionally differ — see remediation table; printf specifier rules must be preserved.
- Status: shipped (runtime catalogs); App Store localized upload = planned/proposed at checkpoint

### F-WI-13 Support & Changelog Surface
- Surface: Website footer (index.html), privacy.html, terms.html; App Store release notes via fastlane (`release_notes.txt` / `whatsNew` strings).
- Summary: User-facing support is a single email: `codybontecou@gmail.com` (homepage footer "Support" mailto; Contact sections on privacy and terms). Changelog exists only as App Store "What's New" (`fastlane/metadata/*/release_notes.txt` and `localizations/<locale>.strings` `whatsNew` key — current en-US content: Apple Watch recording, Watch queue sync, redesigned Ready/Recording/Syncing/Queued/Sent states). No standalone web changelog page exists. The app also has an in-app "Send Feedback" button that opens an email draft with app diagnostics (per i18n prompt string table; app-side, out of scope here).
- Details: footer mailto on homepage; Contact sections on privacy/terms; per-locale `whatsNew` in 39 .strings files plus fastlane `release_notes.txt`; no standalone web changelog.
- Constraints: email-only support channel.
- Evidence: `website/index.html` (footer), `website/privacy.html` (Contact), `website/terms.html` (Contact), `localizations/en-US.strings` (`whatsNew`), `fastlane/metadata/en-US/release_notes.txt`.
- Status: shipped

---

## File-by-file coverage checklist

| File / dir | Read? | Notes |
|---|---|---|
| `worker/domain-redirect/src/index.ts` | ✅ full | |
| `worker/domain-redirect/README.md` | ✅ full | |
| `worker/domain-redirect/wrangler.toml` | ✅ full | |
| `worker/onboarding-analytics/src/index.ts` | ✅ full (399 lines) | |
| `worker/onboarding-analytics/migrations/0001_onboarding_events.sql` | ✅ full | |
| `worker/onboarding-analytics/migrations/0002_capture_quota_buckets.sql` | ✅ full | |
| `worker/onboarding-analytics/wrangler.toml` | ✅ full | |
| `worker/onboarding-analytics/README.md` | ✅ full | |
| `worker/onboarding-analytics/test/onboarding-analytics.test.mjs` | ⛔ not read | tests exist; schema already covered by src |
| `worker/onboarding-analytics/package.json` | ⛔ not read | npm scripts only |
| `website/index.html` | ✅ headings/title/footer/support grep | |
| `website/docs/index.html` | ✅ headings/title | |
| `website/docs/location/index.html` | ✅ headings/title | |
| `website/blog/index.html` | ✅ headings/title | |
| `website/blog/best-voice-to-text-keyboard-iphone/index.html` | ✅ headings/title | |
| `website/privacy.html` | ✅ headings + analytics/location/model/contact excerpts | |
| `website/terms.html` | ✅ headings + contact | |
| `website/llms.txt` | ✅ full | |
| `website/sitemap.xml` | ✅ full | |
| `website/robots.txt` | ✅ full | |
| `website/geist.css`, fonts, favicons, screenshots | ⛔ assets only | |
| `fastlane/Fastfile` | ✅ full | |
| `fastlane/README.md` | ✅ full | |
| `fastlane/metadata/**` | ✅ en-US full; folder listing all 38 locales; en-GB file list spot-checked | |
| `fastlane/screenshots/` | ✅ listing only | en-US only |
| `localizations/*.strings` | ✅ en-US full, ja spot-check, key sets + counts for all | |
| `app-info-localizations/*.strings` | ✅ en-US full + listing | |
| `localization-drafts/summary.tsv`, `voxboard-all-locales.json` | ✅ TSV headers/locales; JSON not opened | |
| `docs/i18n-agent-prompt.md` | ✅ lines 1-180 | |
| `docs/localization-glossary.md` | ✅ full | |
| `docs/localization-remediation.md` | ✅ lines 1-200 | |
| `docs/onboarding-analytics.md` | ✅ full | |
| `app-store-privacy.json` | ✅ head (all three dataUsages verified via docs cross-check) | |

## Uncertainties
- `localization-remediation.md` describes a checkpoint where localized ASC metadata/IAP uploads were "Proposed" (not executed); `fastlane/Fastfile` still pins `app_version: "1.9.5"` and metadata lists iOS 2.0.6 as live in the remediation doc. Whether the localized upload has since been executed is not verifiable from the repo.
- `localizations/en-US.strings` description ("offline voice-to-text keyboard… Whisper… 15 minutes free") reads as an older voice-keyboard positioning vs. the current quick-capture product described in `llms.txt`/docs; remediation doc calls stale non-English descriptions "not reused as source," suggesting `localizations/` may lag the remediation proposal copy.
- The `localizations/` (38-locale) vs runtime (23-locale, 25 ASC) counts differ by design (safe-default exclusions), but which fastlane locales actually have live ASC content is unconfirmed (remediation doc says ASC had only `en-US` at checkpoint).
- `worker/onboarding-analytics/test/onboarding-analytics.test.mjs` not read; no behavioral claims depend on it.
- `llms.txt` states "Production onboarding analytics are disabled by default" while `docs/onboarding-analytics.md` says release builds send events by default (debug disabled by default). These may both be true (release on, debug off) but the phrasing conflicts; flagged for the parent.
