#!/usr/bin/env python3
"""Inspect source-built M2 native leaves and emit privacy-safe canonical evidence."""
import argparse,hashlib,json,os,plistlib,re,subprocess
from pathlib import Path
ABIS={"arm64-v8a":("AArch64","android-core-arm64-uncompressed",12582912),"armeabi-v7a":("ARM","android-core-armv7-uncompressed",10485760),"x86_64":("Advanced Micro Devices X86-64","android-core-x86_64-uncompressed",14680064),"x86":("Intel 80386","android-core-x86-uncompressed",12582912)}
SYMBOL="uniffi_vox_core_uniffi_fn_func_core_build_info"
def run(*args): return subprocess.run(args,text=True,capture_output=True,check=True).stdout
def output(*args): return subprocess.run(args,text=True,capture_output=True).stdout
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def leaf(identifier,scope,path,arch,gate,limit):
 n=path.stat().st_size
 return {"architecture":arch,"artifactID":identifier,"bytes":n,"gateID":gate,"limitBytes":limit,"passed":0<n<=limit,"sha256":sha(path),"targetScope":scope}
def main():
 ap=argparse.ArgumentParser();ap.add_argument("--android",type=Path,required=True);ap.add_argument("--xcframework",type=Path,required=True);ap.add_argument("--output",type=Path,required=True);ap.add_argument("--source-revision",required=True);ap.add_argument("--toolchain-manifest",type=Path,required=True);a=ap.parse_args()
 tool=Path(os.environ.get("ANDROID_NDK_HOME",str(Path.home()/"Library/Android/sdk/ndk/27.1.12297006")))/"toolchains/llvm/prebuilt/darwin-x86_64/bin"
 if not tool.is_dir(): tool=Path(os.environ.get("ANDROID_NDK_HOME",str(Path.home()/"Library/Android/sdk/ndk/27.1.12297006")))/"toolchains/llvm/prebuilt/darwin-aarch64/bin"
 readelf=tool/"llvm-readelf"; nm=tool/"llvm-nm"; leaves=[]
 for abi,(machine,gate,limit) in ABIS.items():
  p=a.android/abi/"libvox_core_uniffi.so"; hdr=run(str(readelf),"-h",str(p)); dyn=run(str(readelf),"-d",str(p)); symbols=run(str(nm),"-D","--defined-only",str(p))
  machine_match=re.search(r"Machine:\s+(.+)",hdr); type_match=re.search(r"Type:\s+DYN",hdr)
  if not machine_match or machine_match.group(1).strip()!=machine or not type_match or SYMBOL not in symbols or "(NEEDED)" not in dyn: raise SystemExit(f"Android inspection failed: {abi}")
  leaves.append(leaf(f"android-{abi}-libvox_core_uniffi.so",abi,p,machine,gate,limit))
 info=plistlib.load((a.xcframework/"Info.plist").open("rb")); libs=info["AvailableLibraries"]
 expected={"ios-arm64":("arm64","xcframework-ios-device-arm64"),"ios-arm64_x86_64-simulator":("arm64 x86_64","xcframework-ios-simulator-arm64-x86_64")}
 aggregate=0
 for ident,(arches,scope) in expected.items():
  entry=next((x for x in libs if x["LibraryIdentifier"]==ident),None)
  if not entry: raise SystemExit(f"missing XCFramework leaf {ident}")
  p=a.xcframework/ident/entry["LibraryPath"]; actual=run("xcrun","lipo","-archs",str(p)).strip()
  if set(actual.split())!=set(arches.split()) or SYMBOL not in output("xcrun","strings",str(p)): raise SystemExit(f"Apple inspection failed: {ident}")
  if not output("xcrun","ar","-t",str(p)).strip() and p.stat().st_size==0: raise SystemExit(f"Apple archive is empty: {ident}")
  deployment=run("xcrun","otool","-l",str(p)); versions=re.findall(r"minos (17\.6)",deployment)
  if not versions: raise SystemExit(f"iOS 17.6 deployment target absent: {ident}")
  leaves.append(leaf(f"apple-{ident}-libVoxCoreFFI.a",scope,p,actual,"apple-xcframework-per-slice",15728640)); aggregate+=p.stat().st_size
 all_passed=all(x["passed"] for x in leaves) and 0<aggregate<=62914560
 record={"schemaVersion":1,"status":"absoluteGatesPassed" if all_passed else "absoluteGatesFailed","sourceRevision":a.source_revision,"toolchain":{"configuration":"release","featureSet":"default-features","manifestSHA256":sha(a.toolchain_manifest),"toolchainID":"android-wear-shared-core-v1"},"leaves":leaves,"xcframeworkAggregate":{"bytes":aggregate,"gateID":"apple-xcframework-aggregate","limitBytes":62914560,"passed":0<aggregate<=62914560},"percentageGrowth":{"status":"notApplicableFirstCore","reasonCode":"noApprovedNonzeroPredecessor"},"campaignStatus":{"PERF-008":"notClaimed","reasonCode":"firstCoreEvidenceContractRepresentabilityGap"}}
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(record,sort_keys=True,indent=2)+"\n")
 print(json.dumps(record,sort_keys=True))
if __name__=="__main__": main()
