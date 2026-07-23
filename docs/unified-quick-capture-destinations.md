# Unified Quick Capture Destinations

Research snapshot: **23 July 2026**

## Goal

Evolve Vox.md from a Markdown-only capture pipeline into one quick-capture system that can deliver the same durable capture to local notes, third-party APIs, Apple frameworks, foreground app handoffs, email, or a webhook.

The source list contains 18 rows and 17 unique destinations. Obsidian appears twice; this plan treats those rows as two distinct transports:

1. Notion, with a Fast Notion-like capture experience
2. Obsidian through native file access
3. Drafts
4. Typefully
5. Reflect
6. Evernote
7. Day One
8. Mem
9. Supernotes
10. Capacities
11. Logseq
12. Obsidian through URI/Shortcuts handoff
13. Any email
14. Any webhook
15. Apple Reminders
16. Todoist
17. TickTick
18. Trello

This plan assumes **one destination per Capture Preset** for the first release. The job model should permit future fan-out, but sending one capture to several services at once introduces partial-success and deletion semantics that should not block the adapter foundation.

## Product experience

The unified system should feel like one product, not 18 integrations:

1. The user chooses a Capture Preset such as Inbox, Journal, Tasks, or Social Draft.
2. The preset owns a destination and its formatting/mapping rules.
3. Quick Capture opens immediately with the correct preset and focuses input.
4. Tapping Send first commits the request and assets to Vox.md-owned durable storage.
5. Vox.md reports **Saved locally** immediately. It then delivers locally, in the background when possible, or through a clearly labeled foreground handoff.
6. The composer clears only after the durable job exists. A network, permission, authentication, app-switch, or sync failure cannot lose the capture.
7. The status UI distinguishes queued, waiting for the user, delivered, degraded, needs authentication, retrying, failed, and unknown outcome.
8. Unsupported content is never silently discarded. Setup and send-time previews say exactly what will be uploaded, converted to text, retained locally, or rejected.

A Fast Notion-like default should be available for every suitable destination: one tap opens a minimal editor, one preset is remembered, and submission requires no route decisions. Advanced target/property settings live in the destination editor.

## What Vox.md already has

The existing code provides an unusually strong base:

- `CaptureRequest` has a stable UUID, source, delivery kind, preset snapshot, processing state, metadata, and ordered multimodal payloads.
- Payloads cover text, links, audio and transcripts, images, arbitrary files, scans/PDF/OCR, and sketches.
- `CaptureDraftStore` and `CaptureInbox` persist requests and staged assets before delivery.
- Prepared on-device processing is persisted so retries do not rerun AI against changed settings.
- The current Markdown pipeline coordinates writes, checks path containment, rolls back attachments, and supports request markers.
- Completed inbox items become payload-free tombstones.
- History intentionally stores coarse metadata rather than captured content.
- Capture quota accounting already reserves and commits by stable request ID.

The main constraint is that `CaptureDestination`, `CaptureReceipt`, `CapturePipeline`, route overrides, renderer, settings UI, and delivery service all assume a filesystem Markdown note.

## Destination viability matrix

| Destination | Primary transport | Execution | Binary fidelity | Retry strength | Initial recommendation |
|---|---|---:|---:|---:|---|
| Notion | REST API | Unattended network | Good, within Notion limits | Medium | High-value cloud adapter after foundation |
| Obsidian files | Security-scoped Markdown files | Local | Full | Strong | Preserve and make first adapter |
| Drafts | x-callback URL | Foreground handoff | Text only | Weak without custom action | Handoff pack |
| Typefully | REST API v2 | Unattended network | Images/video; limited documents | Medium | Draft-only integration |
| Reflect | REST API | Unattended network | Text only | Weak | Gated/experimental |
| Evernote | Remote MCP beta | Unattended network | Potentially good | Medium | Do not ship before Evernote approval |
| Day One | URL scheme or user Shortcut | Foreground handoff | Text; limited handoff media | Weak | Handoff pack |
| Mem | REST API v2 through relay | Unattended network | Text only | Strong create ID | Requires relay or changed auth guidance |
| Supernotes | REST API | Unattended network | Text only in public API | Strong if client UUID contract holds | Good text-first candidate |
| Capacities | REST API | Unattended network | Text only in current CRUD API | Medium/weak | Gated by OAuth approval and ambiguity |
| Logseq | Security-scoped graph files | Local | Full for file graphs | Strong | Early local adapter |
| Obsidian URI | URI or Shortcut | Foreground handoff | Text only | Weak | Fallback when files are inaccessible |
| Review & Send email | Apple composer/share service | Foreground handoff | Good | User-confirmed only | Early handoff adapter |
| Automatic email | Vox relay/provider | Unattended network | Good | Strong with outbox | Later, due privacy/abuse surface |
| Webhook | HTTPS JSON/multipart | Unattended network | Full | Receiver-dependent | High-leverage adapter after security work |
| Apple Reminders | EventKit | Local/system | No attachments | Medium | Early system adapter |
| Todoist | API v1 + Sync commands | Unattended network | Good in later attachment phase | Strong for task commands | Strong cloud candidate |
| TickTick | Open API | Unattended network | Text only | Weak | Gated by undocumented auth/rate behavior |
| Trello | REST API | Unattended network | Good | Medium | Strong cloud candidate, auth transition risk |

