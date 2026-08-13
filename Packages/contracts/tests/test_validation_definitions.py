from __future__ import annotations
import importlib.util, json, hashlib, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; CONTRACTS=ROOT/'Packages/contracts'; VALIDATOR=CONTRACTS/'scripts/validate_validation_definitions.py'
spec=importlib.util.spec_from_file_location('validator',VALIDATOR); validator=importlib.util.module_from_spec(spec); spec.loader.exec_module(validator)

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def dump(p,x): p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(x,indent=2,sort_keys=True)+'\n')

class Tests(unittest.TestCase):
 def execute(self,root,campaign=None):
  cmd=[sys.executable,str(VALIDATOR),'--contracts-root',str(root)]
  if campaign: cmd += ['--campaign-dir',str(campaign)]
  return subprocess.run(cmd,text=True,capture_output=True)
 def copy(self):
  t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);r=Path(t.name)/'contracts';shutil.copytree(CONTRACTS,r,ignore=shutil.ignore_patterns('__pycache__'));return r
 def mutate_definition(self,rel,fn,expected='canonical'):
  r=self.copy();p=r/rel;d=json.loads(p.read_text());fn(d);dump(p,d);q=self.execute(r);self.assertNotEqual(q.returncode,0,q.stdout);self.assertIn(expected,q.stderr)
 def build_campaign(self):
  t=tempfile.TemporaryDirectory();self.addCleanup(t.cleanup);c=Path(t.name)/'campaign';(c/'evidence').mkdir(parents=True);(c/'approvals').mkdir();(c/'artifacts').mkdir()
  docs={n:validator.load(CONTRACTS/'validation'/n) for n in ('device-matrix.json','provider-matrix.json','case-catalog.json','performance-gates.json','aggregate-policy.json','case-evidence-policy.json','approval-policy.json')}
  devices=validator.idx(docs['device-matrix.json']['roles'],'id','role');providers=validator.idx(docs['provider-matrix.json']['providers'],'id','provider');cases=validator.idx(docs['case-catalog.json']['cases'],'id','case');gates=validator.idx(docs['performance-gates.json']['gates'],'id','gate');tuples=validator.tuples(cases,devices,providers)
  diagnostic=lambda kind:{'schemaVersion':1,'format':'vox-validation-diagnostic-summary','kind':kind,'resultCode':'passed','checks':[{'code':'privacyFormat','result':'passed','count':1}],'referencedHashes':[]}
  dump(c/'artifacts/common.diagnostic.json',diagnostic('fixture'));dump(c/'artifacts/clean.diagnostic.json',diagnostic('artifact'))
  package_scopes=[(x['targetScope'],x['gateID']) for x in docs['performance-gates.json']['packagingBaselinePolicy']['requiredLeafScopes']]
  for i,(scope,gid) in enumerate(package_scopes):
   (c/f'artifacts/package-{i}.baseline').write_bytes(b'b'*(100+i));(c/f'artifacts/package-{i}.candidate').write_bytes(b'c'*(105+i))
  manifest=digest(CONTRACTS/'manifest.json');commit='a'*40
  for i,tup in enumerate(tuples):
   case=cases[tup[0]];role=devices[tup[1]] if tup[1] else None;provider_def=providers[tup[2]] if tup[2] else None
   device=None if not role else {'roleID':tup[1],'manufacturer':role['procurementTarget']['manufacturer'],'model':role['procurementTarget']['model'],'serialHash':'1'*64,'osVersion':'release-os','apiLevel':role['procurementTarget']['apiRange']['minimum'],'buildFingerprint':'vendor/product/release','totalStorageBytes':10_000_000_000,'freeStorageBytes':5_000_000_000}
   provider=None if not provider_def else {'providerID':tup[2],'authority':provider_def['authority'],'packageName':provider_def['packageName'],'installedPackageVersion':'1.2.3','signingCertificateSha256':'2'*64}
   measurements=[]
   for gid in case.get('performanceGateIDs',[]):
    g=gates[gid];value=g['value'];measurements.append({'gateID':gid,'metric':g['metric'],'statistic':g['statistic'],'operator':g['operator'],'value':value,'unit':g['unit'],'scope':g.get('scope',gid),'sampleValues':[value]*g['minimumSamples'],'samplingMethod':g['samplingMethod']})
   privacy='INV-PRIVACY-DIAGNOSTICS' in case['invariants']; artifact_id='artifacts/clean.diagnostic.json' if privacy else 'artifacts/clean.diagnostic.json'; fixture_id='artifacts/common.diagnostic.json'
   arts=[{'id':artifact_id,'sha256':digest(c/artifact_id)}]
   e={'$schema':'https://vox.md/contracts/schemas/case-evidence.schema.json','schemaVersion':1,'campaignID':'complete-campaign','evidenceID':f'evidence-{i:03d}','caseID':tup[0],'deviceRoleID':tup[1],'providerID':tup[2],'status':'passed','commitSha':commit,'contractManifestSha256':manifest,'signedBuildID':'signed-release-build','buildSignatureSha256':'3'*64,'operator':'campaign-operator','startedAt':'2029-01-01T00:00:00Z','completedAt':'2029-01-01T00:01:00Z','device':device,'provider':provider,'expected':case['expected'],'actual':{'resultCode':'passed','summaryCode':'expectedOutcomeObserved'},'fixtureHashes':[{'id':fixture_id,'sha256':digest(c/fixture_id)}],'measurements':measurements,'invariantResults':[{'invariantID':x,'passed':True} for x in case['invariants']],'artifacts':arts}
   if tup[0]=='PERF-008':
    baselines=[];arts=[];growth=[]
    for j,(scope,gid) in enumerate(package_scopes):
     bp=c/f'artifacts/package-{j}.baseline';cp=c/f'artifacts/package-{j}.candidate';artifact=f'artifacts/package-{j}';b=bp.stat().st_size;candidate=cp.stat().st_size
     arts += [{'id':artifact+'.baseline','sha256':digest(bp)},{'id':artifact+'.candidate','sha256':digest(cp)}]
     baselines.append({'policyID':'m2-first-core-packaging-baseline-v1','gateID':gid,'baselineRevision':'b'*40,'candidateRevision':commit,'toolchainID':'pinned-release-toolchain','targetScope':scope,'buildConfiguration':'release-stripped','featureSet':'default-features','artifactID':artifact,'baselineBytes':b,'candidateBytes':candidate,'baselineArtifactSha256':digest(bp),'candidateArtifactSha256':digest(cp)})
     growth.append((candidate-b)/b*100)
    for gid in case['performanceGateIDs']:
     if gid=='packaging-growth': continue
     m=next(x for x in measurements if x['gateID']==gid)
     values=[b['candidateBytes'] for b in baselines if b['gateID']==gid or (gid=='apple-xcframework-aggregate' and b['gateID']=='apple-xcframework-per-slice')]
     m['sampleValues']=[sum(values)] if gid=='apple-xcframework-aggregate' else values;m['value']=validator.nearest(m['sampleValues'],m['statistic'])
    m=next(x for x in measurements if x['gateID']=='packaging-growth');m['sampleValues']=growth;m['value']=max(growth);e['artifacts']=arts;e['packagingBaselines']=baselines
   dump(c/'evidence'/f'{i:03d}.json',e)
  self.refresh_campaign(c,docs,tuples)
  return c
 def refresh_campaign(self,c,docs=None,tuples=None):
  if docs is None:
   docs={n:validator.load(CONTRACTS/'validation'/n) for n in ('device-matrix.json','provider-matrix.json','case-catalog.json','performance-gates.json','aggregate-policy.json','case-evidence-policy.json','approval-policy.json')};tuples=validator.tuples(validator.idx(docs['case-catalog.json']['cases'],'id','c'),validator.idx(docs['device-matrix.json']['roles'],'id','d'),validator.idx(docs['provider-matrix.json']['providers'],'id','p'))
  evpaths=sorted((c/'evidence').glob('*.json'));evidence=[json.loads(p.read_text()) for p in evpaths];dh=[{'id':n,'sha256':digest(CONTRACTS/'validation'/n)} for n in ('device-matrix.json','provider-matrix.json','case-catalog.json','performance-gates.json','aggregate-policy.json','case-evidence-policy.json','approval-policy.json')];eh=[{'id':str(p.relative_to(c)),'sha256':digest(p)} for p in evpaths];da=validator.canonical(dh);ea=validator.canonical(eh);by={(e['caseID'],e['deviceRoleID'],e['providerID']):e for e in evidence}
  for kind in ('definition','campaign','releaseGate'):
   a={'$schema':'https://vox.md/contracts/schemas/approval.schema.json','schemaVersion':1,'approvalID':kind+'-approval','kind':kind,'status':'approved','subjectID':'definition-set' if kind=='definition' else 'complete-campaign','subjectSha256':da if kind=='definition' else ea,'definitionAggregateSha256':da,'evidenceAggregateSha256':ea,'approvedBy':'campaign-reviewer','approvedAt':'2029-01-01T01:00:00Z','expiresAt':'2030-01-01T00:00:00Z','rationale':'Reviewed exact complete campaign hashes'};dump(c/'approvals'/(kind+'.json'),a)
  ah=[{'id':str(p.relative_to(c)),'sha256':digest(p)} for p in sorted((c/'approvals').glob('*.json'))];rows=[];counts={x:0 for x in ('passed','failed','blocked','incomplete')};failed=set()
  for t in tuples:
   e=by[t];status='incomplete' if e['status'] in ('notRun','notApplicable') else e['status'];counts[status]+=1;rows.append({'caseID':t[0],'deviceRoleID':t[1],'providerID':t[2],'evidenceID':e['evidenceID'],'status':status});failed|={x['invariantID'] for x in e['invariantResults'] if not x['passed']}
  status='failed' if failed or counts['failed'] else 'blocked' if counts['blocked'] else 'incomplete' if counts['incomplete'] else 'passed';dump(c/'aggregate.json',{'$schema':'https://vox.md/contracts/schemas/aggregate.schema.json','schemaVersion':1,'campaignID':'complete-campaign','status':status,'definitionAggregateSha256':da,'evidenceAggregateSha256':ea,'definitionHashes':dh,'evidenceHashes':eh,'approvalHashes':ah,'requiredTuples':rows,'requiredTupleCounts':{'total':len(rows),**counts},'failedInvariantIDs':sorted(failed),'generatedAt':'2029-01-02T00:00:00Z'})
 def mutate_campaign(self,fn,needle):
  c=self.build_campaign();fn(c);self.refresh_campaign(c);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0,q.stdout);self.assertIn(needle,q.stderr)
 def test_definitions(self): self.assertEqual(self.execute(CONTRACTS).returncode,0)
 def test_status_actual_and_diagnostic_coherence_rejected(self):
  def bad_actual(c):
   ep=self.privacy_evidence(c);e=json.loads(ep.read_text());e['actual']={'resultCode':'failed','summaryCode':'executionNotRun'};dump(ep,e)
  self.mutate_campaign(bad_actual,'evidence status/actual outcome mismatch')
  def bad_kind(c):
   ep=self.privacy_evidence(c);e=json.loads(ep.read_text());p=c/e['fixtureHashes'][0]['id'];d=json.loads(p.read_text());d['kind']='artifact';dump(p,d)
   for q in (c/'evidence').glob('*.json'):
    z=json.loads(q.read_text())
    for h in z['fixtureHashes']:
     if h['id']==e['fixtureHashes'][0]['id']:h['sha256']=digest(p)
    dump(q,z)
  self.mutate_campaign(bad_kind,'diagnostic kind does not match fixtureHashes')
  def bad_check(c):
   ep=self.privacy_evidence(c);e=json.loads(ep.read_text());p=c/e['artifacts'][0]['id'];d=json.loads(p.read_text());d['resultCode']='failed';d['checks'][0]['result']='failed';dump(p,d)
   for q in (c/'evidence').glob('*.json'):
    z=json.loads(q.read_text())
    for h in z['artifacts']:
     if h['id']==e['artifacts'][0]['id']:h['sha256']=digest(p)
    dump(q,z)
  self.mutate_campaign(bad_check,'diagnostic result does not match evidence status')
 def test_campaign_symlink_and_extra_files_rejected(self):
  c=self.build_campaign();outside=c.parent/'outside.json';outside.write_text(next((c/'evidence').glob('*.json')).read_text());p=next((c/'evidence').glob('*.json'));p.unlink();p.symlink_to(outside);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('symlink or unexpected file type',q.stderr)
  c=self.build_campaign();link=c.parent/'campaign-link';link.symlink_to(c,target_is_directory=True);q=self.execute(CONTRACTS,link);self.assertNotEqual(q.returncode,0);self.assertIn('campaign must be a non-symlink directory',q.stderr)
  c=self.build_campaign();outside=c.parent/'unreferenced';outside.write_text('outside');(c/'artifacts/unreferenced-link').symlink_to(outside);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('artifacts contains symlink',q.stderr)
  c=self.build_campaign();(c/'evidence/README.txt').write_text('extra');q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('unexpected non-JSON file',q.stderr)
  c=self.build_campaign();(c/'extra.json').write_text('{}');q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('unexpected entries',q.stderr)
 def test_naive_timestamp_rejected(self):
  c=self.build_campaign();p=next((c/'evidence').glob('*.json'));e=json.loads(p.read_text());e['startedAt']='2029-01-01T00:00:00';dump(p,e);self.refresh_campaign(c);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('pattern mismatch',q.stderr)
 def test_fractional_utc_timestamps_are_portable(self):
  for fraction in ('1','123456789'):
   with self.subTest(fraction=fraction):
    c=self.build_campaign();p=next((c/'evidence').glob('*.json'));e=json.loads(p.read_text());e['startedAt']=f'2029-01-01T00:00:00.{fraction}Z';dump(p,e);self.refresh_campaign(c);q=self.execute(CONTRACTS,c);self.assertEqual(q.returncode,0,q.stdout+q.stderr)
 def test_nanosecond_chronology_is_exact(self):
  c=self.build_campaign();p=next((c/'evidence').glob('*.json'));e=json.loads(p.read_text());e['startedAt']='2029-01-01T00:00:00.123456999Z';e['completedAt']='2029-01-01T00:00:00.123456001Z';dump(p,e);self.refresh_campaign(c);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('evidence chronology invalid',q.stderr)
 def test_complete_61_tuple_campaign_passes(self):
  c=self.build_campaign();q=self.execute(CONTRACTS,c);self.assertEqual(q.returncode,0,q.stdout+q.stderr);self.assertEqual(len(list((c/'evidence').glob('*.json'))),61)
 def privacy_evidence(self,c): return next(p for p in (c/'evidence').glob('*.json') if 'INV-PRIVACY-DIAGNOSTICS' in {x['invariantID'] for x in json.loads(p.read_text())['invariantResults']})
 def test_privacy_arbitrary_text_rejected(self):
  def f(c):
   ep=self.privacy_evidence(c);e=json.loads(ep.read_text());artifact_id=e['artifacts'][0]['id'];p=c/artifact_id;p.write_text('quarterly-report.txt ftp://secret.invalid/item unlabeled captured words\n')
   for item in (c/'evidence').glob('*.json'):
    value=json.loads(item.read_text())
    for ref in value['artifacts']:
     if ref['id']==artifact_id: ref['sha256']=digest(p)
    dump(item,value)
  self.mutate_campaign(f,'privacy diagnostic must be strict JSON')
 def mutate_shared_fixture(self,c,write):
  ep=self.privacy_evidence(c);e=json.loads(ep.read_text());fixture_id=e['fixtureHashes'][0]['id'];p=c/fixture_id;write(p)
  for item in (c/'evidence').glob('*.json'):
   value=json.loads(item.read_text())
   for ref in value['fixtureHashes']:
    if ref['id']==fixture_id: ref['sha256']=digest(p)
   dump(item,value)
 def test_privacy_noncanonical_json_rejected(self):
  self.mutate_campaign(lambda c:self.mutate_shared_fixture(c,lambda p:p.write_text(json.dumps(json.loads(p.read_text())))),'privacy diagnostic must be canonical JSON')
 def test_privacy_unknown_field_rejected(self):
  def f(c):
   def write(p):
    x=json.loads(p.read_text());x['capturedText']='secret';dump(p,x)
   self.mutate_shared_fixture(c,write)
  self.mutate_campaign(f,'unexpected properties')
 def test_privacy_actual_is_structured(self):
  def f(c):
   ep=self.privacy_evidence(c);e=json.loads(ep.read_text());e['actual']='ftp://secret.invalid/item quarterly-report.txt';dump(ep,e)
  self.mutate_campaign(f,'expected object')
 def test_blocked_privacy_case_still_requires_diagnostics(self):
  def f(c):
   ep=self.privacy_evidence(c);e=json.loads(ep.read_text());e['status']='blocked';e['actual']={'resultCode':'blocked','summaryCode':'executionBlocked'};e['invariantResults']=[];e['measurements']=[]
   artifact_id=e['artifacts'][0]['id'];p=c/artifact_id;p.write_text('raw secret content://provider/item\n')
   for item in (c/'evidence').glob('*.json'):
    value=json.loads(item.read_text())
    for ref in value['artifacts']:
     if ref['id']==artifact_id: ref['sha256']=digest(p)
    dump(item,value)
  self.mutate_campaign(f,'privacy diagnostic must be strict JSON')
 def test_packaging_blocked_and_not_run_are_representable(self):
  for status,summary in (('blocked','executionBlocked'),('notRun','executionNotRun')):
   with self.subTest(status=status):
    c=self.build_campaign();ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']=='PERF-008');e=json.loads(ep.read_text());e['status']=status;e['actual']={'resultCode':status,'summaryCode':summary};e['measurements']=[];e['invariantResults']=[];e.pop('packagingBaselines');dump(ep,e);self.refresh_campaign(c);q=self.execute(CONTRACTS,c);self.assertEqual(q.returncode,0,q.stdout+q.stderr)
 def test_packaging_actual_size_mutation_rejected(self):
  def f(c):
   p=c/'artifacts/package-0.candidate';p.write_bytes(p.read_bytes()+b'x')
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']=='PERF-008');e=json.loads(ep.read_text());next(a for a in e['artifacts'] if a['id']=='artifacts/package-0.candidate')['sha256']=digest(p);dump(ep,e)
  self.mutate_campaign(f,'packaging bytes/hashes')
 def test_duplicate_invariant_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['invariantResults']);e=json.loads(ep.read_text());e['invariantResults'].append(dict(e['invariantResults'][0],passed=False));dump(ep,e)
  self.mutate_campaign(f,'duplicate invariant ID')
 def test_duplicate_gate_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['measurements']);e=json.loads(ep.read_text());m=dict(e['measurements'][0]);m['sampleValues']=[m['value']+1]*len(m['sampleValues']);m['value']+=1;e['measurements'].append(m);dump(ep,e)
  self.mutate_campaign(f,'duplicate gate ID')
 def test_blocked_failing_gate_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['measurements']);e=json.loads(ep.read_text());e['status']='blocked';m=e['measurements'][0];bad=10**15 if m['operator']=='lessThanOrEqual' else -1;m['sampleValues']=[bad]*len(m['sampleValues']);m['value']=bad;dump(ep,e)
  self.mutate_campaign(f,'evidence status/actual outcome mismatch')
 def test_packaging_missing_scope_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']=='PERF-008');e=json.loads(ep.read_text());e['packagingBaselines'].pop();dump(ep,e)
  self.mutate_campaign(f,'exact leaf scope coverage')
 def test_packaging_fabricated_scope_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']=='PERF-008');e=json.loads(ep.read_text());e['packagingBaselines'][0]['targetScope']='fabricated';dump(ep,e)
  self.mutate_campaign(f,'exact leaf scope set/order')
 def test_packaging_mixed_identity_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']=='PERF-008');e=json.loads(ep.read_text());e['packagingBaselines'][0]['toolchainID']='other-toolchain';dump(ep,e)
  self.mutate_campaign(f,'not coherent or unique')
 def test_packaging_reused_artifact_id_rejected(self):
  def f(c):
   ep=next(p for p in (c/'evidence').glob('*.json') if json.loads(p.read_text())['caseID']=='PERF-008');e=json.loads(ep.read_text());e['packagingBaselines'][1]['artifactID']=e['packagingBaselines'][0]['artifactID'];dump(ep,e)
  self.mutate_campaign(f,'not coherent or unique')
 def test_duplicate_evidence_id_rejected(self):
  def f(c):
   paths=sorted((c/'evidence').glob('*.json'));a=json.loads(paths[0].read_text());b=json.loads(paths[1].read_text());b['evidenceID']=a['evidenceID'];dump(paths[1],b)
  self.mutate_campaign(f,'duplicate evidence ID')
 def test_duplicate_approval_id_rejected(self):
  c=self.build_campaign();paths=sorted((c/'approvals').glob('*.json'));a=json.loads(paths[0].read_text());b=json.loads(paths[1].read_text());b['approvalID']=a['approvalID'];dump(paths[1],b);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('duplicate approval ID',q.stderr)
 def test_evidence_start_after_completion_rejected(self):
  def f(c):
   ep=next((c/'evidence').glob('*.json'));e=json.loads(ep.read_text());e['startedAt']='2029-01-03T00:00:00Z';dump(ep,e)
  self.mutate_campaign(f,'evidence chronology invalid')
 def test_evidence_completion_after_aggregate_rejected(self):
  def f(c):
   ep=next((c/'evidence').glob('*.json'));e=json.loads(ep.read_text());e['completedAt']='2029-01-03T00:00:00Z';dump(ep,e)
  self.mutate_campaign(f,'evidence chronology invalid')
 def test_approval_predates_completion_rejected(self):
  c=self.build_campaign();p=c/'approvals/campaign.json';a=json.loads(p.read_text());a['approvedAt']='2028-12-31T00:00:00Z';dump(p,a);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('approval chronology',q.stderr)
 def test_approval_expired_at_aggregate_rejected(self):
  c=self.build_campaign();p=c/'approvals/definition.json';a=json.loads(p.read_text());a['expiresAt']='2029-01-02T00:00:00Z';dump(p,a);q=self.execute(CONTRACTS,c);self.assertNotEqual(q.returncode,0);self.assertIn('approval chronology',q.stderr)
 def test_unsafe_artifact_path_rejected(self):
  def f(c):
   ep=next((c/'evidence').glob('*.json'));e=json.loads(ep.read_text());e['fixtureHashes'][0]['id']='../outside';dump(ep,e)
  self.mutate_campaign(f,'unsafe campaign-relative artifact path')
 def test_definition_mutations(self):
  self.mutate_definition('validation/case-catalog.json',lambda d:d['cases'].pop());self.mutate_definition('validation/device-matrix.json',lambda d:d['roles'][0].update(required=False));self.mutate_definition('schemas/case-evidence.schema.json',lambda d:d.update(additionalProperties=True),'canonical schemas')
 def test_schema_fixtures(self):
  schemas={p.name:json.loads(p.read_text()) for p in (CONTRACTS/'schemas').glob('*.json')}
  for f,s,ok in [('definitions/valid-device-matrix.json','device-matrix.schema.json',True),('evidence/valid-synthetic.json','case-evidence.schema.json',True),('evidence/invalid-empty-passed.json','case-evidence.schema.json',False),('aggregate/valid-synthetic.json','aggregate.schema.json',True),('aggregate/invalid-empty-passed.json','aggregate.schema.json',False),('approvals/valid-synthetic.json','approval.schema.json',True)]:
   try:validator.schema_validate(json.loads((CONTRACTS/'fixtures/validation'/f).read_text()),schemas[s],schemas[s])
   except validator.ValidationError:self.assertFalse(ok,f)
   else:self.assertTrue(ok,f)

if __name__=='__main__': unittest.main()
