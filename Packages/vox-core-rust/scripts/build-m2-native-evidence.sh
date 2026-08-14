#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <campaign-directory> <external-artifact-root>" >&2; exit 64; }
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
campaign="$1"; external="$2"; revision="$(git -C "$repo" rev-parse HEAD)"
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || { echo "error: M2 evidence requires a clean checkout" >&2; exit 1; }
mkdir -p "$campaign/artifacts" "$external/executables" "$external/packages/android" "$external/packages/VoxCore.xcframework"
android="$workspace/target/m2-evidence/android"
xcframework="$workspace/target/m2-evidence/VoxCore.xcframework"
VOX_CORE_SOURCE_REVISION="$revision" "$workspace/scripts/build-android-cdylibs.sh" release "$android"
VOX_CORE_SOURCE_REVISION="$revision" "$workspace/scripts/build-apple-xcframework.sh" "$xcframework"
cp "$workspace/scripts/inspect-native-packages.py" "$external/executables/native-package-inspector.py"
chmod 755 "$external/executables/native-package-inspector.py"
# Execute the named production package consumer before retaining the inspected leaves.
python3 "$external/executables/native-package-inspector.py" --android "$android" --xcframework "$xcframework" \
  --output "$workspace/target/m2-evidence/inspector-observation.json" --source-revision "$revision" \
  --toolchain-manifest "$repo/toolchains/android-wear-shared-core.json" >/dev/null
for abi in arm64-v8a armeabi-v7a x86_64 x86; do
  mkdir -p "$external/packages/android/$abi"
  cp "$android/$abi/libvox_core_uniffi.so" "$external/packages/android/$abi/libvox_core_uniffi.so"
done
for identifier in ios-arm64 ios-arm64_x86_64-simulator; do
  mkdir -p "$external/packages/VoxCore.xcframework/$identifier"
  cp "$xcframework/$identifier/libVoxCoreFFI.a" "$external/packages/VoxCore.xcframework/$identifier/libVoxCoreFFI.a"
done
cp "$xcframework/Info.plist" "$external/packages/VoxCore.xcframework/Info.plist"

python3 - "$repo" "$campaign" "$external" "$revision" <<'PY'
import hashlib,json,os,platform,subprocess,sys
from pathlib import Path
repo,campaign,external=map(Path,sys.argv[1:4]);revision=sys.argv[4]
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as source:
  while block:=source.read(1024*1024):h.update(block)
 return h.hexdigest()
def canonical(v):return (json.dumps(v,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
def sysctl(name,default):
 try:return subprocess.run(['sysctl','-n',name],check=True,text=True,capture_output=True).stdout.strip()
 except Exception:return default
host={'osName':platform.system(),'osVersion':platform.mac_ver()[0] or platform.release(),'architecture':platform.machine(),'cpuModel':sysctl('machdep.cpu.brand_string',sysctl('hw.model','Apple runner CPU')),'logicalCPUCount':os.cpu_count() or 1,'totalMemoryBytes':int(sysctl('hw.memsize','1'))}
checks_android=['architecture','binaryFormat','definedUniFFISymbols','dependencyAllowlist'];checks_apple=checks_android+['deploymentTarget','archiveMembers','xcframeworkMetadata']
spec=[('android-arm64-v8a-libvox-core-uniffi','packages/android/arm64-v8a/libvox_core_uniffi.so','android-core-arm64-uncompressed','arm64-v8a',['arm64'],'elf-shared-object'),('android-armeabi-v7a-libvox-core-uniffi','packages/android/armeabi-v7a/libvox_core_uniffi.so','android-core-armv7-uncompressed','armeabi-v7a',['armv7'],'elf-shared-object'),('android-x86-64-libvox-core-uniffi','packages/android/x86_64/libvox_core_uniffi.so','android-core-x86_64-uncompressed','x86_64',['x86_64'],'elf-shared-object'),('android-x86-libvox-core-uniffi','packages/android/x86/libvox_core_uniffi.so','android-core-x86-uncompressed','x86',['x86'],'elf-shared-object'),('apple-ios-arm64-libvox-core-ffi','packages/VoxCore.xcframework/ios-arm64/libVoxCoreFFI.a','apple-xcframework-per-slice','xcframework-ios-device-arm64',['arm64'],'apple-static-library'),('apple-ios-simulator-libvox-core-ffi','packages/VoxCore.xcframework/ios-arm64_x86_64-simulator/libVoxCoreFFI.a','apple-xcframework-per-slice','xcframework-ios-simulator-arm64-x86_64',['arm64','x86_64'],'apple-static-library')]
leaves=[]
for artifact,relative,gate,scope,arches,fmt in spec:
 p=external/relative;codes=checks_android if fmt=='elf-shared-object' else checks_apple
 leaves.append({'artifactID':artifact,'relativeArtifactPath':relative,'gateID':gate,'targetScope':scope,'architectures':arches,'format':fmt,'bytes':p.stat().st_size,'sha256':sha(p),'inspectionChecks':[{'code':code,'result':'passed'} for code in sorted(codes)],'baseline':None})
metadata=external/'packages/VoxCore.xcframework/Info.plist'
receipt={'schemaVersion':1,'format':'vox-m2-native-package-inspection-v1','comparisonMode':'initialCandidate','sourceRevision':revision,'sourceTreeState':'clean','toolchainManifestSha256':sha(repo/'toolchains/android-wear-shared-core.json'),'buildRecipeSha256':sha(repo/'Packages/vox-core-rust/scripts/build-m2-native-evidence.sh'),'inspectorSha256':sha(repo/'Packages/vox-core-rust/scripts/inspect-native-packages.py'),'buildHost':host,'buildConfiguration':'release-stripped','featureSet':'default-features','candidateLeaves':leaves,'appleAggregateBytes':sum(x['bytes'] for x in leaves[-2:]),'xcframeworkMetadata':{'relativeArtifactPath':'packages/VoxCore.xcframework/Info.plist','bytes':metadata.stat().st_size,'sha256':sha(metadata)},'retention':{'kind':'hostedArtifact','runID':os.environ['GITHUB_RUN_ID'],'runAttempt':int(os.environ['GITHUB_RUN_ATTEMPT']),'artifactName':'m2-evidence','archiveSha256':'0'*64,'retentionExpiresAt':'2099-01-01T00:00:00Z'}}
(campaign/'artifacts/native-package-inspection.json').write_bytes(canonical(receipt))
PY