“Strong” does not mean universally exactly once. It means the provider offers a caller-supplied ID, idempotent command UUID, or a local marker that can be verified before replay. “Weak” means an interrupted mutation can only be resolved by user review or a potentially incomplete search.

# Shared architecture

## 1. Replace the flat Markdown destination with an adapter record

Do not add optional Notion, Todoist, email, and webhook fields to `CaptureDestination`. Replace it with a provider-neutral record and migrate the current schema:

```swift
struct DestinationRecord: Identifiable, Codable, Sendable {
    var id: UUID
    var name: String
    var adapterID: DestinationAdapterID
    var configurationVersion: Int
    var configurationRevision: UUID
    var configurationData: Data
    var credentialReferences: [CredentialReference]
    var deliveryPolicy: DestinationDeliveryPolicy
}
```

Each adapter owns a typed, versioned configuration codec. `configurationData` may contain target IDs, formatting rules, security-scoped bookmarks, account display snapshots, and unsupported-content policy. It must never contain access tokens, API keys, client secrets, webhook secrets, or SMTP credentials.

Migrate every existing `CaptureDestination` to an adapter such as `local.markdown.obsidian` without changing behavior. Keep compatibility decoding until all supported installed versions have crossed the migration.

## 2. Define one adapter contract

```swift
protocol CaptureDestinationAdapter: Sendable {
    var id: DestinationAdapterID { get }

    func capabilities(
        for destination: DestinationRecord,
        context: DestinationContext
    ) async throws -> DestinationCapabilities

    func validate(
        _ destination: DestinationRecord,
        context: DestinationContext
    ) async throws -> DestinationValidation

    func prepare(
        _ request: CaptureRequest,
        destination: DestinationSnapshot,
        assets: CaptureAssetStore
    ) async throws -> PreparedDelivery

    func deliver(
        _ delivery: PreparedDelivery,
        checkpoint: DeliveryCheckpoint?,
        context: DeliveryContext
    ) async -> DeliveryOutcome

    func reconcile(
        _ delivery: PreparedDelivery,
        checkpoint: DeliveryCheckpoint,
        context: DeliveryContext
    ) async -> DeliveryReconciliation

    func openTarget(for receipt: DestinationReceipt) -> URL?
}
```

The adapter registry is keyed by a stable string, not a Swift enum that requires the core package to change for every future provider.

## 3. Snapshot delivery, not credentials

When the user taps Send, persist a `DestinationSnapshot` containing adapter ID, configuration version/revision, display name, target IDs, formatting/degradation policy, and credential references. Retries should not silently move to a different database, board, journal, list, graph, or recipient because the live destination was edited later.

Credential references remain stable while the Keychain value rotates. If a destination is deleted, queued jobs retain their snapshot and offer explicit **Reconnect**, **Reroute**, or **Discard** actions. Rerouting replaces the snapshot and clears provider-specific attempts; changing only the destination UUID is no longer sufficient.

## 4. Prepare a deterministic delivery plan

`CaptureRequest` remains the immutable source of truth. Each adapter creates a durable `PreparedDelivery` before the first side effect:

```swift
struct PreparedDelivery: Codable, Sendable {
    var schemaVersion: Int
    var requestID: UUID
    var destinationSnapshot: DestinationSnapshot
    var rendererVersion: Int
    var contentHash: Data
    var operations: [PreparedOperation]
    var degradationReport: DegradationReport
}
```

Preparation resolves dates/time zones, title/body split, property mappings, selected assets, provider limits, and exact request bodies. A retry uses byte-identical content or an explicitly migrated renderer version.

Normalize draft and inbox assets into one request package rooted by `requestID`; today direct drafts and inbox requests use different staging roots. The delivery coordinator should not need to know which entry point created a request.

## 5. Model capabilities and degradation explicitly

Capabilities must cover more than payload types:

- Local, network, or foreground-handoff execution
- Requires foreground/user confirmation
- Create, append, prepend, update, heading/block insertion
- Text/Markdown/rich text
- URL/bookmark support
- Binary types, counts, and byte limits
- Structured title, date, due date, recurrence, priority, tags, collections, hierarchy, properties
- Authentication and authorization requirements
- Remote item opener
- Receipt strength: verified, accepted, callback, launch-only, or none
- Idempotency: native key, caller ID, target marker, searchable marker, or manual only
- Reconciliation support
- Background-transfer support

A send-time `DegradationReport` lists every transformed, omitted, retained, or blocked payload. Policies are explicit:

- **Require full fidelity** — block when any payload cannot be represented.
- **Text fallback** — send transcript/OCR/alt text and retain originals locally.
- **Selected assets only** — user chooses exact media classes.

There is no global “silently ignore attachments” option.

## 6. Support three execution modes

### Transactional local

Used by Obsidian file routes, Logseq file graphs, and EventKit. Delivery can usually be verified immediately and can work offline.

