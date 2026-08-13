#!/usr/bin/env python3
"""Validate frozen M1 definitions and optional synthetic/physical campaign records."""
from __future__ import annotations
import argparse, hashlib, json, math, re, sys
from datetime import datetime
from pathlib import Path
from typing import Any

class ValidationError(Exception): pass

def load(path: Path)->Any:
    try: return json.loads(path.read_text())
    except Exception as e: raise ValidationError(f"{path}: invalid JSON: {e}") from e

def digest(path: Path)->str: return hashlib.sha256(path.read_bytes()).hexdigest()
def canonical(value: Any)->str: return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(",",":"),ensure_ascii=False).encode()).hexdigest()
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
        if s.get("format")=="date-time":
            try: datetime.fromisoformat(x.replace("Z","+00:00"))
            except ValueError as e: raise ValidationError(f"{p}: invalid date-time") from e
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

def validate_campaign(root:Path,cdir:Path,docs,schemas)->None:
    evpaths=sorted((cdir/"evidence").glob("*.json")); apppaths=sorted((cdir/"approvals").glob("*.json")); aggregate=load(cdir/"aggregate.json")
    evidence=[load(p) for p in evpaths]; approvals=[load(p) for p in apppaths]
    for x in evidence: schema_validate(x,schemas["case-evidence.schema.json"],schemas["case-evidence.schema.json"])
    for x in approvals: schema_validate(x,schemas["approval.schema.json"],schemas["approval.schema.json"])
    schema_validate(aggregate,schemas["aggregate.schema.json"],schemas["aggregate.schema.json"])
    devices=idx(docs["device-matrix.json"]["roles"],"id","role"); providers=idx(docs["provider-matrix.json"]["providers"],"id","provider"); cases=idx(docs["case-catalog.json"]["cases"],"id","case"); gates=idx(docs["performance-gates.json"]["gates"],"id","gate")
    required=tuples(cases,devices,providers); bytuple={}
    failed_inv=set()
    for e in evidence:
        reject_placeholders(e,"evidence")
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
        if e["status"]=="notApplicable": raise ValidationError("required expanded tuple cannot be notApplicable")
        inv={x["invariantID"]:x["passed"] for x in e["invariantResults"]}
        if set(inv)!=set(c["invariants"]): raise ValidationError(f"invariant coverage mismatch: {t}")
        failed_inv|={k for k,v in inv.items() if not v}
        if e["status"]=="passed" and not all(inv.values()): raise ValidationError(f"passed evidence fails invariant: {t}")
        ms={x["gateID"]:x for x in e["measurements"]}
        if set(ms)!=set(c.get("performanceGateIDs",[])): raise ValidationError(f"measurement coverage mismatch: {t}")
        for gid,m in ms.items():
            g=gates[gid]; scope=g.get("scope",gid)
            if (m["metric"],m["statistic"],m["operator"],m["unit"],m["scope"])!=(g["metric"],g["statistic"],g["operator"],g["unit"],scope): raise ValidationError(f"gate metadata mismatch: {gid}")
            observed=nearest(m["sampleValues"],g["statistic"])
            if m["value"]!=observed: raise ValidationError(f"measurement is not nearest-rank/statistical result: {gid}")
            if e["status"]=="passed" and not good(g["operator"],observed,g["value"]): raise ValidationError(f"passed evidence fails gate: {gid}")
        if t[1] and role["platform"]=="wearOS" and c["id"]!="WEAR-004":
            floor=max(role["freeStorageFloor"]["minimumBytes"],math.ceil(e["device"]["totalStorageBytes"]*role["freeStorageFloor"]["minimumCapacityFraction"]))
            if e["device"]["freeStorageBytes"]<floor: raise ValidationError(f"Wear storage floor not met: {t}")
        for h in e["fixtureHashes"]+e["artifacts"]:
            fp=cdir/h["id"]
            if not fp.is_file() or digest(fp)!=h["sha256"]: raise ValidationError(f"artifact hash mismatch: {h['id']}")
        if "packaging-growth" in c.get("performanceGateIDs",[]):
            b=e.get("packagingBaseline")
            if not b or b["baselineRevision"]!=docs["performance-gates.json"]["packagingBaselinePolicy"]["baselineRevision"]: raise ValidationError("packaging baseline identity missing or wrong")
    identities={(e["campaignID"],e["commitSha"],e["contractManifestSha256"],e["signedBuildID"],e["buildSignatureSha256"]) for e in evidence}
    if len(identities)>1: raise ValidationError("campaign build identity mismatch")
    if evidence and {e["campaignID"] for e in evidence}!={aggregate["campaignID"]}: raise ValidationError("campaign ID mismatch")
    rows=[]; counts={x:0 for x in ("passed","failed","blocked","incomplete")}
    for t in required:
        e=bytuple.get(t); status="incomplete" if not e or e["status"] in ("notRun","notApplicable") else e["status"]
        counts[status]+=1; rows.append({"caseID":t[0],"deviceRoleID":t[1],"providerID":t[2],"evidenceID":e["evidenceID"] if e else None,"status":status})
    generated=datetime.fromisoformat(aggregate["generatedAt"].replace("Z","+00:00"))
    definition_files=["device-matrix.json","provider-matrix.json","case-catalog.json","performance-gates.json","aggregate-policy.json","case-evidence-policy.json","approval-policy.json"]
    dh=[{"id":n,"sha256":digest(root/"validation"/n)} for n in definition_files]
    eh=[{"id":str(p.relative_to(cdir)),"sha256":digest(p)} for p in evpaths]; ah=[{"id":str(p.relative_to(cdir)),"sha256":digest(p)} for p in apppaths]
    da=canonical(dh); ea=canonical(eh)
    valid_kinds=set()
    nonwaive=set(docs["case-catalog.json"]["nonWaivableInvariants"][i]["id"] for i in range(len(docs["case-catalog.json"]["nonWaivableInvariants"])))
    for a in approvals:
        reject_placeholders(a,"approval")
        if a["kind"]=="waiver" and a.get("requirementID") in nonwaive: raise ValidationError("safety invariant is non-waivable")
        expiry=datetime.fromisoformat(a["expiresAt"].replace("Z","+00:00"))
        subject_ok=(a["kind"]=="definition" and a["subjectID"]=="definition-set" and a["subjectSha256"]==da) or (a["kind"] in ("campaign","releaseGate") and a["subjectID"]==aggregate["campaignID"] and a["subjectSha256"]==ea)
        if a["status"]=="approved" and expiry>generated and a["definitionAggregateSha256"]==da and a["evidenceAggregateSha256"]==ea and subject_ok: valid_kinds.add(a["kind"])
    approvals_ok=set(docs["approval-policy.json"]["requiredKinds"])<=valid_kinds
    computed="failed" if failed_inv or counts["failed"] else "blocked" if counts["blocked"] else "incomplete" if counts["incomplete"] or not approvals_ok else "passed"
    expected={"status":computed,"definitionAggregateSha256":da,"evidenceAggregateSha256":ea,"definitionHashes":dh,"evidenceHashes":eh,"approvalHashes":ah,"requiredTuples":rows,"requiredTupleCounts":{"total":len(required),**counts},"failedInvariantIDs":sorted(failed_inv)}
    for k,v in expected.items():
        if aggregate[k]!=v: raise ValidationError(f"aggregate {k} is not computed value")

