#!/usr/bin/env python3
"""Stdlib-only Vox contract manifest, schema, semantic, mirror, and ledger validator."""
from __future__ import annotations
import argparse, hashlib, json, re, shutil, subprocess, sys
from pathlib import Path, PurePosixPath

CLOSURE='29ec869c8bda4d511af787af394658d0274b339b'
HEALTH='c70de9201ab7cfbadf2442183dfba23c0d248478'
FAMILIES=('capture-preparation-input','required-observations','capture-materialization-input','artifact-plan','wearable-protocol')
MIRRORS=('Packages/VoxboardShared/Tests/Fixtures/Contracts/v1','packages/vox-core-rust/tests/resources/contracts/v1','apps/android/core-bridge/src/test/resources/contracts/v1')
CLASSIFICATIONS={'shared','native','adjusted','unavailable','deferred'}
UUID_RE=re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
SHA_RE=re.compile(r'^[0-9a-f]{64}$')
PRIVACY_PATTERNS=(re.compile(r'/Users/'),re.compile(r'/home/[^/]+/'),re.compile(r'file://'),re.compile(r'group\.[A-Za-z0-9.-]+'),re.compile(r'content://'),re.compile(r'bookmark',re.I))

class ValidationError(Exception): pass

def fail(message): raise ValidationError(message)
def load(path):
 try: return json.loads(path.read_text(encoding='utf-8'))
 except Exception as e: fail(f'{path}: invalid JSON: {e}')
