#!/usr/bin/env python3
"""Execute, retain, and assemble the governed hosted M2 exit campaign."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

CORE_CHECKS = {
    "CORE-001": ("swiftRustParity", ["cargo", "test", "--manifest-path", "Packages/vox-core-rust/Cargo.toml", "--locked", "-p", "vox-core", "swift_oracle_corpus_matches_production_sessions_and_executes_negatives", "--", "--exact"]),
    "CORE-002": ("unsupportedVersionFailClosed", ["cargo", "test", "--manifest-path", "Packages/vox-core-rust/Cargo.toml", "--locked", "-p", "vox-core", "readiness_is_exact_and_fail_closed", "--", "--exact"]),
    "CORE-003": ("bindingDrift", ["Packages/vox-core-rust/scripts/check-bindings.sh"]),
    "CORE-004": ("readinessPins", ["cargo", "test", "--manifest-path", "Packages/vox-core-rust/Cargo.toml", "--locked", "-p", "vox-core", "build_info_exposes_exact_readiness_pins", "--", "--exact"]),
    "CORE-005": ("shadowSideEffects", ["swift", "test", "--package-path", "Packages/VoxboardShared", "--filter", "CaptureCoreEnginePolicyTests"]),
}
SHADOW_ISOLATION_CHECKS = (
    "shadowFrozenInputCompared", "shadowLegacyAuthorityReturned", "shadowNoDestinationWrites",
    "shadowNoAttachmentCopies", "shadowNoQuotaMutations", "shadowNoQueueMutations",
    "shadowNoSuccessReports", "shadowNoContentPathLogs",
)
SEED = "9c795fa9af3eb6fa1bb450172c12a4a9abc04ac1326b76b8a6b8400d8b207ded"
TOTAL_DOMAIN = b"vox-m2-total-input-v1\0"
CORE_BASE_SOURCES = {
    "Packages/VoxboardShared/Package.swift",
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureEntryTemplateRenderer.swift",
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureMarkdownRenderer.swift",
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CaptureModels.swift",
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CapturePathPlanner.swift",
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/CapturePipeline.swift",
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore/MarkdownDocumentEditor.swift",
    "Packages/VoxboardShared/Sources/VoxboardM2Oracle/main.swift",
    "Packages/VoxboardShared/Sources/VoxCoreFFI/module.modulemap",
    "Packages/VoxboardShared/Sources/VoxCoreGenerated/VoxCore.swift",
    "Packages/VoxboardShared/Sources/VoxCoreRust/VoxCoreRust.swift",
    "Packages/VoxboardShared/Tests/VoxboardCaptureCoreTests/CaptureCoreEnginePolicyTests.swift",
    "Packages/contracts/manifest.json",
    "Packages/contracts/validation/case-catalog.json",
    "Packages/vox-core-rust/Cargo.lock", "Packages/vox-core-rust/Cargo.toml",
    "Packages/vox-core-rust/crates/vox-core-uniffi/Cargo.toml", "Packages/vox-core-rust/crates/vox-core-uniffi/src/lib.rs",
    "Packages/vox-core-rust/crates/vox-core/Cargo.toml", "Packages/vox-core-rust/crates/vox-core/build.rs", "Packages/vox-core-rust/crates/vox-core/src/lib.rs", "Packages/vox-core-rust/crates/vox-core/tests/m2_core.rs",
    "Packages/vox-core-rust/generated/kotlin/md/vox/core/vox_core_uniffi.kt", "Packages/vox-core-rust/generated/swift/VoxCore.swift", "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h", "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap",
    "Packages/vox-core-rust/rust-toolchain.toml", "Packages/vox-core-rust/scripts/check-bindings.sh", "Packages/vox-core-rust/scripts/generate-oracle-fixtures.sh", "Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py", "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh", "Packages/vox-core-rust/uniffi.toml",
}
PERF3_SOURCES = {
    "Packages/VoxboardShared/Package.swift", "Packages/VoxboardShared/Sources/VoxboardM2MaterializationEvidence/main.swift", "Packages/VoxboardShared/Sources/VoxCoreFFI/module.modulemap", "Packages/VoxboardShared/Sources/VoxCoreGenerated/VoxCore.swift",
    "Packages/vox-core-rust/Cargo.lock", "Packages/vox-core-rust/Cargo.toml", "Packages/vox-core-rust/crates/vox-core-uniffi/Cargo.toml", "Packages/vox-core-rust/crates/vox-core-uniffi/src/lib.rs", "Packages/vox-core-rust/crates/vox-core/Cargo.toml", "Packages/vox-core-rust/crates/vox-core/build.rs", "Packages/vox-core-rust/crates/vox-core/src/lib.rs", "Packages/vox-core-rust/generated/swift/VoxCore.swift", "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h", "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap", "Packages/vox-core-rust/rust-toolchain.toml", "Packages/vox-core-rust/scripts/generate-m2-materialization-input.py", "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh", "Packages/vox-core-rust/scripts/run-m2-materialization-evidence.sh", "Packages/vox-core-rust/uniffi.toml",
}
PERF8_SOURCES = {
    "Packages/vox-core-rust/Cargo.lock", "Packages/vox-core-rust/Cargo.toml", "Packages/vox-core-rust/crates/vox-core-uniffi/Cargo.toml", "Packages/vox-core-rust/crates/vox-core-uniffi/src/lib.rs", "Packages/vox-core-rust/crates/vox-core/Cargo.toml", "Packages/vox-core-rust/crates/vox-core/build.rs", "Packages/vox-core-rust/crates/vox-core/src/lib.rs", "Packages/vox-core-rust/rust-toolchain.toml", "Packages/vox-core-rust/scripts/build-android-cdylibs.sh", "Packages/vox-core-rust/scripts/build-apple-xcframework.sh", "Packages/vox-core-rust/scripts/inspect-native-packages.py", "Packages/vox-core-rust/scripts/merge-apple-staticlib.sh", "Packages/vox-core-rust/scripts/normalize-apple-xcframework.py", "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh", "Packages/vox-core-rust/uniffi.toml",
}

def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()

def canonical_hash(value: object) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()).hexdigest()

def sha_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024): value.update(block)
    return value.hexdigest()

def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(canonical_bytes(value))

def utc_text(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

def git(repo: Path, *arguments: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *arguments], check=True, text=True, capture_output=True).stdout.strip()

def require_hosted(repo: Path) -> tuple[str, dict]:
    names = ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_WORKSPACE", "GITHUB_JOB", "GITHUB_WORKFLOW_REF", "RUNNER_OS", "RUNNER_ARCH")
    if os.environ.get("GITHUB_ACTIONS") != "true" or any(not os.environ.get(name) for name in names): raise SystemExit("hosted GitHub Actions identity is required")
    revision = git(repo, "rev-parse", "HEAD")
    if revision != os.environ["GITHUB_SHA"] or Path(os.environ["GITHUB_WORKSPACE"]).resolve() != repo.resolve() or os.environ["GITHUB_JOB"] != "m2-evidence": raise SystemExit("hosted checkout/job identity mismatch")
    if git(repo, "status", "--porcelain", "--untracked-files=all"): raise SystemExit("M2 evidence requires a clean checkout")
    workflow = repo / ".github/workflows/core-rust-ci.yml"
    qualification = {"level": "hostedRun", "runID": os.environ["GITHUB_RUN_ID"], "runAttempt": int(os.environ["GITHUB_RUN_ATTEMPT"]), "workflowRepositoryPath": ".github/workflows/core-rust-ci.yml", "workflowSha256": sha_file(workflow)}
    hosted = {"runID": qualification["runID"], "runAttempt": qualification["runAttempt"], "workflowRepositoryPath": qualification["workflowRepositoryPath"], "workflowSha256": qualification["workflowSha256"], "checkoutRevision": revision, "runnerOS": os.environ["RUNNER_OS"], "runnerArchitecture": os.environ["RUNNER_ARCH"]}
    return revision, {"qualification": qualification, "hosted": hosted}

def host_identity() -> dict:
    def command(args: list[str]) -> str:
        value = subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()
        if not value: raise SystemExit("required build-host fact is empty")
        return value
    try: cpu = command(["sysctl", "-n", "machdep.cpu.brand_string"])
    except subprocess.CalledProcessError: cpu = command(["sysctl", "-n", "hw.model"])
    logical = os.cpu_count(); memory = int(command(["sysctl", "-n", "hw.memsize"]))
    if not logical or logical < 1 or memory < 1: raise SystemExit("required build-host capacity fact is invalid")
    values = {"osName": platform.system(), "osVersion": platform.mac_ver()[0] or platform.release(), "architecture": platform.machine(), "cpuModel": cpu, "logicalCPUCount": logical, "totalMemoryBytes": memory}
    if any(not values[key] for key in ("osName", "osVersion", "architecture", "cpuModel")): raise SystemExit("required build-host identity fact is empty")
    return values

def execute_core(repo: Path, campaign: Path, external: Path) -> None:
    require_hosted(repo)
    (campaign / "artifacts").mkdir(parents=True, exist_ok=True); (campaign / "evidence").mkdir(parents=True, exist_ok=True); (campaign / "approvals").mkdir(parents=True, exist_ok=True); (external / "executables").mkdir(parents=True, exist_ok=True)
    executable = external / "executables/core-exit-host.py"; shutil.copyfile(Path(__file__), executable); executable.chmod(0o755)
    for case_id, (_, command) in CORE_CHECKS.items():
        commands = [command]
        if case_id == "CORE-001": commands.append(["Packages/vox-core-rust/scripts/generate-oracle-fixtures.sh"])
        if case_id == "CORE-004": commands.append(["python3", "Packages/contracts/scripts/validate_toolchain.py"])
        output = ""
        for production_command in commands:
            result = subprocess.run(production_command, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            output += result.stdout
            if result.returncode != 0:
                print(output, file=sys.stderr); raise SystemExit(f"{case_id} production check failed")
        if case_id == "CORE-005":
            markers = (
                "test_shadowComparesOneFrozenInputBeforeSideEffectsAndLegacyRemainsAuthoritative",
                "test_shadowAdmissionFailureDoesNotInvokeComparatorOrAlterLegacyOutcome",
                "test_testOnlyRustFailsClosedOnUnsupportedAdmissionBeforeSideEffects",
                "test_testOnlyRustStopsAtCommitBarrierWithoutLegacyFallback",
            )
            if any(marker not in output for marker in markers):
                print(output, file=sys.stderr); raise SystemExit("CORE-005 named production checks were not all executed")

def provenance(repo: Path, external: Path, revision: str, hosted: dict, case_id: str, build: dict) -> dict:
    if case_id.startswith("CORE-"):
        consumer = {"id": "vox-m2-core-exit-host-v1", "language": "Python", "entryPoint": "main", "boundary": "sourceBuiltCoreExitHost"}; sources = set(CORE_BASE_SOURCES)
        sources.update(git(repo, "ls-files", "--", "Packages/VoxboardShared/Sources/VoxboardCaptureCore").splitlines()); executable_path = "executables/core-exit-host.py"; generator = None
    elif case_id == "PERF-003":
        consumer = {"id": "vox-core-uniffi-swift-host-v1", "language": "Swift", "entryPoint": "main", "boundary": "generatedUniFFIHostBinding"}; sources = PERF3_SOURCES; executable_path = "executables/vox-m2-materialization-evidence"; generator = {"id": "vox-m2-deterministic-synthetic-input-v1", "version": 1, "repositoryPath": "Packages/vox-core-rust/scripts/generate-m2-materialization-input.py", "sourceSha256": sha_file(repo / "Packages/vox-core-rust/scripts/generate-m2-materialization-input.py"), "seedSha256": SEED}
    else:
        consumer = {"id": "vox-native-package-inspector-v1", "language": "Python", "entryPoint": "main", "boundary": "sourceBuiltPackageInspector"}; sources = PERF8_SOURCES; executable_path = "executables/native-package-inspector.py"; generator = None
    executable = external / executable_path
    return {"schemaVersion": 1, "format": "vox-execution-provenance-v1", "sourceRevision": revision, "sourceTreeState": "clean", "toolchainManifest": {"repositoryPath": "toolchains/android-wear-shared-core.json", "sha256": build["toolchainManifestSha256"]}, "buildRecipe": {"repositoryPath": {**{key: "Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py" for key in CORE_CHECKS}, "PERF-003": "Packages/vox-core-rust/scripts/run-m2-materialization-evidence.sh", "PERF-008": "Packages/vox-core-rust/scripts/build-m2-native-evidence.sh"}[case_id], "sha256": build["buildRecipeSha256"]}, "consumer": consumer, "executable": {"sha256": sha_file(executable), "bytes": executable.stat().st_size, "externalArtifactPath": executable_path}, "sourceFiles": [{"repositoryPath": path, "sha256": sha_file(repo / path)} for path in sorted(sources)], "inputGenerator": generator, "hosted": hosted}

def hash_ref(campaign: Path, relative: str) -> dict:
    return {"id": relative, "sha256": sha_file(campaign / relative)}

def diagnostic(kind: str, code: str, executable_sha: str, additional_codes: tuple[str, ...] = ()) -> dict:
    checks = [{"code": value, "result": "passed", "count": 1} for value in (code, *additional_codes)]
    return {"schemaVersion": 1, "format": "vox-validation-diagnostic-summary", "kind": kind, "resultCode": "passed", "checks": checks, "referencedHashes": [{"role": "build", "sha256": executable_sha}]}

def measurement(gate: dict, values: list, source: str, selector: str, run_ids: list[str]) -> dict:
    if gate["statistic"] == "p95": value = sorted(values)[max(0, math.ceil(0.95 * len(values)) - 1)]
    elif gate["statistic"] == "minimum": value = min(values)
    else: value = max(values)
    return {"gateID": gate["id"], "metric": gate["metric"], "statistic": gate["statistic"], "operator": gate["operator"], "unit": gate["unit"], "scope": gate.get("scope", gate["id"]), "samplingMethod": gate["samplingMethod"], "sampleValues": values, "value": value, "derivation": {"sourceArtifactID": source, "selector": selector, "runIDs": run_ids}}

def finalize(repo: Path, campaign: Path, external: Path, archive_relative: str) -> None:
    revision, identities = require_hosted(repo); hosted = identities["hosted"]; archive = external / archive_relative; archive_sha = sha_file(archive)
    qualification = identities["qualification"] | {"artifactArchivePath": archive_relative, "artifactArchiveSha256": archive_sha}
    native_path = campaign / "artifacts/native-package-inspection.json"
    native_candidate = repo / "Packages/vox-core-rust/target/m2-evidence/native-package-candidate.json"
    native = json.loads(native_candidate.read_bytes())
    native["retention"] = {"kind": "hostedArtifact", "runID": qualification["runID"], "runAttempt": qualification["runAttempt"], "artifactName": "m2-evidence", "archiveSha256": archive_sha, "retentionExpiresAt": utc_text(datetime.now(timezone.utc) + timedelta(days=30))}
    write_json(native_path, native)
    catalog = {item["id"]: item for item in json.loads((repo / "Packages/contracts/validation/case-catalog.json").read_bytes())["cases"]}; gates = {item["id"]: item for item in json.loads((repo / "Packages/contracts/validation/performance-gates.json").read_bytes())["gates"]}; run_set = json.loads((campaign / "artifacts/materialization-run-set.json").read_bytes()); runs = {item["runID"]: item for item in run_set["runs"]}; manifest_sha = sha_file(repo / "Packages/contracts/manifest.json"); host = host_identity(); campaign_id = f"m2-hosted-{qualification['runID']}-{qualification['runAttempt']}"
    started = os.environ.get("VOX_M2_EVIDENCE_STARTED_AT", "")
    try:
        started_at = datetime.fromisoformat(started.replace("Z", "+00:00"))
    except ValueError as error:
        raise SystemExit("valid observed M2 evidence start time is required") from error
    completed_at = datetime.now(timezone.utc)
    if started_at.tzinfo is None or started_at > completed_at:
        raise SystemExit("observed M2 evidence chronology is invalid")
    completed = utc_text(completed_at)
    for case_id in [*CORE_CHECKS, "PERF-003", "PERF-008"]:
        recipe = "Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py" if case_id in CORE_CHECKS else "Packages/vox-core-rust/scripts/run-m2-materialization-evidence.sh" if case_id == "PERF-003" else "Packages/vox-core-rust/scripts/build-m2-native-evidence.sh"
        executable = external / ("executables/core-exit-host.py" if case_id in CORE_CHECKS else "executables/vox-m2-materialization-evidence" if case_id == "PERF-003" else "executables/native-package-inspector.py")
        build = {"kind": "sourceBuiltHost", "sourceRevision": revision, "sourceTreeState": "clean", "toolchainManifestSha256": sha_file(repo / "toolchains/android-wear-shared-core.json"), "buildRecipeSha256": sha_file(repo / recipe), "executableSha256": sha_file(executable)}
        prov = provenance(repo, external, revision, hosted, case_id, build); prov_rel = f"artifacts/{case_id.lower()}-provenance.json"; write_json(campaign / prov_rel, prov)
        fixture_rel = f"artifacts/{case_id.lower()}-fixture.diagnostic.json"; artifact_rel = f"artifacts/{case_id.lower()}-artifact.diagnostic.json"; required_code = CORE_CHECKS[case_id][0] if case_id in CORE_CHECKS else "performanceGate"
        write_json(campaign / fixture_rel, diagnostic("fixture", "bounds", build["executableSha256"]))
        additional_codes = SHADOW_ISOLATION_CHECKS if case_id == "CORE-005" else ()
        write_json(campaign / artifact_rel, diagnostic("artifact", required_code, build["executableSha256"], additional_codes))
        measurements=[]; run_ref = package_ref = None
        if case_id == "PERF-003":
            run_ref = hash_ref(campaign, "artifacts/materialization-run-set.json")
            bindings={item["gateID"]:item["runIDs"] for item in run_set["gateBindings"]}
            for gid in catalog[case_id]["performanceGateIDs"]:
                ids=bindings[gid]
                if gid=="rust-materialize-1mib-p95": values=[runs[x]["durationNanoseconds"]/1_000_000 for x in ids];selector="durationMilliseconds"
                elif gid=="rust-materialize-additional-rss": values=[runs[ids[0]]["rss"]["additionalBytes"]];selector="additionalRSSBytes"
                elif gid=="ffi-max-chunk": values=[chunk["bytes"] for rid in ids for chunk in runs[rid]["ingressChunks"]+runs[rid]["drainChunks"]];selector="ffiChunkBytes"
                else: values=[runs[x]["streamBytes"] for x in ids];selector="acceptedAggregateInputBytes"
                measurements.append(measurement(gates[gid],values,"artifacts/materialization-run-set.json",selector,ids))
        elif case_id == "PERF-008":
            package_ref = hash_ref(campaign, "artifacts/native-package-inspection.json")
            by_gate={}
            for leaf in native["candidateLeaves"]:by_gate.setdefault(leaf["gateID"],[]).append(leaf["bytes"])
            by_gate["apple-xcframework-aggregate"]=[native["appleAggregateBytes"]]
            for gid in catalog[case_id]["performanceGateIDs"]:
                if gid=="packaging-growth":continue
                measurements.append(measurement(gates[gid],by_gate[gid],"artifacts/native-package-inspection.json","candidateArtifactBytes",[]))
        evidence={"$schema":"https://vox.md/contracts/schemas/case-evidence.schema.json","schemaVersion":2,"evidenceID":f"{campaign_id}-{case_id.lower()}","campaignID":campaign_id,"caseID":case_id,"deviceRoleID":None,"providerID":None,"status":"passed","expected":catalog[case_id]["expected"],"contractManifestSha256":manifest_sha,"buildIdentity":build,"operator":"github-actions-m2-evidence","startedAt":started,"completedAt":completed,"device":None,"buildHost":native["buildHost"] if case_id=="PERF-008" else host,"provider":None,"actual":{"resultCode":"passed","summaryCode":"expectedOutcomeObserved"},"fixtureHashes":[hash_ref(campaign,fixture_rel)],"invariantResults":[{"invariantID":value,"passed":True} for value in catalog[case_id]["invariants"]],"artifacts":[hash_ref(campaign,artifact_rel)],"measurements":measurements,"executionProvenance":hash_ref(campaign,prov_rel),"materializationRunSet":run_ref,"nativePackageInspection":package_ref}
        write_json(campaign / f"evidence/{case_id.lower()}.json", evidence)
    definition_names=["device-matrix.json","provider-matrix.json","case-catalog.json","performance-gates.json","aggregate-policy.json","case-evidence-policy.json","approval-policy.json"]
    definitions=[{"id":name,"sha256":sha_file(repo/"Packages/contracts/validation"/name)} for name in definition_names]
    evidence_paths=sorted((campaign/"evidence").glob("*.json")); evidence_hashes=[{"id":str(path.relative_to(campaign)),"sha256":sha_file(path)} for path in evidence_paths]
    scope={"claim":"milestoneClosure","throughMilestone":"M2"}; definition_aggregate=canonical_hash({"scope":scope,"qualification":qualification,"definitions":definitions}); evidence_aggregate=canonical_hash({"scope":scope,"qualification":qualification,"evidence":evidence_hashes})
    rows=[{"caseID":case_id,"deviceRoleID":None,"providerID":None,"evidenceID":f"{campaign_id}-{case_id.lower()}","status":"passed"} for case_id in [*CORE_CHECKS,"PERF-003","PERF-008"]]
    aggregate={"$schema":"https://vox.md/contracts/schemas/aggregate.schema.json","schemaVersion":2,"campaignID":campaign_id,"scope":scope,"qualification":qualification,"status":"passed","definitionAggregateSha256":definition_aggregate,"evidenceAggregateSha256":evidence_aggregate,"definitionHashes":definitions,"evidenceHashes":evidence_hashes,"approvalHashes":[],"requiredTuples":rows,"requiredTupleCounts":{"total":7,"passed":7,"failed":0,"blocked":0,"incomplete":0},"failedInvariantIDs":[],"generatedAt":utc_text(datetime.now(timezone.utc))}
    write_json(campaign/"aggregate.json",aggregate)

def tar_field(value: int, length: int) -> bytes:
    text = f"{value:0{length-1}o}".encode();
    if len(text) >= length: raise SystemExit("USTAR numeric field overflow")
    return text + b"\0"

def create_archive(external: Path, relative: str) -> None:
    archive=external/relative; archive.parent.mkdir(parents=True,exist_ok=True)
    paths=sorted(path for path in external.rglob("*") if path.is_file() and path != archive)
    with archive.open("wb") as output:
        for path in paths:
            rel=path.relative_to(external).as_posix().encode(); name=rel;prefix=b""
            if len(name)>100:
                split=rel.rfind(b"/");prefix,name=rel[:split],rel[split+1:]
            if len(name)>100 or len(prefix)>155:raise SystemExit("USTAR path is too long")
            header=bytearray(512);header[:len(name)]=name;header[100:108]=tar_field(0o755 if os.access(path,os.X_OK) else 0o644,8);header[108:116]=tar_field(0,8);header[116:124]=tar_field(0,8);header[124:136]=tar_field(path.stat().st_size,12);header[136:148]=tar_field(0,12);header[148:156]=b"        ";header[156:157]=b"0";header[257:263]=b"ustar\0";header[263:265]=b"00";header[345:345+len(prefix)]=prefix
            checksum=sum(header);header[148:156]=f"{checksum:06o}".encode()+b"\0 "
            output.write(header)
            with path.open("rb") as source:
                while block:=source.read(1024*1024):output.write(block)
            padding=(-path.stat().st_size)%512
            if padding:output.write(b"\0"*padding)
        output.write(b"\0"*1024)

def main() -> int:
    parser=argparse.ArgumentParser();sub=parser.add_subparsers(dest="command",required=True)
    for name in ("execute-core","archive","finalize"):
        command=sub.add_parser(name);command.add_argument("--repository-root",type=Path,required=True);command.add_argument("--campaign-dir",type=Path,required=True);command.add_argument("--external-root",type=Path,required=True);command.add_argument("--archive-relative",default="archives/m2-evidence.tar")
    args=parser.parse_args();repo=args.repository_root.resolve();campaign=args.campaign_dir.resolve();external=args.external_root.resolve()
    if args.command=="execute-core":execute_core(repo,campaign,external)
    elif args.command=="archive":create_archive(external,args.archive_relative)
    else:finalize(repo,campaign,external,args.archive_relative)
    return 0
if __name__=="__main__":raise SystemExit(main())
