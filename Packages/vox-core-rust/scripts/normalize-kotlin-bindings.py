#!/usr/bin/env python3
"""Normalize UniFFI Kotlin u16 checksum calls for Android/JNA return registers."""
import re,sys
from pathlib import Path
PATTERN=re.compile(r"if \(lib\.(uniffi_[A-Za-z0-9_]+_checksum_[A-Za-z0-9_]+)\(\) != ([0-9]+)\) \{")
def main():
 if len(sys.argv)!=2: raise SystemExit("usage: normalize-kotlin-bindings.py <root>")
 bindings=sorted(Path(sys.argv[1]).rglob("*uniffi.kt"))
 if not bindings: raise SystemExit("no generated Kotlin binding found")
 for path in bindings:
  text=path.read_text(); normalized,count=PATTERN.subn(r"if ((lib.\1() and 0xffff) != \2) {",text)
  if not count: raise SystemExit(f"no UniFFI checksum calls found in {path}")
  path.write_text(normalized)
if __name__=="__main__": main()
