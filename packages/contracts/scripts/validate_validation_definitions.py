#!/usr/bin/env python3
"""Validate repository-owned Android/Wear validation definitions using stdlib only."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


class ValidationError(Exception):
    pass


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"{path}: invalid JSON: {error}") from error


def json_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    if expected == "null":
        return value is None
    return False


def resolve_pointer(document: Any, pointer: str) -> Any:
    current = document
    if pointer in ("", "#"):
        return current
    if not pointer.startswith("#/"):
        raise ValidationError(f"unsupported schema reference: {pointer}")
    for encoded in pointer[2:].split("/"):
        token = encoded.replace("~1", "/").replace("~0", "~")
        try:
            current = current[int(token)] if isinstance(current, list) else current[token]
        except (KeyError, IndexError, ValueError, TypeError) as error:
            raise ValidationError(f"unresolved schema reference: {pointer}") from error
    return current


def validate_instance(instance: Any, schema: dict[str, Any], root_schema: dict[str, Any], path: str = "$") -> None:
    if "$ref" in schema:
        reference = schema["$ref"]
        if not isinstance(reference, str) or not reference.startswith("#"):
            raise ValidationError(f"{path}: only document-local $ref is supported, found {reference!r}")
        target = resolve_pointer(root_schema, reference)
        if not isinstance(target, dict):
            raise ValidationError(f"{path}: $ref target is not a schema: {reference}")
        validate_instance(instance, target, root_schema, path)
        return

    if "oneOf" in schema:
        matches = 0
        messages: list[str] = []
        for option in schema["oneOf"]:
            try:
                validate_instance(instance, option, root_schema, path)
                matches += 1
            except ValidationError as error:
                messages.append(str(error))
        if matches != 1:
            raise ValidationError(f"{path}: expected exactly one oneOf match, found {matches}; {'; '.join(messages[:2])}")
        return

    if "type" in schema:
        expected = schema["type"]
        expected_types = [expected] if isinstance(expected, str) else expected
        if not isinstance(expected_types, list) or not any(json_type_matches(instance, item) for item in expected_types):
            raise ValidationError(f"{path}: expected type {expected!r}, found {type(instance).__name__}")

    if "const" in schema and instance != schema["const"]:
        raise ValidationError(f"{path}: expected constant {schema['const']!r}, found {instance!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise ValidationError(f"{path}: value {instance!r} is not in enum")

    if isinstance(instance, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                raise ValidationError(f"{path}: missing required property {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            extras = sorted(set(instance) - set(properties))
            if extras:
                raise ValidationError(f"{path}: unexpected properties {extras}")
        for key, value in instance.items():
            child_schema = properties.get(key)
            if isinstance(child_schema, dict):
                validate_instance(value, child_schema, root_schema, f"{path}.{key}")

    if isinstance(instance, list):
        if len(instance) < schema.get("minItems", 0):
            raise ValidationError(f"{path}: requires at least {schema['minItems']} items")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise ValidationError(f"{path}: allows at most {schema['maxItems']} items")
        if schema.get("uniqueItems"):
            encoded = [json.dumps(item, sort_keys=True, separators=(",", ":")) for item in instance]
            if len(encoded) != len(set(encoded)):
                raise ValidationError(f"{path}: items must be unique")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(instance):
                validate_instance(item, item_schema, root_schema, f"{path}[{index}]")

    if isinstance(instance, str):
        if len(instance) < schema.get("minLength", 0):
            raise ValidationError(f"{path}: string is shorter than {schema['minLength']}")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            raise ValidationError(f"{path}: string is longer than {schema['maxLength']}")
        if "pattern" in schema and re.search(schema["pattern"], instance) is None:
            raise ValidationError(f"{path}: value does not match {schema['pattern']!r}")
        if schema.get("format") == "date-time" and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", instance) is None:
            raise ValidationError(f"{path}: date-time must be UTC RFC 3339")
        if "not" in schema:
            try:
                validate_instance(instance, schema["not"], root_schema, path)
            except ValidationError:
                pass
            else:
                raise ValidationError(f"{path}: value matches forbidden schema")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            raise ValidationError(f"{path}: value is below minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            raise ValidationError(f"{path}: value is above maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            raise ValidationError(f"{path}: value must exceed {schema['exclusiveMinimum']}")


def unique_index(items: list[dict[str, Any]], key: str, label: str) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    for item in items:
        identifier = item[key]
        if identifier in result:
            raise ValidationError(f"duplicate {label} ID: {identifier}")
        result[identifier] = item
    return result


def validate_schema_document(schema: dict[str, Any], path: Path) -> None:
    if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise ValidationError(f"{path}: schema must declare JSON Schema 2020-12")
    if not isinstance(schema.get("$id"), str) or not schema["$id"].startswith("https://vox.md/contracts/schemas/"):
        raise ValidationError(f"{path}: missing repository-owned canonical $id")
    # Resolve every document-local reference before validating instances.
    def walk(value: Any) -> None:
        if isinstance(value, dict):
            reference = value.get("$ref")
            if isinstance(reference, str) and reference.startswith("#"):
                resolve_pointer(schema, reference)
            for child in value.values():
                walk(child)
        elif isinstance(value, list):
            for child in value:
                walk(child)
    walk(schema)


def validate(contracts_root: Path) -> None:
    validation_dir = contracts_root / "validation"
    schemas_dir = contracts_root / "schemas"
    expected = {
        "device-matrix.json": "device-matrix.schema.json",
        "provider-matrix.json": "provider-matrix.schema.json",
        "case-catalog.json": "case-catalog.schema.json",
        "performance-gates.json": "performance-gates.schema.json",
        "aggregate-policy.json": "aggregate.schema.json",
        "case-evidence-policy.json": "case-evidence-requirements.schema.json",
        "approval-policy.json": "approval-policy.schema.json",
    }
    required_schemas = set(expected.values()) | {"case-evidence.schema.json", "approval.schema.json"}
    schemas: dict[str, dict[str, Any]] = {}
    for name in sorted(required_schemas):
        path = schemas_dir / name
        if not path.is_file():
            raise ValidationError(f"missing schema: {path}")
        document = load_json(path)
        if not isinstance(document, dict):
            raise ValidationError(f"{path}: schema root must be an object")
        validate_schema_document(document, path)
        schemas[name] = document

    documents: dict[str, dict[str, Any]] = {}
    for name, schema_name in expected.items():
        path = validation_dir / name
        document = load_json(path)
        if not isinstance(document, dict):
            raise ValidationError(f"{path}: definition root must be an object")
        expected_reference = f"../schemas/{schema_name}"
        if document.get("$schema") != expected_reference:
            raise ValidationError(f"{path}: schema reference must be {expected_reference!r}")
        validate_instance(document, schemas[schema_name], schemas[schema_name])
        documents[name] = document

    devices = unique_index(documents["device-matrix.json"]["roles"], "id", "device role")
    providers = unique_index(documents["provider-matrix.json"]["providers"], "id", "provider")
    cases = unique_index(documents["case-catalog.json"]["cases"], "id", "case")
    invariants = unique_index(documents["case-catalog.json"]["nonWaivableInvariants"], "id", "invariant")
    gates = unique_index(documents["performance-gates.json"]["gates"], "id", "performance gate")

    canonical_devices = {
        "phone-low-api28": ("Google", "Pixel 3", "androidPhone"),
        "phone-current-pixel": ("Google", "Pixel 10 Pro", "androidPhone"),
        "phone-current-samsung": ("Samsung", "Galaxy S26", "androidPhone"),
        "large-screen": ("Samsung", "Galaxy Tab S11", "androidTablet"),
        "wear-reference": ("Google", "Pixel Watch 4", "wearOS"),
        "wear-samsung": ("Samsung", "Galaxy Watch8", "wearOS"),
    }
    if set(devices) != set(canonical_devices):
        raise ValidationError(f"device roles drift: expected {sorted(canonical_devices)}, found {sorted(devices)}")
    for role_id, (manufacturer, model, platform) in canonical_devices.items():
        role = devices[role_id]
        target = role["procurementTarget"]
        if (target["manufacturer"], target["model"], role["platform"]) != (manufacturer, model, platform):
            raise ValidationError(f"device target drift for {role_id}")
        if platform == "wearOS" and role.get("freeStorageFloor") != {"minimumBytes": 1073741824, "minimumCapacityFraction": 0.2, "rule": "max"}:
            raise ValidationError(f"{role_id}: free storage floor must be max(1 GiB, 20% capacity)")

    canonical_providers = {
        "documentsui-local": ("com.android.externalstorage.documents", "com.google.android.documentsui"),
        "google-drive": ("com.google.android.apps.docs.storage", "com.google.android.apps.docs"),
        "microsoft-onedrive": ("com.microsoft.skydrive.content.StorageAccessProvider", "com.microsoft.skydrive"),
    }
    if set(providers) != set(canonical_providers):
        raise ValidationError(f"provider set drift: expected {sorted(canonical_providers)}, found {sorted(providers)}")
    for provider_id, identity in canonical_providers.items():
        actual = (providers[provider_id]["authority"], providers[provider_id]["packageName"])
        if actual != identity:
            raise ValidationError(f"provider identity drift for {provider_id}: {actual!r}")

    categories = {"REC", "SAF", "WEAR", "PERF"}
    found_categories = {case["category"] for case in cases.values()}
    if found_categories != categories:
        raise ValidationError(f"case categories must be exactly {sorted(categories)}")
    for case_id, case in cases.items():
        if not case_id.startswith(case["category"] + "-"):
            raise ValidationError(f"{case_id}: ID/category mismatch")
        unknown_roles = sorted(set(case["deviceRoles"]) - set(devices))
        if unknown_roles:
            raise ValidationError(f"{case_id}: unknown device roles {unknown_roles}")
        unknown_invariants = sorted(set(case["invariants"]) - set(invariants))
        if unknown_invariants:
            raise ValidationError(f"{case_id}: unknown invariants {unknown_invariants}")
        unknown_gates = sorted(set(case.get("performanceGateIDs", [])) - set(gates))
        if unknown_gates:
            raise ValidationError(f"{case_id}: unknown performance gates {unknown_gates}")
        if case["category"] == "SAF" and case["providerApplicability"] == "none":
            raise ValidationError(f"{case_id}: SAF case cannot have provider applicability none")
        if case["category"] != "SAF" and case["providerApplicability"] != "none" and case_id != "PERF-004":
            raise ValidationError(f"{case_id}: unexpected provider applicability")

    expected_thresholds = {
        "android-core-arm64-uncompressed": (12582912, "bytes"),
        "android-core-armv7-uncompressed": (10485760, "bytes"),
        "android-core-x86_64-uncompressed": (14680064, "bytes"),
        "android-core-x86-uncompressed": (12582912, "bytes"),
        "apple-xcframework-aggregate": (62914560, "bytes"),
        "apple-xcframework-per-slice": (15728640, "bytes"),
        "packaging-growth": (10, "percent"),
        "enqueue-text-link-p95": (500, "ms"),
        "quick-capture-warm-p95": (500, "ms"),
        "quick-capture-cold-p95": (1500, "ms"),
        "rust-materialize-1mib-p95": (100, "ms"),
        "rust-materialize-additional-rss": (67108864, "bytes"),
        "ffi-max-chunk": (1048576, "bytes"),
        "materialization-max-aggregate": (268435456, "bytes"),
        "saf-actionable-watchdog": (30000, "ms"),
        "recorder-session-duration": (3600, "s"),
        "recorder-max-prefix-loss": (2, "s"),
        "asr-realtime-factor": (1, "ratio"),
        "asr-peak-rss": (1342177280, "bytes"),
        "asr-cancel-latency": (2, "s"),
        "wear-session-duration": (3600, "s"),
        "wear-battery-consumption": (20, "percent"),
        "wear-transfer-ingest": (600, "s"),
    }
    if set(gates) != set(expected_thresholds):
        raise ValidationError("performance gate set drift")
    for gate_id, (value, unit) in expected_thresholds.items():
        gate = gates[gate_id]
        if (gate["value"], gate["unit"]) != (value, unit):
            raise ValidationError(f"threshold drift for {gate_id}: expected {value} {unit}")
    deferred = documents["performance-gates.json"]["deferredRequiredBudgets"]
    if deferred != [{"id": "local-asr-model-package", "requiredBeforeMilestone": "M4", "reason": "Select the launch model and supported tiers from measured licensing, quality, size, memory, and runtime evidence before M4 starts."}]:
        raise ValidationError("model package budget must remain explicitly required before M4")

    aggregate = documents["aggregate-policy.json"]
    if set(aggregate["waiverPolicy"]["nonWaivableInvariantIDs"]) != set(invariants):
        raise ValidationError("aggregate non-waivable invariant set drift")
    if aggregate["waiverPolicy"]["waiverCanProducePassedCase"] is not False:
        raise ValidationError("a waiver must never produce a passed case")

    forbidden_definition_keys = {"serialHash", "buildFingerprint", "installedPackageVersion", "signingCertificateSha256", "buildSignatureSha256"}
    def reject_fabricated(value: Any, location: str) -> None:
        if isinstance(value, dict):
            for key, child in value.items():
                if key in forbidden_definition_keys:
                    raise ValidationError(f"{location}: campaign fact {key} must not be populated in M1 definitions")
                reject_fabricated(child, f"{location}.{key}")
        elif isinstance(value, list):
            for index, child in enumerate(value):
                reject_fabricated(child, f"{location}[{index}]")
    for name in ("device-matrix.json", "provider-matrix.json", "case-catalog.json", "performance-gates.json"):
        reject_fabricated(documents[name], name)

    print(
        "Validation definitions passed: "
        f"{len(devices)} device roles, {len(providers)} providers, {len(cases)} cases, "
        f"{len(invariants)} non-waivable invariants, {len(gates)} numerical gates, {len(required_schemas)} schemas."
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    default_root = Path(__file__).resolve().parents[1]
    parser.add_argument("--contracts-root", type=Path, default=default_root)
    args = parser.parse_args()
    try:
        validate(args.contracts_root.resolve())
    except ValidationError as error:
        print(f"Validation definitions failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
