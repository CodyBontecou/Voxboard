#!/usr/bin/env python3
"""Stdlib-only validation for Vox.md M1 contracts, traces, mirrors, and ledger."""
from __future__ import annotations
import argparse, copy, hashlib, json, re, shutil, subprocess, sys, uuid
from pathlib import Path, PurePosixPath

CLOSURE="29ec869c8bda4d511af787af394658d0274b339b"
HEALTH="c70de9201ab7cfbadf2442183dfba23c0d248478"
FAMILIES=("capture-preparation-input","required-observations","capture-materialization-input","artifact-plan","wearable-protocol","core-api","android-capture-package")
MIRRORS={
 "Packages/VoxboardShared/Tests/Fixtures/Contracts/v1":"resourceOnlyPlanned",
 "Packages/vox-core-rust/tests/resources/contracts/v1":"required",
 "apps/android/core-bridge/src/test/resources/contracts/v1":"resourceOnlyPlanned",
 "apps/android/data/src/test/resources/contracts/v1":"required",
}
LIFECYCLES={"resourceOnlyPlanned","required"}
SCHEMA_KEYWORDS={"$schema","$id","$defs","$ref","title","description","type","const","enum","oneOf","anyOf","allOf","not","if","then","else","properties","required","additionalProperties","minProperties","maxProperties","items","minItems","maxItems","uniqueItems","minLength","maxLength","pattern","minimum","maximum"}
PRIVACY=(re.compile(r"/Users/"),re.compile(r"/home/[^/]+/"),re.compile(r"file://"),re.compile(r"content://"),re.compile(r"bookmark",re.I))
DECISION_RE=re.compile(r"`(PD-M1-[A-Z0-9-]+)`")

class ContractError(Exception):
 def __init__(self,code,path,message): self.code,self.path,self.message=code,path,message; super().__init__(f"{code} at {path}: {message}")
def reject(code,path,message): raise ContractError(code,path,message)
def load(path):
 def pairs(values):
  result={}
  for key,value in values:
   if key in result: reject("json.duplicate","$",f"{path}: duplicate key {key}")
   result[key]=value
  return result
 def nonfinite(value): reject("json.nonFinite","$",f"{path}: {value}")
 try: return json.loads(path.read_text(encoding="utf-8"),object_pairs_hook=pairs,parse_constant=nonfinite)
 except ContractError: raise
 except Exception as e: reject("json.invalid","$",f"{path}: {e}")
def canonical(v): return (json.dumps(v,ensure_ascii=False,indent=2,sort_keys=True)+"\n").encode()
def sha(data): return hashlib.sha256(data).hexdigest()
def digest(path): return sha(path.read_bytes())
def safe_rel(v):
 return isinstance(v,str) and v and not v.startswith("/") and "\\" not in v and all(x not in ("",".","..") for x in PurePosixPath(v).parts)
def relpath(path,root): return path.relative_to(root).as_posix()

def category(path,root):
 r=relpath(path,root)
 if r=="Packages/contracts/README.md": return "contractReadme"
 if r=="Packages/contracts/product-capabilities.json": return "capabilityInventory"
 if r=="Packages/contracts/scope-variances.json": return "scopeVarianceOverlay"
 if r.startswith("Packages/contracts/scripts/"): return "validatorScript"
 if r.startswith("Packages/contracts/tests/"): return "validatorTest"
 if r.startswith("Packages/contracts/schemas/"): return "validationSchema"
 if r.startswith("Packages/contracts/validation/"): return "validationDefinition"
 if r.startswith("toolchains/"): return "toolchainDefinition"
 if r.startswith("Packages/vox-core-rust/"): return "toolchainEntryStub"
 if r.startswith("docs/architecture/adr-") or r.endswith("android-wear-m1-decisions.md"): return "acceptedDecision"
 if r.startswith("docs/validation/"): return "validationDocumentation"
 if r==".github/workflows/contracts-ci.yml": return "contractWorkflow"
 if r=="scripts/test-project-contracts.sh": return "contractGate"
 if "/fixtures/" in r: return "contractFixture"
 return "contractSource"

