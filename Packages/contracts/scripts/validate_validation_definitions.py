#!/usr/bin/env python3
"""Validate frozen M1 definitions and optional synthetic/physical campaign records."""
from __future__ import annotations
import argparse, hashlib, json, math, re, sys
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any

class ValidationError(Exception): pass

def load(path: Path)->Any:
    try: return json.loads(path.read_text())
    except Exception as e: raise ValidationError(f"{path}: invalid JSON: {e}") from e

def digest(path: Path)->str: return hashlib.sha256(path.read_bytes()).hexdigest()
def canonical(value: Any)->str: return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
UTC_RFC3339=re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.(\d{1,9}))?Z$")
def parse_utc(value:str,label:str)->tuple[datetime,int]:
    match=UTC_RFC3339.fullmatch(value) if isinstance(value,str) else None
    if not match: raise ValidationError(f"{label}: timestamp must be canonical UTC RFC3339 ending Z")
    try: parsed=datetime.fromisoformat(value[:19]+"+00:00")
    except ValueError as e: raise ValidationError(f"{label}: invalid date-time") from e
    if parsed.utcoffset() is None: raise ValidationError(f"{label}: timezone is required")
    nanoseconds=int((match.group(1) or "").ljust(9,"0"))
    return parsed,nanoseconds

def campaign_file(cdir:Path,relative:str)->Path:
    if not isinstance(relative,str) or not relative or relative.startswith('/') or '\\' in relative:
        raise ValidationError(f"unsafe campaign-relative artifact path: {relative!r}")
    pure=PurePosixPath(relative)
    if any(x in ('','.','..') for x in pure.parts): raise ValidationError(f"unsafe campaign-relative artifact path: {relative!r}")
    candidate=cdir.joinpath(*pure.parts)
    try: candidate.resolve(strict=True).relative_to(cdir.resolve(strict=True))
    except (OSError,ValueError) as e: raise ValidationError(f"artifact path missing or escapes campaign: {relative!r}") from e
    cursor=cdir
    for part in pure.parts:
        cursor=cursor/part
        if cursor.is_symlink(): raise ValidationError(f"artifact path must not traverse symlinks: {relative!r}")
    if not candidate.is_file(): raise ValidationError(f"artifact path must name a regular file: {relative!r}")
    return candidate

