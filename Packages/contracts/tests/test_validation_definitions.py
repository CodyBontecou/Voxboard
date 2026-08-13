from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
CONTRACTS_ROOT = REPOSITORY_ROOT / "packages" / "contracts"
VALIDATOR = CONTRACTS_ROOT / "scripts" / "validate_validation_definitions.py"


class ValidationDefinitionTests(unittest.TestCase):
    def run_validator(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), "--contracts-root", str(root)],
            text=True,
            capture_output=True,
            check=False,
        )

    def copied_contracts(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name) / "contracts"
        shutil.copytree(CONTRACTS_ROOT, root, ignore=shutil.ignore_patterns("__pycache__"))
        return temporary, root

    def mutate(self, root: Path, relative: str, operation) -> None:
        path = root / relative
        value = json.loads(path.read_text(encoding="utf-8"))
        operation(value)
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def assert_rejected(self, relative: str, operation, expected: str) -> None:
        temporary, root = self.copied_contracts()
        self.addCleanup(temporary.cleanup)
        self.mutate(root, relative, operation)
        result = self.run_validator(root)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(expected, result.stderr)

    def test_committed_definitions_validate(self) -> None:
        result = self.run_validator(CONTRACTS_ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Validation definitions passed", result.stdout)

    def test_rejects_device_target_drift(self) -> None:
        self.assert_rejected(
            "validation/device-matrix.json",
            lambda value: value["roles"][1]["procurementTarget"].update(model="Imaginary Phone"),
            "device target drift",
        )

    def test_rejects_provider_identity_drift(self) -> None:
        self.assert_rejected(
            "validation/provider-matrix.json",
            lambda value: value["providers"][1].update(authority="example.invalid.documents"),
            "provider identity drift",
        )

    def test_rejects_unknown_case_device_reference(self) -> None:
        self.assert_rejected(
            "validation/case-catalog.json",
            lambda value: value["cases"][0]["deviceRoles"].append("missing-role"),
            "unknown device roles",
        )

    def test_rejects_threshold_drift(self) -> None:
        def change(value):
            gate = next(item for item in value["gates"] if item["id"] == "android-core-arm64-uncompressed")
            gate["value"] = 12582913
        self.assert_rejected(
            "validation/performance-gates.json",
            change,
            "threshold drift",
        )

    def test_rejects_definition_schema_reference_drift(self) -> None:
        self.assert_rejected(
            "validation/device-matrix.json",
            lambda value: value.update({"$schema": "../schemas/missing.schema.json"}),
            "schema reference must be",
        )

    def test_rejects_unresolved_local_schema_reference(self) -> None:
        self.assert_rejected(
            "schemas/case-catalog.schema.json",
            lambda value: value["properties"]["cases"].update({"items": {"$ref": "#/$defs/missing"}}),
            "unresolved schema reference",
        )


if __name__ == "__main__":
    unittest.main()