def governed(root):
 base=root/"Packages/contracts"; files=[]
 for name in ("README.md","product-capabilities.json","scope-variances.json"): files.append(base/name)
 for folder in ("scripts","tests","schemas","validation"):
  files += sorted(p for p in (base/folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts and p.suffix in (".py",".json"))
 for fam in FAMILIES:
  files += sorted(p for p in (base/fam/"v1").glob("*") if p.is_file())
 files += sorted(p for p in (base/"fixtures").glob("*/*.json"))
 files += sorted((root/"docs/architecture").glob("adr-*.md")); files.append(root/"docs/architecture/android-wear-m1-decisions.md")
 files += sorted(p for p in (root/"docs/validation").rglob("*") if p.is_file())
 files += [root/".github/workflows/contracts-ci.yml",root/"scripts/test-project-contracts.sh"]
 files += [root/"toolchains/android-wear-shared-core.json",root/"toolchains/android-wear-shared-core.schema.json",root/"Packages/vox-core-rust/rust-toolchain.toml",root/"Packages/vox-core-rust/Cargo.toml",root/"Packages/vox-core-rust/uniffi.toml"]
 return sorted(set(files),key=lambda p:relpath(p,root))

def resources(root):
 base=root/"Packages/contracts"; out=[]
 for fam in FAMILIES: out += sorted(p for p in (base/fam/"v1").glob("*") if p.is_file())
 out += sorted(p for p in (base/"fixtures").glob("*/*.json"))
 return out

def decode_pointer(doc,pointer,path):
 cur=doc
 for token in pointer.lstrip("/").split("/") if pointer else []:
  token=token.replace("~1","/").replace("~0","~")
  if not isinstance(cur,dict) or token not in cur: reject("schema.ref",path,f"unresolved JSON pointer {pointer}")
  cur=cur[token]
 return cur

def resolve_ref(ref,schema_file,root_schema,contracts_root,path):
 if ref.startswith("#"): return decode_pointer(root_schema,ref[1:],path),schema_file,root_schema
 target,_,fragment=ref.partition("#")
 resolved=(schema_file.parent/target).resolve()
 try: resolved.relative_to(contracts_root.resolve())
 except ValueError: reject("schema.ref",path,"reference escapes contracts root")
 document=load(resolved)
 return decode_pointer(document,fragment,path),resolved,document

def audit_schema(schema,path="$"):
 if not isinstance(schema,dict): reject("schema.invalid",path,"schema must be an object")
 unsupported=set(schema)-SCHEMA_KEYWORDS
 if unsupported: reject("schema.unsupportedKeyword",path,f"unsupported keywords {sorted(unsupported)}")
 for k in ("oneOf","anyOf","allOf"):
  for i,s in enumerate(schema.get(k,[])): audit_schema(s,f"{path}.{k}[{i}]")
 for k in ("not","if","then","else","items","additionalProperties"):
  if isinstance(schema.get(k),dict): audit_schema(schema[k],f"{path}.{k}")
 for k,s in schema.get("properties",{}).items(): audit_schema(s,f"{path}.properties.{k}")
 for k,s in schema.get("$defs",{}).items(): audit_schema(s,f"{path}.$defs.{k}")

def schema_validate(value,schema,path="$",schema_file=None,root_schema=None,contracts_root=None):
 root_schema=root_schema or schema
 if "$ref" in schema:
  target,target_file,target_root=resolve_ref(schema["$ref"],schema_file,root_schema,contracts_root,path)
  return schema_validate(value,target,path,target_file,target_root,contracts_root)
 def attempt(s): schema_validate(value,s,path,schema_file,root_schema,contracts_root)
 if "allOf" in schema:
  for s in schema["allOf"]: attempt(s)
 if "anyOf" in schema:
  errors=[]
  for s in schema["anyOf"]:
   try: attempt(s); break
   except ContractError as e: errors.append(e)
  else: reject("schema.anyOf",path,"no variant matched")
 if "oneOf" in schema:
  matches=0
  for s in schema["oneOf"]:
   try: attempt(s); matches+=1
   except ContractError: pass
  if matches!=1: reject("schema.oneOf",path,f"expected exactly one variant, matched {matches}")
 if "not" in schema:
  try: attempt(schema["not"])
  except ContractError: pass
  else: reject("schema.not",path,"forbidden schema matched")
 if "if" in schema:
  try: attempt(schema["if"]); condition=True
  except ContractError: condition=False
  branch="then" if condition else "else"
  if branch in schema: attempt(schema[branch])
 if "const" in schema and value!=schema["const"]: reject("schema.const",path,f"expected {schema['const']!r}")
 if "enum" in schema and value not in schema["enum"]: reject("schema.enum",path,"unknown enum value")
 typ=schema.get("type")
 checks={"object":lambda:isinstance(value,dict),"array":lambda:isinstance(value,list),"string":lambda:isinstance(value,str),"integer":lambda:isinstance(value,int) and not isinstance(value,bool),"number":lambda:isinstance(value,(int,float)) and not isinstance(value,bool),"boolean":lambda:isinstance(value,bool),"null":lambda:value is None}
 if typ and (typ not in checks or not checks[typ]()): reject("schema.type",path,f"expected {typ}")
 if isinstance(value,dict):
  for key in schema.get("required",[]):
   if key not in value: reject("schema.required",f"{path}.{key}","required field absent")
  props=schema.get("properties",{})
  if schema.get("additionalProperties") is False:
   extras=set(value)-set(props)
   if extras: reject("schema.unknownField",f"{path}.{sorted(extras)[0]}","unknown field")
  for key,item in value.items():
   if key in props: schema_validate(item,props[key],f"{path}.{key}",schema_file,root_schema,contracts_root)
   elif isinstance(schema.get("additionalProperties"),dict): schema_validate(item,schema["additionalProperties"],f"{path}.{key}",schema_file,root_schema,contracts_root)
  if len(value)<schema.get("minProperties",0) or len(value)>schema.get("maxProperties",sys.maxsize): reject("schema.objectBounds",path,"property count out of bounds")
 if isinstance(value,list):
  if len(value)<schema.get("minItems",0) or len(value)>schema.get("maxItems",sys.maxsize): reject("schema.arrayBounds",path,"item count out of bounds")
  if schema.get("uniqueItems") and len({json.dumps(x,sort_keys=True) for x in value})!=len(value): reject("schema.uniqueItems",path,"duplicate items")
  if isinstance(schema.get("items"),dict):
   for i,item in enumerate(value): schema_validate(item,schema["items"],f"{path}[{i}]",schema_file,root_schema,contracts_root)
 if isinstance(value,str):
  if len(value)<schema.get("minLength",0) or len(value)>schema.get("maxLength",sys.maxsize): reject("schema.stringBounds",path,"string length out of bounds")
  if "pattern" in schema and re.search(schema["pattern"],value) is None: reject("schema.pattern",path,"pattern mismatch")
 if isinstance(value,(int,float)) and not isinstance(value,bool):
  if value<schema.get("minimum",float("-inf")) or value>schema.get("maximum",float("inf")): reject("schema.numericBounds",path,"number out of bounds")

def validate_android_capture_package(obj):
 if "assetCount" in obj:
  if obj["assetCount"]!=0 or obj["assets"]!=[]: reject("package.assetsProfile","$","M3 assets must be exactly empty")
  return
 if "events" in obj:
  terminal={"completed","permanentFailure","discarded"}; prior=None; resume=None; last_materialized_plan=None
  for index,event in enumerate(obj["events"]):
   path=f"$.events[{index}]"; state=event["state"]; code=event["code"]
   if obj["journalVersion"]!=2: reject("package.journalVersion",path,"journal v2 required")
   if index==0:
    if event["revision"]!=0 or event["fromState"] is not None or state!="queued" or code!="enqueued" or event["resumeState"] is not None or event["receiptID"] is not None: reject("package.initialEvent",path,"invalid initial frontier")
   else:
    if prior in terminal: reject("package.terminalTransition",path,"terminal state has successor")
    if event["revision"]!=index or event["fromState"]!=prior: reject("package.frontier",path,"revision/fromState mismatch")
    expected_resume=("committing" if prior=="unknownOutcome" else prior) if state=="needsPermission" else None
    if event["resumeState"]!=expected_resume: reject("package.resumeFrontier",path,"resume state mismatch")
    allowed={
     "queued":{("preparing","preparationStarted"),("discarded","userDiscarded")},
     "preparing":{("materialized","materialized"),("retryableFailure","retryableFailure"),("needsPermission","permissionLost"),("needsUserAction","userActionRequired"),("permanentFailure","permanentFailure"),("discarded","userDiscarded")},
     "materialized":{("preparing","preparationStarted"),("committing","commitStarted"),("retryableFailure","retryableFailure"),("needsPermission","permissionLost"),("needsUserAction","userActionRequired"),("permanentFailure","permanentFailure"),("discarded","userDiscarded")},
     "committing":{("completed","verifiedCommitted"),("retryableFailure","provedNotCommitted"),("needsPermission","permissionLost"),("unknownOutcome","commitAmbiguous")},
     "retryableFailure":{("preparing","preparationStarted"),("discarded","userDiscarded")},
     "needsPermission":{(resume,"permissionRestored"),("discarded","userDiscarded")},
     "unknownOutcome":{("completed","verifiedCommitted"),("retryableFailure","provedNotCommitted"),("needsPermission","permissionLost"),("discarded","userDiscarded")},
     "needsUserAction":{("discarded","userDiscarded")},
    }
    if (state,code) not in allowed.get(prior,set()): reject("package.illegalTransition",path,"transition/code is not legal")
   if state=="completed":
    if event["receiptID"] is None: reject("package.receipt",path,"completed requires receipt")
   elif event["receiptID"] is not None: reject("package.receipt",path,"receipt only allowed for completed")
   if code in ("materialized","commitStarted"):
    if event["planHash"] is None: reject("package.planHash",path,f"{code} requires planHash")
    if code=="materialized": last_materialized_plan=event["planHash"]
    elif event["planHash"]!=last_materialized_plan: reject("package.planHash",path,"commitStarted planHash must match the latest materialized planHash")
   elif event["planHash"] is not None: reject("package.planHash",path,"planHash only allowed for materialized/commitStarted")
   resume=event["resumeState"] if state=="needsPermission" else resume
   prior=state
  return

def semantic(family,obj,context=None):
 if family=="android-capture-package": validate_android_capture_package(obj)
 if family=="required-observations":
  ids=[x["id"] for x in obj["observations"]]
  if len(ids)!=len(set(ids)): reject("observation.duplicateID","$.observations","observation IDs must be unique")
 if family=="capture-materialization-input":
  ids=[x["observationID"] for x in obj["observations"]]
  if len(ids)!=len(set(ids)): reject("observation.duplicateID","$.observations","observation IDs must be unique")
  for i,x in enumerate(obj["observations"]):
   if x["kind"]=="frozenTemplate" and ((x["status"]=="present") != (x["byteStreamID"] is not None)):
    reject("observation.presenceMismatch",f"$.observations[{i}].byteStreamID","stream presence must match status")
 if family=="artifact-plan" and "receiptID" in obj:
  if set(obj)!={"artifactID","operationID","receiptID","requestID","schemaVersion"} or obj["schemaVersion"]!=1: reject("receipt.vectorShape","$","receipt derivation vector shape")
  pre='{"\n  "'
  import uuid as _uuid, hashlib as _hashlib
  _ns=_uuid.UUID("8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415")
  _pre=canonical({"artifactID":obj["artifactID"],"operationID":obj["operationID"],"requestID":obj["requestID"]})
  _h=_hashlib.sha1(_ns.bytes+b"vox.receipt.v1"+b"\x00"+_pre).digest()
  _id=str(_uuid.UUID(bytes=_h[:16],version=5))
  if obj["receiptID"]!=_id: reject("receipt.derivation","$.receiptID","receiptID does not match the vox.receipt.v1 derivation")
  return
 if family=="artifact-plan":
  marker=obj["retryMarker"]
  expected="<!-- vox-capture:{lowercase-uuid} -->" if marker["policy"]=="voxCaptureCommentV1" else ""
  if marker["syntax"]!=expected: reject("plan.markerSyntax","$.retryMarker.syntax","shipped marker syntax required")
  seq=[x["commitSequence"] for x in obj["artifacts"]]
  if seq!=list(range(len(seq))): reject("plan.commitSequence","$.artifacts","sequence must be ordered and contiguous")
  if obj["artifacts"][-1]["kind"]!="note" or sum(a["kind"]=="note" for a in obj["artifacts"])!=1: reject("plan.noteLast","$.artifacts","exactly one note commits last")
  namespace=uuid.UUID("8c7f8d7e-4f61-5d92-a94a-3b9e6cc8e415")
  def derived(domain,preimage):
   raw=bytearray(hashlib.sha1(namespace.bytes+domain.encode("ascii")+b"\0"+canonical(preimage)).digest()[:16]); raw[6]=(raw[6]&15)|80; raw[8]=(raw[8]&63)|128; return str(uuid.UUID(bytes=bytes(raw)))
  for i,a in enumerate(obj["artifacts"]):
   operation_id=derived("vox.operation.v1",{"commitSequence":a["commitSequence"],"operation":obj["operation"],"requestID":obj["requestID"]})
   if a["operationID"]!=operation_id: reject("plan.operationID",f"$.artifacts[{i}].operationID","deterministic UUID mismatch")
   artifact_id=derived("vox.artifact.v1",{"kind":a["kind"],"logicalPath":a["logicalPath"],"operationID":operation_id})
   if a["artifactID"]!=artifact_id: reject("plan.artifactID",f"$.artifacts[{i}].artifactID","deterministic UUID mismatch")
   if a["kind"]=="note":
    stream_id=derived("vox.stream.v1",{"artifactID":artifact_id,"resultLength":a["resultLength"],"resultSHA256":a["resultSHA256"]})
    if a["preparedStreamID"]!=stream_id: reject("plan.streamID",f"$.artifacts[{i}].preparedStreamID","deterministic UUID mismatch")
  copy_plan=copy.deepcopy(obj); copy_plan["planHash"]="0"*64
  if obj["planHash"]!=sha(canonical(copy_plan)): reject("plan.hash","$.planHash","canonical plan hash mismatch")
 if family=="wearable-protocol":
  p=obj["payload"]; k=obj["messageKind"]
  if k=="recordingMetadata":
   only=p["mode"]=="recordingOnly"
   recording_only_policy=p["localASRPolicy"]=="disabled" and p["locationPolicy"]=="excluded" and p["recordingOnlyFolderPolicyReference"] is not None and p["recordingOnlyFilenamePolicyReference"] is not None
   transcript_policy=p["recordingOnlyFolderPolicyReference"] is None and p["recordingOnlyFilenamePolicyReference"] is None
   if (only and not recording_only_policy) or (not only and not transcript_policy):
    reject("wear.recordingModePolicy","$.payload.mode","Recording Only policies must be complete and transcript references absent")
  if k=="transferFrontier" and (p["durableOffset"]>p["assetLength"] or p["chunkLength"]>p["assetLength"]): reject("wear.frontierBounds","$.payload.durableOffset","frontier offset or chunk exceeds asset")
 if family=="wearable-protocol-trace": validate_trace(obj)
 if family=="core-api":
  kind=obj["kind"]
  if kind=="readinessResult":
   ready=obj["status"]=="ready"
   if ready!=(obj["sessionPermitted"] is True) or ready!=(obj["mismatchCodes"]==[]): reject("core.readinessCoherence","$","ready alone permits a session and has no mismatches")
  if kind=="expectedArtifactDescriptors":
   seq=[x["commitSequence"] for x in obj["artifacts"]]
   if seq!=list(range(len(seq))): reject("core.descriptorOrder","$.artifacts","commit sequence must be ordered and contiguous")
   ids=[x["artifactID"] for x in obj["artifacts"]]; streams=[x["streamID"] for x in obj["artifacts"]]
   if len(ids)!=len(set(ids)) or len(streams)!=len(set(streams)): reject("core.duplicateDescriptor","$.artifacts","artifact and stream IDs must be unique")
  if kind=="drainedArtifactHashes":
   ids=[x["artifactID"] for x in obj["artifacts"]]; streams=[x["streamID"] for x in obj["artifacts"]]
   if len(ids)!=len(set(ids)) or len(streams)!=len(set(streams)): reject("core.duplicateDrainedArtifact","$.artifacts","artifact and stream IDs must be unique")

def recording_scope(e):
 return (e["senderInstallationID"],e["deviceID"],e["recordingID"],e["epoch"],e["correlationID"])

def reconciliation_state(kind,prior=None):
 if kind in ("capabilityHello","presetInventory","presetSnapshot","recordingMetadata"): return "localRecorded"
 if kind in ("assetManifest","transferFrontier","transferReceipt"): return "assetPublished"
 if kind=="phoneIngested": return "phoneIngested"
 if kind in ("vaultCommitted","sourceDeletionAuthorized"): return "vaultCommitted"
 if kind in ("terminalFailure","discarded"): return kind
 return prior

def validate_trace(trace):
 states={}; revisions={}; message_ids={}; installation_epochs={}; retired_installations=set(); record_frontiers={}; active_installation=None
 for i,event in enumerate(trace["events"]):
  e=event["envelope"]; expected=event["expectedDisposition"]; kind=e["messageKind"]
  installation=e["senderInstallationID"]; sender_message=(installation,e["messageID"]); encoded=canonical(e); scope=recording_scope(e); revision_scope=scope[:4]; record_key=scope[:3]; known_epoch=installation_epochs.get(installation)
  semantic("wearable-protocol",e)
  prior=message_ids.get(sender_message)
  if prior is not None:
   if prior!=encoded: reject("trace.messageIDCollision",f"$.events[{i}].envelope.messageID","sender-scoped message ID changed envelope bytes after first observation")
   disposition="duplicateNoOp"
  elif installation in retired_installations:
   disposition="foreignInstallationRejected"
  elif active_installation is not None and installation!=active_installation:
   can_reconcile=kind=="reconciliationSummary" and (known_epoch is None or e["epoch"]>known_epoch)
   disposition="accepted" if can_reconcile else "foreignInstallationRejected"
  elif known_epoch is not None and e["epoch"]<known_epoch: disposition="staleEpochNoOp"
  elif revision_scope in revisions and e["revision"]<=revisions[revision_scope]: disposition="staleRevisionNoOp"
  else: disposition="accepted"
  # First observation is authoritative even when rejected or stale. Reuse must be byte-identical.
  message_ids[sender_message]=encoded
  if disposition!=expected: reject("trace.dispositionMismatch",f"$.events[{i}].expectedDisposition",f"computed {disposition}")
  if disposition!="accepted": continue
  if active_installation is not None and installation!=active_installation:
   retired_installations.add(active_installation)
  active_installation=installation; installation_epochs[installation]=max(e["epoch"],known_epoch if known_epoch is not None else e["epoch"])
  previous_revision=revisions.get(revision_scope); revisions[revision_scope]=e["revision"]
  s=states.setdefault(scope,{"accepted":[],"acceptedRevisions":set(),"state":"reconciled","terminal":None,"inventory":{},"snapshots":{},"metadata":None,"frozenPolicy":None,"asset":None,"frontier":None,"receipt":None,"ingested":None,"vault":None,"actions":{}})
  imported_frontier=record_frontiers.get(record_key); imported_terminal=imported_frontier[1] if imported_frontier and imported_frontier[1] in ("vaultCommitted","terminalFailure","discarded") else None
  terminal=s["terminal"] or imported_terminal
  if terminal and not (terminal=="vaultCommitted" and kind=="sourceDeletionAuthorized"):
   reject("trace.postTerminal",f"$.events[{i}].envelope.messageKind","accepted message follows terminal outcome in recording scope")
  p=e["payload"]
  if kind=="reconciliationSummary":
   recording_ids=[x["recordingID"] for x in p["recordings"]]
   if len(recording_ids)!=len(set(recording_ids)): reject("trace.reconciliationDuplicateRecording",f"$.events[{i}].envelope.payload.recordings","recording IDs must be unique")
   if recording_ids.count(e["recordingID"])!=1: reject("trace.reconciliationRecordingIdentity",f"$.events[{i}].envelope.payload.recordings","summary must include envelope recording exactly once")
   entry=next(x for x in p["recordings"] if x["recordingID"]==e["recordingID"])
   known_frontier=record_frontiers.get(record_key)
   if known_frontier is not None and (entry["lastRevision"],entry["state"])!=known_frontier: reject("trace.reconciliationFrontier",f"$.events[{i}].envelope.payload.recordings","known recording revision/state must match reducer history")
   pending=p["pendingActionCorrelationIDs"]
   prior_correlations={x["correlationID"] for state in states.values() for x in state["accepted"] if x["senderInstallationID"]==installation and x["deviceID"]==e["deviceID"] and x["messageKind"] in ("reassign","retry","discard")}
   if any(x not in prior_correlations for x in pending): reject("trace.reconciliationPendingCorrelation",f"$.events[{i}].envelope.payload.pendingActionCorrelationIDs","pending correlations must identify earlier accepted installation/device messages")
   for reconciled in p["recordings"]:
    key=(installation,e["deviceID"],reconciled["recordingID"]); known=record_frontiers.get(key)
    if known is not None and (reconciled["lastRevision"],reconciled["state"])!=known: reject("trace.reconciliationFrontier",f"$.events[{i}].envelope.payload.recordings","known recording revision/state must match reducer history")
    record_frontiers[key]=(reconciled["lastRevision"],reconciled["state"])
    imported_revision_scope=(installation,e["deviceID"],reconciled["recordingID"],e["epoch"])
    revisions[imported_revision_scope]=max(revisions.get(imported_revision_scope,-1),reconciled["lastRevision"])
    imported_scope=(installation,e["deviceID"],reconciled["recordingID"],e["epoch"],e["correlationID"])
    imported=states.setdefault(imported_scope,{"accepted":[],"acceptedRevisions":set(),"state":"reconciled","terminal":None,"inventory":{},"snapshots":{},"metadata":None,"frozenPolicy":None,"asset":None,"frontier":None,"receipt":None,"ingested":None,"vault":None,"actions":{}})
    imported["acceptedRevisions"].add(reconciled["lastRevision"]); imported["state"]=reconciled["state"]
    if reconciled["state"] in ("vaultCommitted","terminalFailure","discarded"): imported["terminal"]=reconciled["state"]
  if kind=="unsupportedVersion": s["terminal"]=kind
  elif kind=="presetInventory":
   s["inventory"]={x["presetID"]:(x["revision"],x["snapshotHash"]) for x in p["presets"]}
  elif kind=="presetSnapshot":
   key=p["presetID"]
   if s["inventory"].get(key)!=(p["presetRevision"],p["snapshotHash"]): reject("trace.presetMismatch",f"$.events[{i}].envelope.payload","snapshot does not match accepted inventory")
   if sha(canonical(p["portablePolicy"]))!=p["snapshotHash"]: reject("trace.presetHash",f"$.events[{i}].envelope.payload.snapshotHash","snapshot hash must attest complete portable policy canonical bytes")
   s["snapshots"][key]=p
  elif kind=="recordingMetadata":
   if s["metadata"] is not None: reject("trace.metadataAlreadyFrozen",f"$.events[{i}].envelope.payload","recording metadata and policy are immutable in a recording scope")
   snap=s["snapshots"].get(p["presetID"])
   if not snap or (p["presetRevision"],p["presetSnapshotHash"])!=(snap["presetRevision"],snap["snapshotHash"]): reject("trace.metadataPresetMismatch",f"$.events[{i}].envelope.payload","metadata does not match accepted preset snapshot")
   policy=snap["portablePolicy"]
   if (p["localASRPolicy"],p["locationPolicy"],p["recordingOnlyFolderPolicyReference"],p["recordingOnlyFilenamePolicyReference"])!=(policy["localASRPolicy"],policy["locationPolicy"],policy["recordingOnlyFolderPolicyReference"],policy["recordingOnlyFilenamePolicyReference"]): reject("trace.metadataPolicyMismatch",f"$.events[{i}].envelope.payload","metadata does not match complete frozen portable policy")
   s["metadata"]=copy.deepcopy(p); s["frozenPolicy"]=copy.deepcopy(policy)
  elif kind=="assetManifest":
   if not s["metadata"]: reject("trace.assetWithoutMetadata",f"$.events[{i}].envelope.payload","asset lacks accepted frozen recording metadata")
   if s["ingested"] is not None: reject("trace.assetReplacementAfterIngest",f"$.events[{i}].envelope.payload","asset cannot be replaced after phone ingest in the same recording scope")
   s["asset"]=(p["assetID"],p["length"],p["sha256"]); s["frontier"]=None; s["receipt"]=None; s["ingested"]=None; s["vault"]=None; s["terminal"]=None
  elif kind=="transferFrontier":
   if s["asset"]!=(p["assetID"],p["assetLength"],p["assetSHA256"]): reject("trace.assetMismatch",f"$.events[{i}].envelope.payload","frontier does not match scoped manifest")
   previous=s["frontier"]
   if previous:
    expected_offset=previous["durableOffset"]+p["chunkLength"]
    if p["frontierRevision"]<=previous["frontierRevision"]: reject("trace.frontierRevision",f"$.events[{i}].envelope.payload.frontierRevision","frontier revision must strictly increase")
    if p["chunkSequence"]!=previous["chunkSequence"]+1: reject("trace.chunkSequence",f"$.events[{i}].envelope.payload.chunkSequence","chunk sequence must be contiguous")
    if p["durableOffset"]!=expected_offset: reject("trace.frontierProgression",f"$.events[{i}].envelope.payload.durableOffset","durable offset must advance by chunk length")
   elif p["chunkSequence"]!=0 or p["durableOffset"]!=p["chunkLength"]:
    reject("trace.frontierStart",f"$.events[{i}].envelope.payload","first frontier must be chunk zero at its chunk length")
   s["frontier"]=p
  elif kind=="transferReceipt":
   f=s["frontier"]
   if not s["asset"] or not f or p["assetID"]!=s["asset"][0] or p["durableOffset"]!=f["durableOffset"] or p["frontierRevision"]!=f["frontierRevision"]: reject("trace.receiptMismatch",f"$.events[{i}].envelope.payload","receipt does not match scoped durable frontier")
   s["receipt"]=p
  elif kind=="phoneIngested":
   a=s["asset"]; f=s["frontier"]; r=s["receipt"]
   if not a or not f or not r or p["durableReceiptID"]!=r["transportReceiptID"] or (p["assetLength"],p["assetSHA256"])!=a[1:] or f["durableOffset"]!=a[1]: reject("trace.ingestMismatch",f"$.events[{i}].envelope.payload","phone ingest lacks matching complete scoped asset/frontier/receipt")
   s["ingested"]=e
  elif kind=="vaultCommitted":
   ingest=s["ingested"]
   if not ingest or p["phoneIngestedCorrelationID"]!=ingest["correlationID"]: reject("trace.commitCorrelation",f"$.events[{i}].envelope.payload.phoneIngestedCorrelationID","vault ACK lacks scoped correlated ingest")
   if s["metadata"]["mode"]=="recordingOnly" and (p["verifiedArtifactLength"],p["verifiedArtifactHash"])!=s["asset"][1:]: reject("trace.recordingOnlyArtifactMismatch",f"$.events[{i}].envelope.payload","Recording Only vault artifact must match source media")
   s["vault"]=e; s["terminal"]=kind
  elif kind=="sourceDeletionAuthorized":
   vault=s["vault"]
   if not vault or p["vaultCommitCorrelationID"]!=vault["correlationID"] or p["durableObservationReceiptID"]!=vault["payload"]["destinationReceiptID"]: reject("trace.deletionCorrelation",f"$.events[{i}].envelope.payload.vaultCommitCorrelationID","deletion lacks scoped correlated vault ACK receipt")
   s["terminal"]=kind
  elif kind=="terminalFailure":
   if not any(x["correlationID"]==p["failedMessageCorrelationID"] for x in s["accepted"]): reject("trace.failureCorrelation",f"$.events[{i}].envelope.payload.failedMessageCorrelationID","failure lacks earlier scoped correlated message")
   s["terminal"]=kind
  elif kind in ("reassign","retry","discard"):
   action=p["actionID"]
   if action in s["actions"]: reject("trace.actionIDCollision",f"$.events[{i}].envelope.payload.actionID","action ID must be unique in recording scope")
   if kind=="retry" and (p["retryFromRevision"] not in s["acceptedRevisions"] or p["retryFromRevision"]>=e["revision"]): reject("trace.retryRevision",f"$.events[{i}].envelope.payload.retryFromRevision","retry must name an earlier accepted revision")
   if kind=="reassign" and (not s["frozenPolicy"] or p["targetCapabilityReference"]==s["frozenPolicy"]["destinationCapabilityReference"]): reject("trace.reassignMeaning",f"$.events[{i}].envelope.payload.targetCapabilityReference","reassign must change the destination frozen at recording metadata")
   s["actions"][action]=kind
  elif kind=="discarded":
   if s["actions"].get(p["actionReceiptID"])!="discard": reject("trace.discardCorrelation",f"$.events[{i}].envelope.payload.actionReceiptID","discard receipt lacks scoped user action")
   s["terminal"]=kind
  s["accepted"].append(e); s["acceptedRevisions"].add(e["revision"]); s["state"]=kind
  if kind!="reconciliationSummary":
   prior_frontier=record_frontiers.get(record_key); reduced=reconciliation_state(kind,prior_frontier[1] if prior_frontier else None)
   if reduced is not None: record_frontiers[record_key]=(e["revision"],reduced)
 final=trace["expectedFinalRecordingIdentity"]
 final_scope=(final["senderInstallationID"],final["deviceID"],final["recordingID"],final["epoch"],final["correlationID"])
 if final_scope not in states: reject("trace.finalIdentity","$.expectedFinalRecordingIdentity","final recording scope was not accepted")
 state=states[final_scope]["state"]
 if state!=trace["expectedFinalState"]: reject("trace.finalState","$.expectedFinalState",f"computed {state}")
 allowed=state in ("sourceDeletionAuthorized","discarded")
 if trace["expectedDeletionPermitted"]!=allowed: reject("trace.deletionExpectation","$.expectedDeletionPermitted","deletion expectation differs for final recording scope")

def accepted_decisions(root):
 text=(root/"docs/architecture/android-wear-m1-decisions.md").read_text()
 return set(DECISION_RE.findall(text))

def validate_capabilities(root,inventory,overlay):
 base=root/"Packages/contracts"; schema_file=base/"schemas/scope-variances.schema.json"; schema=load(schema_file)
 audit_schema(schema); schema_validate(overlay,schema,schema_file=schema_file,root_schema=schema,contracts_root=base)
 m0_path=root/"docs/architecture/android-wear-m0-capabilities.json"; m0=load(m0_path)
 expected_caps=[]
 for c in m0["capabilities"]:
  item={k:copy.deepcopy(c[k]) for k in ("id","outcome","evidence","platforms")}
  item.update(classification={"shared":"shared","native":"native","adjusted":"adjusted"}[c["owner"]],legacyParity=c["parity"],programScope=c["programScope"],milestone=c["milestone"],dependencies=copy.deepcopy(c["dependencies"]))
  item["acceptance"]=[dict({"mappingID":f"{c['id']}.acceptance.{i+1}"},**copy.deepcopy(a)) for i,a in enumerate(c["acceptance"])]
  item["status"]=c["status"]; expected_caps.append(item)
 expected_inventory={"schemaVersion":1,"producerRevision":CLOSURE,"healthMdPrecedent":HEALTH,"source":{"path":"docs/architecture/android-wear-m0-capabilities.json","sha256":digest(m0_path)},"dependencyCatalog":copy.deepcopy(m0["dependencyCatalog"]),"capabilities":expected_caps}
 if inventory!=expected_inventory: reject("capability.conversionDrift","$","inventory must exactly equal deterministic M0 conversion, including acceptance and dependencies")
 old={x["id"]:x for x in m0["capabilities"]}; new={x["id"]:x for x in inventory["capabilities"]}
 if set(old)!=set(new) or len(new)!=271: reject("capability.oneToOne","$.capabilities","M0 IDs not retained")
 variances={x["capabilityID"]:x for x in overlay["variances"]}; decisions=accepted_decisions(root)
 if len(variances)!=len(overlay["variances"]): reject("variance.duplicate","$.variances","duplicate capability")
 for cid,o in old.items():
  n=new[cid]; expected={"shared":"shared","native":"native","adjusted":"adjusted"}[o["owner"]]
  classification=variances.get(cid,{}).get("classification")
  if n["classification"]!=expected: reject("capability.ownerDrift",f"$.capabilities[{cid}].classification","base inventory must preserve owner")
  for key in ("outcome","evidence","platforms","programScope","milestone","dependencies","status"):
   if n.get(key)!=o.get(key): reject("capability.retention",f"$.capabilities[{cid}].{key}","M0 field drift")
  if classification is not None:
   v=variances[cid]
   if v["decisionID"] not in decisions: reject("variance.unapproved",f"$.variances[{cid}]","variance requires accepted blocking decision")
 for cid in variances:
  if cid not in old: reject("variance.unknownCapability","$.variances","unknown capability")

def case_family(path): return path.parent.name

def validate_case(root,case,schemas):
 path=root/case["path"]; data=path.read_bytes(); obj=load(path)
 if case["family"]=="android-capture-package" and len(data)>1048576: reject("package.controlBounds","$",case["path"])
 if canonical(obj)!=data: reject("fixture.nonCanonical","$",f"{case['path']} is not canonical")
 for pattern in PRIVACY:
  if pattern.search(data.decode()): reject("fixture.privacy","$",case["path"])
 producer=case.get("producer",{})
 if producer!={"name":"vox-contract-fixture-generator","revision":"m1-v1","source":"Packages/contracts/scripts/generate_fixtures.py"}: reject("fixture.provenance","$",case["path"])
 family=case["family"]; schema_file, schema=schemas[family]
 error=None
 try:
  schema_validate(obj,schema,schema_file=schema_file,root_schema=schema,contracts_root=root/"Packages/contracts")
  semantic(family,obj)
 except ContractError as e: error=e
 if case["expect"]=="valid" and error: reject("fixture.validRejected","$",f"{case['path']}: {error}")
 if case["expect"]=="invalid":
  if not error: reject("fixture.negativeAccepted","$",case["path"])
  expected=case.get("expectedError",{})
  if error.code!=expected.get("code") or error.path!=expected.get("path"): reject("fixture.wrongTypedError","$",f"{case['path']}: got {error.code} {error.path}")

def validate_android_package_fixture_binding(root):
 base=root/"Packages/contracts/fixtures"
 request_path=base/"capture-preparation-input/valid-android-m3-text-link.json"
 assets_path=base/"android-capture-package/valid-assets.json"
 request_bytes=request_path.read_bytes(); assets_bytes=assets_path.read_bytes()
 request=load(request_path); assets=load(assets_path)
 if request["requestID"]!=assets["requestID"]: reject("package.fixtureCorrelation","$","request/assets IDs differ")
 preset=copy.deepcopy(request["preset"]); claimed=preset["snapshotHash"]; preset["snapshotHash"]="0"*64
 if claimed!=sha(canonical(preset)): reject("package.fixturePresetHash","$.preset.snapshotHash","fixed preset hash is not derived from canonical zeroed snapshot")
 if request["pins"]!={"coreVersion":"0.1.0-alpha.1","modelProfileID":None,"modelRevision":None,"profileID":"apple-parity-v1","profileVersion":1,"rendererRevision":"swift-legacy-m0"}: reject("package.fixturePins","$.pins","M3 fixture pins drift")
 if request["preset"]["id"]!="33333333-3333-4333-8333-333333333333" or request["preset"]["destinationPolicy"]["expectedCaseSensitivity"]!="sensitive": reject("package.fixtureProfile","$.preset","M3 fixed preset/case profile drift")
 for name in ("valid-queued-journal.json","valid-journal.json"):
  journal=load(base/"android-capture-package"/name)
  expected={"requestByteCount":len(request_bytes),"requestSHA256":sha(request_bytes),"assetManifestByteCount":len(assets_bytes),"assetManifestSHA256":sha(assets_bytes),"requestID":request["requestID"]}
  if any(journal[key]!=value for key,value in expected.items()): reject("package.fixtureBinding","$",f"{name} does not bind governed request/assets bytes")

def build_manifest(root):
 base=root/"Packages/contracts"; files=governed(root)
 for p in files:
  if not p.is_file(): reject("manifest.missingSource","$",relpath(p,root))
 res=resources(root); source_rels=[p.relative_to(base).as_posix() for p in res]
 for destination in MIRRORS:
  target=root/destination
  if target.exists(): shutil.rmtree(target)
  for source in res:
   dest=target/source.relative_to(base); dest.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(source,dest)
 schemas={f:(base/f/"v1/schema.json",load(base/f/"v1/schema.json")) for f in FAMILIES}
 schemas["wearable-protocol-trace"]=(base/"wearable-protocol/v1/trace.schema.json",load(base/"wearable-protocol/v1/trace.schema.json"))
 cases=[]
 producer={"name":"vox-contract-fixture-generator","revision":"m1-v1","source":"Packages/contracts/scripts/generate_fixtures.py"}
 for p in sorted((base/"fixtures").glob("*/*.json")):
  family=case_family(p); expect="valid" if p.name.startswith("valid-") else "invalid"; case={"path":relpath(p,root),"family":family,"expect":expect,"synthetic":True,"producer":producer}
  if expect=="invalid":
   obj=load(p); sf,sch=schemas[family]
   try: schema_validate(obj,sch,schema_file=sf,root_schema=sch,contracts_root=base); semantic(family,obj)
   except ContractError as e: case["expectedError"]={"code":e.code,"path":e.path}
   else: reject("fixture.negativeAccepted","$",relpath(p,root))
  cases.append(case)
 validate_android_package_fixture_binding(root)
 records=[{"path":relpath(p,root),"bytes":len(p.read_bytes()),"sha256":digest(p),"category":category(p,root)} for p in files]
 mirrors=[]
 for path,lifecycle in MIRRORS.items():
  required=path=="Packages/vox-core-rust/tests/resources/contracts/v1"
  if path=="apps/android/data/src/test/resources/contracts/v1":
   consumer="CapturePackageFixtureConsumerTest.production_codec_consumes_governed_fixtures"; evidence="apps/android/data/src/test/kotlin/md/vox/android/data/CapturePackageFixtureConsumerTest.kt"
  else:
   consumer="vox-core m2_core::rust_contract_mirror_is_consumed" if required else None; evidence="Packages/vox-core-rust/crates/vox-core/tests/m2_core.rs" if required else None
  mirrors.append({"path":path,"lifecycle":lifecycle,"sources":source_rels,"consumer":consumer,"evidence":evidence})
 manifest={"schemaVersion":2,"producerRevision":CLOSURE,"healthMdPrecedent":HEALTH,"files":records,"fixtureCases":cases,"mirrors":mirrors,"producer":{"name":"vox-contract-manifest-generator","script":"Packages/contracts/scripts/validate.py","scriptSHA256":digest(base/"scripts/validate.py")}}
 (base/"manifest.json").write_bytes(canonical(manifest)); return manifest

def validate(root):
 base=root/"Packages/contracts"; manifest=load(base/"manifest.json")
 if manifest.get("schemaVersion")!=2: reject("manifest.version","$.schemaVersion","expected 2")
 if manifest.get("producer",{}).get("scriptSHA256")!=digest(base/"scripts/validate.py"): reject("manifest.producerHash","$.producer.scriptSHA256","validator drift")
 expected={relpath(p,root) for p in governed(root)}; records=manifest.get("files",[]); paths=[r.get("path") for r in records]
 if set(paths)!=expected or len(paths)!=len(set(paths)): reject("manifest.exactFileSet","$.files","governed set differs")
 for rec in records:
  p=root/rec["path"]
  if rec.get("category")!=category(p,root): reject("manifest.category","$.files","category differs")
  if rec.get("bytes")!=len(p.read_bytes()) or rec.get("sha256")!=digest(p): reject("manifest.hash","$.files",rec["path"])
 schemas={f:(base/f/"v1/schema.json",load(base/f/"v1/schema.json")) for f in FAMILIES}; schemas["wearable-protocol-trace"]=(base/"wearable-protocol/v1/trace.schema.json",load(base/"wearable-protocol/v1/trace.schema.json"))
 for _,schema in schemas.values(): audit_schema(schema)
 fixtures={relpath(p,root) for p in (base/"fixtures").glob("*/*.json")}; cases=manifest.get("fixtureCases",[])
 if {c.get("path") for c in cases}!=fixtures or len(cases)!=len(fixtures): reject("manifest.fixtureSet","$.fixtureCases","fixture coverage differs")
 for case in cases: validate_case(root,case,schemas)
 validate_android_package_fixture_binding(root)
 res=resources(root); rels=[p.relative_to(base).as_posix() for p in res]; seen=set()
 for mirror in manifest.get("mirrors",[]):
  path=mirror.get("path"); lifecycle=mirror.get("lifecycle")
  if path not in MIRRORS or path in seen or lifecycle not in LIFECYCLES or lifecycle!=MIRRORS[path]: reject("mirror.lifecycle","$.mirrors","lifecycle inventory differs")
  seen.add(path)
  if mirror.get("sources")!=rels: reject("mirror.sourceSet",f"$.mirrors.{path}","source list differs")
  if lifecycle=="required" and (not mirror.get("consumer") or not mirror.get("evidence") or not (root/mirror["evidence"]).is_file()): reject("mirror.requiredEvidence",f"$.mirrors.{path}","named executable consumer evidence required")
  if lifecycle=="resourceOnlyPlanned" and (mirror.get("consumer") is not None or mirror.get("evidence") is not None): reject("mirror.plannedClaimsEvidence",f"$.mirrors.{path}","planned mirror cannot claim execution")
  target=root/path
  if not target.is_dir(): reject("mirror.missing",f"$.mirrors.{path}","declared M1 resource mirror must be present")
  actual={p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()}
  if actual!=set(rels): reject("mirror.exactFileSet",f"$.mirrors.{path}","resource set differs")
  for rel in rels:
   if (target/rel).read_bytes()!=(base/rel).read_bytes(): reject("mirror.bytes",f"$.mirrors.{path}/{rel}","bytes differ")
 if seen!=set(MIRRORS): reject("mirror.inventory","$.mirrors","destination missing")
 overlay=load(base/"scope-variances.json"); validate_capabilities(root,load(base/"product-capabilities.json"),overlay)
 print(f"Contracts validation passed: {len(records)} governed files, {len(cases)} fixtures, 271 owner-preserving capabilities, {len(MIRRORS)} resource mirrors.")

def main(argv=None):
 parser=argparse.ArgumentParser(); parser.add_argument("--root",type=Path); parser.add_argument("--regenerate-manifest",action="store_true"); args=parser.parse_args(argv); root=(args.root or Path(__file__).resolve().parents[3]).resolve()
 try:
  if args.regenerate_manifest:
   subprocess.run([sys.executable,str(root/"Packages/contracts/scripts/convert_capabilities.py"),"--check"],cwd=root,check=True)
   build_manifest(root); print("Regenerated stable manifest and byte-identical mirrors.")
  else: validate(root)
 except (ContractError,subprocess.CalledProcessError) as e: print(f"Contracts validation failed: {e}",file=sys.stderr); return 1
 return 0
if __name__=="__main__": raise SystemExit(main())
