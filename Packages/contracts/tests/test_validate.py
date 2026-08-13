import hashlib,json,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; VALIDATOR=Path("Packages/contracts/scripts/validate.py")
class ContractValidatorTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)/"repo"
  trees=("Packages/contracts","Packages/VoxboardShared/Tests/Fixtures/Contracts","Packages/vox-core-rust/tests/resources/contracts","apps/android/core-bridge/src/test/resources/contracts","docs/validation")
  for rel in trees:
   src=ROOT/rel; dst=self.root/rel; dst.parent.mkdir(parents=True,exist_ok=True); shutil.copytree(src,dst,ignore=shutil.ignore_patterns("__pycache__"))
  (self.root/"docs/architecture").mkdir(parents=True,exist_ok=True)
  for p in (ROOT/"docs/architecture").glob("adr-*.md"): shutil.copyfile(p,self.root/"docs/architecture"/p.name)
  for name in ("android-wear-m1-decisions.md","android-wear-m0-capabilities.json"): shutil.copyfile(ROOT/"docs/architecture"/name,self.root/"docs/architecture"/name)
 def tearDown(self): self.temp.cleanup()
 def run_validator(self): return subprocess.run([sys.executable,str(VALIDATOR),"--root",str(self.root)],cwd=self.root,text=True,capture_output=True)
 def mutate(self,rel,fn,rehash=False):
  p=self.root/rel; v=json.loads(p.read_text()); fn(v); p.write_text(json.dumps(v,indent=2,sort_keys=True)+"\n")
  if rehash:
   m=self.root/"Packages/contracts/manifest.json"; x=json.loads(m.read_text())
   for r in x["files"]:
    if r["path"]==rel: r.update(bytes=len(p.read_bytes()),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
   m.write_text(json.dumps(x,indent=2,sort_keys=True)+"\n")
 def rejected(self,result,needle): self.assertNotEqual(result.returncode,0,result.stdout+result.stderr); self.assertIn(needle,result.stdout+result.stderr)
 def test_clean_pass(self): self.assertEqual(self.run_validator().returncode,0)
 def test_manifest_hash_mutation(self):
  self.mutate("Packages/contracts/manifest.json",lambda x:x["files"][0].update(sha256="f"*64)); self.rejected(self.run_validator(),"manifest.hash")
 def test_schema_unsupported_keyword_rejected(self):
  self.mutate("Packages/contracts/artifact-plan/v1/schema.json",lambda x:x.update(contains={}),True); self.rejected(self.run_validator(),"schema.unsupportedKeyword")
 def test_typed_negative_expectation_is_enforced(self):
  self.mutate("Packages/contracts/manifest.json",lambda x:x["fixtureCases"][0]["expectedError"].update(code="wrong.code")); self.rejected(self.run_validator(),"fixture.wrongTypedError")
 def test_stale_present_mirror_rejected(self):
  p=self.root/"Packages/VoxboardShared/Tests/Fixtures/Contracts/v1/artifact-plan/v1/contract.md"; p.write_text(p.read_text()+"stale\n"); self.rejected(self.run_validator(),"mirror.bytes")
 def test_resource_only_mirror_may_be_absent(self):
  shutil.rmtree(self.root/"Packages/vox-core-rust/tests/resources/contracts/v1"); self.assertEqual(self.run_validator().returncode,0)
 def test_required_mirror_without_consumer_rejected(self):
  def f(x): x["mirrors"][0]["lifecycle"]="required"
  self.mutate("Packages/contracts/manifest.json",f); self.rejected(self.run_validator(),"mirror.lifecycle")
 def test_resource_only_cannot_claim_evidence(self):
  def f(x): x["mirrors"][0]["consumer"]="fake"
  self.mutate("Packages/contracts/manifest.json",f); self.rejected(self.run_validator(),"mirror.plannedClaimsEvidence")
 def test_owner_classification_remains_preserved(self):
  self.mutate("Packages/contracts/product-capabilities.json",lambda x:x["capabilities"][0].update(classification="deferred"),True); self.rejected(self.run_validator(),"capability.ownerDrift")
 def test_unaccepted_scope_variance_rejected(self):
  cid=json.loads((self.root/"Packages/contracts/product-capabilities.json").read_text())["capabilities"][0]["id"]
  v={"capabilityID":cid,"classification":"deferred","decisionID":"PD-M1-NOT-ACCEPTED","reason":"Synthetic scope reason","userVisibleBehavior":"Feature unavailable","objectiveAmended":False,"parityStatus":"blocking"}
  self.mutate("Packages/contracts/scope-variances.json",lambda x:x["variances"].append(v),True); self.rejected(self.run_validator(),"variance.unapproved")
 def test_trace_sequence_mutation_rejected(self):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-ingest-commit-delete.json"
  self.mutate(rel,lambda x:x["envelopes"][5].update(revision=2),True)
  # Mirror bytes would detect first; update all present mirrors to exercise trace.
  canonical=self.root/rel
  suffix="fixtures/wearable-protocol-trace/valid-ingest-commit-delete.json"
  for path in ("Packages/VoxboardShared/Tests/Fixtures/Contracts/v1","Packages/vox-core-rust/tests/resources/contracts/v1","apps/android/core-bridge/src/test/resources/contracts/v1"): shutil.copyfile(canonical,self.root/path/suffix)
  self.rejected(self.run_validator(),"fixture.validRejected")
if __name__=="__main__": unittest.main()
