#!/usr/bin/env python3
"""Validate bounded Android/Wear definitions and scoped campaign evidence (stdlib only)."""
from __future__ import annotations
import argparse, hashlib, json, math, os, plistlib, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Callable

sys.path.insert(0,str(Path(__file__).resolve().parent))
import github_actions_oidc

MAX_JSON_BYTES=16*1024*1024
MAX_RUN_SET_BYTES=16*1024*1024
MAX_EVIDENCE_FILES=256
MAX_APPROVAL_FILES=32
MAX_ARCHIVE_BYTES=1024*1024*1024
HASH_BLOCK_BYTES=1024*1024
TOTAL_INPUT_DOMAIN=b"vox-m2-total-input-v1\0"
CHUNK_MANIFEST_DOMAIN=b"vox-m2-chunk-manifest-v1\0"
SYNTHETIC_STREAM_DOMAIN=b"vox-m2-synthetic-stream-byte-v1\0"
REPEATED_DIGEST_CACHE={}

CORE_REQUIRED_CHECKS={"CORE-001":"swiftRustParity","CORE-002":"unsupportedVersionFailClosed","CORE-003":"bindingDrift","CORE-004":"readinessPins","CORE-005":"shadowSideEffects"}
SHADOW_ISOLATION_CHECKS={"shadowFrozenInputCompared","shadowLegacyAuthorityReturned","shadowNoDestinationWrites","shadowNoAttachmentCopies","shadowNoQuotaMutations","shadowNoQueueMutations","shadowNoSuccessReports","shadowNoContentPathLogs"}

CORE_CONSUMER={"id":"vox-m2-core-exit-host-v1","language":"Python","entryPoint":"main","boundary":"sourceBuiltCoreExitHost"}
EXPECTED_CONSUMERS={
    **{case_id:CORE_CONSUMER for case_id in CORE_REQUIRED_CHECKS},
    "PERF-003": {"id":"vox-core-uniffi-swift-host-v1","language":"Swift","entryPoint":"main","boundary":"generatedUniFFIHostBinding"},
    "PERF-008": {"id":"vox-native-package-inspector-v1","language":"Python","entryPoint":"main","boundary":"sourceBuiltPackageInspector"},
}
PYTHON_EXECUTABLE_SOURCES={"CORE-001":"Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py","CORE-002":"Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py","CORE-003":"Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py","CORE-004":"Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py","CORE-005":"Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py","PERF-008":"Packages/vox-core-rust/scripts/inspect-native-packages.py"}
EXPECTED_PROVENANCE_PATHS={
    **{case_id:{"buildRecipe":"Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py","inputGenerator":None} for case_id in CORE_REQUIRED_CHECKS},
    "PERF-003": {"buildRecipe":"Packages/vox-core-rust/scripts/run-m2-materialization-evidence.sh","inputGenerator":"Packages/vox-core-rust/scripts/generate-m2-materialization-input.py"},
    "PERF-008": {"buildRecipe":"Packages/vox-core-rust/scripts/build-m2-native-evidence.sh","inputGenerator":None},
}

REQUIRED_PROVENANCE_SOURCE_ROOTS={"vox-m2-core-exit-host-v1":{
    "Packages/VoxboardShared/Sources/VoxboardCaptureCore",
    "Packages/VoxboardShared/Tests/VoxboardCaptureCoreTests",
    "Packages/vox-core-rust/tests/resources/contracts/v1",
}}
REQUIRED_PROVENANCE_SOURCES={
    "vox-m2-core-exit-host-v1": {
        "Packages/VoxboardShared/Package.swift",
        "Packages/VoxboardShared/Package.resolved",
        "Packages/VoxboardShared/Sources/VoxboardM2Oracle/main.swift",
        "Packages/VoxboardShared/Sources/VoxCoreFFI/module.modulemap",
        "Packages/VoxboardShared/Sources/VoxCoreGenerated/VoxCore.swift",
        "Packages/VoxboardShared/Sources/VoxCoreRust/VoxCoreRust.swift",
        "Packages/contracts/manifest.json",
        "Packages/contracts/scripts/github_actions_oidc.py",
        "Packages/contracts/scripts/validate_toolchain.py",
        "Packages/contracts/validation/case-catalog.json",
        "Packages/vox-core-rust/Cargo.lock",
        "Packages/vox-core-rust/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/src/lib.rs",
        "Packages/vox-core-rust/crates/vox-core-uniffi/uniffi.toml",
        "Packages/vox-core-rust/crates/vox-core/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core/build.rs",
        "Packages/vox-core-rust/crates/vox-core/src/lib.rs",
        "Packages/vox-core-rust/crates/vox-core/tests/m2_core.rs",
        "Packages/vox-core-rust/generated/kotlin/md/vox/core/vox_core_uniffi.kt",
        "Packages/vox-core-rust/generated/swift/VoxCore.swift",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap",
        "Packages/vox-core-rust/rust-toolchain.toml",
        "Packages/vox-core-rust/scripts/build-android-cdylibs.sh",
        "Packages/vox-core-rust/scripts/build-apple-xcframework.sh",
        "Packages/vox-core-rust/scripts/check-bindings.sh",
        "Packages/vox-core-rust/scripts/generate-kotlin-bindings.sh",
        "Packages/vox-core-rust/scripts/generate-oracle-fixtures.sh",
        "Packages/vox-core-rust/scripts/generate-swift-bindings.sh",
        "Packages/vox-core-rust/scripts/inspect-native-packages.py",
        "Packages/vox-core-rust/scripts/merge-apple-staticlib.sh",
        "Packages/vox-core-rust/scripts/normalize-apple-xcframework.py",
        "Packages/vox-core-rust/scripts/normalize-generated-text.py",
        "Packages/vox-core-rust/scripts/normalize-kotlin-bindings.py",
        "Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py",
        "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh",
        "Packages/vox-core-rust/tests/fixtures/swift-m2-oracle-v1.json",
        "Packages/vox-core-rust/uniffi-bindgen.toml",
        "Packages/vox-core-rust/uniffi.toml",
        "Packages/vox-core-rust/xtask/Cargo.toml",
        "Packages/vox-core-rust/xtask/src/bin/uniffi-bindgen.rs",
        "Packages/vox-core-rust/xtask/src/main.rs",
        "toolchains/android-wear-shared-core.schema.json",
    },
    "vox-core-uniffi-swift-host-v1": {
        "Packages/contracts/scripts/github_actions_oidc.py",
        "Packages/VoxboardShared/Package.swift",
        "Packages/VoxboardShared/Package.resolved",
        "Packages/VoxboardShared/Sources/VoxboardM2MaterializationEvidence/main.swift",
        "Packages/VoxboardShared/Sources/VoxCoreFFI/module.modulemap",
        "Packages/VoxboardShared/Sources/VoxCoreGenerated/VoxCore.swift",
        "Packages/vox-core-rust/Cargo.lock",
        "Packages/vox-core-rust/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/src/lib.rs",
        "Packages/vox-core-rust/crates/vox-core/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core/build.rs",
        "Packages/vox-core-rust/crates/vox-core/src/lib.rs",
        "Packages/vox-core-rust/generated/swift/VoxCore.swift",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap",
        "Packages/vox-core-rust/rust-toolchain.toml",
        "Packages/vox-core-rust/scripts/generate-m2-materialization-input.py",
        "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh",
        "Packages/vox-core-rust/scripts/run-m2-materialization-evidence.sh",
        "Packages/vox-core-rust/uniffi.toml",
    },
    "vox-native-package-inspector-v1": {
        "Packages/contracts/scripts/github_actions_oidc.py",
        "Packages/vox-core-rust/Cargo.lock",
        "Packages/vox-core-rust/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core-uniffi/src/lib.rs",
        "Packages/vox-core-rust/crates/vox-core/Cargo.toml",
        "Packages/vox-core-rust/crates/vox-core/build.rs",
        "Packages/vox-core-rust/crates/vox-core/src/lib.rs",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.h",
        "Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap",
        "Packages/vox-core-rust/rust-toolchain.toml",
        "Packages/vox-core-rust/scripts/build-android-cdylibs.sh",
        "Packages/vox-core-rust/scripts/build-apple-xcframework.sh",
        "Packages/vox-core-rust/scripts/inspect-native-packages.py",
        "Packages/vox-core-rust/scripts/merge-apple-staticlib.sh",
        "Packages/vox-core-rust/scripts/normalize-apple-xcframework.py",
        "Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh",
        "Packages/vox-core-rust/uniffi.toml",
    },
}

class ValidationError(Exception): pass

def bounded_bytes(path:Path,limit:int)->bytes:
    try:
        size=path.stat().st_size
        if size>limit: raise ValidationError(f"{path}: JSON exceeds {limit} byte bound")
        with path.open("rb") as f:
            data=f.read(limit+1)
    except OSError as e: raise ValidationError(f"{path}: unreadable: {e}") from e
    if len(data)>limit: raise ValidationError(f"{path}: JSON exceeds {limit} byte bound")
    return data

def strict_json_loads(data:bytes,label:str)->Any:
    def pairs(items):
        result={}
        for key,value in items:
            if key in result: raise ValidationError(f"{label}: duplicate JSON property {key!r}")
            result[key]=value
        return result
    def finite(value:str)->float:
        number=float(value)
        if not math.isfinite(number): raise ValidationError(f"{label}: non-finite JSON number")
        return number
    def constant(value:str): raise ValidationError(f"{label}: forbidden JSON constant {value}")
    try: return json.loads(data.decode("utf-8"),object_pairs_hook=pairs,parse_float=finite,parse_constant=constant)
    except ValidationError: raise
    except (UnicodeDecodeError,json.JSONDecodeError) as e: raise ValidationError(f"{label}: invalid JSON: {e}") from e

def load(path:Path,limit:int=MAX_JSON_BYTES)->Any: return strict_json_loads(bounded_bytes(path,limit),str(path))

def stream_digest(path:Path)->str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        while block:=f.read(HASH_BLOCK_BYTES): h.update(block)
    return h.hexdigest()

def digest(path:Path)->str: return stream_digest(path)
def canonical(value:Any)->str: return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
def canonical_json_bytes(value:Any)->bytes: return (json.dumps(value,ensure_ascii=False,indent=2,sort_keys=True)+"\n").encode()
def sha(data:bytes)->str: return hashlib.sha256(data).hexdigest()

UTC_RFC3339=re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.(\d{1,9}))?Z$")
def parse_utc(value:str,label:str)->tuple[datetime,int]:
    m=UTC_RFC3339.fullmatch(value) if isinstance(value,str) else None
    if not m: raise ValidationError(f"{label}: timestamp must be canonical UTC RFC3339 ending Z")
    try: parsed=datetime.fromisoformat(value[:19]+"+00:00")
    except ValueError as e: raise ValidationError(f"{label}: invalid date-time") from e
    return parsed,int((m.group(1) or "").ljust(9,"0"))

def safe_relative(value:str,label:str)->PurePosixPath:
    if not isinstance(value,str) or not value or len(value)>512 or value.startswith("/") or "\\" in value or any(ord(c)<32 or ord(c)==127 for c in value):
        raise ValidationError(f"unsafe relative path: {label}: {value!r}")
    if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:",value): raise ValidationError(f"unsafe relative path URL: {label}: {value!r}")
    pure=PurePosixPath(value)
    if value!=pure.as_posix() or any(x in ("",".","..") for x in pure.parts): raise ValidationError(f"unsafe noncanonical relative path: {label}: {value!r}")
    return pure

def contained_file(root:Path,relative:str,label:str)->Path:
    pure=safe_relative(relative,label); candidate=root.joinpath(*pure.parts)
    try: candidate.resolve(strict=True).relative_to(root.resolve(strict=True))
    except (OSError,ValueError) as e: raise ValidationError(f"path missing or escapes root: {label}: {relative!r}") from e
    cursor=root
    for part in pure.parts:
        cursor/=part
        if cursor.is_symlink(): raise ValidationError(f"path must not traverse symlinks: {label}: {relative!r}")
    if not candidate.is_file(): raise ValidationError(f"path must name regular file: {label}: {relative!r}")
    return candidate

def campaign_file(cdir:Path,relative:str)->Path: return contained_file(cdir,relative,"campaign artifact")
def repository_file(root:Path,relative:str)->Path: return contained_file(root,relative,"repository path")

def jt(v:Any,t:str)->bool:
    return {"object":isinstance(v,dict),"array":isinstance(v,list),"string":isinstance(v,str),"boolean":isinstance(v,bool),"integer":isinstance(v,int) and not isinstance(v,bool),"number":isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v),"null":v is None}.get(t,False)
def pointer(root:Any,p:str)->Any:
    if p in ("#",""): return root
    if not p.startswith("#/"): raise ValidationError(f"unsupported $ref {p}")
    x=root
    try:
        for k in p[2:].split("/"): x=x[k.replace("~1","/").replace("~0","~")]
        return x
    except Exception as e: raise ValidationError(f"unresolved schema reference: {p}") from e

def json_equal(a:Any,b:Any)->bool:
    if isinstance(a,bool) or isinstance(b,bool): return isinstance(a,bool) and isinstance(b,bool) and a==b
    if isinstance(a,(int,float)) and isinstance(b,(int,float)): return not isinstance(a,bool) and not isinstance(b,bool) and a==b
    if type(a) is not type(b): return False
    if isinstance(a,dict): return set(a)==set(b) and all(json_equal(a[k],b[k]) for k in a)
    if isinstance(a,list): return len(a)==len(b) and all(json_equal(x,y) for x,y in zip(a,b))
    return a==b