### Unattended network

Used by APIs, webhooks, and automatic email. Extensions, widgets, keyboard, Watch, and Shortcuts only enqueue. The containing iOS/macOS app owns credentials and performs network work. iOS background delivery is opportunistic; foreground/app-resume draining remains required even when background `URLSession` is added.

### Foreground handoff

Used by Drafts, Day One, Obsidian URI/Shortcut, and Review & Send email. These jobs enter `awaitingUser`, open another app or composer from foreground UI, and finish only after a callback or user result. A successful URL launch is not equivalent to a successful mutation.

## 7. Expand durable job state

The current pending/processing/failed/completed state is too coarse. Add an attempt journal and user-action state:

- `queued`
- `leased`
- `waitingForNetwork(nextAttemptAt)`
- `waitingForRateLimit(nextAttemptAt)`
- `awaitingUser(action)`
- `needsAuthentication`
- `unknownOutcome`
- `failedPermanent`
- `completed`

A stale lease returns to its prior actionable state. Completed jobs still become content-free tombstones. Checkpoints may retain remote IDs, operation indices, hashes, attempt counts, and retry dates, but not rendered bodies; rendered content belongs in the protected prepared-delivery package and is deleted after completion.

## 8. Make unknown outcome a first-class result

Every mutation crosses a crash window: the provider may commit before Vox.md receives or persists the response.

Rules:

1. Generate all provider-supported idempotency keys from `CaptureRequest.id`.
2. Persist the attempt before transmission.
3. Persist returned remote IDs after each operation rather than only at the end.
4. If the connection fails after bytes may have been sent, return `unknownOutcome`, not ordinary failure.
5. Reconcile by native idempotency key, caller-supplied object ID, target marker, or bounded search.
6. Never automatically repeat an unknown, non-idempotent mutation.
7. If reconciliation is impossible, offer **Open target**, **Mark delivered**, or **Retry—may duplicate**.

This is especially important for Drafts, Day One, Reflect daily-note append, TickTick, Capacities daily notes, and URI handoffs.

## 9. Generalize receipts and history

Replace the file-only `CaptureReceipt` with a provider-neutral result:

```swift
struct DestinationReceipt: Codable, Sendable {
    var requestID: UUID
    var destinationID: UUID
    var adapterID: DestinationAdapterID
    var state: ReceiptState       // accepted, confirmed, degraded
    var resource: ResourceLocator?
    var completedOperationCount: Int
    var acceptedAssetCount: Int
    var warnings: [ReceiptWarning]
    var deliveredAt: Date
}
```

A `ResourceLocator` can contain a local relative path, opaque provider object ID, or validated open URL. Do not force every provider into `noteURL` and `attachmentURLs`.

History remains privacy-limited. Add adapter ID, receipt state, warning count, and an optional opaque resource reference. Full URLs, account IDs, target names, filenames, headers, and response bodies should remain outside ordinary history. If “Open destination” requires a sensitive locator, store it in a short-lived/protected receipt store and expose a setting controlling retention.

## 10. Lift quota accounting around the coordinator

`CaptureDeliveryUsageStore` should wrap the generic delivery coordinator rather than the Markdown pipeline. Reserve before the first destination mutation; commit only at the adapter’s declared success boundary:

- Verified local write
- Confirmed API object creation
- Provider acceptance when later final delivery is outside Vox.md’s control
- User-completed handoff such as Mail composer result `.sent`

A launch-only URI without callback is not a verified success.

## 11. Authentication and security

- Use `ASWebAuthenticationSession`, PKCE, random state, and HTTPS callback links where providers support them.
- Store tokens and user API keys in Keychain, device-only where practical. Store only opaque credential references in App Group files.
- Never embed a provider client secret or shared email/API credential in the app. Providers that require a secret for code exchange need a minimal backend exchange service or explicit provider approval for a public-native client.
- Fixed-provider adapters use an endpoint allowlist and normal ATS validation.
- Webhooks require HTTPS, redirect blocking, private/reserved-address rejection, header restrictions, optional HMAC signing, and careful DNS-rebinding treatment.
- Redact authorization, cookies, query secrets, capture text, URLs, filenames, and response bodies from logs and analytics.
- Destination setup states clearly when content leaves the device and which third party retains it.

# Individual destination plans

## 1. Notion — Fast Notion-like

**Transport:** public Notion integration and REST API. Use OAuth for a consumer product; an internal integration token is suitable only for development or an advanced manual mode. If token exchange/refresh requires a client secret, keep that secret in a minimal backend.

**MVP:** connect a workspace, recommend a preconfigured “Vox Inbox,” select a page or data source, and create one page/row per capture. Title comes from the first useful line. Text maps to blocks, URLs to bookmark/link blocks, metadata to explicitly bound properties, and supported images/audio/PDF/files to Notion-hosted uploads. Do not mutate a database schema or create select options silently.

**Reliability:** chunk rich text and blocks within Notion limits, throttle below documented rate limits, honor `Retry-After`, and checkpoint upload/page IDs. Notion does not document general create-page idempotency. Include a stable request marker/property and reconcile before retry. Append-to-existing-page should be later and opt-in because invisible exactly-once append is not available.

