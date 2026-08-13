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

The M1-approved restore and offline policy is:

- On the same installation, the last locally verified `PURCHASED` state remains usable
  indefinitely while Play purchase query is unavailable. The UI must visibly label the
  entitlement stale/offline, record the last successful verification time, and provide
  retry/restore. This is continuity of already verified authority, not promotion of an
  unverified state.
- On a fresh install or after local entitlement evidence is absent, corrupt, or cannot
  be authenticated, the app remains on the free tier until Play verifies `PURCHASED`.
  Network unavailability never manufactures an entitlement.
- A current authoritative non-purchased result, including refund or revocation, removes
  Unlimited entitlement for future admission only. It never deletes user content,
  prepared artifacts, transcripts, audio, or history and never strands a job already
  durably admitted under the prior entitlement. Already admitted jobs remain executable
  and recoverable through their terminal outcome.
- `PENDING` grants no Unlimited entitlement. If a previously verified same-install
  purchase is still the last authoritative completed state and Play reports only a new
  pending transaction, that transaction does not erase the prior purchase; otherwise
  the user remains free while pending. The UI exposes pending status and refresh/restore.
- User-cancelled purchase flow changes no prior verified entitlement. With no prior
  verified purchase, cancellation leaves the user on the free tier. A cancelled flow is
  not a revocation signal and does not affect admitted jobs or content.
- A verified authoritative current result with no owned non-consumable is the
  non-purchased result described above. Mere query error, timeout, disconnected service,
  unknown product, or unverified response is `unavailable`, not proof of non-purchase.

The cached evidence must be native, integrity-protected, scoped to the installation and
product, and must distinguish verified purchase, authoritative non-purchase, pending,
cancelled flow, unavailable, and visibly stale derived access. M8 implements and tests
this already-approved policy; it does not choose a new grace duration.

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

- Billing license tests cover purchased/acknowledged, pending with and without prior
  verified purchase, cancelled flow with and without prior verified purchase,
  unavailable and visibly stale same-install access, fresh-install offline behavior,
  authoritative non-purchase, refund/revocation, reinstall/restore, and unknown product
  states.
- Dependency tests prove the billing module cannot import/read capture repositories and
  outbound-request inspection proves no captured fields enter billing payloads/logs.
- Queue tests preserve staged content across every entitlement transition.
- Release inspection and Data Safety review enumerate actual billing SDK/network use.

No store-account transaction is claimed by this ADR.