def schema_validate(x:Any,s:dict[str,Any],root:dict[str,Any],p:str="$")->None:
    if "$ref" in s: schema_validate(x,pointer(root,s["$ref"]),root,p); return
    if "oneOf" in s:
        n=0
        for q in s["oneOf"]:
            try: schema_validate(x,q,root,p); n+=1
            except ValidationError: pass
        if n!=1: raise ValidationError(f"{p}: oneOf matched {n}, expected 1")
        return
    if "allOf" in s:
        for q in s["allOf"]: schema_validate(x,q,root,p)
    if "not" in s:
        try: schema_validate(x,s["not"],root,p)
        except ValidationError: pass
        else: raise ValidationError(f"{p}: forbidden schema matched")
    if "type" in s:
        ts=s["type"] if isinstance(s["type"],list) else [s["type"]]
        if not any(jt(x,t) for t in ts): raise ValidationError(f"{p}: expected {s['type']}, got {type(x).__name__}")
    if "const" in s and not json_equal(x,s["const"]): raise ValidationError(f"{p}: const mismatch")
    if "enum" in s and not any(json_equal(x,v) for v in s["enum"]): raise ValidationError(f"{p}: enum mismatch")
    if isinstance(x,dict):
        for k in s.get("required",[]):
            if k not in x: raise ValidationError(f"{p}: missing required property {k}")
        props=s.get("properties",{})
        if s.get("additionalProperties") is False and set(x)-set(props): raise ValidationError(f"{p}: unexpected properties {sorted(set(x)-set(props))}")
        for k,v in x.items():
            if k in props: schema_validate(v,props[k],root,f"{p}.{k}")
    if isinstance(x,list):
        if len(x)<s.get("minItems",0): raise ValidationError(f"{p}: too few items")
        if len(x)>s.get("maxItems",math.inf): raise ValidationError(f"{p}: too many items")
        if s.get("uniqueItems") and any(json_equal(x[i],x[j]) for i in range(len(x)) for j in range(i)): raise ValidationError(f"{p}: duplicate items")
        if isinstance(s.get("items"),dict):
            for i,v in enumerate(x): schema_validate(v,s["items"],root,f"{p}[{i}]")
    if isinstance(x,str):
        if len(x)<s.get("minLength",0) or len(x)>s.get("maxLength",math.inf): raise ValidationError(f"{p}: string length")
        if "pattern" in s and not re.search(s["pattern"],x): raise ValidationError(f"{p}: pattern mismatch")
        if s.get("format")=="date-time": parse_utc(x,p)
    if isinstance(x,(int,float)) and not isinstance(x,bool):
        if x<s.get("minimum",-math.inf) or x>s.get("maximum",math.inf): raise ValidationError(f"{p}: numeric bound")
        if "exclusiveMinimum" in s and x<=s["exclusiveMinimum"]: raise ValidationError(f"{p}: exclusive minimum")
        if "exclusiveMaximum" in s and x>=s["exclusiveMaximum"]: raise ValidationError(f"{p}: exclusive maximum")

ALLOWED={"$schema","$id","$ref","$defs","title","description","type","required","additionalProperties","properties","items","minItems","maxItems","uniqueItems","minLength","maxLength","pattern","format","minimum","maximum","exclusiveMinimum","exclusiveMaximum","const","enum","oneOf","allOf","not"}
def check_schema(s:dict[str,Any],path:Path)->None:
    if s.get("$schema")!="https://json-schema.org/draft/2020-12/schema": raise ValidationError(f"{path}: must use JSON Schema 2020-12")
    if s.get("$id")!=f"https://vox.md/contracts/schemas/{path.name}": raise ValidationError(f"{path}: canonical $id must match filename")
    def walk(v:Any,in_props=False):
        if isinstance(v,dict):
            if not in_props:
                unknown=set(v)-ALLOWED
                if unknown: raise ValidationError(f"{path}: unsupported schema keywords {sorted(unknown)}")
            if "$ref" in v: pointer(s,v["$ref"])
            for k,z in v.items(): walk(z,k in ("properties","$defs"))
        elif isinstance(v,list):
            for z in v: walk(z)
    walk(s)

def idx(a:list[dict],key:str,label:str)->dict[str,dict]:
    d={}
    for x in a:
        if x[key] in d: raise ValidationError(f"duplicate {label}: {x[key]}")
        d[x[key]]=x
    return d

def milestone_number(value:str)->int: return int(value[1:])
def selected_cases(scope:dict,cases:dict[str,dict])->set[str]:
    if scope["claim"]=="milestoneClosure": return {c["id"] for c in cases.values() if c["required"] and milestone_number(c["milestone"])<=milestone_number(scope["throughMilestone"])}
    unknown=set(scope["caseIDs"])-set(cases)
    if unknown: raise ValidationError(f"scope references unknown cases: {sorted(unknown)}")
    return set(scope["caseIDs"])

def tuples(cases,devices,providers,scope=None):
    selected=set(cases) if scope is None else selected_cases(scope,cases); out=[]
    for c in cases.values():
        if not c["required"] or c["id"] not in selected: continue
        roles=c["deviceRoles"] or [None]
        if c["providerApplicability"]=="allRequired": ps=[p for p,v in providers.items() if v["required"]]
        elif c["providerApplicability"]=="nonLocalRequired": ps=[p for p,v in providers.items() if v["required"] and v["kind"]=="nonLocal"]
        else: ps=[None]
        out += [(c["id"],r,p) for r in roles for p in ps]
    return out

def nearest(values:list[float],stat:str)->float:
    if stat=="maximum": return max(values)
    if stat=="minimum": return min(values)
    return sorted(values)[max(0,math.ceil(.95*len(values))-1)]
def good(op:str,x:float,limit:float)->bool: return x<=limit if op=="lessThanOrEqual" else x>=limit

def discover_json_directory(cdir:Path,name:str,limit:int)->list[Path]:
    directory=cdir/name
    if directory.is_symlink() or not directory.is_dir(): raise ValidationError(f"campaign {name} must be a non-symlink directory")
    paths=[]
    for entry in directory.iterdir():
        if len(paths)>=limit: raise ValidationError(f"campaign {name} exceeds {limit} file bound")
        if entry.is_symlink() or not entry.is_file(): raise ValidationError(f"campaign {name} contains symlink or unexpected file type: {entry.name}")
        if entry.suffix!=".json": raise ValidationError(f"campaign {name} contains unexpected non-JSON file: {entry.name}")
        paths.append(campaign_file(cdir,f"{name}/{entry.name}"))
    return sorted(paths,key=lambda p:p.name)

def canonical_receipt(cdir:Path,ref:dict,schema:dict,limit=MAX_JSON_BYTES)->dict:
    path=campaign_file(cdir,ref["id"]); data=bounded_bytes(path,limit)
    if sha(data)!=ref["sha256"]: raise ValidationError(f"artifact hash mismatch: {ref['id']}")
    value=strict_json_loads(data,f"typed receipt {ref['id']}")
    if data!=canonical_json_bytes(value): raise ValidationError(f"typed receipt must be canonical JSON: {ref['id']}")
    schema_validate(value,schema,schema)
    return value

def git_output(root:Path,args:list[str],label:str)->str:
    try:
        return subprocess.run(["git",*args],cwd=root,check=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL).stdout.strip()
    except (OSError,subprocess.CalledProcessError) as e:
        raise ValidationError(label) from e

def validate_github_hosted_environment(repository_root:Path,qualification:dict,hosted_identity_verifier:Callable[[Path,dict,str],dict]|None=None)->dict:
    required=("GITHUB_ACTIONS","GITHUB_RUN_ID","GITHUB_RUN_ATTEMPT","GITHUB_SHA","GITHUB_WORKFLOW_REF","GITHUB_WORKFLOW_SHA","GITHUB_REF","GITHUB_EVENT_NAME","GITHUB_WORKSPACE","GITHUB_JOB","RUNNER_OS","RUNNER_ARCH")
    if any(not os.environ.get(name) for name in required) or os.environ["GITHUB_ACTIONS"]!="true": raise ValidationError("hosted qualification requires the bound GitHub Actions environment")
    if os.environ["GITHUB_RUN_ID"]!=qualification["runID"] or os.environ["GITHUB_RUN_ATTEMPT"]!=str(qualification["runAttempt"]): raise ValidationError("hosted qualification run environment mismatch")
    revision=git_output(repository_root,["rev-parse","HEAD"],"hosted repository HEAD unavailable")
    if os.environ["GITHUB_SHA"]!=revision: raise ValidationError("hosted qualification checkout environment mismatch")
    if Path(os.environ["GITHUB_WORKSPACE"]).resolve()!=repository_root.resolve(): raise ValidationError("hosted qualification workspace environment mismatch")
    try:
        facts=(hosted_identity_verifier or github_actions_oidc.authenticate)(repository_root,qualification,revision)
    except github_actions_oidc.OIDCError as error:
        raise ValidationError(f"hosted qualification OIDC authentication failed: {error}") from error
    fact_keys=("repository","repositoryID","repositoryOwner","repositoryOwnerID","repositoryVisibility","oidcIssuer","oidcAudience","sourceRevision","workflowRevision","workflowReference","ref","eventName","runnerEnvironment","orchestratorRepositoryPath","orchestratorSha256")
    if not isinstance(facts,dict) or any(facts.get(key)!=qualification[key] for key in fact_keys): raise ValidationError("hosted qualification authenticated identity facts mismatch")
    return facts

def validate_m2_workflow_contract(repository_root:Path,workflow:Path,scope:dict)->None:
    selected=set(CORE_REQUIRED_CHECKS)|{"PERF-003","PERF-008"} if scope["claim"]=="milestoneClosure" and milestone_number(scope["throughMilestone"])>=2 else set(scope.get("caseIDs",[]))
    selected&=set(CORE_REQUIRED_CHECKS)|{"PERF-003","PERF-008"}
    if not selected: return
    if str(workflow.relative_to(repository_root))!=".github/workflows/core-rust-ci.yml" or os.environ.get("GITHUB_JOB")!="m2-evidence": raise ValidationError("hosted M2 workflow/job identity mismatch")
    try: lines=bounded_bytes(workflow,1024*1024).decode("utf-8").splitlines()
    except UnicodeDecodeError as e: raise ValidationError("hosted M2 workflow is not UTF-8") from e
    starts=[index for index,line in enumerate(lines) if line=="  m2-evidence:"]
    if len(starts)!=1: raise ValidationError("hosted M2 workflow lacks one canonical m2-evidence job")
    start=starts[0]; end=next((index for index in range(start+1,len(lines)) if re.match(r"^  [A-Za-z0-9_-]+:\s*$",lines[index])),len(lines)); job=lines[start:end]
    required_step=["      - name: Produce and validate M2 evidence","        run: Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh"]
    required_permissions=["    permissions:","      contents: read","      id-token: write"]
    if lines.count("      id-token: write")!=1 or any(line.strip().startswith("if:") for line in job) or any(job.count(line)!=1 for line in [*required_step,*required_permissions]) or job.index(required_step[1])!=job.index(required_step[0])+1: raise ValidationError("hosted M2 workflow job is disabled, lacks exclusive exact OIDC permissions, or lacks the canonical orchestration step")
    script_path="Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh"; script=repository_file(repository_root,script_path)
    if git_output(repository_root,["ls-files","--",script_path],"hosted M2 orchestration source inventory unavailable")!=script_path or script.stat().st_size==0: raise ValidationError("hosted M2 orchestration script is not a tracked nonempty source")

def required_provenance_sources(consumer_id:str,repository_root:Path)->set[str]:
    required=set(REQUIRED_PROVENANCE_SOURCES[consumer_id])
    for source_root in REQUIRED_PROVENANCE_SOURCE_ROOTS.get(consumer_id,set()):
        discovered=set(git_output(repository_root,["ls-files","--",source_root],"provenance source-root inventory is unavailable").splitlines())
        if not discovered: raise ValidationError(f"provenance source root has no tracked files: {source_root}")
        required.update(discovered)
    return required

def validate_provenance(value:dict,repository_root:Path|None,qualification:dict,build:dict,case_id:str)->None:
    if value["sourceRevision"]!=build["sourceRevision"] or value["sourceTreeState"]!="clean": raise ValidationError("provenance source identity mismatch")
    if value["toolchainManifest"]["sha256"]!=build["toolchainManifestSha256"] or value["buildRecipe"]["sha256"]!=build["buildRecipeSha256"] or value["executable"]["sha256"]!=build["executableSha256"]: raise ValidationError("provenance build identity mismatch")
    expected_consumer=EXPECTED_CONSUMERS[case_id]
    if value["consumer"]!=expected_consumer: raise ValidationError("provenance consumer tuple is not allowlisted for case")
    expected_consumer_id=expected_consumer["id"]
    paths=[x["repositoryPath"] for x in value["sourceFiles"]]
    if paths!=sorted(paths) or len(paths)!=len(set(paths)): raise ValidationError("provenance source paths must be sorted and unique")
    if repository_root is None: raise ValidationError("executed M2 evidence requires --repository-root provenance verification")
    required_paths=required_provenance_sources(expected_consumer_id,repository_root)
    if set(paths)!=required_paths: raise ValidationError(f"provenance source inventory is not exact for {expected_consumer_id}")
    expected_paths=EXPECTED_PROVENANCE_PATHS[case_id]; generator=value["inputGenerator"]
    if value["buildRecipe"]["repositoryPath"]!=expected_paths["buildRecipe"] or ((generator or {}).get("repositoryPath") if generator is not None else None)!=expected_paths["inputGenerator"]: raise ValidationError("provenance recipe/generator path is not exact for case")
    level=qualification["level"]
    if repository_root is not None:
        bound_items=[(value["toolchainManifest"],"sha256"),(value["buildRecipe"],"sha256")]
        if generator is not None: bound_items.append((generator,"sourceSha256"))
        bound_paths=[*paths,*[item["repositoryPath"] for item,_ in bound_items]]
        for item in value["sourceFiles"]:
            if digest(repository_file(repository_root,item["repositoryPath"]))!=item["sha256"]: raise ValidationError("provenance source hash mismatch")
        executable_source=PYTHON_EXECUTABLE_SOURCES.get(case_id)
        if executable_source is not None:
            source=repository_file(repository_root,executable_source)
            if value["executable"]["sha256"]!=digest(source) or value["executable"]["bytes"]!=source.stat().st_size: raise ValidationError("provenance executable is not byte-identical to its tracked Python consumer")
        for item,key in bound_items:
            if digest(repository_file(repository_root,item["repositoryPath"]))!=item[key]: raise ValidationError("provenance repository file hash mismatch")
        tracked=set(git_output(repository_root,["ls-files","--",*sorted(set(bound_paths))],"provenance tracked-source inventory is unavailable").splitlines())
        if tracked!=set(bound_paths): raise ValidationError("provenance path is not tracked at the declared revision")
        if git_output(repository_root,["rev-parse","HEAD"],"provenance repository HEAD is unavailable")!=value["sourceRevision"]: raise ValidationError("provenance source revision is not repository HEAD")
        try:
            subprocess.run(["git","diff","--quiet",value["sourceRevision"],"--",*sorted(set(bound_paths))],cwd=repository_root,check=True)
        except (OSError,subprocess.CalledProcessError) as e: raise ValidationError("provenance bound source tree differs from source revision") from e
    hosted=value.get("hosted")
    if level in ("hostedRun","releaseGate"):
        if not hosted or hosted["checkoutRevision"]!=value["sourceRevision"]: raise ValidationError("hosted provenance checkout mismatch")
        for k in ("runID","runAttempt","workflowRepositoryPath","workflowSha256","repository","repositoryID","repositoryOwner","repositoryOwnerID","repositoryVisibility","oidcIssuer","oidcAudience","sourceRevision","workflowRevision","workflowReference","ref","eventName","runnerEnvironment","orchestratorRepositoryPath","orchestratorSha256"):
            if hosted[k]!=qualification[k]: raise ValidationError("hosted provenance qualification mismatch")
        if digest(repository_file(repository_root,hosted["orchestratorRepositoryPath"]))!=hosted["orchestratorSha256"]: raise ValidationError("hosted orchestrator hash mismatch")
        if hosted["runnerOS"]!=os.environ.get("RUNNER_OS") or hosted["runnerArchitecture"]!=os.environ.get("RUNNER_ARCH"): raise ValidationError("hosted provenance runner environment mismatch")
        workflow=repository_file(repository_root,hosted["workflowRepositoryPath"])
        if digest(workflow)!=hosted["workflowSha256"]: raise ValidationError("hosted workflow hash mismatch")
        if git_output(repository_root,["status","--porcelain","--untracked-files=all"],"hosted source tree status unavailable"): raise ValidationError("hosted source tree is not clean")
    elif hosted is not None: raise ValidationError("repository observation cannot claim hosted provenance")

