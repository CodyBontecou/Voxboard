import hashlib,json,shutil,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]; VALIDATOR=Path("Packages/contracts/scripts/validate.py")
class ContractValidatorTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)/"repo"
  trees=("Packages/contracts","Packages/VoxboardShared/Tests/Fixtures/Contracts","apps/android/core-bridge/src/test/resources/contracts","docs/validation","toolchains","Packages/vox-core-rust")
  for rel in trees:
   src=ROOT/rel; dst=self.root/rel; dst.parent.mkdir(parents=True,exist_ok=True); shutil.copytree(src,dst,ignore=shutil.ignore_patterns("__pycache__"))
  (self.root/"docs/architecture").mkdir(parents=True,exist_ok=True)
  for p in (ROOT/"docs/architecture").glob("adr-*.md"): shutil.copyfile(p,self.root/"docs/architecture"/p.name)
  for name in ("android-wear-m1-decisions.md","android-wear-m0-capabilities.json"): shutil.copyfile(ROOT/"docs/architecture"/name,self.root/"docs/architecture"/name)
  for rel in (".github/workflows/contracts-ci.yml","scripts/test-project-contracts.sh"):
   src=ROOT/rel; dst=self.root/rel; dst.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(src,dst)
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
 def test_declared_m1_resource_mirror_must_be_present(self):
  shutil.rmtree(self.root/"Packages/vox-core-rust/tests/resources/contracts/v1"); self.rejected(self.run_validator(),"mirror.missing")
 def test_required_mirror_without_consumer_rejected(self):
  def f(x): x["mirrors"][0]["lifecycle"]="required"
  self.mutate("Packages/contracts/manifest.json",f); self.rejected(self.run_validator(),"mirror.lifecycle")
 def test_resource_only_cannot_claim_evidence(self):
  def f(x): x["mirrors"][0]["consumer"]="fake"
  self.mutate("Packages/contracts/manifest.json",f); self.rejected(self.run_validator(),"mirror.plannedClaimsEvidence")
 def test_owner_classification_remains_preserved(self):
  self.mutate("Packages/contracts/product-capabilities.json",lambda x:x["capabilities"][0].update(classification="deferred"),True); self.rejected(self.run_validator(),"capability.conversionDrift")
 def test_acceptance_mapping_mutations_rejected(self):
  rel="Packages/contracts/product-capabilities.json"
  mutations=(lambda x:x["capabilities"][0]["acceptance"][0].update(assertion="changed assertion"),lambda x:x["capabilities"][0]["acceptance"][0].update(path="changed/path"),lambda x:x["capabilities"][0]["acceptance"][0].update(kind="changedKind"),lambda x:x["capabilities"][0]["acceptance"][0].update(status="changedStatus"),lambda x:x["capabilities"][0]["acceptance"][0].update(mappingID="changed.mapping"),lambda x:x["capabilities"][0].update(dependencies=["changed-dependency"]))
  for mutate in mutations:
   with self.subTest(mutate=mutate):
    self.tearDown(); self.setUp(); self.mutate(rel,mutate,True); self.rejected(self.run_validator(),"capability.conversionDrift")
 def test_unaccepted_scope_variance_rejected(self):
  cid=json.loads((self.root/"Packages/contracts/product-capabilities.json").read_text())["capabilities"][0]["id"]
  v={"capabilityID":cid,"classification":"deferred","decisionID":"PD-M1-NOT-ACCEPTED","reason":"Synthetic scope reason","userVisibleBehavior":"Feature unavailable","objectiveAmended":False,"parityStatus":"blocking"}
  self.mutate("Packages/contracts/scope-variances.json",lambda x:x["variances"].append(v),True); self.rejected(self.run_validator(),"variance.unapproved")
 def test_unknown_scope_variance_classification_rejected(self):
  cid=json.loads((self.root/"Packages/contracts/product-capabilities.json").read_text())["capabilities"][0]["id"]
  v={"capabilityID":cid,"classification":"garbage","decisionID":"PD-M1-NOT-ACCEPTED","reason":"Synthetic scope reason","userVisibleBehavior":"Feature unavailable","objectiveAmended":False,"parityStatus":"blocking"}
  self.mutate("Packages/contracts/scope-variances.json",lambda x:x["variances"].append(v),True); self.rejected(self.run_validator(),"schema.enum")
 def test_malformed_scope_variance_rejected(self):
  cid=json.loads((self.root/"Packages/contracts/product-capabilities.json").read_text())["capabilities"][0]["id"]
  v={"capabilityID":cid,"classification":"deferred","decisionID":"PD-M1-NOT-ACCEPTED","reason":"Synthetic scope reason","userVisibleBehavior":"Feature unavailable","objectiveAmended":False,"parityStatus":"blocking","unexpected":True}
  self.mutate("Packages/contracts/scope-variances.json",lambda x:x["variances"].append(v),True); self.rejected(self.run_validator(),"schema.unknownField")
 def trace_mutation_rejected(self,rel,fn,needle):
  self.mutate(rel,fn,True);canonical=self.root/rel;suffix=rel.removeprefix("Packages/contracts/")
  for path in ("Packages/VoxboardShared/Tests/Fixtures/Contracts/v1","Packages/vox-core-rust/tests/resources/contracts/v1","apps/android/core-bridge/src/test/resources/contracts/v1"):
   target=self.root/path/suffix; target.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(canonical,target)
  self.rejected(self.run_validator(),needle)
 def test_trace_sequence_mutation_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-transcript-ingest-commit-delete.json",lambda x:x["events"][5].update(expectedDisposition="duplicateNoOp"),"fixture.validRejected")
 def test_trace_cross_recording_state_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-transcript-ingest-commit-delete.json",lambda x:x["events"][7]["envelope"].update(recordingID="22222222-2222-4222-8222-222222222222"),"trace.ingestMismatch")
 def test_trace_cross_correlation_state_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-transcript-ingest-commit-delete.json",lambda x:x["events"][8]["envelope"].update(correlationID="99999999-9999-4999-8999-999999999999"),"trace.commitCorrelation")
 def test_trace_message_id_collision_rejected(self):
  def mutate(x): x["events"][5]["envelope"].update(messageID=x["events"][4]["envelope"]["messageID"])
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-transcript-ingest-commit-delete.json",mutate,"trace.messageIDCollision")
 def test_trace_preset_binding_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-recording-only.json",lambda x:x["events"][2]["envelope"]["payload"].update(presetSnapshotHash="3"*64),"trace.metadataPresetMismatch")
 def test_trace_frontier_progression_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-transcript-ingest-commit-delete.json",lambda x:x["events"][5]["envelope"]["payload"].update(frontierRevision=1),"trace.frontierRevision")
 def test_trace_future_retry_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/wearable-protocol-trace/valid-reassign-retry.json",lambda x:x["events"][-1]["envelope"]["payload"].update(retryFromRevision=999999),"trace.retryRevision")
 def manifest_error(self,name):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/"+name;case=next(c for c in json.loads((self.root/"Packages/contracts/manifest.json").read_text())["fixtureCases"] if c["path"]==rel);return case["expectedError"]["code"]
 def test_unsupported_version_followup_rejected(self): self.assertEqual(self.manifest_error("invalid-unsupported-followup.json"),"trace.postTerminal")
 def test_trace_envelope_semantics_execute(self):
  self.assertEqual(self.manifest_error("invalid-recording-only-mode-policy.json"),"wear.recordingModePolicy")
  self.assertEqual(self.manifest_error("invalid-transcript-recording-only-policy.json"),"wear.recordingModePolicy")
  self.assertEqual(self.manifest_error("invalid-frontier-exceeds-asset.json"),"wear.frontierBounds")
 def test_asset_replacement_after_ingest_rejected(self): self.assertEqual(self.manifest_error("invalid-asset-replacement-after-ingest.json"),"trace.assetReplacementAfterIngest")
 def test_frozen_policy_reassignment_rejected(self): self.assertEqual(self.manifest_error("invalid-frozen-policy-reassignment.json"),"trace.reassignMeaning")
 def test_reinstall_epoch_is_per_installation(self):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-reinstall-reconciliation.json";x=json.loads((self.root/rel).read_text());self.assertEqual(x["events"][0]["envelope"]["epoch"],100);self.assertEqual(x["events"][2]["envelope"]["epoch"],1);self.assertEqual(x["events"][2]["envelope"]["payload"]["recordings"][0]["lastRevision"],100)
 def test_imported_reconciliation_frontier_blocks_regression_and_terminal_followup(self):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-reinstall-reconciliation.json"
  def f(x):
   imported=x["events"][2];imported["envelope"]["payload"]["recordings"][0]["state"]="terminalFailure"
   follow=copy.deepcopy(x["events"][0]);follow["envelope"].update(senderInstallationID=imported["envelope"]["senderInstallationID"],deviceID=imported["envelope"]["deviceID"],recordingID=imported["envelope"]["recordingID"],epoch=imported["envelope"]["epoch"],correlationID=imported["envelope"]["correlationID"],messageID="eeeeeee1-1111-4111-8111-111111111111",revision=101);follow["expectedDisposition"]="accepted";x["events"].append(follow)
  import copy
  self.trace_mutation_rejected(rel,f,"trace.postTerminal")
 def test_secondary_imported_terminal_frontier_blocks_followup(self):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-reinstall-reconciliation.json"
  def f(x):
   imported=x["events"][2];secondary="22222222-2222-4222-8222-222222222222";imported["envelope"]["payload"]["recordings"].append({"recordingID":secondary,"lastRevision":100,"state":"terminalFailure"})
   follow=copy.deepcopy(x["events"][0]);follow["envelope"].update(senderInstallationID=imported["envelope"]["senderInstallationID"],deviceID=imported["envelope"]["deviceID"],recordingID=secondary,epoch=imported["envelope"]["epoch"],correlationID=imported["envelope"]["correlationID"],messageID="eeeeeee2-1111-4111-8111-111111111111",revision=101);follow["expectedDisposition"]="accepted";x["events"].append(follow)
  import copy
  self.trace_mutation_rejected(rel,f,"trace.postTerminal")
 def test_retired_installation_switchback_rejected(self):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-reinstall-reconciliation.json"
  def f(x):
   old=copy.deepcopy(x["events"][0]);old["envelope"].update(messageKind="reconciliationSummary",messageID="ddddddd1-1111-4111-8111-111111111111",epoch=101,revision=1);old["envelope"]["payload"]={"pendingActionCorrelationIDs":[],"recordings":[{"lastRevision":1,"recordingID":old["envelope"]["recordingID"],"state":"localRecorded"}]};old["envelope"]["replayRule"]="newerRevisionWins";old["expectedDisposition"]="accepted";x["events"].append(old);x["expectedFinalRecordingIdentity"]={k:old["envelope"][k] for k in ("senderInstallationID","deviceID","recordingID","epoch","correlationID")}
  import copy
  self.trace_mutation_rejected(rel,f,"trace.dispositionMismatch")
 def test_reconciliation_payload_mutations_rejected(self):
  rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-negotiation-preset-reconciliation.json"
  mutations=(lambda x:x["events"][-1]["envelope"]["payload"]["recordings"][0].update(recordingID="22222222-2222-4222-8222-222222222222"),lambda x:x["events"][-1]["envelope"]["payload"]["recordings"].append(dict(x["events"][-1]["envelope"]["payload"]["recordings"][0])),lambda x:x["events"][-1]["envelope"]["payload"]["recordings"][0].update(lastRevision=99),lambda x:x["events"][-1]["envelope"]["payload"]["recordings"][0].update(state="vaultCommitted"),lambda x:x["events"][-1]["envelope"]["payload"]["pendingActionCorrelationIDs"].append("77777777-7777-4777-8777-777777777777"))
  for mutate in mutations:
   with self.subTest(mutate=mutate):
    self.tearDown();self.setUp();self.trace_mutation_rejected(rel,mutate,"fixture.validRejected")
 def test_rejected_and_stale_message_id_reuse_rejected(self):
  for index in (1,3):
   with self.subTest(index=index):
    self.tearDown();self.setUp();rel="Packages/contracts/fixtures/wearable-protocol-trace/valid-reinstall-reconciliation.json"
    def f(x,index=index): changed=copy.deepcopy(x["events"][index]);changed["envelope"]["revision"]+=10;changed["expectedDisposition"]="foreignInstallationRejected";x["events"].append(changed)
    import copy
    self.trace_mutation_rejected(rel,f,"trace.messageIDCollision")
 def test_core_api_semantic_negatives_are_typed(self):
  cases=json.loads((self.root/"Packages/contracts/manifest.json").read_text())["fixtureCases"]
  errors={Path(c["path"]).name:c.get("expectedError",{}).get("code") for c in cases if c["family"]=="core-api"}
  self.assertEqual(errors["invalid-ready-not-permitted.json"],"core.readinessCoherence")
  self.assertEqual(errors["invalid-incompatible-no-mismatch.json"],"core.readinessCoherence")
  self.assertEqual(errors["invalid-descriptor-order.json"],"core.descriptorOrder")
  self.assertEqual(errors["invalid-duplicate-drained-artifact.json"],"core.duplicateDrainedArtifact")
 def test_artifact_identity_mutations_rejected(self):
  rel="Packages/contracts/fixtures/artifact-plan/valid-complete.json"
  for field,code in (("operationID","plan.operationID"),("artifactID","plan.artifactID"),("preparedStreamID","plan.streamID")):
   with self.subTest(field=field):
    self.tearDown();self.setUp()
    def f(x,field=field): x["artifacts"][-1][field]="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    self.trace_mutation_rejected(rel,f,code)
 def test_artifact_plan_hash_mutation_rejected(self):
  self.trace_mutation_rejected("Packages/contracts/fixtures/artifact-plan/valid-complete.json",lambda x:x.update(planHash="f"*64),"plan.hash")
 def test_toolchain_validator_rejects_drift_and_landed_unhashed_files(self):
  validator=ROOT/"Packages/contracts/scripts/validate_toolchain.py"
  p=self.root/"toolchains/android-wear-shared-core.json";m=json.loads(p.read_text());m["rust"]["toolchain"]="stable";p.write_text(json.dumps(m,indent=2,sort_keys=True)+"\n")
  r=subprocess.run([sys.executable,str(validator),"--root",str(self.root)],cwd=self.root,text=True,capture_output=True);self.assertNotEqual(r.returncode,0)
  self.tearDown();self.setUp();pending=self.root/"Packages/vox-core-rust/Cargo.lock";pending.write_text("# premature\n");r=subprocess.run([sys.executable,str(validator),"--root",str(self.root)],cwd=self.root,text=True,capture_output=True);self.assertNotEqual(r.returncode,0);self.assertIn("landed without replacing",r.stderr+r.stdout)
 def test_all_wearable_integers_are_bounded(self):
  schema=json.loads((self.root/"Packages/contracts/wearable-protocol/v1/schema.json").read_text());missing=[]
  def walk(v,path="$"):
   if isinstance(v,dict):
    if v.get("type")=="integer" and "const" not in v and "maximum" not in v: missing.append(path)
    for k,z in v.items(): walk(z,path+"."+k)
   elif isinstance(v,list):
    for i,z in enumerate(v): walk(z,f"{path}[{i}]")
  walk(schema);self.assertEqual(missing,[])
if __name__=="__main__": unittest.main()
