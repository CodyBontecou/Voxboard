#!/usr/bin/env python3
"""Validate the assembled Phase 1 merged manifest and backup defenses."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
EXPECTED_DOMAINS = {
    "root",
    "file",
    "database",
    "sharedpref",
    "external",
    "device_root",
    "device_file",
    "device_database",
    "device_sharedpref",
}
COMPONENT_TAGS = {"activity", "activity-alias", "service", "receiver", "provider"}
WORKMANAGER_MARKERS = {"androidx.work.WorkManagerInitializer"}
REVIEWED_DEBUG_EXPORTED = {"androidx.compose.ui.tooling.PreviewActivity"}
REVIEWED_PLATFORM_COMPONENT_PERMISSIONS = {"android.permission.DUMP"}


class ValidationError(Exception):
    pass


def parse_xml(path: Path) -> ET.Element:
    if not path.is_file():
        raise ValidationError(f"missing XML input: {path}")
    data = path.read_bytes()
    if b"<!DOCTYPE" in data.upper():
        raise ValidationError(f"DOCTYPE is forbidden: {path}")
    try:
        return ET.fromstring(data)
    except ET.ParseError as error:
        raise ValidationError(f"invalid XML {path}: {error}") from error


def android(element: ET.Element, name: str) -> str:
    return element.get(ANDROID + name, "")


def signature_permissions(manifest: ET.Element) -> set[str]:
    result = set()
    for declaration in manifest.findall("permission"):
        name = android(declaration, "name")
        levels = android(declaration, "protectionLevel").split("|")
        if name and "signature" in levels:
            result.add(name)
    return result


def validate_merged_manifest(path: Path) -> None:
    manifest = parse_xml(path)
    if manifest.tag != "manifest":
        raise ValidationError("merged manifest root must be <manifest>")
    application = manifest.find("application")
    if application is None:
        raise ValidationError("merged manifest has no application")
    if android(application, "allowBackup") != "false":
        raise ValidationError("merged application must set allowBackup=false")
    if android(application, "fullBackupContent") != "@xml/backup_rules":
        raise ValidationError("merged application legacy backup rule reference drift")
    if android(application, "dataExtractionRules") != "@xml/data_extraction_rules":
        raise ValidationError("merged application data extraction rule reference drift")

    protected = signature_permissions(manifest)
    for request in manifest.findall("uses-permission") + manifest.findall("uses-permission-sdk-23"):
        name = android(request, "name")
        if name.startswith("android.permission."):
            raise ValidationError(f"Phase 1 merged manifest requests platform permission {name}")
        if name not in protected:
            raise ValidationError(f"merged manifest requests unreviewed non-signature permission {name}")

    launcher_count = 0
    for component in application:
        tag = component.tag.rsplit("}", 1)[-1]
        if tag == "meta-data" and android(component, "value") in WORKMANAGER_MARKERS:
            raise ValidationError("WorkManager/startup initializer is packaged")
        if tag not in COMPONENT_TAGS:
            continue
        name = android(component, "name")
        if name in WORKMANAGER_MARKERS or name.startswith("androidx.work."):
            raise ValidationError(f"WorkManager component is packaged: {name}")
        for metadata in component.findall(".//meta-data"):
            if android(metadata, "name") in WORKMANAGER_MARKERS or android(metadata, "value") in WORKMANAGER_MARKERS:
                raise ValidationError("WorkManager initializer metadata is packaged")
        actions = {
            android(action, "name")
            for intent_filter in component.findall("intent-filter")
            for action in intent_filter.findall("action")
        }
        categories = {
            android(category, "name")
            for intent_filter in component.findall("intent-filter")
            for category in intent_filter.findall("category")
        }
        is_launcher = (
            tag in {"activity", "activity-alias"}
            and "android.intent.action.MAIN" in actions
            and "android.intent.category.LAUNCHER" in categories
        )
        if is_launcher:
            launcher_count += 1
            if name != "md.vox.android.MainActivity" or android(component, "exported") != "true":
                raise ValidationError(f"unexpected launcher component: {name}")
        if android(component, "exported") == "true" and not is_launcher:
            permission = android(component, "permission")
            explicitly_reviewed = name in REVIEWED_DEBUG_EXPORTED
            permission_protected = (
                permission in protected
                or permission in REVIEWED_PLATFORM_COMPONENT_PERMISSIONS
            )
            if not explicitly_reviewed and not permission_protected:
                raise ValidationError(f"unexpected unpermissioned exported component: {name}")
    if launcher_count != 1:
        raise ValidationError(f"expected one launcher, found {launcher_count}")


def excluded_domains(parent: ET.Element) -> set[str]:
    domains = set()
    for exclude in parent.findall("exclude"):
        if exclude.get("path") != ".":
            raise ValidationError("backup exclusion must cover domain root path='.'")
        domains.add(exclude.get("domain", ""))
    return domains


def validate_backup_rules(legacy_path: Path, modern_path: Path) -> None:
    legacy = parse_xml(legacy_path)
    if legacy.tag != "full-backup-content" or excluded_domains(legacy) != EXPECTED_DOMAINS:
        raise ValidationError("legacy backup exclusions do not cover every governed domain")
    modern = parse_xml(modern_path)
    if modern.tag != "data-extraction-rules":
        raise ValidationError("modern backup rules root drift")
    for section_name in ("cloud-backup", "device-transfer"):
        section = modern.find(section_name)
        if section is None or excluded_domains(section) != EXPECTED_DOMAINS:
            raise ValidationError(f"{section_name} exclusions do not cover every governed domain")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--backup-rules", required=True, type=Path)
    parser.add_argument("--data-extraction-rules", required=True, type=Path)
    arguments = parser.parse_args(argv)
    try:
        validate_merged_manifest(arguments.manifest)
        validate_backup_rules(arguments.backup_rules, arguments.data_extraction_rules)
    except ValidationError as error:
        print(f"Android artifact validation failed: {error}", file=sys.stderr)
        return 1
    print("Android artifact validation passed: merged permissions/components and backup defenses are closed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
