# ADR-0008: Play Billing and network isolation

- Status: **Accepted**
- Product decision IDs: `PD-M1-PLAY-BILLING-001`, `PD-M1-CROSS-STORE-ENTITLEMENT-001`
- Required by: M3 entitlement boundary and M8 billing

## Context

Play purchase infrastructure requires network-capable Google services, while Vox.md
must never send capture content for billing or inference. Apple and Google stores also
do not provide a shared entitlement identity.

## Decision

Map Vox.md Unlimited to a Google Play non-consumable product. Play Billing may use the
network only inside a native billing boundary. Query purchases on startup/resume and
restore, accept access only from verified `PURCHASED` state, acknowledge according to
Play policy, and model pending, cancelled, unavailable, refunded/revoked, and stale
cached states explicitly. Billing failure must never delete, mutate, upload, or block
access to already staged user content; durable jobs remain recoverable while entitlement
requires user action.

The billing module receives product IDs and coarse local entitlement/quota facts only.
It cannot read capture packages, vault/provider records, notes, transcripts, audio,
filenames, URIs, coordinates, hashes derived from user content, or wearable payloads.
Billing logs/analytics contain no captured content or store account/transaction
identifiers beyond protected native evidence strictly required by the store workflow.
Entitlement traffic and storage are isolated from capture workers and core contracts.

Purchases are store-specific. An Apple purchase grants Apple-product access under the
existing Apple policy; a Play purchase grants Android-product access. No cross-store
entitlement, account linking, or backend is implied. Adding one requires a separate
approved account/backend/privacy ADR and migration.

Offline access may use the last locally verified non-revoked purchase state until the
store can refresh; it must not silently convert a pending/unverified/refunded state into
permanent authority. The exact operational grace timing, if needed, must be frozen and
tested before M8 release rather than invented by an implementation.

## Compatibility and consequences

Existing Apple StoreKit products, lifetime/family behavior, and original paid-app
classification remain native Apple compatibility concerns. Shared core materialization
never resolves commerce. Quota counters and staged packages survive temporary store
unavailability.

## Rejected alternatives

- **Share purchase state through capture contracts or a user-content backend:** rejected
  for ownership and privacy reasons.
- **Assume an Apple purchase restores on Play:** rejected because no approved account
  service exists.
- **Network inference/billing SDK access to capture stores:** rejected categorically.
- **Delete queued work when purchase is revoked:** rejected because entitlement and
  content retention are separate.

## Executable gates

- Billing license tests cover purchased/acknowledged, pending, cancelled, unavailable,
  stale offline, refund/revocation, reinstall/restore, and unknown product states.
- Dependency tests prove the billing module cannot import/read capture repositories and
  outbound-request inspection proves no captured fields enter billing payloads/logs.
- Queue tests preserve staged content across every entitlement transition.
- Release inspection and Data Safety review enumerate actual billing SDK/network use.

No store-account transaction is claimed by this ADR.