def canonical_json_bytes(value:Any)->bytes:
    return (json.dumps(value,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
def validate_diagnostic_summary(cdir:Path,relative:str,schema:dict[str,Any])->None:
    if not relative.endswith('.diagnostic.json'): raise ValidationError(f"privacy diagnostic must use .diagnostic.json: {relative}")
    path=campaign_file(cdir,relative); data=path.read_bytes()
    try: value=json.loads(data.decode('utf-8'))
    except (UnicodeDecodeError,json.JSONDecodeError) as e: raise ValidationError(f"privacy diagnostic must be strict JSON: {relative}") from e
    if data!=canonical_json_bytes(value): raise ValidationError(f"privacy diagnostic must be canonical JSON: {relative}")
    schema_validate(value,schema,schema)
def jt(v:Any,t:str)->bool:
    return {"object":isinstance(v,dict),"array":isinstance(v,list),"string":isinstance(v,str),"boolean":isinstance(v,bool),"integer":isinstance(v,int) and not isinstance(v,bool),"number":isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v),"null":v is None}.get(t,False)
def pointer(root:Any,p:str)->Any:
    if p in ("#",""): return root
    if not p.startswith("#/"): raise ValidationError(f"unsupported $ref {p}")
    x=root
    try:
        for k in p[2:].split('/'): x=x[k.replace('~1','/').replace('~0','~')]
        return x
    except Exception as e: raise ValidationError(f"unresolved schema reference: {p}") from e

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
    if "const" in s and x!=s["const"]: raise ValidationError(f"{p}: const mismatch")
    if "enum" in s and x not in s["enum"]: raise ValidationError(f"{p}: enum mismatch")
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
        if s.get("uniqueItems") and len({json.dumps(v,sort_keys=True,separators=(',',':')) for v in x})!=len(x): raise ValidationError(f"{p}: duplicate items")
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
    if not str(s.get("$id","")).startswith("https://vox.md/contracts/schemas/"): raise ValidationError(f"{path}: canonical $id missing")
    def walk(v:Any, in_props=False):
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

def tuples(cases,devices,providers):
    out=[]
    for c in cases.values():
        if not c["required"]: continue
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

def discover_json_directory(cdir:Path,name:str)->list[Path]:
    directory=cdir/name
    if directory.is_symlink() or not directory.is_dir(): raise ValidationError(f"campaign {name} must be a non-symlink directory")
    paths=[]
    for entry in sorted(directory.iterdir(),key=lambda p:p.name):
        if entry.is_symlink() or not entry.is_file(): raise ValidationError(f"campaign {name} contains symlink or unexpected file type: {entry.name}")
        if entry.suffix!=".json": raise ValidationError(f"campaign {name} contains unexpected non-JSON file: {entry.name}")
        paths.append(campaign_file(cdir,f"{name}/{entry.name}"))
    return paths

def validate_campaign(root:Path,cdir:Path,docs,schemas)->None:
    if cdir.is_symlink() or not cdir.is_dir(): raise ValidationError("campaign must be a non-symlink directory")
    artifacts_dir=cdir/"artifacts"
    if artifacts_dir.is_symlink() or not artifacts_dir.is_dir(): raise ValidationError("campaign artifacts must be a non-symlink directory")
    for entry in artifacts_dir.rglob("*"):
        if entry.is_symlink(): raise ValidationError(f"campaign artifacts contains symlink: {entry.relative_to(cdir)}")
    allowed={"evidence","approvals","artifacts","aggregate.json"}
    extras={p.name for p in cdir.iterdir()}-allowed
    if extras: raise ValidationError(f"campaign root contains unexpected entries: {sorted(extras)}")
    evpaths=discover_json_directory(cdir,"evidence"); apppaths=discover_json_directory(cdir,"approvals"); aggregate_path=campaign_file(cdir,"aggregate.json"); aggregate=load(aggregate_path)
    evidence=[load(p) for p in evpaths]; approvals=[load(p) for p in apppaths]
    for x in evidence: schema_validate(x,schemas["case-evidence.schema.json"],schemas["case-evidence.schema.json"])
    for x in approvals: schema_validate(x,schemas["approval.schema.json"],schemas["approval.schema.json"])
    schema_validate(aggregate,schemas["aggregate.schema.json"],schemas["aggregate.schema.json"])
    devices=idx(docs["device-matrix.json"]["roles"],"id","role"); providers=idx(docs["provider-matrix.json"]["providers"],"id","provider"); cases=idx(docs["case-catalog.json"]["cases"],"id","case"); gates=idx(docs["performance-gates.json"]["gates"],"id","gate")
    required=tuples(cases,devices,providers); bytuple={}; evidence_ids=set(); approval_ids=set()
    failed_inv=set(); generated=parse_utc(aggregate["generatedAt"],"aggregate.generatedAt"); max_completed=None
    for e in evidence:
        reject_placeholders(e,"evidence")
        if e["evidenceID"] in evidence_ids: raise ValidationError(f"duplicate evidence ID: {e['evidenceID']}")
        evidence_ids.add(e["evidenceID"])
        started=parse_utc(e["startedAt"],f"{e['evidenceID']}.startedAt"); completed=parse_utc(e["completedAt"],f"{e['evidenceID']}.completedAt")
        if started>completed or completed>generated: raise ValidationError(f"evidence chronology invalid: {e['evidenceID']}")
        max_completed=completed if max_completed is None or completed>max_completed else max_completed
        t=(e["caseID"],e["deviceRoleID"],e["providerID"])
        if t not in required: raise ValidationError(f"evidence tuple is not catalog-approved: {t}")
        if t in bytuple: raise ValidationError(f"duplicate evidence tuple: {t}")
        bytuple[t]=e; c=cases[t[0]]; role=devices[t[1]] if t[1] else None
        if e["expected"]!=c["expected"]: raise ValidationError(f"expected outcome drift: {t}")
        if e["contractManifestSha256"]!=digest(root/"manifest.json"): raise ValidationError(f"contract manifest hash mismatch: {t}")
        if role is None:
            if e["device"] is not None: raise ValidationError(f"unexpected device identity: {t}")
        else:
            if not e["device"] or e["device"]["roleID"]!=t[1] or (e["device"]["manufacturer"],e["device"]["model"])!=(role["procurementTarget"]["manufacturer"],role["procurementTarget"]["model"]): raise ValidationError(f"device identity mismatch: {t}")
            ar=role["procurementTarget"]["apiRange"]
            if not ar["minimum"]<=e["device"]["apiLevel"]<=ar["maximum"]: raise ValidationError(f"device API outside role range: {t}")
        if t[2] is None:
            if e.get("provider") is not None: raise ValidationError(f"unexpected provider identity: {t}")
        else:
            p=providers[t[2]]
            if e.get("providerID")!=t[2] or not e.get("provider") or (e["provider"]["providerID"],e["provider"]["authority"],e["provider"]["packageName"])!=(t[2],p["authority"],p["packageName"]): raise ValidationError(f"provider identity mismatch: {t}")
        status=e["status"]; outcome_mapping={"passed":("passed","expectedOutcomeObserved"),"failed":("failed","expectedOutcomeNotObserved"),"blocked":("blocked","executionBlocked"),"notRun":("notRun","executionNotRun"),"notApplicable":("notApplicable","catalogNotApplicable")}
        if (e["actual"]["resultCode"],e["actual"]["summaryCode"])!=outcome_mapping[status]: raise ValidationError(f"evidence status/actual outcome mismatch: {t}")
        if status=="notApplicable": raise ValidationError("required expanded tuple cannot be notApplicable")
        inv_ids=[x["invariantID"] for x in e["invariantResults"]]
        if len(inv_ids)!=len(set(inv_ids)): raise ValidationError(f"duplicate invariant ID: {t}")
        inv={x["invariantID"]:x["passed"] for x in e["invariantResults"]}
        expected_inv=set(c["invariants"]) if status in ("passed","failed") else set()
        if set(inv)!=expected_inv: raise ValidationError(f"invariant coverage/status mismatch: {t}")
        failed_here={k for k,v in inv.items() if not v}; failed_inv|=failed_here
        if status=="passed" and failed_here: raise ValidationError(f"passed evidence requires all invariants passed: {t}")
        privacy_governed="INV-PRIVACY-DIAGNOSTICS" in c["invariants"]
        gate_ids=[x["gateID"] for x in e["measurements"]]
        if len(gate_ids)!=len(set(gate_ids)): raise ValidationError(f"duplicate gate ID: {t}")
        ms={x["gateID"]:x for x in e["measurements"]}
        expected_gates=set(c.get("performanceGateIDs",[])) if status in ("passed","failed") else set()
        if set(ms)!=expected_gates: raise ValidationError(f"measurement coverage/status mismatch: {t}")
        failed_gates=[]
        for gid,m in ms.items():
            g=gates[gid]; scope=g.get("scope",gid)
            if (m["metric"],m["statistic"],m["operator"],m["unit"],m["scope"])!=(g["metric"],g["statistic"],g["operator"],g["unit"],scope): raise ValidationError(f"gate metadata mismatch: {gid}")
            if len(m["sampleValues"])<g["minimumSamples"] or m["samplingMethod"]!=g["samplingMethod"]: raise ValidationError(f"gate sampling policy mismatch: {gid}")
            observed=nearest(m["sampleValues"],g["statistic"])
            if m["value"]!=observed: raise ValidationError(f"measurement is not nearest-rank/statistical result: {gid}")
            if not good(g["operator"],observed,g["value"]): failed_gates.append(gid)
        if status=="passed" and failed_gates: raise ValidationError(f"passed evidence requires all measurements passed: {t}: {failed_gates}")
        if t[1] and role["platform"]=="wearOS" and c["id"]!="WEAR-004":
            floor=max(role["freeStorageFloor"]["minimumBytes"],math.ceil(e["device"]["totalStorageBytes"]*role["freeStorageFloor"]["minimumCapacityFraction"]))
            if e["device"]["freeStorageBytes"]<floor: raise ValidationError(f"Wear storage floor not met: {t}")
        refs={}; diagnostic_failures=False
        for list_name,expected_kind in (("fixtureHashes","fixture"),("artifacts","artifact")):
            for h in e[list_name]:
                if h["id"] in refs: raise ValidationError(f"duplicate artifact ID: {h['id']}")
                fp=campaign_file(cdir,h["id"])
                if digest(fp)!=h["sha256"]: raise ValidationError(f"artifact hash mismatch: {h['id']}")
                if privacy_governed:
                    validate_diagnostic_summary(cdir,h["id"],schemas["diagnostic-summary.schema.json"]); summary=load(fp)
                    if summary["kind"]!=expected_kind: raise ValidationError(f"diagnostic kind does not match {list_name}: {h['id']}")
                    if summary["resultCode"]!=status: raise ValidationError(f"diagnostic result does not match evidence status: {h['id']}")
                    results=[x["result"] for x in summary["checks"]]
                    if status=="passed" and any(x!="passed" for x in results): raise ValidationError(f"passed diagnostic requires passed checks: {h['id']}")
                    if status=="failed" and ("failed" not in results or any(x not in ("passed","failed") for x in results)): raise ValidationError(f"failed diagnostic requires a failed check: {h['id']}")
                    if status in ("blocked","notRun","notApplicable") and any(x!=status for x in results): raise ValidationError(f"diagnostic checks do not match evidence status: {h['id']}")
                    role_allow={"fixture":{"fixture","input","manifest","build"},"artifact":{"output","receipt","manifest","build"}}[expected_kind]
                    if any(x["role"] not in role_allow for x in summary["referencedHashes"]): raise ValidationError(f"diagnostic referenced hash role is unsafe for {expected_kind}: {h['id']}")
                    diagnostic_failures |= "failed" in results
                refs[h["id"]]=(h["sha256"],fp.stat().st_size)
        observed_failure=bool(failed_here or failed_gates or diagnostic_failures)
        if status=="failed" and not observed_failure: raise ValidationError(f"failed evidence requires an observed invariant, measurement, or diagnostic failure: {t}")
        if "packaging-growth" in c.get("performanceGateIDs",[]) and status in ("passed","failed"):
            baselines=e.get("packagingBaselines"); required_gates={x for x in c["performanceGateIDs"] if x!="packaging-growth"}; policy=docs["performance-gates.json"]["packagingBaselinePolicy"]
            required_scopes=[(x["gateID"],x["targetScope"]) for x in policy["requiredLeafScopes"]]
            if not baselines or len(baselines)!=len(required_scopes): raise ValidationError("packaging baseline exact leaf scope coverage missing")
            actual_scopes=[(b["gateID"],b["targetScope"]) for b in baselines]
            if actual_scopes!=required_scopes: raise ValidationError("packaging baseline exact leaf scope set/order mismatch")
            coherent={(b["toolchainID"],b["buildConfiguration"],b["featureSet"]) for b in baselines}; artifact_ids=[b["artifactID"] for b in baselines]
            if len(coherent)!=1 or len(artifact_ids)!=len(set(artifact_ids)): raise ValidationError("packaging baseline identities are not coherent or unique")
            growths=[]; seen_gates=set()
            for b in baselines:
                scope=b["targetScope"]; gate_id=b["gateID"]; seen_gates.add(gate_id)
                if b["baselineRevision"]==b["candidateRevision"] or b["candidateRevision"]!=e["commitSha"]: raise ValidationError("packaging future baseline identity missing or wrong")
                baseline_id=b["artifactID"]+".baseline"; candidate_id=b["artifactID"]+".candidate"
                if refs.get(baseline_id)!=(b["baselineArtifactSha256"],b["baselineBytes"]) or refs.get(candidate_id)!=(b["candidateArtifactSha256"],b["candidateBytes"]): raise ValidationError("packaging bytes/hashes are not bound to referenced artifact files")
                growths.append(((b["candidateBytes"]-b["baselineBytes"])/b["baselineBytes"])*100)
            if seen_gates|({"apple-xcframework-aggregate"} if "apple-xcframework-per-slice" in seen_gates else set())!=required_gates: raise ValidationError("packaging baseline gate coverage mismatch")
            for gid in required_gates:
                measurement=ms[gid]
                values=[b["candidateBytes"] for b in baselines if b["gateID"]==gid or (gid=="apple-xcframework-aggregate" and b["gateID"]=="apple-xcframework-per-slice")]
                expected_values=[sum(values)] if gid=="apple-xcframework-aggregate" else values
                if measurement["sampleValues"]!=expected_values or not math.isclose(measurement["value"],nearest(expected_values,gates[gid]["statistic"]),rel_tol=0,abs_tol=1e-12): raise ValidationError("absolute packaging measurement is not candidate artifact bytes")
            m=ms.get("packaging-growth")
            if not m or len(m["sampleValues"])!=len(growths) or any(not math.isclose(x,y,rel_tol=0,abs_tol=1e-12) for x,y in zip(m["sampleValues"],growths)) or not math.isclose(m["value"],max(growths),rel_tol=0,abs_tol=1e-12): raise ValidationError("packaging growth is not exact scoped growth set/maximum")
        elif e.get("packagingBaselines") is not None: raise ValidationError("unexpected packaging baselines for unexecuted/non-packaging evidence")
    identities={(e["campaignID"],e["commitSha"],e["contractManifestSha256"],e["signedBuildID"],e["buildSignatureSha256"]) for e in evidence}
    if len(identities)>1: raise ValidationError("campaign build identity mismatch")
    if evidence and {e["campaignID"] for e in evidence}!={aggregate["campaignID"]}: raise ValidationError("campaign ID mismatch")
    rows=[]; counts={x:0 for x in ("passed","failed","blocked","incomplete")}
    for t in required:
        e=bytuple.get(t); status="incomplete" if not e or e["status"] in ("notRun","notApplicable") else e["status"]
        counts[status]+=1; rows.append({"caseID":t[0],"deviceRoleID":t[1],"providerID":t[2],"evidenceID":e["evidenceID"] if e else None,"status":status})
    definition_files=["device-matrix.json","provider-matrix.json","case-catalog.json","performance-gates.json","aggregate-policy.json","case-evidence-policy.json","approval-policy.json"]
    dh=[{"id":n,"sha256":digest(root/"validation"/n)} for n in definition_files]
    eh=[{"id":str(p.relative_to(cdir)),"sha256":digest(p)} for p in evpaths]; ah=[{"id":str(p.relative_to(cdir)),"sha256":digest(p)} for p in apppaths]
    da=canonical(dh); ea=canonical(eh)
    valid_kinds=set()
    nonwaive=set(docs["case-catalog.json"]["nonWaivableInvariants"][i]["id"] for i in range(len(docs["case-catalog.json"]["nonWaivableInvariants"])))
    covered_invariants={x for c in cases.values() if c["required"] for x in c["invariants"]}
    if covered_invariants!=nonwaive: raise ValidationError(f"non-waivable invariant required-case coverage mismatch: missing={sorted(nonwaive-covered_invariants)} extra={sorted(covered_invariants-nonwaive)}")
    for a in approvals:
        reject_placeholders(a,"approval")
        if a["approvalID"] in approval_ids: raise ValidationError(f"duplicate approval ID: {a['approvalID']}")
        approval_ids.add(a["approvalID"])
        if a["kind"]=="waiver" and (not a.get("requirementID") or not a.get("owner") or a["requirementID"] in nonwaive or a["requirementID"].startswith("INV-")): raise ValidationError("waiver fields invalid or safety invariant is non-waivable")
        approved=parse_utc(a["approvedAt"],f"{a['approvalID']}.approvedAt"); expiry=parse_utc(a["expiresAt"],f"{a['approvalID']}.expiresAt")
        if approved>generated or expiry<=generated or (max_completed is not None and approved<max_completed): raise ValidationError("approval chronology is future, expired, or predates completed evidence")
        subject_ok=(a["kind"]=="definition" and a["subjectID"]=="definition-set" and a["subjectSha256"]==da) or (a["kind"] in ("campaign","releaseGate") and a["subjectID"]==aggregate["campaignID"] and a["subjectSha256"]==ea)
        if a["status"]=="approved" and expiry>generated and a["definitionAggregateSha256"]==da and a["evidenceAggregateSha256"]==ea and subject_ok: valid_kinds.add(a["kind"])
    approvals_ok=set(docs["approval-policy.json"]["requiredKinds"])<=valid_kinds
    computed="failed" if failed_inv or counts["failed"] else "blocked" if counts["blocked"] else "incomplete" if counts["incomplete"] or not approvals_ok else "passed"
    expected={"status":computed,"definitionAggregateSha256":da,"evidenceAggregateSha256":ea,"definitionHashes":dh,"evidenceHashes":eh,"approvalHashes":ah,"requiredTuples":rows,"requiredTupleCounts":{"total":len(required),**counts},"failedInvariantIDs":sorted(failed_inv)}
    for k,v in expected.items():
        if aggregate[k]!=v: raise ValidationError(f"aggregate {k} is not computed value")

def reject_placeholders(v:Any,where:str)->None:
    bad=re.compile(r"(?:^|[^a-z])(tbd|todo|unknown|placeholder|dummy|changeme|example|n/?a|not[-_ ]?set)(?:$|[^a-z])",re.I)
    if isinstance(v,str) and bad.search(v.replace("unknownOutcome","")): raise ValidationError(f"{where}: placeholder value rejected")
    if isinstance(v,dict):
        for x in v.values(): reject_placeholders(x,where)
    if isinstance(v,list):
        for x in v: reject_placeholders(x,where)

def validate(root:Path,campaign:Path|None=None)->None:
    mapping={"device-matrix.json":"device-matrix.schema.json","provider-matrix.json":"provider-matrix.schema.json","case-catalog.json":"case-catalog.schema.json","performance-gates.json":"performance-gates.schema.json","aggregate-policy.json":"aggregate.schema.json","case-evidence-policy.json":"case-evidence-requirements.schema.json","approval-policy.json":"approval-policy.schema.json"}
    names=set(mapping.values())|{"case-evidence.schema.json","approval.schema.json","diagnostic-summary.schema.json"}; schemas={}
    for n in names: schemas[n]=load(root/"schemas"/n); check_schema(schemas[n],root/"schemas"/n)
    docs={}
    for n,sn in mapping.items():
        docs[n]=load(root/"validation"/n)
        if docs[n].get("$schema")!=f"../schemas/{sn}": raise ValidationError(f"{n}: schema reference drift")
        schema_validate(docs[n],schemas[sn],schemas[sn])
    devices=idx(docs["device-matrix.json"]["roles"],"id","role"); providers=idx(docs["provider-matrix.json"]["providers"],"id","provider"); cases=idx(docs["case-catalog.json"]["cases"],"id","case"); gates=idx(docs["performance-gates.json"]["gates"],"id","gate")
    # Complete canonical tuples make deletion, optionalization, API/fallback/applicability/milestone and gate retargeting fail closed.
    expected_hashes=CANONICAL_HASHES
    actual={"devices":canonical(docs["device-matrix.json"]),"providers":canonical(docs["provider-matrix.json"]),"cases":canonical(docs["case-catalog.json"]),"gates":canonical(docs["performance-gates.json"]),"aggregate":canonical(docs["aggregate-policy.json"]),"evidencePolicy":canonical(docs["case-evidence-policy.json"]),"approvalPolicy":canonical(docs["approval-policy.json"]),"schemas":canonical({n:schemas[n] for n in sorted(schemas)})}
    for k,v in actual.items():
        if expected_hashes.get(k)!=v: raise ValidationError(f"canonical {k} definition drift")
    covered={r for c in cases.values() if c["required"] for r in c["deviceRoles"]}
    missing={r for r,v in devices.items() if v["required"]}-covered
    if missing: raise ValidationError(f"required device roles lack case coverage: {sorted(missing)}")
    nonwaive={x["id"] for x in docs["case-catalog.json"]["nonWaivableInvariants"]}; covered_inv={x for c in cases.values() if c["required"] for x in c["invariants"]}
    if covered_inv!=nonwaive: raise ValidationError(f"non-waivable invariant required-case coverage mismatch: missing={sorted(nonwaive-covered_inv)} extra={sorted(covered_inv-nonwaive)}")
    if campaign: validate_campaign(root,campaign,docs,schemas)
    print(f"Validation definitions passed: {len(devices)} roles, {len(providers)} providers, {len(cases)} cases, {len(gates)} gates" + ("; campaign computed" if campaign else ""))

CANONICAL_HASHES={'devices': 'ecd13c2b779065abe91824bdbc2726c3e1363368fe46558fe694aa571597d8a4', 'providers': 'd0e9a96c63213cbaa13c587e92b6318ae63f88ecd88b7387c0a441c57e0eaed2', 'cases': '040cd3a30f4dc2ee6dc6e28571a3c9afa40bdf97163de23fdf7242fa20896970', 'gates': '4e2a436353c4c34d42d54a8be415dbe818e64621dc7cada8b30c8807b5ba2040', 'aggregate': '871d3746e8d18191510f211caa5877c2a59056223abcac2365f207d9034dd013', 'evidencePolicy': '843a97c88a5303036a0fd1a5c57fd62c323a90e9201bfc5b04ef4040b7fda9b3', 'approvalPolicy': '72733b3c0b09f38ee7b534a456dbfabec103afa169413f37eac70979f037fab3', 'schemas': '1abb5372f6e42c16b6ada17c95e04b8959df497810e48d4ce887d894a318f877'}

def main()->int:
    ap=argparse.ArgumentParser(); ap.add_argument("--contracts-root",type=Path,default=Path(__file__).resolve().parents[1]); ap.add_argument("--campaign-dir",type=Path)
    a=ap.parse_args()
    campaign=(Path.cwd()/a.campaign_dir).absolute() if a.campaign_dir and not a.campaign_dir.is_absolute() else (a.campaign_dir.absolute() if a.campaign_dir else None)
    try: validate(a.contracts_root.resolve(),campaign)
    except ValidationError as e: print(f"Validation definitions failed: {e}",file=sys.stderr); return 1
    return 0
if __name__=="__main__": raise SystemExit(main())
