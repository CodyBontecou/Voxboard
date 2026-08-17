# Android/Wear validation program

Status: **scoped evidence definitions; no real M2 or physical campaign recorded**

Repository definitions specify targets, cases, gates, evidence, qualification, approvals, and aggregate computation. They do not attest hardware, execution, hosted runs, signatures, or approval.

## Scope

Every required case declares its first milestone and immutable execution target. Aggregate scope is one of:

- `milestoneClosure`: derives every required case whose milestone is at or before `throughMilestone`; caller-supplied subsets are impossible.
- `caseExecution`: derives only its explicit case IDs for a shard or rerun and makes no closure claim.

An M2 closure contains `CORE-001` through `CORE-005`, build-host `PERF-003`, and artifact-build-host `PERF-008`. The CORE cases prevent performance-only evidence from claiming the implementation milestone: parity, fail-closed versions, binding drift, readiness-pin completeness, and side-effect-free Apple shadow execution each require their named production check, exact allowlisted producer provenance, and build-bound executable. An M3 closure also contains all M2 cases and every M3 case. Later physical requirements are not weakened or retargeted.

## Qualification versus technical status

Aggregate `status` reports selected technical coverage. `qualification.level` reports what independently verifiable context exists:

- `repositoryObservation`: canonical receipts and repository facts; no retained-artifact rehash; approvals must be empty.
- `hostedRun`: exact checkout/workflow/run facts authenticated by a live GitHub Actions OIDC token (issuer `https://token.actions.githubusercontent.com`, audience `https://vox.md/m2-evidence/v1`, pinned repository/owner IDs, public visibility, source/workflow SHA and ref, event, run attempt, and GitHub-hosted runner), with a clean tracked checkout, hash-bound tracked orchestrator, and an exact external artifact inventory rehashed while retained; approvals may be empty. Forgeable `GITHUB_*` variables alone never qualify a run.
- `releaseGate`: hosted evidence plus real, hash-bound definition, campaign, and release approvals that remain unexpired at validation time. The CLI currently fails closed because no authenticated approval verifier is configured; schema-shaped JSON alone cannot activate this level.

Technical pass alone never implies hosted qualification, release approval, or milestone completion. Executed M2 repository observations also require `--repository-root`; no M2 provenance is accepted as a free-standing assertion. The M2 exit audit requires hosted M2 closure.

## Target identities

`buildHost` and `artifactBuildHost` evidence use a clean `sourceBuiltHost` build identity plus observed non-secret host OS, architecture, CPU count/model, and memory. They require no fake device serial or application signature. The seven M2 CORE/PERF cases use these targets.

Every physical-device case retains its device-role expansion, exact observed device/provider facts, and `signedApplication` identity with signed build ID and signature hash. Missing facts make evidence incomplete; they are never guessed.

## Typed execution evidence

Executed M2 evidence references canonical typed receipts:

- `execution-provenance.schema.json`: source revision, toolchain, exact case-specific recipe and consumer tuple, retained executable identity, complete sorted tracked source inventory, the PERF-003 deterministic generator (explicitly absent for PERF-008), and hosted facts when applicable. The materialization inventory names `VoxboardM2MaterializationEvidence`, not the Swift parity-oracle executable.
- `materialization-run-set.schema.json`: canonical control documents, seed-derived synthetic input bytes/chunks, terminal verified drains, exact 1/16/256 MiB coverage, twenty-sample 1 MiB latency, and dedicated 256 MiB unfiltered RSS.
- `native-package-inspection.schema.json`: exact six ordered leaves, structured checks, absolute sizes/hashes, comparison mode, and retention.

CORE-001 through CORE-005 diagnostics are emitted by `execute-core` only after each governed production command succeeds. `finalize` consumes and byte-for-byte semantically checks those pre-existing diagnostics and cannot mint them. Each measurement has a derivation selector and source artifact. The validator derives all samples and the statistic. Hosted mode requires `--external-artifact-root`, an exact GitHub workflow reference and `m2-evidence` job, one unconditional canonical step invoking the tracked `run-m2-hosted-evidence.sh` orchestrator, retained executable bytes, and exact declared benchmark/package/archive files. Paths reject noncanonical spellings, absolute prefixes, URL schemes, control characters, backslashes, dot segments, traversal, and symlinks. JSON rejects duplicate names/non-finite numbers; JSON and tar input use explicit byte/member bounds, and tar extensions are forbidden.

## Packaging

The first core uses `initialCandidate`, has no baseline or growth measurement, and may technically pass six absolute gates. A future `approvedBaselineComparison` requires a separately governed real baseline registry and retains the exact <=10% maximum growth gate. Registry and adoption approval must be committed tracked files, hash-bound, unexpired, and accepted by an authenticated verifier that also validates the hosted source campaign/archive. The production CLI currently has no such verifier and rejects adoption files; tests inject an explicitly synthetic in-process verifier only to exercise downstream coherence. Once a registry is genuinely adopted, deletion and `initialCandidate` are forbidden.

## Privacy and campaign layout

Receipts contain only deterministic synthetic generator identity, numeric execution/resource metadata, sequences, and hashes—never note text, audio, transcript, user path, URI, coordinate, or provider handle. Privacy-governed physical cases retain canonical diagnostic-summary restrictions.

A campaign contains only non-symlink `evidence/*.json`, `approvals/*.json`, `aggregate.json`, and exactly the `artifacts/` files declared by evidence references. Large native/benchmark artifacts remain outside Git and are supplied through an equally exact hosted external inventory; undeclared files and symlinks fail validation.

## Validation

```sh
python3 Packages/contracts/scripts/validate_validation_definitions.py
python3 Packages/contracts/scripts/validate_validation_definitions.py \
  --campaign-dir <campaign> \
  --qualification hostedRun \
  --repository-root . \
  --external-artifact-root <retained-artifacts>
python3 -m unittest discover -s Packages/contracts/tests -p 'test_validation_definitions.py' -v
```

Fixtures under `Packages/contracts/fixtures/validation/` and dynamically built test campaigns are explicitly synthetic. They are not real measurements, identities, signatures, approvals, or hosted runs.