**Blockers:** public integration review, OAuth exchange service, media limits, and ambiguous appends.

Sources: [public integrations](https://developers.notion.com/guides/get-started/public-connections), [authorization](https://developers.notion.com/guides/get-started/authorization), [request limits](https://developers.notion.com/reference/request-limits), [file uploads](https://developers.notion.com/guides/data-apis/uploading-small-files).

## 2. Obsidian — native file destination

**Transport:** keep direct security-scoped filesystem writes as the primary Obsidian route. This is the highest-fidelity, most private adapter and is already mostly implemented.

**MVP changes:** move the existing path planner, Markdown renderer, attachment writer, template loader, document editor, and coordinated writer behind `ObsidianFileDestinationAdapter`. Add writable-vault validation, test write/delete, daily-note folder/date-format settings, create-only daily templates, link/embed policy, typed Properties rendering, a heading picker, and an “Open in Obsidian” URI after successful delivery.

Do not depend on undocumented `.obsidian` JSON files. Optional best-effort settings import can come later. Treat `.obsidian` as a helpful signal, not proof that a selected folder is a vault.

**Reliability:** make request markers mandatory for rolling/shared-note mutation; an app ledger alone cannot close the write-before-receipt crash window. Classify stale bookmarks, offloaded files, provider conflicts, and unavailable document providers as retryable.

Sources: [Obsidian URI](https://obsidian.md/help/uri), [Daily Notes](https://obsidian.md/help/plugins/daily-notes), [Templates](https://obsidian.md/help/plugins/templates), [Properties](https://obsidian.md/help/properties), [embeds](https://obsidian.md/help/embeds).

## 3. Drafts

**Transport:** `drafts:` x-callback URL is the supported cross-platform route. It can create text with tags, inbox/archive state, flagging, and an optional Drafts action. It foregrounds Drafts. Apple Shortcuts is a user-configured alternative, not an intent Vox.md can call directly.

**MVP:** destination settings for tags, inbox/archive, flagged, text template, and optional action name. Percent-encode with `URLComponents`; enforce an empirically tested conservative encoded-byte limit and never truncate. Drafts is text-first: send text, links, transcripts, OCR, and metadata. Block or explicitly text-degrade binary-only captures.

**Reliability:** persist before opening Drafts. Model confirmed callback UUID, cancel, error, launch failure, and timeout/interruption. Stock `/create` is not idempotent; unknown outcomes cannot auto-retry. Later provide a Vox Drafts action that searches for the request marker and returns a UUID for stronger deduplication.

Sources: [URL schemes](https://docs.getdrafts.com/docs/automation/urlschemes), [Shortcuts](https://docs.getdrafts.com/docs/automation/shortcuts), [workspaces](https://docs.getdrafts.com/docs/drafts/workspaces).

## 4. Typefully

**Transport:** Typefully REST API v2 with a user-created bearer key. Store the key only in Keychain. Confirm commercial/public-product suitability with Typefully before shipping.

**MVP:** create **drafts only**, for one selected social set and one platform. Do not schedule or publish directly from Quick Capture. Convert Markdown to conservative platform text, preserve URLs, upload supported images, and put selected private metadata in `scratchpad_text` rather than public copy. Use transcript/OCR fallback; audio and arbitrary files remain unsupported. PDF is platform-specific.

Persist the exact body and uploaded media IDs. Typefully does not document an idempotency key; use the Vox UUID in a private draft title and reconcile recent drafts before repeating an unknown create. Immediate publishing and webhook-backed status belong in later, explicit-confirmation workflows.

Sources: [API docs](https://typefully.com/docs/api), [OpenAPI](https://api.typefully.com/v2/openapi.json), [v1 to v2 migration](https://support.typefully.com/en/articles/13133296-typefully-api-v1-v2-migration-guide).

## 5. Reflect

**Transport:** Reflect’s REST API, with OAuth/PKCE or a personal token. The viable target modes are append daily note and create new note.

**MVP:** text, links, transcripts, OCR, tags, backlinks, and a stable request marker. Offer **reject binary** or explicit **text-only fallback**. Reflect does not document attachment uploads, arbitrary-note append, idempotency, rate limits, or note IDs in write responses.

A 200 plus `success: true` is confirmation only for that request. A timeout after transmission is unknown and cannot be reconciled reliably because content is write-oriented/end-to-end encrypted and write responses lack a note ID. Do not auto-retry ambiguous mutations. Deep links are a manual fallback, not the primary adapter.

Sources: [API](https://reflect.academy/api), [OAuth](https://reflect.app/developer/oauth), [deep links](https://reflect.academy/deep-links).

## 6. Evernote

**Transport:** investigate Evernote’s remote MCP server, not a new classic EDAM integration. Evernote labels EDAM and its iOS SDK deprecated. The MCP server is beta, currently has plan limitations, and needs confirmation that a distributed native capture client is acceptable.

**MVP only after approval:** OAuth, notebook/tag selection, one new note per capture, text/link conversion, and supported multipart attachments. Record the returned note identifier immediately. Include a stable Vox marker and search before retrying an ambiguous create. Append/update is later because it requires read-modify-write and has concurrency risk.

If MCP production access or response contracts are unsuitable, do not ship an undocumented workaround. Legacy EDAM can inform ENML mapping but should not become a new long-lived dependency.

Sources: [legacy deprecation](https://dev.evernote.com/legacy), [MCP overview](https://dev.evernote.com/mcp), [MCP authentication](https://dev.evernote.com/mcp/authentication), [MCP tools](https://dev.evernote.com/mcp/tools).

## 7. Day One

**Transport:** official Day One URL scheme or a user-configured Apple Shortcut. There is no documented general REST API for third-party background delivery. `dayone://post` can create an entry with text, journal, tags, and an optional clipboard image, but it does not document a created-entry callback/ID.

**MVP:** text-first foreground handoff with journal, tags, and body template. Persist the request before opening Day One. Avoid the clipboard-image option by default because it overwrites/exposes pasteboard content and does not provide durable multi-asset delivery. Offer a user-configured Shortcut for richer create/find/append behavior, but treat its contract as setup-dependent.

Unknown URI outcomes cannot auto-retry. A share-sheet fallback may support user-reviewed media, but Vox.md cannot claim deterministic target selection or a semantic receipt until verified on devices.

The macOS `dayone` CLI supports journal, tags, date/timezone, starred state, coordinates, and up to ten image/video/audio/PDF attachments. It is useful for scripts but is not a safe App Store-sandbox foundation because it requires installing/executing a separate tool.

Sources: [URL scheme](https://dayoneapp.com/guides/tips-and-tutorials/day-one-url-scheme/), [Shortcuts](https://dayoneapp.com/guides/day-one-ios/day-one-shortcuts/), [CLI](https://dayoneapp.com/guides/day-one-for-mac/command-line-interface-cli/).

## 8. Mem

**Transport:** Mem REST API v2. `POST /v2/notes` accepts a caller-provided UUID, which gives this adapter strong create idempotency. Mem’s own guidance says API keys should not be exposed in client apps, so a production integration needs a minimal privacy-preserving relay unless Mem adds OAuth or approves native Keychain storage.

**MVP:** deterministic Markdown note, request UUID as Mem note UUID, selected collections, title from first line, and text/transcript/OCR/metadata. Public API media upload is not documented; originals stay local and the user sees a degradation report. Prefer explicit note creation over asynchronous “Mem It,” whose status tracking is not available.

On timeout or conflict, fetch the deterministic UUID and compare content/hash. Avoid append: update replaces the full body and requires the current version.

Sources: [create note](https://docs.mem.ai/api-reference/notes/create-note), [authentication](https://docs.mem.ai/api-reference/overview/authentication), [rate limits](https://docs.mem.ai/api-reference/overview/rate-limits), [Mem It](https://docs.mem.ai/guides/use-cases/mem-it).

## 9. Supernotes

**Transport:** official REST API using a user API key in Keychain. Supernotes supports simple/full card creation, update, append, parent cards, tags, and readback.

**MVP:** one card per capture, native Markdown, configured parent IDs/tags, metadata, and text/link/transcript/OCR. Use the Capture UUID as a full-create card UUID and include a content digest in metadata, subject to a live contract test of duplicate semantics. The public API has no documented file/media upload endpoint; image/file/PDF/sketch payloads require text fallback or rejection.

Create/update responses are HTTP 207 with per-item status, so HTTP success alone is insufficient. Reconcile an interrupted create with `GET /v1/cards/{id}`. Avoid rolling-card append until a safe concurrency/idempotency policy exists.

Sources: [API reference](https://developer.supernotes.app/api-reference), [OpenAPI](https://api.supernotes.app/openapi.json), [API access](https://help.supernotes.app/en/articles/5257176-api-access), [resource limits](https://developer.supernotes.app/api-reference/resource-limits).

## 10. Capacities

**Transport:** curated OAuth REST integration using authorization code, PKCE, and rotating refresh tokens. Do not use the deprecated beta API.

**MVP:** select a space, discover live structures and writable properties, then create a Page/custom object, append a daily note, or create a weblink. Map Markdown, tags, collections, and compatible typed properties. Current CRUD docs do not expose media creation, so images/audio/PDF/files use visible text fallback or block delivery.

Persist target/property IDs and date/timezone in the prepared plan. Object writes can be reconciled by readback. Daily-note append is asynchronous and has no documented idempotency or final callback, so acceptance and confirmation must be distinct; an ambiguous append must not be blindly repeated.

**Blockers:** OAuth client approval, no public media upload, last-write-wins concurrency, and weak daily-note confirmation.

Sources: [API overview](https://developers.capacities.io/api/overview), [authentication](https://developers.capacities.io/api/overview/authentication), [objects](https://developers.capacities.io/api/concepts/objects), [rate limiting](https://developers.capacities.io/api/overview/rate-limiting).

## 11. Logseq

**Transport:** direct writes to a user-selected **file graph**. Refuse DB graphs whose authoritative state is `db.sqlite`; do not edit Markdown exports/mirrors.

**MVP:** inspect `logseq/config.edn` for preferred format, pages/journals directories, journal filename format, and name encoding. Support Markdown file graphs, journal/existing/literal paths, root append/prepend, and graph-root `assets/`. Render Logseq outliner blocks and `key:: value` properties rather than Obsidian embeds. Use `id:: <Capture UUID>` on the root block for retry detection and deep linking.

Before atomic replacement, recheck the source hash because Logseq’s Electron watcher does not coordinate with `NSFileCoordinator`. Re-read and verify the block ID and asset references before committing. Defer Org and semantic child-block insertion until parser fixtures prove compatibility.

Sources: [DB version](https://github.com/logseq/docs/blob/master/db-version.md), [Properties](https://github.com/logseq/docs/blob/master/pages/Properties.md?plain=1), [desktop HTTP API](https://github.com/logseq/logseq/blob/master/resources/docs/api_server.html), [plugin Editor API](https://logseq.github.io/plugins/interfaces/IEditorProxy.html).

## 12. Obsidian — URI/Shortcuts fallback

**Transport priority:** user-configured official Obsidian Shortcut, then official `obsidian://new`, then interactive share sheet. The Advanced URI community plugin is optional and never a hidden dependency.

Use this route only when native file access is unavailable or the user explicitly prefers handoff. URI/URL-launched Shortcut inputs are text-first; staged attachments are not delivered merely because Markdown links mention them.

Persist before handoff, percent-encode all values, enforce an empirically tested encoded-byte ceiling, and use one-time callback nonces. Callback interruption is unknown outcome. Never auto-retry an append. Advanced URI may add heading/line targeting but still needs plugin/version validation and cannot be treated as a universal confirmed receipt.

Sources: [Obsidian URI](https://obsidian.md/help/uri), [Obsidian iOS](https://obsidian.md/help/ios), [Apple Shortcut URLs](https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios), [Advanced URI](https://github.com/Vinzent03/obsidian-advanced-uri).

## 13. Any email

Implement two separately named destinations.

### Review & Send

Use `MFMailComposeViewController` on iOS/iPadOS and `NSSharingService.composeEmail` on macOS. Support recipient, subject/body templates, and selected attachments. The result confirms composer disposition, not inbox delivery. `mailto:` is not a reliable attachment fallback. Jobs wait for foreground user confirmation.

### Automatic Email

Use a Vox relay and email provider; never embed shared SMTP/API credentials. Restrict the first version to challenge-verified recipients, authenticate devices, enforce quotas, and handle bounce/complaint suppression. Configure SPF, DKIM, and DMARC. A backend outbox atomically records the stable idempotency key before provider submission and exposes accepted/delivered/bounced status through verified webhooks. Disable open/click tracking and delete server-side content after a short disclosed retry window.

Sources: [MessageUI](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller), [macOS compose email](https://developer.apple.com/documentation/appkit/nssharingservice/name/composeemail), [SMTP size extension](https://www.rfc-editor.org/rfc/rfc1870.html), [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/).

## 14. Any webhook

**Transport:** public HTTPS `POST` by default, optionally `PUT`/`PATCH`. Disable GET/DELETE, redirects, URL user-info, private/reserved IP targets, dangerous headers, and ATS exceptions.

**MVP:** versioned canonical JSON plus optional `multipart/form-data` assets, exact redacted preview, synthetic Test Send, Keychain bearer/HMAC secrets, `Idempotency-Key: <Capture UUID>`, content digest, and HMAC signature. Never expose local paths/bookmarks. Bound JSON, asset, response, and total sizes. Custom templates are declarative mappings, not JavaScript.

Classify 2xx as accepted; retry transport errors, 408/425/429 and most 5xx with `Retry-After` and jitter. A timeout after sending is unknown and may retry only with the same idempotency key. Receipt extraction is allowlisted and response bodies are capped/redacted.

**Blocker:** DNS preflight plus normal `URLSession` still has a DNS-rebinding TOCTOU gap. Strong protection may require a controlled relay or custom pinned connection path; local-network webhooks should remain unsupported.

Sources: [OWASP SSRF guidance](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html), [ATS](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity), [HTTP semantics](https://www.rfc-editor.org/rfc/rfc9110.html), [HTTP signatures](https://www.rfc-editor.org/rfc/rfc9421.html).

## 15. Apple Reminders

**Transport:** EventKit with full Reminders access. Request permission only during destination setup, never from an extension/widget. Select writable lists by `calendarIdentifier` and do not silently fall back when a list disappears.

**MVP:** one reminder per capture. Derive title from the first useful text/transcript/OCR line, put the full textual representation in notes, map the first explicit URL, and parse only Vox.md’s explicit due-date token format. Priority, recurrence, and alarms come from structured preset settings rather than inferred prose. EventKit has no reminder attachment API; default to block binary loss and offer an explicit text-only fallback.

Persist a `Vox.md capture ID` marker in notes. Reconcile uncertain saves by local identifier and then by scanning the selected list for the marker. There is no documented URL to open a specific reminder.

Sources: [access migration](https://developer.apple.com/documentation/technotes/tn3152-migrating-to-the-latest-calendar-access-levels), [creating reminders](https://developer.apple.com/documentation/eventkit/creating-events-and-reminders), [EKReminder](https://developer.apple.com/documentation/eventkit/ekreminder), [identifiers](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemidentifier).

## 16. Todoist

**Transport:** current Todoist API v1. Use OAuth/PKCE and Keychain. Prefer Sync commands for mutation because deterministic command UUIDs provide documented idempotency; use REST for discovery and uploads.

**MVP:** project/section/label selection, one task per capture, first line as content, remaining Markdown/transcript/OCR/metadata in description, structured due date, priority, and a request marker. Derive Sync command and temporary UUIDs deterministically from the Capture UUID. Later add file uploads and attachment comments; upload idempotency itself is not documented, so attachment legs need separate warnings/checkpoints.

Do not use Quick Add by default because it may reinterpret `#project`, `@label`, dates, and priorities. Offer it only as an explicit provider-parsing mode.

Sources: [API v1](https://developer.todoist.com/api/v1/), [OAuth](https://developer.todoist.com/api/v1/#tag/Authorization/OAuth), [Sync command UUID](https://developer.todoist.com/api/v1/#tag/Sync/Overview/Command-UUID), [uploads](https://developer.todoist.com/api/v1/#tag/Uploads).

## 17. TickTick

**Transport:** official Open API with OAuth. Token exchange requires a shared client secret and the docs do not specify PKCE, refresh tokens, expiry, revocation, rate limits, pagination, webhooks, or idempotency. A production app therefore needs a backend exchange and validation with TickTick developer support.

**MVP if approved:** project picker, one task per capture, title/content, exact due date/timezone, priority, tags, and optional checklist mapping after contract tests. There is no documented attachment endpoint; keep binaries local and report degradation.

Include `Vox-ID` in content. An interrupted create is unknown; scan project tasks for the marker before offering a duplicate-risk retry. The x-callback add-task URL can be a foreground fallback but has a weaker field set and receipt model.

Sources: [Open API](https://developer.ticktick.com/docs#/openapi), [app registration](https://developer.ticktick.com/manage), [URL scheme](https://help.ticktick.com/articles/7055781515422072832), [Shortcuts](https://help.ticktick.com/articles/7270720248427315200).

## 18. Trello

**Transport:** Trello REST API. The current practical route uses an API key plus delegated user token. Keep authentication behind a provider because Trello/Atlassian is transitioning toward OAuth2 and current documentation has access inconsistencies for board/card resources.

**MVP:** workspace/board/list picker, one card per capture, title, conservative Markdown description, due date, URL and binary attachments, and `Vox-ID` marker. Persist the card ID and URL immediately, then checkpoint each attachment. Trello supports multipart attachments within account/workspace limits.

Trello has no documented idempotency key. After an unknown create, search for the exact marker and scan recent target-list cards because indexing may lag. Unknown attachment upload reconciles against card attachments and deterministic UUID-bearing names. Later add labels, members, native checklists, safe updates, and custom fields.

Sources: [authorization](https://developer.atlassian.com/cloud/trello/guides/rest-api/authorization/), [cards](https://developer.atlassian.com/cloud/trello/rest/api-group-cards/), [rate limits](https://developer.atlassian.com/cloud/trello/guides/rest-api/rate-limits/), [changelog](https://developer.atlassian.com/cloud/trello/changelog/).

# Implementation sequence

## Phase 0 — adapter foundation with no product regression

1. Add destination record/configuration/credential reference models.
2. Migrate schema-v1 Markdown destinations to `ObsidianFileDestinationAdapter`.
3. Add adapter registry, capability model, prepared delivery, generic outcome/receipt, checkpoint store, and error taxonomy.
4. Move quota accounting around a generic `CaptureDeliveryCoordinator`.
5. Route both direct composer submission and inbox draining through the same coordinator.
6. Normalize assets into request-ID packages.
7. Add destination snapshots and explicit queued-job rerouting.
8. Extend inbox states and history without retaining new captured content.
9. Keep all existing Markdown tests green and add migration/fault-injection tests.

## Phase 1 — validate all execution modes

Implement four representative adapters before building every brand integration:

- **Obsidian files** — transactional local, full fidelity
- **Apple Reminders** — system framework with partial capabilities
- **Drafts or Review & Send email** — foreground user handoff
- **Webhook** — unattended network, signing, retries, multipart assets

Add Logseq once the local adapter boundary is proven.

## Phase 2 — high-value cloud adapters

- Notion
- Todoist
- Trello
- Typefully, draft-only
- Supernotes

These cover rich documents, tasks, cards, social drafts, and text-first cards with several idempotency models.

## Phase 3 — provider/backend-dependent adapters

- Mem, after relay/auth decision
- Capacities, after OAuth approval
- TickTick, after auth/rate-limit contract validation
- Evernote, after MCP client approval and beta schema validation
- Reflect as an experimental text-only adapter because ambiguous writes cannot be safely reconciled

## Phase 4 — handoff completeness

- Day One
- Obsidian Shortcut/URI fallback
- Advanced Drafts action
- Automatic email relay
- Optional Advanced URI and user-installed Shortcut contracts

# Repo-aware file plan

## New shared core files

Suggested locations under `Packages/VoxboardShared/Sources/VoxboardCaptureCore/`:

- `DestinationRecord.swift`
- `DestinationCapabilities.swift`
- `DestinationAdapter.swift`
- `DestinationSnapshot.swift`
- `PreparedDelivery.swift`
- `DestinationReceipt.swift`
- `DeliveryCheckpointStore.swift`
- `CaptureDeliveryCoordinator.swift`
- `CaptureProjection.swift`
- `DegradationReport.swift`

## Refactors

- `CaptureModels.swift` — retain payload/request models; add generic route snapshot and eventually replace Markdown-only overrides.
- `CapturePipeline.swift` — become the implementation behind `ObsidianFileDestinationAdapter`; remove quota ownership from this level.
- `CaptureInbox.swift` — add waiting/user/auth/unknown states and checkpoint-safe recovery.
- `CaptureHistoryStore.swift` — add adapter/receipt/degradation fields while preserving privacy constraints.
- `CaptureDraftStore.swift` — persist the generic prepared delivery and normalize request assets.
- `CaptureInboxDeliveryService.swift` — dispatch by adapter rather than always resolving a bookmark.
- `CaptureDeliveryUsageStore.swift` — wrap generic success boundaries.
- `TranscriptCaptureDestinationExporter.swift` — create a normal durable capture job instead of knowing Markdown delivery details.
- `CaptureComposerViewModel.swift` — submit through one coordinator; stop duplicating direct/inbox delivery logic.

## UI

Replace the single filesystem editor with a destination catalog and adapter-owned setup flow on both iOS and macOS:

1. Destination type
2. Privacy/execution disclosure
3. Authorization or folder permission
4. Account/target selection
5. Mapping and unsupported-content policy
6. Test delivery
7. Capability summary

The route picker should show only overrides the selected adapter supports. A Notion data-source destination should not display “Heading insertion”; Reminders should show due/priority options; Drafts should explain app switching.

## Credentials and frameworks

Add a shared Keychain credential store under `VoxboardShared`; do not reuse the freemium high-water key directly. Add `AuthenticationServices`, `EventKit`, and MessageUI/AppKit integration in platform targets rather than the framework-independent capture core.

Any OAuth exchange, automatic email, webhook relay, or provider-secret work should live in a separate narrowly scoped service, not the existing analytics worker by default.

# Test strategy

Every adapter must pass one common contract suite:

- Configuration schema migration and round-trip
- Capability and degradation matrix for every `CapturePayload`
- Deterministic prepared plan and content hash
- No secret in library/request/draft/inbox/history/log fixtures
- Offline enqueue and relaunch
- Crash before send, after provider commit, after response, and before receipt persistence
- 401/403/404/409/429/5xx and transport timeout classification
- Stable idempotency key and duplicate reconciliation
- Partial attachment/multi-operation recovery
- Destination deletion/edit while queued
- Quota reserve/commit/release behavior
- Privacy-safe completed tombstone and history

Provider contract tests are opt-in and use dedicated test accounts. Recorded fixtures must be redacted. URI, share-sheet, EventKit, security-scoped folder, iCloud/provider, and callback flows require physical-device coverage.

# Decisions to lock before implementation

1. **One destination per preset for v1.** Add fan-out only after child-job receipts and partial-success UX exist.
2. **No silent loss.** Unsupported binaries block or use an explicit text-fallback policy.
3. **No blind retry after unknown mutations.** User review is preferable to duplicate notes, tasks, cards, posts, or email.
4. **No secrets in App Group storage.** Only Keychain references may cross capture processes.
5. **No provider publishing from Quick Capture by default.** Typefully creates drafts; scheduling/publishing requires a separate confirmation workflow.
6. **Local remains first-class.** Obsidian and Logseq routes should not become second-class wrappers around a cloud-oriented API design.
7. **API integrations are feature-gated by current contracts.** OAuth approval, plans, rate limits, and beta APIs must be revalidated at implementation and release time.

# Recommended first milestone

The first build should not contain 18 incomplete integrations. Its acceptance criteria should be:

- Existing Obsidian/Markdown behavior is unchanged after schema migration.
- All capture entry points create one durable generic job.
- Obsidian file, Apple Reminders, one foreground handoff, and webhook adapters work through the same coordinator.
- Unsupported-content previews are visible before delivery.
- Unknown outcomes cannot auto-retry.
- Credentials never enter App Group JSON or logs.
- History and completed tombstones remain privacy-limited.
- A fifth adapter can be added without changing the inbox, coordinator, quota store, draft model, or composer submission path.

Once that boundary is proven, Notion should be the first large third-party implementation because it validates OAuth, target discovery, structured properties, rich blocks, media upload, rate limiting, and reconciliation while delivering the most recognizable Fast Notion-style user experience.
