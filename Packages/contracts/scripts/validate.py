#!/usr/bin/env python3
"""Stdlib-only validation for Vox.md M1 contracts, traces, mirrors, and ledger."""
from __future__ import annotations
import argparse, hashlib, json, re, shutil, subprocess, sys
from pathlib import Path, PurePosixPath

CLOSURE="29ec869c8bda4d511af787af394658d0274b339b"
HEALTH="c70de9201ab7cfbadf2442183dfba23c0d248478"
FAMILIES=("capture-preparation-input","required-observations","capture-materialization-input","artifact-plan","wearable-protocol")
MIRRORS={
 "Packages/VoxboardShared/Tests/Fixtures/Contracts/v1":"resourceOnlyPlanned",
 "Packages/vox-core-rust/tests/resources/contracts/v1":"resourceOnlyPlanned",
 "apps/android/core-bridge/src/test/resources/contracts/v1":"resourceOnlyPlanned",
}
LIFECYCLES={"resourceOnlyPlanned","required"}
SCHEMA_KEYWORDS={"$schema","$id","$defs","$ref","title","description","type","const","enum","oneOf","anyOf","allOf","not","if","then","else","properties","required","additionalProperties","minProperties","maxProperties","items","minItems","maxItems","uniqueItems","minLength","maxLength","pattern","minimum","maximum"}
PRIVACY=(re.compile(r"/Users/"),re.compile(r"/home/[^/]+/"),re.compile(r"file://"),re.compile(r"content://"),re.compile(r"bookmark",re.I))
DECISION_RE=re.compile(r"`(PD-M1-[A-Z0-9-]+)`")

class ContractError(Exception):
 def __init__(self,code,path,message): self.code,self.path,self.message=code,path,message; super().__init__(f"{code} at {path}: {message}")
def reject(code,path,message): raise ContractError(code,path,message)
def load(path):
 try: return json.loads(path.read_text(encoding="utf-8"))
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
 if r.startswith("docs/architecture/adr-") or r.endswith("android-wear-m1-decisions.md"): return "acceptedDecision"
 if r.startswith("docs/validation/"): return "validationDocumentation"
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

def semantic(family,obj,context=None):
 if family=="required-observations":
  ids=[x["id"] for x in obj["observations"]]
  if len(ids)!=len(set(ids)): reject("observation.duplicateID","$.observations","observation IDs must be unique")
 if family=="capture-materialization-input":
  ids=[x["observationID"] for x in obj["observations"]]
  if len(ids)!=len(set(ids)): reject("observation.duplicateID","$.observations","observation IDs must be unique")
  for i,x in enumerate(obj["observations"]):
   if x["kind"]=="frozenTemplate" and ((x["status"]=="present") != (x["byteStreamID"] is not None)):
    reject("observation.presenceMismatch",f"$.observations[{i}].byteStreamID","stream presence must match status")
 if family=="artifact-plan":
  marker=obj["retryMarker"]
  expected="<!-- vox-capture:{lowercase-uuid} -->" if marker["policy"]=="voxCaptureCommentV1" else ""
  if marker["syntax"]!=expected: reject("plan.markerSyntax","$.retryMarker.syntax","shipped marker syntax required")
  seq=[x["commitSequence"] for x in obj["artifacts"]]
  if seq!=list(range(len(seq))): reject("plan.commitSequence","$.artifacts","sequence must be ordered and contiguous")
  if obj["artifacts"][-1]["kind"]!="note" or sum(a["kind"]=="note" for a in obj["artifacts"])!=1: reject("plan.noteLast","$.artifacts","exactly one note commits last")
 if family=="wearable-protocol":
  p=obj["payload"]; k=obj["messageKind"]
  if k=="recordingMetadata":
   only=p["mode"]=="recordingOnly"
   if only != (p["localASRPolicy"]=="disabled" and p["locationPolicy"]=="excluded" and p["recordingOnlyFolderPolicyReference"] is not None and p["recordingOnlyFilenamePolicyReference"] is not None):
    reject("wear.recordingModePolicy","$.payload.mode","Recording Only policies must be complete and transcript references absent")
  if k=="transferFrontier" and p["durableOffset"]>p["assetLength"]: reject("wear.frontierBounds","$.payload.durableOffset","offset exceeds asset")
 if family=="wearable-protocol-trace": validate_trace(obj)

def validate_trace(trace):
 env=trace["envelopes"]; first=env[0]; sender=first["senderInstallationID"]; device=first["deviceID"]; recording=first["recordingID"]; epoch=first["epoch"]; corr=first["correlationID"]
 last=-1; kinds=[]; terminal=None
 for i,e in enumerate(env):
  for field,expected in (("senderInstallationID",sender),("deviceID",device),("recordingID",recording),("epoch",epoch),("correlationID",corr)):
   if e[field]!=expected: reject(f"trace.{field}Mismatch",f"$.envelopes[{i}].{field}","trace correlation changed")
  if e["revision"]<=last: reject("trace.revisionNonMonotonic",f"$.envelopes[{i}].revision","revision must increase")
  last=e["revision"]; kind=e["messageKind"]
  if terminal and not (terminal=="vaultCommitted" and kind=="sourceDeletionAuthorized"): reject("trace.postTerminal",f"$.envelopes[{i}].messageKind","message follows terminal outcome")
  if kind=="phoneIngested" and not any(x in kinds for x in ("transferReceipt","assetManifest")): reject("trace.ingestWithoutTransfer","$.envelopes[%d].messageKind"%i,"ingest lacks transfer evidence")
  if kind=="vaultCommitted" and "phoneIngested" not in kinds: reject("trace.commitWithoutIngest",f"$.envelopes[{i}].messageKind","vault ACK lacks phone ingest")
  if kind=="sourceDeletionAuthorized" and "vaultCommitted" not in kinds: reject("trace.deletionBeforeCommit",f"$.envelopes[{i}].messageKind","deletion lacks vault ACK")
  if kind in ("vaultCommitted","terminalFailure","discarded"): terminal=kind
  kinds.append(kind)
 final=kinds[-1]
 if final!=trace["expectedFinalState"]: reject("trace.finalState","$.expectedFinalState","declared state differs")
 allowed=final in ("sourceDeletionAuthorized","discarded")
 if trace["expectedDeletionPermitted"]!=allowed: reject("trace.deletionExpectation","$.expectedDeletionPermitted","deletion expectation differs")