def synthetic_stream_byte(seed_sha256:str)->int: return hashlib.sha256(SYNTHETIC_STREAM_DOMAIN+bytes.fromhex(seed_sha256)).digest()[0]
def repeated_digest(byte_value:int,size:int)->str:
    key=(byte_value,size)
    if key not in REPEATED_DIGEST_CACHE:
        digest_value=hashlib.sha256(); block=bytes([byte_value])*min(HASH_BLOCK_BYTES,size); left=size
        while left: n=min(left,len(block)); digest_value.update(block[:n]); left-=n
        REPEATED_DIGEST_CACHE[key]=digest_value.hexdigest()
    return REPEATED_DIGEST_CACHE[key]

def chunk_manifest_sha(chunks:list[dict])->str:
    h=hashlib.sha256(); h.update(CHUNK_MANIFEST_DOMAIN)
    for chunk in chunks:
        h.update(chunk["sequence"].to_bytes(4,"big")); h.update(chunk["bytes"].to_bytes(8,"big")); h.update(bytes.fromhex(chunk["sha256"]))
    return h.hexdigest()

def chunk_values(chunks:list[dict],label:str)->tuple[int,list[int]]:
    if [x["sequence"] for x in chunks]!=list(range(len(chunks))): raise ValidationError(f"{label} chunk sequences must start zero and be contiguous")
    return sum(x["bytes"] for x in chunks),[x["bytes"] for x in chunks]

def verify_file_chunks(path:Path,chunks:list[dict],label:str)->None:
    with path.open("rb") as handle:
        for chunk in chunks:
            data=handle.read(chunk["bytes"])
            if len(data)!=chunk["bytes"] or sha(data)!=chunk["sha256"]: raise ValidationError(f"{label} chunk bytes/hash mismatch")
        if handle.read(1): raise ValidationError(f"{label} chunk list omits bytes")

def validate_run_set(value:dict,build:dict,gates:dict,qualification:dict|None=None,external_root:Path|None=None,expected_seed_sha256:str|None=None)->dict[str,tuple[list[str],list[float]]]:
    if value["sourceRevision"]!=build["sourceRevision"] or value["executableSha256"]!=build["executableSha256"] or value["toolchainManifestSha256"]!=build["toolchainManifestSha256"]: raise ValidationError("run-set build identity mismatch")
    runs=idx(value["runs"],"runID","run"); bindings=idx(value["gateBindings"],"gateID","gate binding")
    expected={"rust-materialize-1mib-p95","rust-materialize-additional-rss","ffi-max-chunk","materialization-max-aggregate"}
    if set(bindings)!=expected: raise ValidationError("run-set gate bindings are not exact")
    warmups=set(value["warmupRunIDs"]); run_order=list(runs)
    if len(warmups)!=1 or value["warmupRunIDs"]!=run_order[:1] or not warmups<=set(runs) or any(runs[x]["purpose"]!="warmup" for x in warmups): raise ValidationError("run-set requires exactly one first untimed warmup")
    computed={}
    governed=set()
    chunk_by_run={}
    for rid,r in runs.items():
        control=r["controlDocument"]; expected_control={"operation":"newNoteTextLink","profileVersion":"apple-parity-v1","runID":rid,"purpose":r["purpose"],"streamBytes":r["streamBytes"],"syntheticSeedSha256":control["syntheticSeedSha256"]}
        if control!=expected_control or (expected_seed_sha256 is not None and control["syntheticSeedSha256"]!=expected_seed_sha256): raise ValidationError("materialization control/generator identity mismatch")
        control_bytes=canonical_json_bytes(control)
        if r["controlBytes"]!=len(control_bytes) or r["controlSha256"]!=sha(control_bytes): raise ValidationError("materialization canonical control bytes/hash mismatch")
        stream_byte=synthetic_stream_byte(control["syntheticSeedSha256"])
        if r["streamSha256"]!=repeated_digest(stream_byte,r["streamBytes"]): raise ValidationError("materialization input is not the governed deterministic synthetic stream")
        ingress_sum,ingress=chunk_values(r["ingressChunks"],rid+" ingress"); drain_sum,drain=chunk_values(r["drainChunks"],rid+" drain")
        if ingress_sum!=r["streamBytes"]: raise ValidationError("ingress chunk sum mismatch")
        if drain_sum!=r["outputBytes"]: raise ValidationError("drain chunk sum mismatch")
        if r["ingressChunkManifestSha256"]!=chunk_manifest_sha(r["ingressChunks"]) or r["drainChunkManifestSha256"]!=chunk_manifest_sha(r["drainChunks"]): raise ValidationError("chunk manifest hash mismatch")
        if any(chunk["sha256"]!=repeated_digest(stream_byte,chunk["bytes"]) for chunk in r["ingressChunks"]): raise ValidationError("ingress chunks are not the governed deterministic synthetic stream")
        if r["totalInputBytes"]!=r["controlBytes"]+r["streamBytes"]: raise ValidationError("total input byte count mismatch")
        expected_total=sha(TOTAL_INPUT_DOMAIN+r["controlBytes"].to_bytes(8,"big")+r["streamBytes"].to_bytes(8,"big")+bytes.fromhex(r["controlSha256"])+bytes.fromhex(r["streamSha256"]))
        if r["totalInputSha256"]!=expected_total: raise ValidationError("total input hash mismatch")
        vd=r["verifiedDrain"]
        if vd["descriptorOutputBytes"]!=r["outputBytes"] or vd["descriptorOutputSha256"]!=r["outputSha256"]: raise ValidationError("verified drain descriptor mismatch")
        chunk_by_run[rid]=ingress+drain
        hosted=qualification and qualification["level"] in ("hostedRun","releaseGate")
        if hosted:
            if external_root is None or not r["controlArtifactPath"] or not r["inputArtifactPath"] or not r["outputArtifactPath"]: raise ValidationError("hosted materialization requires external control/input/output artifacts")
            cp=contained_file(external_root,r["controlArtifactPath"],"external materialization control"); ip=contained_file(external_root,r["inputArtifactPath"],"external materialization input"); op=contained_file(external_root,r["outputArtifactPath"],"external materialization output")
            if cp.stat().st_size!=r["controlBytes"] or digest(cp)!=r["controlSha256"] or ip.stat().st_size!=r["streamBytes"] or digest(ip)!=r["streamSha256"] or op.stat().st_size!=r["outputBytes"] or digest(op)!=r["outputSha256"]: raise ValidationError("external materialization artifact bytes/hash mismatch")
            verify_file_chunks(ip,r["ingressChunks"],rid+" ingress"); verify_file_chunks(op,r["drainChunks"],rid+" drain")
        elif r["controlArtifactPath"] is not None or r["inputArtifactPath"] is not None or r["outputArtifactPath"] is not None: raise ValidationError("repository observation cannot claim external materialization artifacts")
        rss=r["rss"]
        if rss:
            elapsed=[x["elapsedNanoseconds"] for x in rss["samples"]]; resident=[x["residentBytes"] for x in rss["samples"]]
            if elapsed[0]!=0 or elapsed!=sorted(elapsed) or len(elapsed)!=len(set(elapsed)) or elapsed[-1]>r["durationNanoseconds"]: raise ValidationError("RSS samples are filtered, unordered, or outside run")
            if any(b-a>rss["sampleIntervalNanoseconds"] for a,b in zip(elapsed,elapsed[1:])): raise ValidationError("RSS sample cadence exceeds declared interval")
            peak=max([rss["baselineBytes"],*resident]); additional=max(0,peak-rss["baselineBytes"])
            if rss["peakBytes"]!=peak or rss["additionalBytes"]!=additional or elapsed[-1]!=r["durationNanoseconds"]: raise ValidationError("RSS peak/additional/final sample mismatch")
    for gid,b in bindings.items():
        ids=b["runIDs"]
        if any(x not in runs for x in ids) or warmups.intersection(ids): raise ValidationError("gate binding references missing or warmup run")
        governed.update(ids)
        if gid=="rust-materialize-1mib-p95":
            if len(ids)<20 or any(runs[x]["purpose"]!="latency" or runs[x]["streamBytes"]!=1048576 for x in ids): raise ValidationError("latency binding requires twenty independent 1 MiB runs")
            values=[runs[x]["durationNanoseconds"]/1_000_000 for x in ids]
        elif gid=="materialization-max-aggregate":
            if any(runs[x]["purpose"]!="aggregateCoverage" for x in ids): raise ValidationError("aggregate binding purpose mismatch")
            values=[runs[x]["streamBytes"] for x in ids]
            if sorted(values)!=[1048576,16777216,268435456]: raise ValidationError("aggregate binding requires exact 1/16/256 MiB set")
        elif gid=="rust-materialize-additional-rss":
            if len(ids)!=1 or runs[ids[0]]["purpose"]!="resource" or runs[ids[0]]["streamBytes"]!=268435456 or runs[ids[0]]["rss"] is None: raise ValidationError("RSS binding requires dedicated 256 MiB resource run")
            values=[runs[ids[0]]["rss"]["additionalBytes"]]
        else:
            values=[n for rid in ids for n in chunk_by_run[rid]]
        computed[gid]=(ids,values)
    principal={rid for gid,b in bindings.items() if gid!="ffi-max-chunk" for rid in b["runIDs"]}
    non_warmup=set(runs)-warmups
    if principal!=non_warmup: raise ValidationError("every non-warmup run must appear in its purpose gate binding")
    expected_ffi_order=[rid for rid in runs if rid in non_warmup]
    if bindings["ffi-max-chunk"]["runIDs"]!=expected_ffi_order: raise ValidationError("ffi chunk binding must include every governed run in run-set order")
    return computed

PACKAGE_ORDER=[("android-core-arm64-uncompressed","arm64-v8a",["arm64"],"elf-shared-object"),("android-core-armv7-uncompressed","armeabi-v7a",["armv7"],"elf-shared-object"),("android-core-x86_64-uncompressed","x86_64",["x86_64"],"elf-shared-object"),("android-core-x86-uncompressed","x86",["x86"],"elf-shared-object"),("apple-xcframework-per-slice","xcframework-ios-device-arm64",["arm64"],"apple-static-library"),("apple-xcframework-per-slice","xcframework-ios-simulator-arm64-x86_64",["arm64","x86_64"],"apple-static-library")]
XCFRAMEWORK_HEADER_ORDER=[
    ("xcframework-ios-device-arm64","cHeader","ios-arm64/Headers/VoxCoreFFI.h","Packages/vox-core-rust/generated/swift/VoxCoreFFI.h"),
    ("xcframework-ios-device-arm64","moduleMap","ios-arm64/Headers/module.modulemap","Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap"),
    ("xcframework-ios-simulator-arm64-x86_64","cHeader","ios-arm64_x86_64-simulator/Headers/VoxCoreFFI.h","Packages/vox-core-rust/generated/swift/VoxCoreFFI.h"),
    ("xcframework-ios-simulator-arm64-x86_64","moduleMap","ios-arm64_x86_64-simulator/Headers/module.modulemap","Packages/vox-core-rust/generated/swift/VoxCoreFFI.modulemap"),
]
ANDROID_INSPECTION_CHECKS={"architecture","binaryFormat","definedUniFFISymbols","dependencyAllowlist"}
APPLE_INSPECTION_CHECKS=ANDROID_INSPECTION_CHECKS|{"deploymentTarget","archiveMembers","xcframeworkMetadata"}
APPLE_CPU_ARCH={0x0100000c:"arm64",0x01000007:"x86_64"}
def macho_arch(prefix:bytes)->str|None:
    if len(prefix)<8: return None
    if prefix[:4]==b"\xcf\xfa\xed\xfe": endian="little"
    elif prefix[:4]==b"\xfe\xed\xfa\xcf": endian="big"
    else: return None
    return APPLE_CPU_ARCH.get(int.from_bytes(prefix[4:8],endian))

