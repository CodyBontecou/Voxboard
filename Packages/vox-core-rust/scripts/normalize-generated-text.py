#!/usr/bin/env python3
"""Remove generator whitespace noise while preserving source semantics."""
import sys
from pathlib import Path
if len(sys.argv)<2: raise SystemExit("usage: normalize-generated-text.py <file>...")
for name in sys.argv[1:]:
 path=Path(name); lines=path.read_text().splitlines(); path.write_text("\n".join(line.rstrip() for line in lines)+"\n")