def accepted_decisions(root):
 text=(root/"docs/architecture/android-wear-m1-decisions.md").read_text()
 return set(DECISION_RE.findall(text))

def validate_capabilities(root,inventory,overlay):
 m0=load(root/"docs/architecture/android-wear-m0-capabilities.json")
 if inventory.get("producerRevision")!=CLOSURE or inventory.get("healthMdPrecedent")!=HEALTH: reject("capability.provenance","$","pin mismatch")
 src=inventory["source"]
 if src.get("sha256")!=digest(root/src["path"]): reject("capability.sourceHash","$.source.sha256","M0 source drift")
 old={x["id"]:x for x in m0["capabilities"]}; new={x["id"]:x for x in inventory["capabilities"]}
 if set(old)!=set(new) or len(new)!=270: reject("capability.oneToOne","$.capabilities","M0 IDs not retained")
 variances={x["capabilityID"]:x for x in overlay["variances"]}; decisions=accepted_decisions(root)
 if len(variances)!=len(overlay["variances"]): reject("variance.duplicate","$.variances","duplicate capability")
 for cid,o in old.items():
  n=new[cid]; expected={"shared":"shared","native":"native","adjusted":"adjusted"}[o["owner"]]
  classification=variances.get(cid,{}).get("classification",expected)
  if n["classification"]!=expected: reject("capability.ownerDrift",f"$.capabilities[{cid}].classification","base inventory must preserve owner")
  for key in ("outcome","evidence","platforms","programScope","milestone","dependencies","status"):
   if n.get(key)!=o.get(key): reject("capability.retention",f"$.capabilities[{cid}].{key}","M0 field drift")
  if classification in ("unavailable","deferred"):
   v=variances[cid]
   if v.get("decisionID") not in decisions or not v.get("reason") or not v.get("userVisibleBehavior") or v.get("objectiveAmended") is not False or v.get("parityStatus")!="blocking": reject("variance.unapproved",f"$.variances[{cid}]","variance requires accepted blocking decision")
 for cid in variances:
  if cid not in old: reject("variance.unknownCapability","$.variances","unknown capability")

def case_family(path): return path.parent.name

def validate_case(root,case,schemas):
 path=root/case["path"]; data=path.read_bytes(); obj=load(path)
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
 records=[{"path":relpath(p,root),"bytes":len(p.read_bytes()),"sha256":digest(p),"category":category(p,root)} for p in files]
 mirrors=[]
 for path,lifecycle in MIRRORS.items(): mirrors.append({"path":path,"lifecycle":lifecycle,"sources":source_rels,"consumer":None,"evidence":None})
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
 res=resources(root); rels=[p.relative_to(base).as_posix() for p in res]; seen=set()
 for mirror in manifest.get("mirrors",[]):
  path=mirror.get("path"); lifecycle=mirror.get("lifecycle")
  if path not in MIRRORS or path in seen or lifecycle not in LIFECYCLES or lifecycle!=MIRRORS[path]: reject("mirror.lifecycle","$.mirrors","lifecycle inventory differs")
  seen.add(path)
  if mirror.get("sources")!=rels: reject("mirror.sourceSet",f"$.mirrors.{path}","source list differs")
  if lifecycle=="required" and (not mirror.get("consumer") or not mirror.get("evidence") or not (root/mirror["evidence"]).is_file()): reject("mirror.requiredEvidence",f"$.mirrors.{path}","named executable consumer evidence required")
  if lifecycle=="resourceOnlyPlanned" and (mirror.get("consumer") is not None or mirror.get("evidence") is not None): reject("mirror.plannedClaimsEvidence",f"$.mirrors.{path}","planned mirror cannot claim execution")
  target=root/path; actual={p.relative_to(target).as_posix() for p in target.rglob("*") if p.is_file()} if target.exists() else set()
  if target.exists() and actual!=set(rels): reject("mirror.exactFileSet",f"$.mirrors.{path}","resource set differs")
  if target.exists():
   for rel in rels:
    if (target/rel).read_bytes()!=(base/rel).read_bytes(): reject("mirror.bytes",f"$.mirrors.{path}/{rel}","bytes differ")
 if seen!=set(MIRRORS): reject("mirror.inventory","$.mirrors","destination missing")
 overlay=load(base/"scope-variances.json"); validate_capabilities(root,load(base/"product-capabilities.json"),overlay)
 print(f"Contracts validation passed: {len(records)} governed files, {len(cases)} fixtures, 270 owner-preserving capabilities, {len(MIRRORS)} resource mirrors.")

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
