# Onboarding Analytics

Vox.md has an app-side, privacy-safe onboarding analytics engine modeled after the Health.md pricing analytics client.

## Production status

Production ingestion is deployed at:

```text
https://voxboard-onboarding-analytics.costream.workers.dev
```

The remote D1 database is `voxboard-onboarding-analytics` (`af59f484-87cd-4f0b-b4ab-c5225125c50d`). `Voxboard/Info.plist` configures `ONBOARDING_ANALYTICS_ENDPOINT_URL` with this endpoint so release builds send events by default.

No ingest token is configured today, matching the Health.md worker setup. If abuse becomes an issue, set a Worker `INGEST_TOKEN` secret and provide `ONBOARDING_ANALYTICS_INGEST_TOKEN` to the app build.

Events are queued in UserDefaults with stable event IDs and flushed asynchronously. Failures never block app flows.

## Debug/local testing

Debug builds are disabled by default. To exercise queuing locally, set:

```text
ONBOARDING_ANALYTICS_ENABLED=1
ONBOARDING_ANALYTICS_TRANSPORT=offline
```

## Website and App Store privacy notes

The updated privacy policy is deployed at:

```text
https://vox.isolated.tech/privacy.html
```

The fastlane privacy, support, and marketing URLs use the canonical `vox.isolated.tech` domain.

App Store Connect App Privacy is now published for app `6758967337` with the canonical declaration in `app-store-privacy.json`:

- Product Interaction → Analytics → Not Linked to You
- Purchase History → Analytics → Not Linked to You
- User ID (anonymous Vox.md install UUID) → Analytics → Not Linked to You

All entries are first-party analytics only and not used for tracking. Do not mark audio data, transcripts, keystrokes, contacts, location, diagnostics, or user content as collected for this analytics path.

## Privacy contract

Allowed fields are intentionally coarse:

- anonymous install UUID
- event name
- experiment/variant IDs
- app version/build/platform
- coarse onboarding step
- microphone permission status
- model engine and size bucket
- file-export format/mode only
- free-minute and successful-Capture usage buckets
- paywall context
- product ID
- purchase/restore outcome
- coarse error category

Do **not** add audio, recordings, transcript text, dictated text, keystrokes, file/folder paths, custom template text, model file paths, user-entered names, email addresses, raw dates/timestamps, device names, IP addresses, or user-agent storage.
