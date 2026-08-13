# ADR-0006: Android backup and device transfer

- Status: **Accepted**
- Product decision ID: `PD-M1-ANDROID-BACKUP-001`
- Required by: M3 and release hardening

## Context

Automatic Android backup or device transfer can move captured content outside the
user-owned vault, restore stale jobs without storage grants, or duplicate installation
identity. That conflicts with local-first durability and explicit provider ownership.

## Decision

Exclude all content-bearing or authority-bearing Vox.md data from Android Auto Backup,
data extraction, cloud backup, and device-to-device transfer:

- capture packages, drafts, audio, transcripts, staged/imported media, and prepared
  bytes/plans;
- Room databases/indexes containing jobs or content, journals, receipts, tombstones,
  recovery state, and wearable replicas/frontiers;
- provider URIs/document IDs/grants, installation/device identity, credentials,
  entitlement caches, model files/caches, diagnostics, and temporary files.

Use `noBackupFilesDir` for capture packages and explicit backup/data-extraction rules
for content stored elsewhere. Non-content preferences may be allowlisted only after a
field audit proves they contain no user content, storage handle, stable installation
identity, credential, entitlement authority, retry frontier, or location. The default
for a new preference is excluded until reviewed.

A new/reinstalled/transferred app creates a new installation identity, asks the user to
select/re-authorize a vault, and reconciles only data actually present on that device.
Wear/phone re-pairing and quota/entitlement behavior follow their separate accepted
policies; backup must not synthesize continuity.

## Compatibility and consequences

This does not delete user-owned Markdown or files in a chosen provider. Users regain
access by selecting that vault, while app-private pending captures intentionally do not
leave the original installation through OS backup. UI and disclosure must make this
recovery boundary clear.

## Rejected alternatives

- **Backup Room but omit media:** rejected because orphan rows and stale authority are
  unsafe and may still contain text/metadata.
- **Rely on `noBackupFilesDir` alone:** rejected because databases/preferences can live
  elsewhere and device-transfer rules differ.
- **Restore provider grants or installation IDs:** rejected because capability and
  identity ownership cannot be transferred safely.
- **Allowlist all DataStore preferences:** rejected because future keys could silently
  become content-bearing.

## Executable gates

- Static tests parse both legacy and modern backup rule resources and prove every
  content-bearing path/database is excluded for cloud and device transfer.
- Instrumentation seeds synthetic content/identity/grants and validates that a backup
  extraction contains none of it while only approved non-content keys may restore.
- Fresh-install/device-transfer tests require new identity and permission repair before
  destination work.
- Release bundle inspection fails when backup flags/rules drift.

No physical transfer result is claimed by this ADR.
