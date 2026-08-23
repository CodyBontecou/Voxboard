#!/usr/bin/env python3
"""Audit helper for the Vox.md featureset baseline.

Checks each inventory file in docs/featureset/inventory/ for:
  - presence of at least one F-<LID>-<NN> feature section
  - unique feature IDs (no duplicates within a lane)
  - required per-feature fields (Surface, Summary, Details, Constraints,
    Evidence, Status)
  - presence of the file-by-file coverage checklist and Uncertainties sections
  - valid status vocabulary

Usage: python3 docs/featureset/scripts/check_inventory.py [--lane IU]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

INVENTORY_DIR = Path(__file__).resolve().parents[1] / "inventory"

VALID_STATUS = {"shipped", "gated", "experimental", "hidden", "legacy", "planned"}
REQUIRED_FIELDS = ("Surface", "Summary", "Details", "Constraints", "Evidence", "Status")

FEATURE_RE = re.compile(r"^### (F-([A-Z]{2})-(\d{2,}))\b", re.MULTILINE)
FIELD_RE = re.compile(r"^- (\w+)(\s*\([^)]*\))?:", re.MULTILINE)


def check_lane(path: Path) -> tuple[list[str], int]:
    text = path.read_text(encoding="utf-8")
    problems: list[str] = []
    matches = FEATURE_RE.findall(text)
    if not matches:
        problems.append("no feature sections found")
    ids = [m[0] for m in matches]
    if len(ids) != len(set(ids)):
        dupes = sorted({i for i in ids if ids.count(i) > 1})
        problems.append(f"duplicate feature IDs: {', '.join(dupes)}")

    # Per-feature field checks
    sections = re.split(r"^### ", text, flags=re.MULTILINE)[1:]
    for section in sections:
        header = section.splitlines()[0]
        fields = {m.group(1) for m in FIELD_RE.finditer(section)}
        missing = [f for f in REQUIRED_FIELDS if f not in fields]
        if missing:
            problems.append(f"{header}: missing fields {', '.join(missing)}")
        status_m = re.search(r"^- Status:\s*(\w+)", section, re.MULTILINE)
        if status_m and status_m.group(1) not in VALID_STATUS:
            problems.append(f"{header}: invalid status '{status_m.group(1)}'")

    if not re.search(r"^#+ .*coverage", text, re.MULTILINE | re.IGNORECASE):
        problems.append("missing file-by-file coverage checklist")
    if "## Uncertainties" not in text:
        problems.append("missing Uncertainties section")
    return problems, len(ids)


def main() -> int:
    lanes = sorted(INVENTORY_DIR.glob("*.md"))
    if not lanes:
        print(f"No inventory files found in {INVENTORY_DIR}")
        return 1

    filter_lane = None
    if "--lane" in sys.argv:
        filter_lane = sys.argv[sys.argv.index("--lane") + 1]
        lanes = [p for p in lanes if p.stem.endswith(filter_lane.lower())]

    total_features = 0
    failed = False
    for path in lanes:
        problems, count = check_lane(path)
        total_features += count
        status = "OK" if not problems else "FAIL"
        print(f"{status}  {path.name}  ({count} features)")
        for problem in problems:
            print(f"      - {problem}")
            failed = True

    print(f"\nTotal features inventoried: {total_features}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