def inspect_macho_executable(path:Path,runner_architecture:str)->None:
    with path.open("rb") as handle: header=handle.read(32)
    arch=macho_arch(header); expected={"ARM64":"arm64","X64":"x86_64"}.get(runner_architecture); file_size=path.stat().st_size
    if arch is None or arch!=expected or len(header)<32: raise ValidationError("hosted Swift executable Mach-O architecture mismatch")
    endian="little" if header[:4]==b"\xcf\xfa\xed\xfe" else "big"; file_type=int.from_bytes(header[12:16],endian); command_count=int.from_bytes(header[16:20],endian); command_bytes=int.from_bytes(header[20:24],endian)
    if file_type!=2 or command_count<2 or command_count>4096 or command_bytes<16 or 32+command_bytes>=file_size: raise ValidationError("hosted Swift executable is not a bounded Mach-O executable")
    with path.open("rb") as handle: handle.seek(32); commands=handle.read(command_bytes)
    position=0; executable_sections=[]; entry_offset=None
    for _ in range(command_count):
        if position+8>len(commands): raise ValidationError("hosted Swift executable load command truncated")
        command=int.from_bytes(commands[position:position+4],endian); command_size=int.from_bytes(commands[position+4:position+8],endian)
        if command_size<8 or command_size%4 or position+command_size>len(commands): raise ValidationError("hosted Swift executable load command size mismatch")
        body=commands[position:position+command_size]
        if command==0x19:
            if command_size<72: raise ValidationError("hosted Swift executable segment truncated")
            file_offset=int.from_bytes(body[40:48],endian); segment_bytes=int.from_bytes(body[48:56],endian); initial_protection=int.from_bytes(body[60:64],endian); sections=int.from_bytes(body[64:68],endian)
            if command_size!=72+sections*80 or file_offset+segment_bytes>file_size: raise ValidationError("hosted Swift executable segment bounds mismatch")
            for section_index in range(sections):
                section=body[72+section_index*80:152+section_index*80]; section_bytes=int.from_bytes(section[40:48],endian); section_offset=int.from_bytes(section[48:52],endian); section_flags=int.from_bytes(section[64:68],endian); section_type=section_flags&0xff
                if section_type not in {1,0x0c,0x12} and section_bytes and section_offset+section_bytes<=file_size and initial_protection&4 and section_flags&0x80000400: executable_sections.append((section_offset,section_offset+section_bytes))
        if command==0x80000028:
            if command_size!=24 or entry_offset is not None: raise ValidationError("hosted Swift executable LC_MAIN mismatch")
            entry_offset=int.from_bytes(body[8:16],endian)
        position+=command_size
    if position!=len(commands) or entry_offset is None or entry_offset<32+command_bytes or not any(start<=entry_offset<end for start,end in executable_sections): raise ValidationError("hosted Swift executable lacks a file-backed instruction-section LC_MAIN entry point")

def inspect_macho_object(handle,start:int,size:int,expected_platform:int)->tuple[str,bool]:
    if size<32: raise ValidationError("external Apple Mach-O object is truncated")
    handle.seek(start); header=handle.read(32); arch=macho_arch(header)
    if arch is None: raise ValidationError("external Apple archive member is not a supported Mach-O object")
    endian="little" if header[:4]==b"\xcf\xfa\xed\xfe" else "big"; file_type=int.from_bytes(header[12:16],endian); command_count=int.from_bytes(header[16:20],endian); command_bytes=int.from_bytes(header[20:24],endian)
    if file_type!=1 or command_count<1 or command_count>4096 or command_bytes>size-32: raise ValidationError("external Apple Mach-O header/load-command mismatch")
    handle.seek(start+32); commands=handle.read(command_bytes); position=0; build_versions=0; build_version_commands=0; symtab=None; sections=[]; dylib_commands={0xc,0x20,0x18|0x80000000,0x1f|0x80000000,0x23|0x80000000}
    for _ in range(command_count):
        if position+8>len(commands): raise ValidationError("external Apple Mach-O load command truncated")
        command=int.from_bytes(commands[position:position+4],endian); command_size=int.from_bytes(commands[position+4:position+8],endian)
        if command_size<8 or command_size%4 or position+command_size>len(commands): raise ValidationError("external Apple Mach-O load command size mismatch")
        body=commands[position:position+command_size]
        if command in dylib_commands: raise ValidationError("external Apple static object has a forbidden dynamic dependency")
        if command==0x19:
            if command_size<72: raise ValidationError("external Apple segment command truncated")
            section_count=int.from_bytes(body[64:68],endian)
            if command_size!=72+section_count*80: raise ValidationError("external Apple segment/section inventory mismatch")
            for section_index in range(section_count):
                section=body[72+section_index*80:152+section_index*80]; address=int.from_bytes(section[32:40],endian); section_bytes=int.from_bytes(section[40:48],endian); file_offset=int.from_bytes(section[48:52],endian); section_flags=int.from_bytes(section[64:68],endian); section_type=section_flags&0xff; zero_fill=section_type in {1,0x0c,0x12}
                if not zero_fill and (section_bytes<1 or file_offset+section_bytes>size): raise ValidationError("external Apple materialized section bounds mismatch")
                sections.append((address,section_bytes,file_offset,section_type,section_flags))
        if command==0x32:
            build_version_commands+=1
            if command_size<24: raise ValidationError("external Apple build-version command truncated")
            platform=int.from_bytes(body[8:12],endian); minimum=int.from_bytes(body[12:16],endian); tools=int.from_bytes(body[20:24],endian)
            if command_size!=24+tools*8: raise ValidationError("external Apple build-version tool inventory mismatch")
            if platform==expected_platform and minimum==0x00110600: build_versions+=1
        if command==0x2:
            if command_size!=24 or symtab is not None: raise ValidationError("external Apple symbol-table command mismatch")
            symtab=tuple(int.from_bytes(body[offset:offset+4],endian) for offset in (8,12,16,20))
        position+=command_size
    if position!=len(commands) or build_version_commands!=1 or build_versions!=1 or symtab is None or not sections: raise ValidationError("external Apple deployment target, section, or symbol table missing/conflicting")
    symbol_offset,symbol_count,string_offset,string_size=symtab
    if symbol_count<1 or symbol_count>1000000 or symbol_offset+symbol_count*16>size or string_offset+string_size>size: raise ValidationError("external Apple symbol table bounds mismatch")
    handle.seek(start+string_offset); strings=handle.read(string_size); handle.seek(start+symbol_offset); symbols=handle.read(symbol_count*16); found=False
    for index in range(symbol_count):
        entry=symbols[index*16:(index+1)*16]; name_offset=int.from_bytes(entry[:4],endian); symbol_type=entry[4]; section_index=entry[5]; value=int.from_bytes(entry[8:16],endian); name=ascii_table_value(strings,name_offset,"external Apple symbol string offset/encoding mismatch"); section=sections[section_index-1] if 0<section_index<=len(sections) else None
        materialized=bool(section and section[3] not in {1,0x0c,0x12} and section[4]&0x80000400 and section[0]<=value<section[0]+section[1])
        if name=="_"+UNIFFI_BUILD_INFO_SYMBOL and symbol_type&0xe0==0 and symbol_type&0x1f==0x0f and materialized: found=True
    return arch,found

def inspect_archive_region(path:Path,start:int,length:int,expected_platform:int)->set[str]:
    end=start+length
    with path.open("rb") as handle:
        handle.seek(start)
        if handle.read(8)!=b"!<arch>\n": raise ValidationError("external Apple archive format mismatch")
        position=start+8; found=set(); object_members=0; required_symbol_found=False
        while position<end:
            if end-position<60: raise ValidationError("external Apple archive metadata mismatch")
            handle.seek(position); header=handle.read(60)
            if len(header)!=60 or header[58:60]!=b"`\n": raise ValidationError("external Apple archive metadata mismatch")
            raw_size=header[48:58].strip()
            if not raw_size or not raw_size.isdigit(): raise ValidationError("external Apple archive member size mismatch")
            size=int(raw_size); data_start=position+60; data_end=data_start+size; next_position=data_end+(size&1)
            if data_end>end or next_position>end: raise ValidationError("external Apple archive member exceeds container")
            raw_name=header[:16].strip(); payload_start=data_start; payload_size=size
            if raw_name.startswith(b"#1/"):
                extension=raw_name[3:]
                if not extension.isdigit() or int(extension)>size: raise ValidationError("external Apple archive extended name mismatch")
                name_bytes=int(extension); handle.seek(data_start); member_name=handle.read(name_bytes).rstrip(b"\0"); payload_start+=name_bytes; payload_size-=name_bytes
            else: member_name=raw_name.rstrip(b"/")
            special=raw_name in (b"/",b"//") or member_name in {b"__.SYMDEF",b"__.SYMDEF SORTED",b"__.SYMDEF_64",b"__.SYMDEF_64 SORTED"}
            if not special:
                arch,member_symbol=inspect_macho_object(handle,payload_start,payload_size,expected_platform); found.add(arch); required_symbol_found|=member_symbol; object_members+=1
            position=next_position
        if position!=end or object_members==0: raise ValidationError("external Apple archive contains no bounded object members")
        if not required_symbol_found: raise ValidationError("external Apple archive omits required visible external UniFFI symbol")
    return found

UNIFFI_BUILD_INFO_SYMBOL="uniffi_vox_core_uniffi_fn_func_core_build_info"
def bounded_region(handle,offset:int,size:int,file_size:int,label:str)->bytes:
    if offset<0 or size<0 or offset+size>file_size: raise ValidationError(label)
    handle.seek(offset); data=handle.read(size)
    if len(data)!=size: raise ValidationError(label)
    return data

def ascii_table_value(table:bytes,offset:int,label:str)->str:
    if offset>=len(table): raise ValidationError(label)
    try: return table[offset:].split(b"\0",1)[0].decode("ascii","strict")
    except UnicodeDecodeError as e: raise ValidationError(label) from e

def elf_sysv_hash(name:bytes)->int:
    value=0
    for byte in name:
        value=(value<<4)+byte; high=value&0xf0000000
        if high: value^=high>>24
        value&=~high
    return value&0xffffffff
def elf_gnu_hash(name:bytes)->int:
    value=5381
    for byte in name: value=((value*33)+byte)&0xffffffff
    return value

