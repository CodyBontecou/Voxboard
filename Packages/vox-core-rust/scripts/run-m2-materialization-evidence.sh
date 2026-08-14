#!/usr/bin/env bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo "usage: $0 <campaign-directory> <external-artifact-root>" >&2; exit 64; }
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
campaign="$1"; external="$2"
seed="9c795fa9af3eb6fa1bb450172c12a4a9abc04ac1326b76b8a6b8400d8b207ded"
revision="$(git -C "$repo" rev-parse HEAD)"
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || { echo "error: M2 evidence requires a clean checkout" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo "error: M2 Swift evidence requires macOS" >&2; exit 1; }
mkdir -p "$campaign/artifacts" "$external/executables" "$external/materialization"

VOX_CORE_SOURCE_REVISION="$revision" cargo build --manifest-path "$workspace/Cargo.toml" --locked --release --package vox-core-uniffi
static_library="$workspace/target/release/libvox_core_uniffi.a"
[[ -s "$static_library" ]] || { echo "error: host static library missing" >&2; exit 1; }
VOX_CORE_SOURCE_REVISION="$revision" swift build --package-path "$repo/Packages/VoxboardShared" --configuration release --product VoxboardM2MaterializationEvidence -Xlinker "$static_library"
bin_dir="$(swift build --package-path "$repo/Packages/VoxboardShared" --configuration release --show-bin-path)"
host="$bin_dir/VoxboardM2MaterializationEvidence"
[[ -x "$host" ]] || { echo "error: materialization host executable missing" >&2; exit 1; }
cp "$host" "$external/executables/vox-m2-materialization-evidence"
chmod 755 "$external/executables/vox-m2-materialization-evidence"

runs=("warmup-000:warmup:1048576")
n=1
while [[ $n -le 20 ]]; do
  printf -v padded '%02d' "$n"
  runs+=("latency-$padded:latency:1048576")
  n=$((n + 1))
done
runs+=("aggregate-001:aggregateCoverage:1048576" "aggregate-016:aggregateCoverage:16777216" "aggregate-256:aggregateCoverage:268435456" "resource-256:resource:268435456")
for specification in "${runs[@]}"; do
  IFS=: read -r run_id purpose stream_bytes <<<"$specification"
  directory="$external/materialization/$run_id"; mkdir -p "$directory"
  python3 "$workspace/scripts/generate-m2-materialization-input.py" \
    --seed-sha256 "$seed" --run-id "$run_id" --purpose "$purpose" --stream-bytes "$stream_bytes" \
    --control-output "$directory/control.json" --input-output "$directory/input.bin"
  "$external/executables/vox-m2-materialization-evidence" \
    "$directory/control.json" "$directory/input.bin" "$directory/output.bin" "$directory/report.json"
done

python3 - "$repo" "$campaign" "$external" "$revision" "$seed" <<'PY'
import hashlib,json,sys
from pathlib import Path
repo,campaign,external=map(Path,sys.argv[1:4]); revision=sys.argv[4]; seed=sys.argv[5]
DOMAIN=b"vox-m2-total-input-v1\0"; CHUNK=b"vox-m2-chunk-manifest-v1\0"
def sha_bytes(data): return hashlib.sha256(data).hexdigest()
def sha_file(path):
 h=hashlib.sha256()
 with path.open('rb') as source:
  while block:=source.read(1024*1024): h.update(block)
 return h.hexdigest()
def canonical(value): return (json.dumps(value,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
def manifest(chunks):
 h=hashlib.sha256(CHUNK)
 for item in chunks:
  h.update(item['sequence'].to_bytes(4,'big'));h.update(item['bytes'].to_bytes(8,'big'));h.update(bytes.fromhex(item['sha256']))
 return h.hexdigest()
spec=[('warmup-000','warmup',1048576)]+[(f'latency-{n:02d}','latency',1048576) for n in range(1,21)]+[('aggregate-001','aggregateCoverage',1048576),('aggregate-016','aggregateCoverage',16777216),('aggregate-256','aggregateCoverage',268435456),('resource-256','resource',268435456)]
runs=[]
for rid,purpose,size in spec:
 rel=f'materialization/{rid}'; root=external/rel
 control_bytes=(root/'control.json').read_bytes(); control=json.loads(control_bytes); report=json.loads((root/'report.json').read_bytes())
 stream_sha=sha_file(root/'input.bin'); control_sha=sha_bytes(control_bytes)
 total_sha=sha_bytes(DOMAIN+len(control_bytes).to_bytes(8,'big')+size.to_bytes(8,'big')+bytes.fromhex(control_sha)+bytes.fromhex(stream_sha))
 runs.append({'runID':rid,'purpose':purpose,'status':'completed','controlDocument':control,'controlBytes':len(control_bytes),'controlSha256':control_sha,'controlArtifactPath':rel+'/control.json','streamBytes':size,'streamSha256':stream_sha,'totalInputBytes':len(control_bytes)+size,'totalInputSha256':total_sha,'ingressChunks':report['ingressChunks'],'ingressChunkManifestSha256':manifest(report['ingressChunks']),'inputArtifactPath':rel+'/input.bin','outputBytes':report['outputBytes'],'outputSha256':report['outputSha256'],'outputArtifactPath':rel+'/output.bin','drainChunks':report['drainChunks'],'drainChunkManifestSha256':manifest(report['drainChunks']),'verifiedDrain':report['verifiedDrain'],'durationNanoseconds':report['durationNanoseconds'],'rss':report['rss'] if purpose=='resource' else None})
 # Reports are transient producer output, not retained campaign claims.
 (root/'report.json').unlink()
host=external/'executables/vox-m2-materialization-evidence'; tool=repo/'toolchains/android-wear-shared-core.json'
run_set={'schemaVersion':1,'format':'vox-m2-materialization-run-set-v1','operation':'newNoteTextLink','profileVersion':'apple-parity-v1','productionConsumerID':'vox-core-uniffi-swift-host-v1','sourceRevision':revision,'executableSha256':sha_file(host),'toolchainManifestSha256':sha_file(tool),'warmupRunIDs':['warmup-000'],'gateBindings':[{'gateID':'rust-materialize-1mib-p95','runIDs':[f'latency-{n:02d}' for n in range(1,21)]},{'gateID':'rust-materialize-additional-rss','runIDs':['resource-256']},{'gateID':'ffi-max-chunk','runIDs':[x[0] for x in spec if x[1]!='warmup']},{'gateID':'materialization-max-aggregate','runIDs':['aggregate-001','aggregate-016','aggregate-256']}],'runs':runs}
path=campaign/'artifacts/materialization-run-set.json';path.write_bytes(canonical(run_set))
PY
