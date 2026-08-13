from __future__ import annotations
import importlib.util, json, shutil, subprocess, sys, tempfile, unittest
from datetime import datetime, timezone
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; CONTRACTS=ROOT/'packages/contracts'; VALIDATOR=CONTRACTS/'scripts/validate_validation_definitions.py'
spec=importlib.util.spec_from_file_location('validator',VALIDATOR); validator=importlib.util.module_from_spec(spec); spec.loader.exec_module(validator)

class Tests(unittest.TestCase):
 def execute(self,root,campaign=None):
  cmd=[sys.executable,str(VALIDATOR),'--contracts-root',str(root)]
  if campaign: cmd += ['--campaign-dir',str(campaign)]
  return subprocess.run(cmd,text=True,capture_output=True)
 def copy(self):
  t=tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup); r=Path(t.name)/'contracts'; shutil.copytree(CONTRACTS,r,ignore=shutil.ignore_patterns('__pycache__')); return r
 def mutate(self,rel,fn,expected='canonical'):
  r=self.copy(); p=r/rel; d=json.loads(p.read_text()); fn(d); p.write_text(json.dumps(d,indent=2)+'\n'); q=self.execute(r); self.assertNotEqual(q.returncode,0,q.stdout); self.assertIn(expected,q.stderr)
 def test_definitions(self): self.assertEqual(self.execute(CONTRACTS).returncode,0)
 def test_synthetic_schema_fixtures(self):
  schemas={p.name:json.loads(p.read_text()) for p in (CONTRACTS/'schemas').glob('*.json')}
  pairs=[('definitions/valid-device-matrix.json','device-matrix.schema.json',True),('evidence/valid-synthetic.json','case-evidence.schema.json',True),('evidence/invalid-empty-passed.json','case-evidence.schema.json',False),('aggregate/valid-synthetic.json','aggregate.schema.json',True),('aggregate/invalid-empty-passed.json','aggregate.schema.json',False),('approvals/valid-synthetic.json','approval.schema.json',True)]
  for f,s,ok in pairs:
   try: validator.schema_validate(json.loads((CONTRACTS/'fixtures/validation'/f).read_text()),schemas[s],schemas[s])
   except validator.ValidationError:
    if ok: raise
   else: self.assertTrue(ok,f)
 def test_invalid_synthetic_definition_fixture_is_semantically_rejected(self):
  r=self.copy(); shutil.copyfile(CONTRACTS/'fixtures/validation/definitions/invalid-optionalized-role.json',r/'validation/device-matrix.json'); q=self.execute(r); self.assertNotEqual(q.returncode,0); self.assertIn('canonical devices',q.stderr)
 def test_deletion(self): self.mutate('validation/case-catalog.json',lambda d:d['cases'].pop())
 def test_optionalization(self): self.mutate('validation/device-matrix.json',lambda d:d['roles'][0].update(required=False))
 def test_retargeting(self): self.mutate('validation/case-catalog.json',lambda d:d['cases'][0].update(deviceRoles=['large-screen']))
 def test_provider_applicability(self): self.mutate('validation/case-catalog.json',lambda d:d['cases'][3].update(providerApplicability='none'))
 def test_milestone(self): self.mutate('validation/case-catalog.json',lambda d:d['cases'][-1].update(milestone='M3'))
 def test_gate_and_invariant(self): self.mutate('validation/case-catalog.json',lambda d:d['cases'][0].update(invariants=[]))
 def test_api_and_required(self): self.mutate('validation/device-matrix.json',lambda d:d['roles'][0]['procurementTarget']['apiRange'].update(minimum=29))
 def test_fallback(self): self.mutate('validation/device-matrix.json',lambda d:d['roles'][0].update(fallback='Any emulator'))
 def test_gate_metadata(self):
  for k,v in [('operator','greaterThanOrEqual'),('metric','ratio'),('statistic','minimum'),('scope','wrong')]:
   self.mutate('validation/performance-gates.json',lambda d,k=k,v=v:d['gates'][0].update({k:v}))
 def test_schema_weakening(self): self.mutate('schemas/case-evidence.schema.json',lambda d:d.update(additionalProperties=True),'canonical schemas')
 def test_unknown_schema_keyword(self): self.mutate('schemas/case-evidence.schema.json',lambda d:d.update(nullable=True),'unsupported schema keywords')
 def test_placeholder(self):
  with self.assertRaises(validator.ValidationError): validator.reject_placeholders({'operator':'TODO later'},'fixture')
 def test_nearest_rank(self): self.assertEqual(validator.nearest(list(range(1,21)),'p95'),19)
 def test_wear_floor_math(self): self.assertEqual(max(1073741824,__import__('math').ceil(10_000_000_000*.2)),2_000_000_000)
 def test_packaging_baseline(self): self.mutate('validation/performance-gates.json',lambda d:d['packagingBaselinePolicy'].update(baselineRevision='0'*40))
 def test_expired_approval_fixture(self):
  a=json.loads((CONTRACTS/'fixtures/validation/approvals/invalid-expired-synthetic.json').read_text()); generated=datetime.fromisoformat('2029-01-01T00:00:00+00:00'); expiry=datetime.fromisoformat(a['expiresAt'].replace('Z','+00:00')); self.assertLess(expiry,generated)
 def test_aggregate_empty_rejected(self):
  s=json.loads((CONTRACTS/'schemas/aggregate.schema.json').read_text()); x=json.loads((CONTRACTS/'fixtures/validation/aggregate/invalid-empty-passed.json').read_text())
  with self.assertRaises(validator.ValidationError): validator.schema_validate(x,s,s)

if __name__=='__main__': unittest.main()
