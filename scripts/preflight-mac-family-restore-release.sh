#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="6758967337"
BUNDLE_ID="bontecou.Voxboard"
BASE_REVISION="2c079cabb23b219e78b9292107589ccdbffb00a7"
PATCH="$ROOT/artifacts/releases/mac-family-restore-diagnostics.patch"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vox-mac-family-preflight.XXXXXX")"
WORKTREE="$WORK_ROOT/worktree"
DERIVED_DATA="$WORK_ROOT/DerivedData"
ARCHIVE_LOG="$WORK_ROOT/release-build.log"

cleanup() {
    cd "$ROOT"
    # TMPDIR may be reported through its /private symlink by `git worktree
    # list`; remove unconditionally so path spelling cannot leave a prunable
    # registration behind.
    git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

failures=0
warn() {
    printf 'BLOCKED: %s\n' "$*" >&2
    failures=$((failures + 1))
}
pass() {
    printf 'PASS: %s\n' "$*"
}

for tool in git xcodebuild security asc python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        warn "required tool is unavailable: $tool"
    fi
done
if [ "$failures" -ne 0 ]; then
    exit 2
fi

if [ ! -s "$PATCH" ]; then
    warn "independent patch is missing: $PATCH"
    exit 2
fi

expected_patch_sha="6d69e21e21c329f6d8efd79b6d347427c600cb1c252b33c7e13523750b3bbedc"
actual_patch_sha="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
if [ "$actual_patch_sha" = "$expected_patch_sha" ]; then
    pass "independent patch checksum matches"
else
    warn "independent patch checksum is $actual_patch_sha, expected $expected_patch_sha"
    # Never feed an untrusted or stale patch into a build, whose scripts and
    # compiler plugins can execute code on the host.
    exit 2
fi

cd "$ROOT"
if ! git cat-file -e "$BASE_REVISION^{commit}" 2>/dev/null; then
    warn "independent StoreKit base revision is unavailable: $BASE_REVISION"
    exit 2
fi
git worktree add --quiet --detach "$WORKTREE" "$BASE_REVISION"
cd "$WORKTREE"
if git apply --check "$PATCH" && git apply "$PATCH"; then
    pass "StoreKit patch applies cleanly to base $(git rev-parse --short HEAD)"
else
    warn "StoreKit patch does not apply cleanly to base $BASE_REVISION"
fi

if xcodebuild \
    -project Voxboard.xcodeproj \
    -scheme 'Voxboard Mac' \
    -destination 'platform=macOS' \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$ARCHIVE_LOG" 2>&1; then
    pass "independent macOS Release build succeeds"
else
    warn "independent macOS Release build failed (log: $ARCHIVE_LOG)"
fi

cd "$ROOT"
asc_reads_succeeded=1
if ! asc iap list --app "$APP_ID" --paginate --output json >"$WORK_ROOT/iaps.json"; then
    warn "ASC in-app purchase read failed"
    asc_reads_succeeded=0
fi
if ! asc builds list --app "$APP_ID" --platform MAC_OS --sort -uploadedDate --limit 1 --output json >"$WORK_ROOT/builds.json"; then
    warn "ASC macOS build read failed"
    asc_reads_succeeded=0
fi
if [ "$asc_reads_succeeded" -eq 1 ]; then
    set +e
    python3 - "$WORK_ROOT/iaps.json" "$WORK_ROOT/builds.json" <<'PY'
import json
import sys

iaps = json.load(open(sys.argv[1]))
products = {
    item["attributes"]["productId"]: item["attributes"]
    for item in iaps.get("data", [])
}
expected = {
    "bontecou.Voxboard.family": True,
    "bontecou.Voxboard.familyUpgrade": True,
    "bontecou.Voxboard.unlock": None,
}
problems = []
for product_id, family_sharable in expected.items():
    product = products.get(product_id)
    if product is None:
        problems.append(f"missing ASC product {product_id}")
        continue
    if product.get("state") != "APPROVED":
        problems.append(f"{product_id} state={product.get('state')}")
    if family_sharable is not None and product.get("familySharable") is not family_sharable:
        problems.append(f"{product_id} familySharable={product.get('familySharable')}")
if problems:
    for problem in problems:
        print(f"BLOCKED: {problem}")
    raise SystemExit(2)
print("PASS: ASC Family products are approved and family-shareable")

builds = json.load(open(sys.argv[2])).get("data", [])
if not builds:
    print("BLOCKED: ASC returned no macOS builds")
    raise SystemExit(2)
latest = builds[0]["attributes"]
print(
    "INFO: latest ASC macOS build "
    f"{latest.get('version')} uploaded {latest.get('uploadedDate')} "
    f"state={latest.get('processingState')}"
)
PY
    asc_status=$?
    set -e
    if [ "$asc_status" -ne 0 ]; then
        failures=$((failures + 1))
    fi
fi

identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if printf '%s\n' "$identities" | grep -Eq '"(Apple Distribution|3rd Party Mac Developer Application):'; then
    pass "local App Store distribution signing identity is installed"
else
    warn "no local Apple Distribution private key is installed"
fi

profile_found=0
for directory in \
    "$HOME/Library/MobileDevice/Provisioning Profiles" \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
    [ -d "$directory" ] || continue
    for profile in "$directory"/*.mobileprovision; do
        [ -f "$profile" ] || continue
        decoded="$WORK_ROOT/profile.plist"
        if security cms -D -i "$profile" >"$decoded" 2>/dev/null \
            && grep -Fq "$BUNDLE_ID" "$decoded"; then
            profile_found=1
            break 2
        fi
    done
done
if [ "$profile_found" -eq 1 ]; then
    pass "a local Vox.md provisioning profile is installed"
else
    warn "no local provisioning profile contains $BUNDLE_ID"
fi

if [ "$failures" -ne 0 ]; then
    cat >&2 <<'EOF'

Release upload is intentionally not attempted. Resolve the blockers above, then archive with explicit permission:
  xcodebuild -project Voxboard.xcodeproj -scheme 'Voxboard Mac' \
    -configuration Release -destination 'generic/platform=macOS' \
    -allowProvisioningUpdates archive
EOF
    exit 2
fi

pass "preflight is ready for an explicitly authorized archive/export/upload"
