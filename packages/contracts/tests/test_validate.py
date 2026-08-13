import json
import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[3]
VALIDATOR=Path('packages/contracts/scripts/validate.py')

class ContractValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)/'repo'
        required_trees = [
            'packages/contracts',
            'Packages/VoxboardShared/Tests/Fixtures/Contracts',
            'packages/vox-core-rust/tests/resources/contracts',
            'apps/android/core-bridge/src/test/resources/contracts',
        ]
        for relative in required_trees:
            source = ROOT / relative
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(
                source,
                destination,
                ignore=shutil.ignore_patterns('__pycache__'),
            )
        ledger = Path('docs/architecture/android-wear-m0-capabilities.json')
        destination = self.root / ledger
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / ledger, destination)

    def tearDown(self): self.temp.cleanup()

    def run_validator(self):
        return subprocess.run([sys.executable,str(VALIDATOR),'--root',str(self.root)],cwd=self.root,text=True,capture_output=True)

    def json_file(self,relative,change):
        path=self.root/relative; value=json.loads(path.read_text()); change(value); path.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')

    def assertRejected(self,result,needle):
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn(needle,result.stdout+result.stderr)

    def test_clean_pass(self):
        result=self.run_validator(); self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('Contracts validation passed',result.stdout)

    def test_bad_hash(self):
        self.json_file('packages/contracts/manifest.json',lambda x:x['files'][0].update(sha256='f'*64))
        self.assertRejected(self.run_validator(),'hash/count drift')

    def test_missing_capability(self):
        self.json_file('packages/contracts/product-capabilities.json',lambda x:x['capabilities'].pop())
        self.assertRejected(self.run_validator(),'manifest hash/count drift')

    def test_changed_acceptance_mapping(self):
        def mutate(x): x['capabilities'][0]['acceptance'][0]['assertion']='changed'
        self.json_file('packages/contracts/product-capabilities.json',mutate)
        # Update manifest hash/count so retention, rather than byte drift, is exercised.
        p=self.root/'packages/contracts/product-capabilities.json'; m=self.root/'packages/contracts/manifest.json'; manifest=json.loads(m.read_text())
        for r in manifest['files']:
            if r['path']=='packages/contracts/product-capabilities.json': r.update(bytes=len(p.read_bytes()),sha256=hashlib.sha256(p.read_bytes()).hexdigest())
        m.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n')
        self.assertRejected(self.run_validator(),'acceptance retention drift')

    def test_stale_mirror(self):
        path=self.root/'Packages/VoxboardShared/Tests/Fixtures/Contracts/v1/artifact-plan/v1/contract.md'
        path.write_text(path.read_text()+'stale\n')
        self.assertRejected(self.run_validator(),'stale mirror')

    def test_missing_mirror(self):
        shutil.rmtree(self.root/'apps/android/core-bridge/src/test/resources/contracts/v1')
        self.assertRejected(self.run_validator(),'mirror exact file-set drift')

    def test_unsafe_path_fixture_cannot_be_marked_valid(self):
        def mutate(x):
            for c in x['fixtureCases']:
                if c['path'].endswith('invalid-unsafe-path.json'):
                    c['expect']='valid'; break
        self.json_file('packages/contracts/manifest.json',mutate)
        self.assertRejected(self.run_validator(),'expected valid')

    def test_unsupported_version_fixture_cannot_be_marked_valid(self):
        def mutate(x):
            for c in x['fixtureCases']:
                if c['path'].endswith('invalid-unsupported-version.json'):
                    c['expect']='valid'; break
        self.json_file('packages/contracts/manifest.json',mutate)
        self.assertRejected(self.run_validator(),'expected valid')

    def test_session_violation_fixture_cannot_be_marked_valid(self):
        def mutate(x):
            for c in x['fixtureCases']:
                if c['path'].endswith('invalid-session-chunk-limit.json'):
                    c['expect']='valid'; break
        self.json_file('packages/contracts/manifest.json',mutate)
        self.assertRejected(self.run_validator(),'expected valid')

    def test_ack_violation_fixture_cannot_be_marked_valid(self):
        def mutate(x):
            for c in x['fixtureCases']:
                if c['path'].endswith('invalid-delete-before-vault.json'):
                    c['expect']='valid'; break
        self.json_file('packages/contracts/manifest.json',mutate)
        self.assertRejected(self.run_validator(),'expected valid')

if __name__=='__main__': unittest.main()