def reject_placeholders(v:Any,where:str)->None:
    bad=re.compile(r"(?:^|[^a-z])(tbd|todo|unknown|placeholder|dummy|changeme|example|n/?a|not[-_ ]?set)(?:$|[^a-z])",re.I)
    if isinstance(v,str) and bad.search(v): raise ValidationError(f"{where}: placeholder value rejected")
    if isinstance(v,dict):
        for x in v.values(): reject_placeholders(x,where)
    if isinstance(v,list):
        for x in v: reject_placeholders(x,where)

def validate(root:Path,campaign:Path|None=None)->None:
    mapping={"device-matrix.json":"device-matrix.schema.json","provider-matrix.json":"provider-matrix.schema.json","case-catalog.json":"case-catalog.schema.json","performance-gates.json":"performance-gates.schema.json","aggregate-policy.json":"aggregate.schema.json","case-evidence-policy.json":"case-evidence-requirements.schema.json","approval-policy.json":"approval-policy.schema.json"}
    names=set(mapping.values())|{"case-evidence.schema.json","approval.schema.json"}; schemas={}
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
    if campaign: validate_campaign(root,campaign,docs,schemas)
    print(f"Validation definitions passed: {len(devices)} roles, {len(providers)} providers, {len(cases)} cases, {len(gates)} gates" + ("; campaign computed" if campaign else ""))

CANONICAL_HASHES={'devices': 'ecd13c2b779065abe91824bdbc2726c3e1363368fe46558fe694aa571597d8a4', 'providers': 'd0e9a96c63213cbaa13c587e92b6318ae63f88ecd88b7387c0a441c57e0eaed2', 'cases': 'e91631c47f034ca64cdedc2e441eb4d5732714701320cbda46e0c6f1b589250f', 'gates': '32884f20dc7760c4931e69ffc3edc33e07b92e5153f46276ddf95d2ab54a5f97', 'aggregate': '871d3746e8d18191510f211caa5877c2a59056223abcac2365f207d9034dd013', 'evidencePolicy': '843a97c88a5303036a0fd1a5c57fd62c323a90e9201bfc5b04ef4040b7fda9b3', 'approvalPolicy': '72733b3c0b09f38ee7b534a456dbfabec103afa169413f37eac70979f037fab3', 'schemas': '1beabba53d32be3e8014a416944c9c6d7d6a7a1e6acee1a0b935876f9b686434'}

def main()->int:
    ap=argparse.ArgumentParser(); ap.add_argument("--contracts-root",type=Path,default=Path(__file__).resolve().parents[1]); ap.add_argument("--campaign-dir",type=Path)
    a=ap.parse_args()
    try: validate(a.contracts_root.resolve(),a.campaign_dir.resolve() if a.campaign_dir else None)
    except ValidationError as e: print(f"Validation definitions failed: {e}",file=sys.stderr); return 1
    return 0
if __name__=="__main__": raise SystemExit(main())
