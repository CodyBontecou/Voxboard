#!/usr/bin/env python3
import plistlib,sys
from pathlib import Path
if len(sys.argv)!=2: raise SystemExit("usage: normalize-apple-xcframework.py <xcframework>")
p=Path(sys.argv[1])/"Info.plist"
with p.open("rb") as f: info=plistlib.load(f)
libs=info.get("AvailableLibraries")
if not isinstance(libs,list) or not all(isinstance(x,dict) and isinstance(x.get("LibraryIdentifier"),str) for x in libs): raise SystemExit("invalid AvailableLibraries")
libs.sort(key=lambda x:x["LibraryIdentifier"])
with p.open("wb") as f: plistlib.dump(info,f,fmt=plistlib.FMT_XML,sort_keys=True)