def canonical_bytes(value): return (json.dumps(value,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
def digest_bytes(data): return hashlib.sha256(data).hexdigest()
def digest(path): return digest_bytes(path.read_bytes())
def safe_rel(value):
 if not isinstance(value,str) or '\\' in value or value.startswith('/') or not value: return False
 p=PurePosixPath(value)
 return all(x not in ('','.','..') for x in p.parts)
def governed_files(root):
 base=root/'packages/contracts'; out=[base/'product-capabilities.json']
 for f in FAMILIES: out += [base/f/'v1/contract.md',base/f/'v1/schema.json']
 out += sorted((base/'fixtures').glob('*/*.json'))
 return out

def mirror_relative(path,root): return path.relative_to(root/'packages/contracts').as_posix()

def schema_validate(instance,schema,path='$',root_schema=None):
 """Minimal strict draft-2020-12 subset used by repository schemas."""
 root_schema=root_schema or schema
 if '$ref' in schema:
  ref=schema['$ref'];
  if not ref.startswith('#/$defs/'): fail(f'{path}: unsupported $ref {ref}')
  return schema_validate(instance,root_schema['$defs'][ref.split('/')[-1]],path,root_schema)
 if 'const' in schema and instance != schema['const']: fail(f'{path}: expected constant {schema["const"]!r}')
 if 'enum' in schema and instance not in schema['enum']: fail(f'{path}: value is not in enum')
 typ=schema.get('type')
 ok={'object':isinstance(instance,dict),'array':isinstance(instance,list),'string':isinstance(instance,str),'integer':isinstance(instance,int) and not isinstance(instance,bool),'number':isinstance(instance,(int,float)) and not isinstance(instance,bool),'boolean':isinstance(instance,bool),'null':instance is None}.get(typ,True)
 if not ok: fail(f'{path}: expected {typ}')
 if isinstance(instance,dict):
  for key in schema.get('required',[]):
   if key not in instance: fail(f'{path}: missing required property {key}')
  props=schema.get('properties',{})
  if schema.get('additionalProperties') is False:
   extra=set(instance)-set(props)
   if extra: fail(f'{path}: unknown properties {sorted(extra)}')
  elif isinstance(schema.get('additionalProperties'),dict):
   for k,v in instance.items():
    if k not in props: schema_validate(v,schema['additionalProperties'],f'{path}.{k}',root_schema)
  if len(instance)>schema.get('maxProperties',sys.maxsize): fail(f'{path}: too many properties')
  for k,v in instance.items():
   if k in props: schema_validate(v,props[k],f'{path}.{k}',root_schema)
 if isinstance(instance,list):
  if len(instance)<schema.get('minItems',0): fail(f'{path}: too few items')
  if len(instance)>schema.get('maxItems',sys.maxsize): fail(f'{path}: too many items')
  if schema.get('uniqueItems') and len({json.dumps(x,sort_keys=True) for x in instance})!=len(instance): fail(f'{path}: duplicate items')
  if 'items' in schema:
   for i,v in enumerate(instance): schema_validate(v,schema['items'],f'{path}[{i}]',root_schema)
 if isinstance(instance,str):
  if len(instance)<schema.get('minLength',0) or len(instance)>schema.get('maxLength',sys.maxsize): fail(f'{path}: string length out of bounds')
  if 'pattern' in schema and re.search(schema['pattern'],instance) is None: fail(f'{path}: pattern mismatch')
 if isinstance(instance,(int,float)) and not isinstance(instance,bool):
  if instance<schema.get('minimum',float('-inf')) or instance>schema.get('maximum',float('inf')): fail(f'{path}: numeric bound exceeded')

def logical_segments(values,path):
 for x in values:
  if x in ('.','..') or '/' in x or '\\' in x or '\0' in x: fail(f'{path}: unsafe logical path segment')

def semantic(family,obj,context=None):
 if family=='capture-preparation-input':
  logical_segments(obj['routePolicy']['logicalFolder'],'routePolicy.logicalFolder')
  ids=[x['id'] for x in obj['payloads']]
  if len(ids)!=len(set(ids)): fail('payload IDs must be unique')
  for p in obj['payloads']:
   if p['kind']=='text' and 'text' not in p: fail('text payload requires text')
   if p['kind']=='link' and ('url' not in p or not p['url'].startswith(('http://','https://'))): fail('link payload requires HTTP(S) URL')
   if p['kind']=='asset' and not all(k in p for k in ('sourceID','mediaType','length','sha256')): fail('asset payload descriptor incomplete')
 if family=='required-observations':
  ids=[x['id'] for x in obj['observations']]
  if len(ids)!=len(set(ids)): fail('observation IDs must be unique')
 if family=='capture-materialization-input':
  ids=[x['observationID'] for x in obj['observations']]
  if len(ids)!=len(set(ids)): fail('observation result IDs must be unique')
  for x in obj['observations']:
   if x['status']=='present' and not all(k in x for k in ('length','sha256')) and x['kind'] in ('frozenTemplate','existingNote'): fail('byte observation requires length/hash')
  if context and context.get('snapshotHash') != obj['snapshotHash']: fail('materialization snapshot does not match preparation response')
 if family=='artifact-plan':
  if obj['retryMarker']['policy']=='voxCaptureCommentV1' and obj['retryMarker']['syntax']!='<!-- vox-capture:{lowercase-uuid} -->': fail('retry marker syntax drift')
  if obj['preparedByteDelivery']!={'mode':'drainedImmutableArtifacts','maximumChunkBytes':1048576,'finalJSONDuplicatesBytes':False}: fail('prepared byte commit-barrier violation')
  seq=[x['commitSequence'] for x in obj['artifacts']]
  if seq!=list(range(len(seq))): fail('artifact commit sequence must be contiguous and ordered')
  seen=set()
  for a in obj['artifacts']:
   if a['artifactID'] in seen: fail('artifact IDs must be unique')
   seen.add(a['artifactID']); logical_segments(a['logicalPath'],'artifacts.logicalPath')
  note=[a for a in obj['artifacts'] if a['kind']=='note']
  if len(note)!=1 or note[0]['commitSequence']!=max(seq): fail('exactly one note must commit last')
  if obj['operation'].startswith('existingNote') and 'expectedOriginalHash' not in note[0]: fail('existing-note mutation requires original hash')
 if family=='wearable-protocol':
  p=obj['payload']; kind=obj['messageKind']
  if kind=='recordingMetadata' and p.get('mode')=='recordingOnly':
   if p.get('localASRPolicy')!='disabled' or p.get('locationPolicy')!='excluded' or not p.get('recordingOnlyPolicyReference'): fail('Recording Only must disable ASR, exclude location, and freeze native policy')
  if kind=='phoneIngested' and not all(k in p for k in ('assetLength','assetSHA256','phonePackageHash')): fail('phoneIngested requires verified durable package evidence')
  if kind=='vaultCommitted' and not p.get('verifiedArtifactHash'): fail('vaultCommitted requires verified destination artifact')
  if kind=='sourceDeletionAuthorized':
   if p.get('authorizationThreshold')!='vaultCommitted' or not p.get('vaultCommitCorrelationID') or obj['replayRule']!='terminal': fail('source deletion requires correlated durable vaultCommitted threshold')
  if kind=='transferFrontier':
   if p.get('chunkLength',0)>1048576 or p.get('durableOffset',0)>p.get('assetLength',-1): fail('transfer frontier violates bounds')
  if context:
   stages={'phoneIngested':2,'vaultCommitted':3,'sourceDeletionAuthorized':4}
   if kind in stages and obj['revision'] != stages[kind]: fail('wearable acknowledgement revision/stage violation')

def validate_capabilities(root,inventory):
 m0=load(root/'docs/architecture/android-wear-m0-capabilities.json')
 if inventory.get('producerRevision')!=CLOSURE or inventory.get('healthMdPrecedent')!=HEALTH: fail('capability provenance pin mismatch')
 src=inventory.get('source',{})
 if src.get('path')!='docs/architecture/android-wear-m0-capabilities.json' or src.get('sha256')!=digest(root/src['path']): fail('M0 source hash drift')
 if inventory.get('dependencyCatalog')!=m0['dependencyCatalog']: fail('dependency catalog retention drift')
 a={x['id']:x for x in m0['capabilities']}; b={x['id']:x for x in inventory['capabilities']}
 if len(a)!=len(m0['capabilities']) or len(b)!=len(inventory['capabilities']) or set(a)!=set(b): fail('one-to-one M0 capability retention failed')
 mapping_ids=set()
 for cid,old in a.items():
  new=b[cid]
  if new.get('classification') not in CLASSIFICATIONS: fail(f'{cid}: invalid classification')
  expected={'shared':'shared','native':'native','adjusted':'adjusted'}[old['owner']]
  if new['classification']!=expected: fail(f'{cid}: classification does not retain M0 owner')
  for k in ('outcome','evidence','platforms','programScope','milestone','dependencies','status'):
   if new.get(k)!=old.get(k): fail(f'{cid}: {k} retention drift')
  if new.get('legacyParity')!=old.get('parity'): fail(f'{cid}: parity retention drift')
  acc=new.get('acceptance',[])
  if len(acc)!=len(old['acceptance']): fail(f'{cid}: acceptance retention drift')
  for i,(na,oa) in enumerate(zip(acc,old['acceptance']),1):
   expected_id=f'{cid}.acceptance.{i}'
   if na.get('mappingID')!=expected_id or expected_id in mapping_ids: fail(f'{cid}: acceptance mapping ID drift')
   mapping_ids.add(expected_id)
   stripped={k:v for k,v in na.items() if k!='mappingID'}
   if stripped!=oa: fail(f'{cid}: acceptance retention drift')
  if new['classification'] in ('unavailable','deferred') and new['programScope']=='parity': fail(f'{cid}: unavailable/deferred cannot satisfy parity scope')

def generate_manifest(root):
 base=root/'packages/contracts'
 files=governed_files(root)
 for p in files:
  if not p.is_file(): fail(f'missing governed source: {p.relative_to(root)}')
 # Mirrors are generated from governed family docs/schemas/fixtures, not inventory.
 resources=[p for p in files if p.name!='product-capabilities.json']
 for mirror in MIRRORS:
  target=root/mirror
  if target.exists(): shutil.rmtree(target)
  for source in resources:
   rel=mirror_relative(source,root); dest=target/rel; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(source,dest)
 entries=[]
 fixture_cases=[]
 for p in files:
  rel=p.relative_to(root).as_posix(); data=p.read_bytes()
  entries.append({'path':rel,'bytes':len(data),'sha256':digest_bytes(data),'kind':'fixture' if '/fixtures/' in rel else ('capabilityInventory' if p.name=='product-capabilities.json' else 'contractSource')})
  if '/fixtures/' in rel:
   family=p.parent.name; valid=p.name.startswith(('valid-','boundary-'))
   case={'path':rel,'family':family,'expect':'valid' if valid else 'invalid','synthetic':True,'provenance':'Vox.md deterministic M1 synthetic contract fixture'}
   if family=='capture-materialization-input': case['context']='packages/contracts/fixtures/required-observations/valid-template-request.json'
   if family=='wearable-protocol': case['enforceAcknowledgementStage']=True
   fixture_cases.append(case)
 mirrors=[]
 for mirror in MIRRORS:
  mirrors.append({'path':mirror,'status':'required','sources':[mirror_relative(p,root) for p in resources]})
 manifest={'schemaVersion':1,'producerRevision':CLOSURE,'healthMdPrecedent':HEALTH,'producer':{'conversionScript':'packages/contracts/scripts/convert_capabilities.py','conversionScriptSHA256':digest(root/'packages/contracts/scripts/convert_capabilities.py'),'validatorScript':'packages/contracts/scripts/validate.py','validatorScriptSHA256':digest(root/'packages/contracts/scripts/validate.py')},'files':entries,'fixtureCases':fixture_cases,'mirrors':mirrors}
 (base/'manifest.json').write_bytes(canonical_bytes(manifest))
 return manifest

def validate(root):
 base=root/'packages/contracts'; manifest=load(base/'manifest.json')
 if manifest.get('schemaVersion')!=1 or manifest.get('producerRevision')!=CLOSURE or manifest.get('healthMdPrecedent')!=HEALTH: fail('manifest version/provenance pin mismatch')
 producer=manifest.get('producer',{})
 for key,hashkey in (('conversionScript','conversionScriptSHA256'),('validatorScript','validatorScriptSHA256')):
  rel=producer.get(key)
  if not safe_rel(rel) or not (root/rel).is_file() or producer.get(hashkey)!=digest(root/rel): fail(f'manifest producer drift: {key}')
 expected={p.relative_to(root).as_posix() for p in governed_files(root)}
 records=manifest.get('files',[])
 paths=[x.get('path') for x in records]
 if len(paths)!=len(set(paths)) or set(paths)!=expected: fail('manifest exact governed file-set coverage failed')
 for rec in records:
  rel=rec['path']
  if not safe_rel(rel): fail(f'unsafe manifest path: {rel}')
  p=root/rel
  if not p.is_file(): fail(f'manifest file missing: {rel}')
  data=p.read_bytes()
  if rec.get('bytes')!=len(data) or rec.get('sha256')!=digest_bytes(data): fail(f'manifest hash/count drift: {rel}')
 cases=manifest.get('fixtureCases',[])
 if {x.get('path') for x in cases}!={x for x in expected if '/fixtures/' in x}: fail('fixture case coverage drift')
 schemas={f:load(base/f/'v1/schema.json') for f in FAMILIES}
 for f,s in schemas.items():
  for required in ('$schema','$id','type','required','properties','additionalProperties'):
   if required not in s: fail(f'{f}: schema shape missing {required}')
  if s['additionalProperties'] is not False: fail(f'{f}: root schema must reject unknown fields')
 for case in cases:
  if not case.get('synthetic') or case.get('provenance')!='Vox.md deterministic M1 synthetic contract fixture': fail(f'{case.get("path")}: synthetic provenance missing')
  p=root/case['path']; data=p.read_bytes(); obj=load(p)
  if canonical_bytes(obj)!=data: fail(f'{case["path"]}: fixture JSON is not canonical')
  text=data.decode()
  for pat in PRIVACY_PATTERNS:
   if pat.search(text): fail(f'{case["path"]}: privacy-sensitive fixture content')
  context=load(root/case['context']) if case.get('context') else ({'ack':True} if case.get('enforceAcknowledgementStage') else None)
  error=None
  try:
   schema_validate(obj,schemas[case['family']]); semantic(case['family'],obj,context)
  except ValidationError as e: error=str(e)
  if case['expect']=='valid' and error: fail(f'{case["path"]}: expected valid: {error}')
  if case['expect']=='invalid' and not error: fail(f'{case["path"]}: negative fixture was accepted')
 expected_mirrors=set(MIRRORS); seen=set()
 resources=[p for p in governed_files(root) if p.name!='product-capabilities.json']
 expected_sources=[mirror_relative(p,root) for p in resources]
 for m in manifest.get('mirrors',[]):
  if m.get('status')!='required' or m.get('path') not in expected_mirrors or m.get('path') in seen: fail('mirror inventory drift')
  seen.add(m['path'])
  if m.get('sources')!=expected_sources: fail(f'{m["path"]}: mirror source-set drift')
  target=root/m['path']; actual={p.relative_to(target).as_posix() for p in target.rglob('*') if p.is_file()} if target.exists() else set()
  if actual!=set(expected_sources): fail(f'{m["path"]}: mirror exact file-set drift')
  for rel in expected_sources:
   if (target/rel).read_bytes()!=(base/rel).read_bytes(): fail(f'{m["path"]}/{rel}: stale mirror')
 if seen!=expected_mirrors: fail('required mirror missing')
 inventory=load(base/'product-capabilities.json'); validate_capabilities(root,inventory)
 print(f'Contracts validation passed: {len(records)} governed files, {len(cases)} fixtures, {len(inventory["capabilities"])} capabilities, {len(MIRRORS)} mirrors.')

def main(argv=None):
 p=argparse.ArgumentParser(); p.add_argument('--root',type=Path); p.add_argument('--regenerate-manifest',action='store_true'); a=p.parse_args(argv)
 root=(a.root or Path(__file__).resolve().parents[3]).resolve()
 try:
  if a.regenerate_manifest:
   # Conversion is deliberately explicit here; normal validation never rewrites.
   subprocess.run([sys.executable,str(root/'packages/contracts/scripts/convert_capabilities.py')],cwd=root,check=True)
   generate_manifest(root); print('Regenerated contract mirrors and manifest.')
  else: validate(root)
 except (ValidationError, subprocess.CalledProcessError) as e:
  print(f'Contracts validation failed: {e}',file=sys.stderr); return 1
 return 0
if __name__=='__main__': raise SystemExit(main())
