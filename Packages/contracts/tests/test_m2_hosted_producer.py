from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT=Path(__file__).resolve().parents[3]
PRODUCER_PATH=ROOT/'Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py'
spec=importlib.util.spec_from_file_location('m2_producer',PRODUCER_PATH)
producer=importlib.util.module_from_spec(spec); spec.loader.exec_module(producer)

class HostedProducerTests(unittest.TestCase):
 def repository(self):
  temporary=tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup); repo=Path(temporary.name)/'repo'
  paths=['.github/workflows/core-rust-ci.yml','Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh','Packages/contracts/scripts/github_actions_oidc.py']
  for relative in paths:
   destination=repo/relative; destination.parent.mkdir(parents=True,exist_ok=True)
   source=ROOT/relative; destination.write_bytes(source.read_bytes())
  subprocess.run(['git','init','-q'],cwd=repo,check=True); subprocess.run(['git','config','user.email','test@invalid'],cwd=repo,check=True); subprocess.run(['git','config','user.name','Test'],cwd=repo,check=True); subprocess.run(['git','add','.'],cwd=repo,check=True); subprocess.run(['git','commit','-qm','fixture'],cwd=repo,check=True)
  return repo
 def identity(self,repo,qualification,revision):
  return {'repository':'CodyBontecou/vox.md','repositoryID':'1153091883','repositoryOwner':'CodyBontecou','repositoryOwnerID':'20440899','repositoryVisibility':'public','oidcIssuer':'https://token.actions.githubusercontent.com','oidcAudience':'https://vox.md/m2-evidence/v1','sourceRevision':revision,'workflowRevision':revision,'workflowReference':'CodyBontecou/vox.md/.github/workflows/core-rust-ci.yml@refs/heads/main','ref':'refs/heads/main','eventName':'push','runnerEnvironment':'github-hosted','runID':'123','runAttempt':1,'orchestratorRepositoryPath':'Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh','orchestratorSha256':producer.sha_file(repo/'Packages/vox-core-rust/scripts/run-m2-hosted-evidence.sh')}
 def environment(self,repo):
  revision=producer.git(repo,'rev-parse','HEAD'); return {'GITHUB_ACTIONS':'true','GITHUB_RUN_ID':'123','GITHUB_RUN_ATTEMPT':'1','GITHUB_SHA':revision,'GITHUB_WORKSPACE':str(repo),'GITHUB_JOB':'m2-evidence','GITHUB_WORKFLOW_REF':'CodyBontecou/vox.md/.github/workflows/core-rust-ci.yml@refs/heads/main','GITHUB_WORKFLOW_SHA':revision,'GITHUB_REF':'refs/heads/main','GITHUB_EVENT_NAME':'push','RUNNER_OS':'macOS','RUNNER_ARCH':'ARM64'}
 def test_finalize_cannot_mint_core_diagnostics_and_rejects_mutation(self):
  repo=self.repository(); temporary=tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup); root=Path(temporary.name); campaign=root/'campaign'; external=root/'external'; (campaign/'artifacts').mkdir(parents=True); (external/'archives').mkdir(parents=True); (external/'archives/m2-evidence.tar').write_bytes(b'archive')
  verifier=lambda repository,qualification,revision:self.identity(repository,qualification,revision)
  with mock.patch.dict(os.environ,self.environment(repo),clear=True):
   with self.assertRaisesRegex(SystemExit,'requires execute-core retained executable'): producer.finalize(repo,campaign,external,'archives/m2-evidence.tar',verifier)
   executable=external/'executables/core-exit-host.py'; executable.parent.mkdir(); shutil.copyfile(PRODUCER_PATH,executable); executable_sha=producer.sha_file(executable)
   for case_id,(code,_) in producer.CORE_CHECKS.items():
    producer.write_json(campaign/f'artifacts/{case_id.lower()}-fixture.diagnostic.json',producer.diagnostic('fixture','bounds',executable_sha))
    producer.write_json(campaign/f'artifacts/{case_id.lower()}-artifact.diagnostic.json',producer.diagnostic('artifact',code,executable_sha,producer.SHADOW_ISOLATION_CHECKS if case_id=='CORE-005' else ()))
   path=campaign/'artifacts/core-002-artifact.diagnostic.json'; value=json.loads(path.read_bytes()); value['checks'][0]['count']=2; producer.write_json(path,value)
   with self.assertRaisesRegex(SystemExit,'exact pre-existing CORE-002 execution diagnostics'): producer.finalize(repo,campaign,external,'archives/m2-evidence.tar',verifier)

if __name__=='__main__': unittest.main()