def inspect_elf_semantics(path:Path,elf_class:int)->None:
    file_size=path.stat().st_size; endian="little"
    with path.open("rb") as handle:
        header=bounded_region(handle,0,64 if elf_class==2 else 52,file_size,"external ELF header is truncated")
        if elf_class==2:
            phoff=int.from_bytes(header[32:40],endian); phentsize=int.from_bytes(header[54:56],endian); phnum=int.from_bytes(header[56:58],endian); expected_ph=56; shoff=int.from_bytes(header[40:48],endian); shentsize=int.from_bytes(header[58:60],endian); shnum=int.from_bytes(header[60:62],endian); expected_sh=64
        else:
            phoff=int.from_bytes(header[28:32],endian); phentsize=int.from_bytes(header[42:44],endian); phnum=int.from_bytes(header[44:46],endian); expected_ph=32; shoff=int.from_bytes(header[32:36],endian); shentsize=int.from_bytes(header[46:48],endian); shnum=int.from_bytes(header[48:50],endian); expected_sh=40
        if phentsize!=expected_ph or phnum<2 or phnum>4096 or phoff+phentsize*phnum>file_size: raise ValidationError("external ELF program-header table mismatch")
        loads=[]; dynamic_program=None; executable_load=False
        for index in range(phnum):
            program=bounded_region(handle,phoff+index*phentsize,phentsize,file_size,"external ELF program header truncated"); program_type=int.from_bytes(program[:4],endian)
            if elf_class==2: flags=int.from_bytes(program[4:8],endian); offset=int.from_bytes(program[8:16],endian); address=int.from_bytes(program[16:24],endian); file_bytes=int.from_bytes(program[32:40],endian); memory_bytes=int.from_bytes(program[40:48],endian)
            else: offset=int.from_bytes(program[4:8],endian); address=int.from_bytes(program[8:12],endian); file_bytes=int.from_bytes(program[16:20],endian); memory_bytes=int.from_bytes(program[20:24],endian); flags=int.from_bytes(program[24:28],endian)
            if program_type in (1,2) and (file_bytes>memory_bytes or offset+file_bytes>file_size): raise ValidationError("external ELF load/dynamic segment bounds mismatch")
            if program_type==1: loads.append((offset,address,file_bytes,flags)); executable_load|=bool(flags&1)
            if program_type==2:
                if dynamic_program is not None: raise ValidationError("external ELF has multiple PT_DYNAMIC segments")
                dynamic_program=(offset,address,file_bytes)
        if not loads or not executable_load or dynamic_program is None: raise ValidationError("external ELF lacks loadable executable/PT_DYNAMIC segments")
        def map_address(address:int,size:int=1,required_flags:int=0)->tuple[int,int]:
            for offset,virtual,file_bytes,flags in loads:
                if flags&required_flags==required_flags and virtual<=address and address+size<=virtual+file_bytes: return offset+(address-virtual),virtual+file_bytes-address
            raise ValidationError("external ELF dynamic address is outside PT_LOAD")
        if shentsize!=expected_sh or shnum<2 or shnum>4096 or shoff+shentsize*shnum>file_size: raise ValidationError("external ELF section table mismatch")
        sections=[]
        for index in range(shnum):
            section=bounded_region(handle,shoff+index*shentsize,shentsize,file_size,"external ELF section header truncated"); section_type=int.from_bytes(section[4:8],endian)
            if elf_class==2: flags=int.from_bytes(section[8:16],endian); address=int.from_bytes(section[16:24],endian); offset=int.from_bytes(section[24:32],endian); size=int.from_bytes(section[32:40],endian); link=int.from_bytes(section[40:44],endian); entsize=int.from_bytes(section[56:64],endian)
            else: flags=int.from_bytes(section[8:12],endian); address=int.from_bytes(section[12:16],endian); offset=int.from_bytes(section[16:20],endian); size=int.from_bytes(section[20:24],endian); link=int.from_bytes(section[24:28],endian); entsize=int.from_bytes(section[36:40],endian)
            if (section_type!=8 and offset+size>file_size) or link>=shnum: raise ValidationError("external ELF section bounds/link mismatch")
            sections.append((section_type,flags,address,offset,size,link,entsize))
        dynamic_sections=[section for section in sections if section[0]==6]; symbol_sections=[section for section in sections if section[0]==11]
        if len(dynamic_sections)!=1 or len(symbol_sections)!=1: raise ValidationError("external ELF dynamic/dynamic-symbol section inventory mismatch")
        dynamic=dynamic_sections[0]; dynsym=symbol_sections[0]
        if (dynamic[3],dynamic[4])!=(dynamic_program[0],dynamic_program[2]) or map_address(dynamic_program[1],dynamic_program[2])[0]!=dynamic_program[0] or not dynamic[1]&2 or not dynsym[1]&2: raise ValidationError("external ELF section tables disagree with loader-visible dynamic segments")
        entry_size=16 if elf_class==2 else 8
        if dynamic[6]!=entry_size or dynamic[4]%entry_size: raise ValidationError("external ELF dynamic entry size mismatch")
        dynamic_bytes=bounded_region(handle,dynamic_program[0],dynamic_program[2],file_size,"external ELF PT_DYNAMIC truncated"); tags={}; needed=[]; terminated=False
        for position in range(0,len(dynamic_bytes),entry_size):
            entry=dynamic_bytes[position:position+entry_size]; width=8 if elf_class==2 else 4; tag=int.from_bytes(entry[:width],endian,signed=True); value=int.from_bytes(entry[width:2*width],endian)
            if tag==0: terminated=True; break
            if tag==1: needed.append(value)
            else:
                if tag in {4,5,6,10,11,0x6ffffef5} and tag in tags:
                    raise ValidationError("external ELF has duplicate singleton loader tags")
                tags[tag]=value
        required_tags={5,6,10,11}
        if not terminated or not required_tags<=set(tags): raise ValidationError("external ELF PT_DYNAMIC omits terminator or required loader tags")
        string_section=sections[dynsym[5]]
        if string_section[0]!=3 or not string_section[1]&2 or tags[5]!=string_section[2] or tags[10]!=string_section[4] or tags[6]!=dynsym[2] or tags[11]!=dynsym[6]: raise ValidationError("external ELF dynamic tags disagree with loaded symbol/string tables")
        if map_address(string_section[2],string_section[4])[0]!=string_section[3] or map_address(dynsym[2],dynsym[4])[0]!=dynsym[3]: raise ValidationError("external ELF loaded section address/file mapping mismatch")
        strings=bounded_region(handle,string_section[3],string_section[4],file_size,"external ELF dynamic string table truncated"); dependencies={ascii_table_value(strings,value,"external ELF dependency string offset/encoding mismatch") for value in needed}
        symbol_size=24 if elf_class==2 else 16
        if dynsym[6]!=symbol_size or dynsym[4]%symbol_size: raise ValidationError("external ELF dynamic symbol entry size mismatch")
        symbols=bounded_region(handle,dynsym[3],dynsym[4],file_size,"external ELF dynamic symbol table truncated"); required_index=None
        for index in range(len(symbols)//symbol_size):
            entry=symbols[index*symbol_size:(index+1)*symbol_size]; name_offset=int.from_bytes(entry[:4],endian); info=entry[4] if elf_class==2 else entry[12]; visibility=(entry[5] if elf_class==2 else entry[13])&3; section_index=int.from_bytes(entry[6:8] if elf_class==2 else entry[14:16],endian); symbol_value=int.from_bytes(entry[8:16] if elf_class==2 else entry[4:8],endian); symbol_bytes=int.from_bytes(entry[16:24] if elf_class==2 else entry[8:12],endian); name=ascii_table_value(strings,name_offset,"external ELF symbol string offset/encoding mismatch")
            section=sections[section_index] if 0<section_index<len(sections) else None; materialized=bool(section and section[1]&2 and section[0] not in (3,6,8,11) and symbol_bytes>0 and section[2]<=symbol_value and symbol_value+symbol_bytes<=section[2]+section[4])
            if name==UNIFFI_BUILD_INFO_SYMBOL and info>>4 in (1,2) and visibility==0 and materialized and map_address(symbol_value,symbol_bytes,1): required_index=index
        if required_index is None: raise ValidationError("external ELF omits required visible global UniFFI symbol")
        hash_results=[]
        if 4 in tags:
            sysv_resolved=False; hash_offset,available=map_address(tags[4],8); header_hash=bounded_region(handle,hash_offset,8,file_size,"external ELF SYSV hash truncated"); bucket_count=int.from_bytes(header_hash[:4],endian); chain_count=int.from_bytes(header_hash[4:8],endian); table_size=8+4*(bucket_count+chain_count)
            if 0<bucket_count<=1000000 and 0<chain_count<=1000000 and table_size<=available:
                table=bounded_region(handle,hash_offset,table_size,file_size,"external ELF SYSV hash table truncated"); bucket_index=elf_sysv_hash(UNIFFI_BUILD_INFO_SYMBOL.encode())%bucket_count; symbol=int.from_bytes(table[8+bucket_index*4:12+bucket_index*4],endian); chains_offset=8+bucket_count*4; visited=set()
                while symbol and symbol<chain_count and symbol not in visited:
                    if symbol==required_index: sysv_resolved=True
                    visited.add(symbol); symbol=int.from_bytes(table[chains_offset+symbol*4:chains_offset+symbol*4+4],endian)
            hash_results.append(sysv_resolved)
        if 0x6ffffef5 in tags:
            gnu_resolved=False; hash_offset,available=map_address(tags[0x6ffffef5],16); gnu=bounded_region(handle,hash_offset,min(available,file_size-hash_offset),file_size,"external ELF GNU hash truncated"); bucket_count=int.from_bytes(gnu[:4],endian); symbol_base=int.from_bytes(gnu[4:8],endian); bloom_count=int.from_bytes(gnu[8:12],endian); bloom_shift=int.from_bytes(gnu[12:16],endian); word=8 if elf_class==2 else 4; bucket_offset=16+bloom_count*word; name_hash=elf_gnu_hash(UNIFFI_BUILD_INFO_SYMBOL.encode())
            if 0<bucket_count<=1000000 and 0<bloom_count<=1000000 and bucket_offset+bucket_count*4<=len(gnu):
                bloom_word=int.from_bytes(gnu[16+(name_hash//(word*8)%bloom_count)*word:16+(name_hash//(word*8)%bloom_count+1)*word],endian); bloom_ok=bloom_word&(1<<(name_hash%(word*8))) and bloom_word&(1<<((name_hash>>bloom_shift)%(word*8))); bucket_index=name_hash%bucket_count; symbol=int.from_bytes(gnu[bucket_offset+bucket_index*4:bucket_offset+bucket_index*4+4],endian)
                if bloom_ok and symbol>=symbol_base:
                    chain_offset=bucket_offset+bucket_count*4+(symbol-symbol_base)*4
                    while chain_offset+4<=len(gnu) and symbol<=1000000:
                        value=int.from_bytes(gnu[chain_offset:chain_offset+4],endian)
                        if symbol==required_index and (value&0xfffffffe)==(name_hash&0xfffffffe): gnu_resolved=True
                        symbol+=1; chain_offset+=4
                        if value&1: break
            hash_results.append(gnu_resolved)
        if not hash_results or not all(hash_results): raise ValidationError("external ELF required UniFFI symbol is absent from every advertised loader hash table")
        if not dependencies or not dependencies<={"libc.so","libdl.so"}: raise ValidationError("external ELF dependency allowlist mismatch")

def inspect_external_package_leaf(path:Path,leaf:dict)->None:
    with path.open("rb") as handle: prefix=handle.read(4096)
    expected=set(leaf["architectures"]); file_size=path.stat().st_size
    if leaf["format"]=="elf-shared-object":
        if len(prefix)<20 or prefix[:4]!=b"\x7fELF" or prefix[5]!=1 or prefix[6]!=1: raise ValidationError("external package binary format mismatch")
        machine=int.from_bytes(prefix[18:20],"little"); arch={183:"arm64",40:"armv7",62:"x86_64",3:"x86"}.get(machine); expected_class=2 if arch in ("arm64","x86_64") else 1
        if int.from_bytes(prefix[16:18],"little")!=3 or prefix[4]!=expected_class: raise ValidationError("external package is not an ELF shared object for its architecture class")
        if arch is None or {arch}!=expected: raise ValidationError("external package architecture mismatch")
        inspect_elf_semantics(path,prefix[4]); return
    magic=prefix[:4]
    if magic in (b"\xca\xfe\xba\xbe",b"\xca\xfe\xba\xbf",b"\xbe\xba\xfe\xca",b"\xbf\xba\xfe\xca"):
        endian="big" if magic in (b"\xca\xfe\xba\xbe",b"\xca\xfe\xba\xbf") else "little"; wide=magic in (b"\xca\xfe\xba\xbf",b"\xbf\xba\xfe\xca"); count=int.from_bytes(prefix[4:8],endian); entry_size=32 if wide else 20; table_end=8+count*entry_size
        if count<1 or count>8 or len(prefix)<table_end: raise ValidationError("external Apple fat metadata mismatch")
        found=set(); regions=[]
        for index in range(count):
            offset=8+index*entry_size; cpu=int.from_bytes(prefix[offset:offset+4],endian); arch=APPLE_CPU_ARCH.get(cpu); width=8 if wide else 4; slice_offset=int.from_bytes(prefix[offset+8:offset+8+width],endian); slice_size=int.from_bytes(prefix[offset+8+width:offset+8+2*width],endian)
            if arch is None or slice_size<8 or slice_offset<table_end or slice_offset+slice_size>file_size: raise ValidationError("external Apple fat slice metadata mismatch")
            if any(not (slice_offset+slice_size<=a or slice_offset>=b) for a,b in regions): raise ValidationError("external Apple fat slices overlap")
            if arch in found: raise ValidationError("external Apple fat architecture is duplicated")
            regions.append((slice_offset,slice_offset+slice_size)); slice_arches=inspect_archive_region(path,slice_offset,slice_size,7 if "simulator" in leaf["targetScope"] else 2)
            if slice_arches!={arch}: raise ValidationError("external Apple fat slice architecture mismatch")
            found.add(arch)
        cursor=table_end
        with path.open("rb") as handle:
            for begin,end in sorted(regions):
                handle.seek(cursor)
                if any(handle.read(begin-cursor)): raise ValidationError("external Apple fat padding is noncanonical")
                cursor=end
            handle.seek(cursor)
            if any(handle.read()): raise ValidationError("external Apple fat trailing padding is noncanonical")
    elif prefix.startswith(b"!<arch>\n"): found=inspect_archive_region(path,0,file_size,7 if "simulator" in leaf["targetScope"] else 2)
    else: raise ValidationError("external package binary format mismatch")
    if found!=expected: raise ValidationError("external package architecture mismatch")

def exact_directory_inventory(path:Path,expected:set[str],label:str)->None:
    if path.is_symlink() or not path.is_dir(): raise ValidationError(f"{label} must be a non-symlink directory")
    try: entries=list(path.iterdir())
    except OSError as e: raise ValidationError(f"{label} is unreadable: {e}") from e
    if {entry.name for entry in entries}!=expected: raise ValidationError(f"{label} inventory mismatch")
    if any(entry.is_symlink() for entry in entries): raise ValidationError(f"{label} contains symlinks")


def validate_xcframework_metadata(path:Path,external_root:Path,leaves:list[dict])->None:
    try:
        with path.open("rb") as source: value=plistlib.load(source)
    except (OSError,plistlib.InvalidFileException) as e: raise ValidationError("XCFramework metadata is not a readable property list") from e
    libraries=value.get("AvailableLibraries") if isinstance(value,dict) else None
    if not isinstance(libraries,list) or len(libraries)!=2 or set(value)!={"AvailableLibraries","CFBundlePackageType","XCFrameworkFormatVersion"} or value.get("CFBundlePackageType")!="XFWK" or value.get("XCFrameworkFormatVersion")!="1.0": raise ValidationError("XCFramework metadata format/leaf inventory mismatch")
    expected={"ios-arm64":({"arm64"},None,"xcframework-ios-device-arm64"),"ios-arm64_x86_64-simulator":({"arm64","x86_64"},"simulator","xcframework-ios-simulator-arm64-x86_64")}; observed=set(); by_scope={leaf["targetScope"]:leaf for leaf in leaves}
    for library in libraries:
        if not isinstance(library,dict): raise ValidationError("XCFramework metadata leaf mismatch")
        identifier=library.get("LibraryIdentifier"); specification=expected.get(identifier)
        expected_keys={"BinaryPath","HeadersPath","LibraryIdentifier","LibraryPath","SupportedArchitectures","SupportedPlatform"}|({"SupportedPlatformVariant"} if specification and specification[1] is not None else set())
        architectures=library.get("SupportedArchitectures",[])
        if specification is None or set(library)!=expected_keys or identifier in observed or len(architectures)!=len(set(architectures)) or set(architectures)!=specification[0] or library.get("SupportedPlatform")!="ios" or library.get("SupportedPlatformVariant")!=specification[1]: raise ValidationError("XCFramework metadata leaf mismatch")
        library_path=library.get("LibraryPath")
        if library_path!="libVoxCoreFFI.a" or library.get("BinaryPath")!=library_path or library.get("HeadersPath")!="Headers": raise ValidationError("XCFramework metadata library/header path mismatch")
        leaf=by_scope.get(specification[2]); expected_leaf=contained_file(external_root,leaf["relativeArtifactPath"],"XCFramework candidate leaf") if leaf else None; metadata_leaf=path.parent/identifier/library_path
        if expected_leaf is None or metadata_leaf.resolve()!=expected_leaf.resolve(): raise ValidationError("XCFramework metadata is not bound to the inspected candidate leaf")
        observed.add(identifier)
    if observed!=set(expected): raise ValidationError("XCFramework metadata leaf inventory mismatch")

def validate_package(value:dict,build:dict,qualification:dict,external_root:Path|None,baseline_registry:dict|None,build_host:dict|None=None,repository_root:Path|None=None)->dict[str,tuple[list[str],list[float]]]:
    if value["sourceRevision"]!=build["sourceRevision"] or value["toolchainManifestSha256"]!=build["toolchainManifestSha256"] or value["buildRecipeSha256"]!=build["buildRecipeSha256"]: raise ValidationError("package receipt build identity mismatch")
    leaves=value["candidateLeaves"]
    actual=[(x["gateID"],x["targetScope"],x["architectures"],x["format"]) for x in leaves]
    if actual!=PACKAGE_ORDER: raise ValidationError("package exact leaf scope/order mismatch")
    ids=[x["artifactID"] for x in leaves]
    if len(ids)!=len(set(ids)): raise ValidationError("package artifact IDs must be unique")
    headers=value["xcframeworkHeaders"]
    metadata_relative=PurePosixPath(value["xcframeworkMetadata"]["relativeArtifactPath"])
    xcframework_relative=metadata_relative.parent
    expected_headers=[(scope,kind,(xcframework_relative/relative).as_posix(),source) for scope,kind,relative,source in XCFRAMEWORK_HEADER_ORDER]
    actual_headers=[(item["targetScope"],item["kind"],item["relativeArtifactPath"],item["repositorySourcePath"]) for item in headers]
    if actual_headers!=expected_headers: raise ValidationError("XCFramework exact header descriptor scope/order/path mismatch")
    if build_host is not None and value["buildHost"]!=build_host: raise ValidationError("package receipt build host mismatch")
    if value["inspectorSha256"]!=build["executableSha256"]: raise ValidationError("package inspector executable hash mismatch")
    for leaf in leaves:
        codes={x["code"] for x in leaf["inspectionChecks"]}
        expected_checks=ANDROID_INSPECTION_CHECKS if leaf["format"]=="elf-shared-object" else APPLE_INSPECTION_CHECKS
        if codes!=expected_checks or len(codes)!=len(leaf["inspectionChecks"]): raise ValidationError("package inspection check coverage mismatch")
    apple=sum(x["bytes"] for x in leaves if x["format"]=="apple-static-library")
    if value["appleAggregateBytes"]!=apple: raise ValidationError("Apple aggregate byte sum mismatch")
    hosted=qualification["level"] in ("hostedRun","releaseGate")
    if hosted:
        if value["retention"]["kind"]!="hostedArtifact" or external_root is None: raise ValidationError("hosted package validation requires retained external artifact root")
        for k in ("runID","runAttempt"):
            if value["retention"][k]!=qualification[k]: raise ValidationError("hosted package retention identity mismatch")
        if value["retention"]["archiveSha256"]!=qualification["artifactArchiveSha256"]: raise ValidationError("hosted package archive identity mismatch")
        if repository_root is None: raise ValidationError("hosted package validation requires repository source bytes")
        metadata=value["xcframeworkMetadata"]; metadata_path=contained_file(external_root,metadata["relativeArtifactPath"],"external XCFramework metadata")
        if metadata_path.stat().st_size!=metadata["bytes"] or digest(metadata_path)!=metadata["sha256"]: raise ValidationError("external XCFramework metadata bytes/hash mismatch")
        xcframework_root=metadata_path.parent
        exact_directory_inventory(xcframework_root,{"Info.plist","ios-arm64","ios-arm64_x86_64-simulator"},"external XCFramework root")
        for identifier in ("ios-arm64","ios-arm64_x86_64-simulator"):
            slice_root=xcframework_root/identifier
            exact_directory_inventory(slice_root,{"libVoxCoreFFI.a","Headers"},f"external XCFramework slice {identifier}")
            exact_directory_inventory(slice_root/"Headers",{"VoxCoreFFI.h","module.modulemap"},f"external XCFramework headers {identifier}")
        validate_xcframework_metadata(metadata_path,external_root,leaves)
        for descriptor in headers:
            header_path=contained_file(external_root,descriptor["relativeArtifactPath"],"external XCFramework header")
            source_path=repository_file(repository_root,descriptor["repositorySourcePath"])
            if header_path.stat().st_size!=descriptor["bytes"] or digest(header_path)!=descriptor["sha256"]: raise ValidationError("external XCFramework header bytes/hash mismatch")
            if header_path.read_bytes()!=source_path.read_bytes(): raise ValidationError("external XCFramework header differs from tracked generated source")
        for leaf in leaves:
            p=contained_file(external_root,leaf["relativeArtifactPath"],"external package artifact")
            if p.stat().st_size!=leaf["bytes"] or digest(p)!=leaf["sha256"]: raise ValidationError("external package artifact bytes/hash mismatch")
            inspect_external_package_leaf(p,leaf)
    elif value["retention"]["kind"]!="notRetained": raise ValidationError("repository observation cannot claim hosted artifact retention")
    mode=value["comparisonMode"]
    if mode=="initialCandidate":
        if baseline_registry is not None: raise ValidationError("initial candidate mode is forbidden after a governed baseline exists")
        if any(x["baseline"] is not None for x in leaves): raise ValidationError("initial candidate forbids baseline and growth data")
        growth=None
    else:
        if baseline_registry is None: raise ValidationError("approved baseline comparison requires governed baseline registry")
        if digest(Path(baseline_registry["_path"]))!=baseline_registry["sha256"]: raise ValidationError("baseline registry hash mismatch")
        registry=baseline_registry["value"]; reg=registry["leaves"]
        if registry["toolchainManifestSha256"]!=value["toolchainManifestSha256"] or registry["buildConfiguration"]!=value["buildConfiguration"] or registry["featureSet"]!=value["featureSet"]: raise ValidationError("future comparison is not identically scoped to approved baseline")
        reg_order=[(x["gateID"],x["targetScope"]) for x in reg]
        if reg_order!=[(x[0],x[1]) for x in PACKAGE_ORDER] or any(x["sourceRevision"]!=registry["sourceRevision"] for x in reg): raise ValidationError("baseline registry exact leaf identity/order mismatch")
        growth=[]
        for leaf,base,registered in zip(leaves,[x["baseline"] for x in leaves],reg):
            if base is None or base["approvedRegistrySha256"]!=baseline_registry["sha256"]: raise ValidationError("future comparison baseline identity missing")
            if (registered["gateID"],registered["targetScope"],registered["artifactID"],registered["bytes"],registered["artifactSha256"],registered["sourceRevision"])!=(leaf["gateID"],leaf["targetScope"],leaf["artifactID"],base["bytes"],base["artifactSha256"],base["sourceRevision"]): raise ValidationError("future comparison baseline registry mismatch")
            if base["sourceRevision"]==value["sourceRevision"]: raise ValidationError("baseline and candidate revisions must differ")
            growth.append((leaf["bytes"]-base["bytes"])/base["bytes"]*100)
    computed={}
    for gid in {x[0] for x in PACKAGE_ORDER}:
        values=[x["bytes"] for x in leaves if x["gateID"]==gid]
        computed[gid]=([],values)
    computed["apple-xcframework-aggregate"]=([],[apple])
    if growth is not None: computed["packaging-growth"]=([],growth)
    return computed

def ustar_numeric_field(value:int,length:int)->bytes:
    text=f"{value:0{length-1}o}".encode()
    if len(text)>=length: raise ValidationError("hosted artifact USTAR numeric field overflow")
    return text+b"\0"

def canonical_ustar_header(relative:str,source:Path)->bytes:
    encoded=relative.encode("utf-8"); name=encoded; prefix=b""
    if len(name)>100:
        split=encoded.rfind(b"/")
        if split<1: raise ValidationError("hosted artifact USTAR path is too long")
        prefix,name=encoded[:split],encoded[split+1:]
    if len(name)>100 or len(prefix)>155: raise ValidationError("hosted artifact USTAR path is too long")
    header=bytearray(512); header[:len(name)]=name
    header[100:108]=ustar_numeric_field(0o755 if os.access(source,os.X_OK) else 0o644,8)
    header[108:116]=ustar_numeric_field(0,8); header[116:124]=ustar_numeric_field(0,8)
    header[124:136]=ustar_numeric_field(source.stat().st_size,12); header[136:148]=ustar_numeric_field(0,12)
    header[148:156]=b"        "; header[156:157]=b"0"; header[257:263]=b"ustar\0"; header[263:265]=b"00"; header[345:345+len(prefix)]=prefix
    header[148:156]=f"{sum(header):06o}".encode()+b"\0 "
    return bytes(header)

def validate_retained_archive(archive:Path,external_root:Path,expected_paths:set[str])->None:
    archive_size=archive.stat().st_size
    if archive.suffix!=".tar" or archive_size>MAX_ARCHIVE_BYTES or archive_size%512: raise ValidationError("hosted artifact archive must be an uncompressed bounded block-aligned .tar")
    observed=set(); terminated=False; ordered_expected=sorted(expected_paths); member_index=0
    try:
        with archive.open("rb") as raw:
            while raw.tell()<archive_size:
                header=raw.read(512)
                if len(header)!=512: raise ValidationError("hosted artifact tar header truncated")
                if not any(header):
                    second=raw.read(512)
                    if len(second)!=512 or any(second) or raw.read(1): raise ValidationError("hosted artifact tar termination mismatch")
                    terminated=True; break
                if header[257:263]!=b"ustar\0" or header[263:265]!=b"00" or header[156:157] not in (b"0",b"\0"): raise ValidationError("hosted artifact archive forbids non-USTAR regular or extension members")
                if member_index>=len(ordered_expected): raise ValidationError("hosted artifact archive member inventory mismatch")
                expected_relative=ordered_expected[member_index]; expected_source=contained_file(external_root,expected_relative,"hosted archive source artifact")
                if header!=canonical_ustar_header(expected_relative,expected_source): raise ValidationError("hosted artifact USTAR header or member order is noncanonical")
                member_index+=1
                checksum_field=header[148:156].rstrip(b"\0 ")
                try: stored_checksum=int(checksum_field,8)
                except ValueError as e: raise ValidationError("hosted artifact tar checksum encoding mismatch") from e
                if stored_checksum!=sum(header[:148])+8*32+sum(header[156:]): raise ValidationError("hosted artifact tar checksum mismatch")
                size_field=header[124:136].rstrip(b"\0 ")
                if not size_field or any(byte not in b"01234567" for byte in size_field): raise ValidationError("hosted artifact tar size encoding mismatch")
                member_size=int(size_field,8); name=header[:100].split(b"\0",1)[0]; prefix=header[345:500].split(b"\0",1)[0]
                try: relative_text=((prefix+b"/") if prefix else b"")+name; relative=str(safe_relative(relative_text.decode("utf-8","strict"),"hosted archive member"))
                except UnicodeDecodeError as e: raise ValidationError("hosted artifact tar path encoding mismatch") from e
                if relative in observed or relative not in expected_paths: raise ValidationError("hosted artifact archive member inventory mismatch")
                source=contained_file(external_root,relative,"hosted archive source artifact")
                if member_size!=source.stat().st_size: raise ValidationError("hosted artifact archive member size mismatch")
                digest_value=hashlib.sha256(); remaining=member_size
                while remaining:
                    block=raw.read(min(HASH_BLOCK_BYTES,remaining))
                    if not block: raise ValidationError("hosted artifact archive member truncated")
                    digest_value.update(block); remaining-=len(block)
                padding=(-member_size)%512
                if padding and any(raw.read(padding)): raise ValidationError("hosted artifact archive member padding is noncanonical")
                if digest_value.hexdigest()!=digest(source): raise ValidationError("hosted artifact archive member hash mismatch")
                observed.add(relative)
    except OSError as e: raise ValidationError("hosted artifact archive is not readable") from e
    if not terminated or observed!=expected_paths: raise ValidationError("hosted artifact archive termination/inventory mismatch")

def validate_diagnostic_summary(cdir:Path,relative:str,schema:dict[str,Any])->None:
    if not relative.endswith(".diagnostic.json"): raise ValidationError(f"privacy diagnostic must use .diagnostic.json: {relative}")
    path=campaign_file(cdir,relative); data=bounded_bytes(path,MAX_JSON_BYTES)
    value=strict_json_loads(data,f"privacy diagnostic {relative}")
    if data!=canonical_json_bytes(value): raise ValidationError(f"privacy diagnostic must be canonical JSON: {relative}")
    schema_validate(value,schema,schema)

def reject_placeholders(v:Any,where:str)->None:
    bad=re.compile(r"(?:^|[^a-z])(tbd|todo|unknown|placeholder|dummy|changeme|example|n/?a|not[-_ ]?set)(?:$|[^a-z])",re.I)
    if isinstance(v,str) and bad.search(v.replace("unknownOutcome","")): raise ValidationError(f"{where}: placeholder value rejected")
    if isinstance(v,dict):
        for x in v.values(): reject_placeholders(x,where)
    if isinstance(v,list):
        for x in v: reject_placeholders(x,where)

def validate_campaign(root:Path,cdir:Path,docs,schemas,repository_root:Path|None,expected_qualification:str|None,external_root:Path|None,approval_verifier:Callable[[str,dict,dict],bool]|None=None,hosted_identity_verifier:Callable[[Path,dict,str],dict]|None=None)->None:
    if cdir.is_symlink() or not cdir.is_dir(): raise ValidationError("campaign must be a non-symlink directory")
    artifacts_dir=cdir/"artifacts"
    if artifacts_dir.is_symlink() or not artifacts_dir.is_dir(): raise ValidationError("campaign artifacts must be a non-symlink directory")
    for entry in artifacts_dir.rglob("*"):
        if entry.is_symlink(): raise ValidationError(f"campaign artifacts contains symlink: {entry.relative_to(cdir)}")
    allowed={"evidence","approvals","artifacts","aggregate.json"}; extras={p.name for p in cdir.iterdir()}-allowed
    if extras: raise ValidationError(f"campaign root contains unexpected entries: {sorted(extras)}")
    evpaths=discover_json_directory(cdir,"evidence",MAX_EVIDENCE_FILES); apppaths=discover_json_directory(cdir,"approvals",MAX_APPROVAL_FILES); aggregate_path=campaign_file(cdir,"aggregate.json")
    aggregate=load(aggregate_path); evidence=[load(p) for p in evpaths]; approvals=[load(p) for p in apppaths]
    for x in evidence: schema_validate(x,schemas["case-evidence.schema.json"],schemas["case-evidence.schema.json"])
    for x in approvals: schema_validate(x,schemas["approval.schema.json"],schemas["approval.schema.json"])
    schema_validate(aggregate,schemas["aggregate.schema.json"],schemas["aggregate.schema.json"])
    qualification=aggregate["qualification"]
    if expected_qualification and qualification["level"]!=expected_qualification: raise ValidationError("declared qualification does not match CLI qualification")
    if qualification["level"]=="releaseGate" and aggregate["scope"]["claim"]!="milestoneClosure": raise ValidationError("caseExecution scope cannot claim releaseGate qualification")
    if qualification["level"]=="releaseGate" and approval_verifier is None: raise ValidationError("releaseGate is disabled until an authenticated approval verifier is configured")
    if external_root is not None:
        if external_root.is_symlink() or not external_root.is_dir(): raise ValidationError("external artifact root must be a non-symlink directory")
        for entry in external_root.rglob("*"):
            if entry.is_symlink(): raise ValidationError(f"external artifact root contains symlink: {entry.relative_to(external_root)}")
            if not entry.is_file() and not entry.is_dir(): raise ValidationError(f"external artifact root contains unexpected file type: {entry.relative_to(external_root)}")
    if qualification["level"] in ("hostedRun","releaseGate"):
        if external_root is None: raise ValidationError("hosted qualification requires --external-artifact-root")
        if repository_root is None: raise ValidationError("hosted qualification requires --repository-root")
        workflow=repository_file(repository_root,qualification["workflowRepositoryPath"])
        if digest(workflow)!=qualification["workflowSha256"]: raise ValidationError("hosted qualification workflow hash mismatch")
        if git_output(repository_root,["status","--porcelain","--untracked-files=all"],"hosted source tree status unavailable"): raise ValidationError("hosted qualification source tree is not clean")
        validate_github_hosted_environment(repository_root,qualification,hosted_identity_verifier); validate_m2_workflow_contract(repository_root,workflow,aggregate["scope"])
    devices=idx(docs["device-matrix.json"]["roles"],"id","role"); providers=idx(docs["provider-matrix.json"]["providers"],"id","provider"); cases=idx(docs["case-catalog.json"]["cases"],"id","case"); gates=idx(docs["performance-gates.json"]["gates"],"id","gate")
    required=tuples(cases,devices,providers,aggregate["scope"]); required_set=set(required); bytuple={}; evidence_ids=set(); failed_inv=set(); generated=parse_utc(aggregate["generatedAt"],"aggregate.generatedAt"); now=datetime.now(timezone.utc); validation_time=(now.replace(microsecond=0),now.microsecond*1000)
    if generated>validation_time: raise ValidationError("aggregate generation time is in the future")
    max_completed=None; declared_campaign_artifacts=set(); declared_external_artifacts=set()
    baseline_path=root/"validation/native-package-baseline.json"; baseline_approval_path=root/"validation/native-package-baseline-approval.json"; baseline_registry=None; baseline_relatives=("validation/native-package-baseline.json","validation/native-package-baseline-approval.json")
    if baseline_path.exists()!=baseline_approval_path.exists(): raise ValidationError("baseline registry and adoption approval must either both exist or both be absent")
    if not baseline_path.exists():
        history=git_output(root,["log","--format=%H","HEAD","--",*baseline_relatives],"baseline adoption history is unavailable")
        if history: raise ValidationError("governed baseline adoption is monotonic and its registry files cannot be removed")
    if baseline_path.exists():
        if approval_verifier is None: raise ValidationError("package baseline adoption is disabled until an authenticated hosted-evidence approval verifier is configured")
        prefix=git_output(root,["rev-parse","--show-prefix"],"baseline registry requires a Git worktree")
        tracked=set(git_output(root,["ls-files","--full-name","--",*baseline_relatives],"baseline registry tracked-file inventory is unavailable").splitlines())
        if tracked!={prefix+x for x in baseline_relatives}: raise ValidationError("baseline registry and adoption approval must be committed tracked files")
        try: subprocess.run(["git","diff","--quiet","HEAD","--",*baseline_relatives],cwd=root,check=True)
        except (OSError,subprocess.CalledProcessError) as e: raise ValidationError("baseline registry or adoption approval differs from committed HEAD") from e
        baseline_bytes=bounded_bytes(baseline_path,MAX_JSON_BYTES); baseline_value=load(baseline_path)
        if baseline_bytes!=canonical_json_bytes(baseline_value): raise ValidationError("baseline registry must be canonical JSON")
        schema_validate(baseline_value,schemas["native-package-baseline.schema.json"],schemas["native-package-baseline.schema.json"])
        adoption_bytes=bounded_bytes(baseline_approval_path,MAX_JSON_BYTES); adoption=load(baseline_approval_path)
        if adoption_bytes!=canonical_json_bytes(adoption): raise ValidationError("baseline adoption approval must be canonical JSON")
        schema_validate(adoption,schemas["approval.schema.json"],schemas["approval.schema.json"])
        registry_sha=sha(baseline_bytes)
        if adoption["approvalID"]!=baseline_value["adoptionApprovalID"] or adoption["kind"]!="packageBaselineAdoption" or adoption["status"]!="approved" or adoption["subjectID"]!=baseline_value["registryID"] or adoption["subjectSha256"]!=registry_sha or adoption["definitionAggregateSha256"]!=baseline_value["definitionAggregateSha256"] or adoption["evidenceAggregateSha256"]!=baseline_value["hostedEvidenceAggregateSha256"]: raise ValidationError("baseline registry lacks a real hash-bound adoption approval")
        approved=parse_utc(adoption["approvedAt"],"baseline adoption approvedAt"); expires=parse_utc(adoption["expiresAt"],"baseline adoption expiresAt")
        if approved>generated or expires<=validation_time: raise ValidationError("baseline adoption approval is future or expired at validation time")
        if not approval_verifier("packageBaselineAdoption",adoption,baseline_value): raise ValidationError("baseline adoption approval authentication or hosted source evidence failed")
        baseline_registry={"_path":str(baseline_path),"sha256":registry_sha,"value":baseline_value}
    for e in evidence:
        reject_placeholders(e,"evidence")
        if e["evidenceID"] in evidence_ids: raise ValidationError(f"duplicate evidence ID: {e['evidenceID']}")
        evidence_ids.add(e["evidenceID"]); started=parse_utc(e["startedAt"],e["evidenceID"]+".startedAt"); completed=parse_utc(e["completedAt"],e["evidenceID"]+".completedAt")
        if started>completed or completed>generated: raise ValidationError(f"evidence chronology invalid: {e['evidenceID']}")
        max_completed=completed if max_completed is None or completed>max_completed else max_completed
        t=(e["caseID"],e["deviceRoleID"],e["providerID"])
        if t not in required_set: raise ValidationError(f"evidence tuple is outside aggregate scope: {t}")
        if t in bytuple: raise ValidationError(f"duplicate evidence tuple: {t}")
        bytuple[t]=e; c=cases[t[0]]; role=devices[t[1]] if t[1] else None
        if e["expected"]!=c["expected"]: raise ValidationError(f"expected outcome drift: {t}")
        if e["contractManifestSha256"]!=digest(root/"manifest.json"): raise ValidationError(f"contract manifest hash mismatch: {t}")
        target=c["executionTarget"]; build=e["buildIdentity"]; status=e["status"]
        if c["milestone"]=="M3" and status=="passed":
            raise ValidationError(
                f"passed M3 evidence is disabled until case-specific governed typed producers, "
                f"receipts, and exact provenance validation exist: {t[0]}"
            )
        if status in ("passed","failed") and build is None: raise ValidationError("executed evidence requires build identity")
        if build is None:
            if target=="physicalDevice" and (e["device"] is not None or e["buildHost"] is not None): raise ValidationError("unbuilt physical evidence cannot claim target identity")
            if target!="physicalDevice" and (e["device"] is not None or e["buildHost"] is not None): raise ValidationError("unbuilt host evidence cannot claim target identity")
        elif target=="physicalDevice":
            if build["kind"]!="signedApplication" or not role or not e["device"] or e["buildHost"] is not None: raise ValidationError("physical target requires signed application and observed device only")
            if qualification["level"] in ("hostedRun","releaseGate") and build["sourceRevision"]!=git_output(repository_root,["rev-parse","HEAD"],"hosted repository HEAD unavailable"): raise ValidationError("physical build source revision does not match hosted checkout")
            if e["device"]["roleID"]!=t[1] or (e["device"]["manufacturer"],e["device"]["model"])!=(role["procurementTarget"]["manufacturer"],role["procurementTarget"]["model"]): raise ValidationError(f"device identity mismatch: {t}")
            ar=role["procurementTarget"]["apiRange"]
            if not ar["minimum"]<=e["device"]["apiLevel"]<=ar["maximum"]: raise ValidationError(f"device API outside role range: {t}")
        elif target!="physicalDevice":
            if build["kind"]!="sourceBuiltHost" or e["device"] is not None or e["buildHost"] is None or t[1] is not None: raise ValidationError("build-host target requires source build and observed host only")
        if t[2] is None:
            if e.get("provider") is not None: raise ValidationError(f"unexpected provider identity: {t}")
        elif status in ("passed","failed"):
            p=providers[t[2]]
            if not e.get("provider") or (e["provider"]["providerID"],e["provider"]["authority"],e["provider"]["packageName"])!=(t[2],p["authority"],p["packageName"]): raise ValidationError(f"provider identity mismatch: {t}")
        elif e.get("provider") is not None: raise ValidationError(f"unexecuted provider evidence cannot claim observed provider identity: {t}")
        outcome_mapping={"passed":("passed","expectedOutcomeObserved"),"failed":("failed","expectedOutcomeNotObserved"),"blocked":("blocked","executionBlocked"),"notRun":("notRun","executionNotRun"),"notApplicable":("notApplicable","catalogNotApplicable")}
        if (e["actual"]["resultCode"],e["actual"]["summaryCode"])!=outcome_mapping[status]: raise ValidationError(f"evidence status/actual outcome mismatch: {t}")
        if status=="notApplicable": raise ValidationError("required selected tuple cannot be notApplicable")
        inv_ids=[x["invariantID"] for x in e["invariantResults"]]
        if len(inv_ids)!=len(set(inv_ids)): raise ValidationError(f"duplicate invariant ID: {t}")
        inv={x["invariantID"]:x["passed"] for x in e["invariantResults"]}; expected_inv=set(c["invariants"]) if status in ("passed","failed") else set()
        if set(inv)!=expected_inv: raise ValidationError(f"invariant coverage/status mismatch: {t}")
        failed_here={k for k,v in inv.items() if not v}; failed_inv|=failed_here
        if status=="passed" and failed_here: raise ValidationError(f"passed evidence requires all invariants passed: {t}")
        refs={}
        for list_name in ("fixtureHashes","artifacts"):
            for h in e[list_name]:
                if h["id"] in refs: raise ValidationError(f"duplicate artifact ID: {h['id']}")
                fp=campaign_file(cdir,h["id"])
                if digest(fp)!=h["sha256"]: raise ValidationError(f"artifact hash mismatch: {h['id']}")
                refs[h["id"]]=fp; declared_campaign_artifacts.add(h["id"])
        provenance=run_set=package=None; derived={}
        if status in ("passed","failed") and t[0] in {*CORE_REQUIRED_CHECKS,"PERF-003","PERF-008"}:
            if e["executionProvenance"] is None: raise ValidationError("executed M2 host evidence requires provenance")
            declared_campaign_artifacts.add(e["executionProvenance"]["id"]); provenance=canonical_receipt(cdir,e["executionProvenance"],schemas["execution-provenance.schema.json"]); validate_provenance(provenance,repository_root,qualification,build,t[0])
            executable_path=provenance["executable"]["externalArtifactPath"]
            if qualification["level"] in ("hostedRun","releaseGate"):
                if executable_path is None: raise ValidationError("hosted provenance requires retained executable bytes")
                executable=contained_file(external_root,executable_path,"hosted provenance executable")
                if executable.stat().st_size!=provenance["executable"]["bytes"] or digest(executable)!=provenance["executable"]["sha256"]: raise ValidationError("hosted provenance executable bytes/hash mismatch")
                if t[0]=="PERF-003": inspect_macho_executable(executable,os.environ["RUNNER_ARCH"])
                declared_external_artifacts.add(executable_path)
            elif executable_path is not None: raise ValidationError("repository observation cannot claim retained executable bytes")
            if t[0] in CORE_REQUIRED_CHECKS:
                if e["materializationRunSet"] is not None or e["nativePackageInspection"] is not None: raise ValidationError("CORE exit evidence cannot claim performance/package receipts")
            elif t[0]=="PERF-003":
                if e["materializationRunSet"] is None or e["nativePackageInspection"] is not None: raise ValidationError("PERF-003 receipt type mismatch")
                declared_campaign_artifacts.add(e["materializationRunSet"]["id"]); run_set=canonical_receipt(cdir,e["materializationRunSet"],schemas["materialization-run-set.schema.json"],MAX_RUN_SET_BYTES); derived=validate_run_set(run_set,build,gates,qualification,external_root,provenance["inputGenerator"]["seedSha256"])
                if qualification["level"] in ("hostedRun","releaseGate"):
                    for run in run_set["runs"]: declared_external_artifacts.update((run["controlArtifactPath"],run["inputArtifactPath"],run["outputArtifactPath"]))
            else:
                if e["nativePackageInspection"] is None or e["materializationRunSet"] is not None: raise ValidationError("PERF-008 receipt type mismatch")
                declared_campaign_artifacts.add(e["nativePackageInspection"]["id"]); package=canonical_receipt(cdir,e["nativePackageInspection"],schemas["native-package-inspection.schema.json"])
                if qualification["level"] in ("hostedRun","releaseGate") and parse_utc(package["retention"]["retentionExpiresAt"],"package retention expiry")<=generated: raise ValidationError("hosted package retention expired before aggregate generation")
                derived=validate_package(package,build,qualification,external_root,baseline_registry,e["buildHost"],repository_root)
                if qualification["level"] in ("hostedRun","releaseGate"):
                    declared_external_artifacts.update(x["relativeArtifactPath"] for x in package["candidateLeaves"]); declared_external_artifacts.add(package["xcframeworkMetadata"]["relativeArtifactPath"]); declared_external_artifacts.update(x["relativeArtifactPath"] for x in package["xcframeworkHeaders"])
        elif any(e[x] is not None for x in ("executionProvenance","materializationRunSet","nativePackageInspection")): raise ValidationError("unexecuted/non-M2 evidence cannot claim typed execution receipts")
        gate_ids=[x["gateID"] for x in e["measurements"]]
        if len(gate_ids)!=len(set(gate_ids)): raise ValidationError(f"duplicate gate ID: {t}")
        ms={x["gateID"]:x for x in e["measurements"]}; expected_gates=set(c.get("performanceGateIDs",[])) if status in ("passed","failed") else set()
        if package and package["comparisonMode"]=="initialCandidate": expected_gates.discard("packaging-growth")
        if set(ms)!=expected_gates: raise ValidationError(f"measurement coverage/status mismatch: {t}")
        failed_gates=[]
        for gid,m in ms.items():
            g=gates[gid]; scope=g.get("scope",gid)
            if (m["metric"],m["statistic"],m["operator"],m["unit"],m["scope"])!=(g["metric"],g["statistic"],g["operator"],g["unit"],scope): raise ValidationError(f"gate metadata mismatch: {gid}")
            if m["samplingMethod"]!=g["samplingMethod"]: raise ValidationError(f"gate sampling policy mismatch: {gid}")
            source=e["materializationRunSet"] if t[0]=="PERF-003" else e["nativePackageInspection"] if t[0]=="PERF-008" else None
            if source:
                expected_selector={"rust-materialize-1mib-p95":"durationMilliseconds","rust-materialize-additional-rss":"additionalRSSBytes","ffi-max-chunk":"ffiChunkBytes","materialization-max-aggregate":"acceptedAggregateInputBytes","packaging-growth":"packagingGrowthPercent"}.get(gid,"candidateArtifactBytes")
                expected_ids,values=derived[gid]
                if m["derivation"]!={"sourceArtifactID":source["id"],"selector":expected_selector,"runIDs":expected_ids}: raise ValidationError(f"measurement derivation mismatch: {gid}")
            else: values=m["sampleValues"]
            if len(values)<g["minimumSamples"] or m["sampleValues"]!=values: raise ValidationError(f"measurement samples are not exact typed derivation: {gid}")
            required_values=g.get("requiredSampleValues")
            if required_values is not None and sorted(values)!=sorted(required_values): raise ValidationError(f"required sample values missing or extra: {gid}")
            observed=nearest(values,g["statistic"])
            if not math.isclose(m["value"],observed,rel_tol=0,abs_tol=1e-12): raise ValidationError(f"measurement is not derived statistic: {gid}")
            if not good(g["operator"],observed,g["value"]): failed_gates.append(gid)
        if status=="passed" and failed_gates: raise ValidationError(f"passed evidence requires all measurements passed: {failed_gates}")
        if status in ("passed","failed") and t[1] and role["platform"]=="wearOS" and c["id"]!="WEAR-004":
            floor=max(role["freeStorageFloor"]["minimumBytes"],math.ceil(e["device"]["totalStorageBytes"]*role["freeStorageFloor"]["minimumCapacityFraction"]))
            if e["device"]["freeStorageBytes"]<floor: raise ValidationError(f"Wear storage floor not met: {t}")
        core_build_bound_checks=set()
        if "INV-PRIVACY-DIAGNOSTICS" in c["invariants"] or t[0] in ("PERF-003","PERF-008"):
            for list_name,kind in (("fixtureHashes","fixture"),("artifacts","artifact")):
                for h in e[list_name]:
                    validate_diagnostic_summary(cdir,h["id"],schemas["diagnostic-summary.schema.json"]); summary=load(campaign_file(cdir,h["id"]))
                    if summary["kind"]!=kind or summary["resultCode"]!=status: raise ValidationError("privacy diagnostic kind/status mismatch")
                    if list_name=="artifacts" and build is not None and {"role":"build","sha256":build["executableSha256"]} in summary["referencedHashes"]:
                        core_build_bound_checks.update(x["code"] for x in summary["checks"] if x["result"]==status and x["count"]>0)
        required_check=CORE_REQUIRED_CHECKS.get(t[0])
        if status in ("passed","failed") and required_check and required_check not in core_build_bound_checks: raise ValidationError("executed M2 core exit case lacks its build-bound named production check")
        if status=="passed" and t[0]=="CORE-005" and not SHADOW_ISOLATION_CHECKS<=core_build_bound_checks: raise ValidationError("CORE-005 lacks complete build-bound shadow isolation observations")
        if status=="failed" and not (failed_here or failed_gates): raise ValidationError(f"failed evidence requires observed failure: {t}")
    identities={(e["campaignID"],e["contractManifestSha256"],e["buildIdentity"]["sourceRevision"],e["buildIdentity"]["sourceTreeState"],e["buildIdentity"]["toolchainManifestSha256"]) for e in evidence if e["buildIdentity"] is not None}
    if len(identities)>1: raise ValidationError("campaign source/toolchain identity mismatch")
    if evidence and {e["campaignID"] for e in evidence}!={aggregate["campaignID"]}: raise ValidationError("campaign ID mismatch")
    rows=[]; counts={x:0 for x in ("passed","failed","blocked","incomplete")}
    for t in required:
        e=bytuple.get(t); status="incomplete" if not e or e["status"] in ("notRun","notApplicable") else e["status"]
        counts[status]+=1; rows.append({"caseID":t[0],"deviceRoleID":t[1],"providerID":t[2],"evidenceID":e["evidenceID"] if e else None,"status":status})
    definition_files=["device-matrix.json","provider-matrix.json","case-catalog.json","performance-gates.json","aggregate-policy.json","case-evidence-policy.json","approval-policy.json"]
    if baseline_registry: definition_files += ["native-package-baseline.json","native-package-baseline-approval.json"]
    dh=[{"id":n,"sha256":digest(root/"validation"/n)} for n in definition_files]; eh=[{"id":str(p.relative_to(cdir)),"sha256":digest(p)} for p in evpaths]; ah=[{"id":str(p.relative_to(cdir)),"sha256":digest(p)} for p in apppaths]
    da=canonical({"scope":aggregate["scope"],"qualification":aggregate["qualification"],"definitions":dh}); ea=canonical({"scope":aggregate["scope"],"qualification":aggregate["qualification"],"evidence":eh})
    valid_kinds=set(); approval_ids=set(); nonwaive={x["id"] for x in docs["case-catalog.json"]["nonWaivableInvariants"]}
    for a in approvals:
        reject_placeholders(a,"approval")
        if a["approvalID"] in approval_ids: raise ValidationError(f"duplicate approval ID: {a['approvalID']}")
        approval_ids.add(a["approvalID"]); approved=parse_utc(a["approvedAt"],a["approvalID"]+".approvedAt"); expiry=parse_utc(a["expiresAt"],a["approvalID"]+".expiresAt")
        if approved>generated or expiry<=validation_time or (max_completed and approved<max_completed): raise ValidationError("approval chronology is future, expired at validation time, or predates completed evidence")
        subject_ok=(a["kind"]=="definition" and a["subjectID"]=="definition-set" and a["subjectSha256"]==da) or (a["kind"] in ("campaign","releaseGate") and a["subjectID"]==aggregate["campaignID"] and a["subjectSha256"]==ea)
        authenticated=approval_verifier(a["kind"],a,aggregate) if approval_verifier is not None else False
        if a["status"]=="approved" and a["definitionAggregateSha256"]==da and a["evidenceAggregateSha256"]==ea and subject_ok and authenticated: valid_kinds.add(a["kind"])
    required_kinds=set(docs["approval-policy.json"]["qualificationRequirements"][qualification["level"]])
    approvals_ok=required_kinds<=valid_kinds
    if qualification["level"]!="releaseGate" and approvals: raise ValidationError("technical qualification forbids approval records")
    actual_campaign_artifacts={str(p.relative_to(cdir)) for p in artifacts_dir.rglob("*") if p.is_file()}
    if actual_campaign_artifacts!=declared_campaign_artifacts: raise ValidationError("campaign artifact inventory differs from declared evidence references")
    if qualification["level"] in ("hostedRun","releaseGate"):
        archive=contained_file(external_root,qualification["artifactArchivePath"],"hosted artifact archive")
        if digest(archive)!=qualification["artifactArchiveSha256"]: raise ValidationError("hosted artifact archive hash mismatch")
        validate_retained_archive(archive,external_root,declared_external_artifacts)
        declared_external_artifacts.add(qualification["artifactArchivePath"])
        actual_external_artifacts={str(p.relative_to(external_root)) for p in external_root.rglob("*") if p.is_file()}
        if actual_external_artifacts!=declared_external_artifacts: raise ValidationError("external artifact inventory differs from declared retained evidence")
    computed="failed" if failed_inv or counts["failed"] else "blocked" if counts["blocked"] else "incomplete" if counts["incomplete"] or not approvals_ok else "passed"
    expected={"status":computed,"definitionAggregateSha256":da,"evidenceAggregateSha256":ea,"definitionHashes":dh,"evidenceHashes":eh,"approvalHashes":ah,"requiredTuples":rows,"requiredTupleCounts":{"total":len(required),**counts},"failedInvariantIDs":sorted(failed_inv)}
    for k,v in expected.items():
        if aggregate[k]!=v: raise ValidationError(f"aggregate {k} is not computed value")

def validate(root:Path,campaign:Path|None=None,repository_root:Path|None=None,qualification:str|None=None,external_root:Path|None=None,approval_verifier:Callable[[str,dict,dict],bool]|None=None,hosted_identity_verifier:Callable[[Path,dict,str],dict]|None=None)->None:
    mapping={"device-matrix.json":"device-matrix.schema.json","provider-matrix.json":"provider-matrix.schema.json","case-catalog.json":"case-catalog.schema.json","performance-gates.json":"performance-gates.schema.json","aggregate-policy.json":"aggregate.schema.json","case-evidence-policy.json":"case-evidence-requirements.schema.json","approval-policy.json":"approval-policy.schema.json"}
    names=set(mapping.values())|{"case-evidence.schema.json","approval.schema.json","diagnostic-summary.schema.json","execution-provenance.schema.json","materialization-run-set.schema.json","native-package-inspection.schema.json","native-package-baseline.schema.json"}; schemas={}
    for n in names: schemas[n]=load(root/"schemas"/n); check_schema(schemas[n],root/"schemas"/n)
    docs={}
    for n,sn in mapping.items():
        docs[n]=load(root/"validation"/n)
        if docs[n].get("$schema")!=f"../schemas/{sn}": raise ValidationError(f"{n}: schema reference drift")
        schema_validate(docs[n],schemas[sn],schemas[sn])
    devices=idx(docs["device-matrix.json"]["roles"],"id","role"); providers=idx(docs["provider-matrix.json"]["providers"],"id","provider"); cases=idx(docs["case-catalog.json"]["cases"],"id","case"); gates=idx(docs["performance-gates.json"]["gates"],"id","gate")
    for c in cases.values():
        if c["executionTarget"]=="physicalDevice" and not c["deviceRoles"]: raise ValidationError(f"physical case lacks device role: {c['id']}")
        if c["executionTarget"]!="physicalDevice" and c["deviceRoles"]: raise ValidationError(f"build-host case has device role: {c['id']}")
    covered={r for c in cases.values() if c["required"] for r in c["deviceRoles"]}; missing={r for r,v in devices.items() if v["required"]}-covered
    if missing: raise ValidationError(f"required device roles lack case coverage: {sorted(missing)}")
    nonwaive={x["id"] for x in docs["case-catalog.json"]["nonWaivableInvariants"]}; covered_inv={x for c in cases.values() if c["required"] for x in c["invariants"]}
    if covered_inv!=nonwaive: raise ValidationError(f"non-waivable invariant required-case coverage mismatch: missing={sorted(nonwaive-covered_inv)} extra={sorted(covered_inv-nonwaive)}")
    for g in gates.values():
        if "requiredSampleValues" in g and (g["minimumSamples"]!=len(g["requiredSampleValues"]) or g["statistic"]!="maximum"): raise ValidationError(f"required sample value gate semantics invalid: {g['id']}")
    actual={"devices":canonical(docs["device-matrix.json"]),"providers":canonical(docs["provider-matrix.json"]),"cases":canonical(docs["case-catalog.json"]),"gates":canonical(docs["performance-gates.json"]),"aggregate":canonical(docs["aggregate-policy.json"]),"evidencePolicy":canonical(docs["case-evidence-policy.json"]),"approvalPolicy":canonical(docs["approval-policy.json"]),"schemas":canonical({n:schemas[n] for n in sorted(schemas)})}
    for k,v in actual.items():
        if CANONICAL_HASHES.get(k)!=v: raise ValidationError(f"canonical {k} definition drift")
    if campaign: validate_campaign(root,campaign,docs,schemas,repository_root,qualification,external_root,approval_verifier,hosted_identity_verifier)
    print(f"Validation definitions passed: {len(devices)} roles, {len(providers)} providers, {len(cases)} cases, {len(gates)} gates"+("; scoped campaign computed" if campaign else ""))

CANONICAL_HASHES={'devices': 'ecd13c2b779065abe91824bdbc2726c3e1363368fe46558fe694aa571597d8a4', 'providers': 'd0e9a96c63213cbaa13c587e92b6318ae63f88ecd88b7387c0a441c57e0eaed2', 'cases': 'dd002172abe0f59ff784b0237d5422563811f6fb22b8f4ce92449ae9b4b77b8a', 'gates': 'f227ffb7119ec4599a46870166b49ce9ed9a30974b3e41db1cb8097e28366559', 'aggregate': 'e99042ec440740050384ae1576c980de7f42a06b96db82d1c5d6d40c2f56ef58', 'evidencePolicy': '8446cf2b15504c7a7b5861e93b5cbbc1477682a8dfb4de8b0c968603caf994fc', 'approvalPolicy': 'c086d7b57f2a832ff6a1d9a8d4acdc0d8d52ffdbf0131a4512fe60b3c6b69e02', 'schemas': 'f147817d0dfb43c1b3de89ba8a5eedffaaca0716a4bbca4f248cc3fd3e66dd51'}

def main()->int:
    ap=argparse.ArgumentParser(); ap.add_argument("--contracts-root",type=Path,default=Path(__file__).resolve().parents[1]); ap.add_argument("--campaign-dir",type=Path); ap.add_argument("--repository-root",type=Path); ap.add_argument("--qualification",choices=("repositoryObservation","hostedRun","releaseGate")); ap.add_argument("--external-artifact-root",type=Path)
    a=ap.parse_args(); campaign=a.campaign_dir.absolute() if a.campaign_dir else None; repository=a.repository_root.absolute() if a.repository_root else None; external=a.external_artifact_root.absolute() if a.external_artifact_root else None
    try: validate(a.contracts_root.resolve(),campaign,repository,a.qualification,external)
    except ValidationError as e: print(f"Validation definitions failed: {e}",file=sys.stderr); return 1
    return 0
if __name__=="__main__": raise SystemExit(main())
