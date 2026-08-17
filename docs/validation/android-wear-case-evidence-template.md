# Android/Wear case evidence template

Do not commit this template as proof. Create strict records only from an actual run.

## Choose scope and qualification first

- `milestoneClosure` derives all required cases through the named milestone.
- `caseExecution` is a shard/rerun and cannot claim closure.
- `repositoryObservation` records canonical technical receipts without retained-artifact rehash.
- `hostedRun` binds the exact workflow/run and externally retained artifacts.
- `releaseGate` additionally requires real unexpired definition, campaign, and release approvals.

Never fabricate approvals or signatures for a source-built technical campaign. Repository and hosted technical aggregates use an empty approval list.

## Build-host M2 facts

M2 closure includes `CORE-001` through `CORE-005`, `PERF-003`, and `PERF-008`. Every executed CORE case needs its named canonical diagnostic (`swiftRustParity`, `unsupportedVersionFailClosed`, `bindingDrift`, `readinessPins`, or `shadowSideEffects`) plus the exact allowlisted producer provenance and source-built executable hash. For both PERF cases, record:

- clean source revision;
- toolchain-manifest, build-recipe, inspector/consumer, and executable SHA-256;
- observed host OS/version, architecture, CPU model/count, and total memory;
- canonical execution provenance with the exact consumer tuple and tracked source inventory;
- retained executable bytes for hosted qualification;
- materialization run set (`PERF-003`) or native inspection receipt (`PERF-008`);
- measurement derivations pointing to the typed receipt.

No device serial, provider, signed build ID, or signature belongs in these source-built host records.

Materialization receipts contain exact input/output byte counts and hashes, every contiguous chunk sequence/hash, completed verified drain, twenty 1 MiB timed runs after warmup, exact 1/16/256 MiB aggregate runs, and dedicated 256 MiB RSS samples.

Initial packaging contains exactly six candidate leaves and absolute measurements, with no baseline or growth. Future comparison is valid only against the governed approved-baseline registry, and initial-candidate mode is no longer valid after that registry exists.

## Physical cases

Physical cases still require the signed application identity, exact device role/manufacturer/model/serial hash/OS/API/fingerprint/storage, applicable provider package/version/signing certificate, operator, UTC chronology, fixtures, invariant results, and typed measurements. A missing fact yields incomplete/blocked/notRun evidence, never a placeholder.

## Privacy and paths

Use deterministic synthetic inputs. Machine evidence must not include note text, transcript, audio, filenames, user paths, URIs, document IDs, bookmarks, coordinates, or raw Wear payloads. Repository/artifact paths are slash-normalized relative paths only; absolute paths, URLs, controls, backslashes, `.`/`..`, traversal, and symlinks are rejected.

## Review checklist

- [ ] Scope derives the intended cases; no later case substitutes for a missing earlier case.
- [ ] Execution target matches catalog identity rules.
- [ ] Every numeric measurement exactly matches its typed receipt derivation.
- [ ] Every chunk and required size is present; drain and hashes verify.
- [ ] Hosted runs match the active GitHub Actions environment and rehash the exact still-present external artifact inventory, including executables and archive.
- [ ] Initial package evidence has no predecessor/growth; future comparison matches a real approved registry.
- [ ] All five M2 CORE exit cases are present; performance-only evidence remains incomplete.
- [ ] Qualification wording does not overclaim technical status.
- [ ] Physical and release facts were observed, not copied or invented.
