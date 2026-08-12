#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AXE="${VOXBOARD_AXE:-$(find "$HOME/.npm/_npx" -path '*/xcodebuildmcp/bundled/axe' -type f -perm +111 -print -quit 2>/dev/null || true)}"
if [ -z "$AXE" ] || [ ! -x "$AXE" ]; then
    echo "AXe is required for semantic queue action validation (set VOXBOARD_AXE)." >&2
    exit 1
fi
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vox-ios-queue-runtime.XXXXXX")"
DERIVED_DATA="$WORK_ROOT/DerivedData"
DEVICE_UDID=""
BUNDLE_ID="bontecou.Voxboard"

cleanup() {
    if [ -n "$DEVICE_UDID" ]; then
        xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl shutdown "$DEVICE_UDID" >/dev/null 2>&1 || true
        xcrun simctl delete "$DEVICE_UDID" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_ROOT"
    if [ -n "${RUNTIME_ROOT:-}" ]; then
        rm -rf "$RUNTIME_ROOT"
    fi
}
trap cleanup EXIT INT TERM

read -r DEVICE_TYPE_ID RUNTIME_ID <<EOF
$(python3 - <<'PY'
import json
import subprocess

devices = json.loads(subprocess.check_output([
    "xcrun", "simctl", "list", "devicetypes", "-j"
]))["devicetypes"]
preferred = next((d for d in devices if d["name"] == "iPhone 17 Pro"), None)
if preferred is None:
    preferred = next(d for d in devices if d["name"].startswith("iPhone"))
runtimes = [
    runtime for runtime in json.loads(subprocess.check_output([
        "xcrun", "simctl", "list", "runtimes", "-j"
    ]))["runtimes"]
    if runtime.get("isAvailable") and "iOS" in runtime.get("name", "")
]
if not runtimes:
    raise SystemExit("No available iOS simulator runtime")
runtime = max(runtimes, key=lambda item: tuple(
    int(part) for part in item.get("version", "0").split(".")
))
print(preferred["identifier"], runtime["identifier"])
PY
)
EOF

DEVICE_UDID="$(xcrun simctl create \
    "Vox Queue Runtime $RANDOM" "$DEVICE_TYPE_ID" "$RUNTIME_ID")"
xcrun simctl boot "$DEVICE_UDID"
xcrun simctl bootstatus "$DEVICE_UDID" -b >"$WORK_ROOT/boot.log"

# Build only the current checkout into disposable Derived Data. The dedicated
# simulator is deleted on every exit, so no user's simulator app or data is
# installed, replaced, or inspected.
xcodebuild \
    -project "$ROOT/Voxboard.xcodeproj" \
    -scheme Voxboard \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$WORK_ROOT/build.log" 2>&1
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Voxboard.app"
if [ ! -d "$APP" ]; then
    echo "iOS runtime validation app is unavailable: $APP" >&2
    exit 1
fi
xcrun simctl install "$DEVICE_UDID" "$APP"
DATA_CONTAINER="$(xcrun simctl get_app_container "$DEVICE_UDID" "$BUNDLE_ID" data)"
RUNTIME_PARENT="/tmp/VoxQueueRuntimeValidation"
RUNTIME_ROOT="$RUNTIME_PARENT/ios-$DEVICE_UDID"
rm -rf "$RUNTIME_ROOT"
mkdir -p "$RUNTIME_ROOT/Recordings"
SOURCE_WAV="$RUNTIME_ROOT/Recordings/recording_runtime_validation.wav"
python3 - "$SOURCE_WAV" <<'PY'
import os
import struct
import sys
import time
import wave

path = sys.argv[1]
with wave.open(path, "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(16_000)
    wav.writeframes(struct.pack("<" + "h" * 1_600, *([0] * 1_600)))
old = time.time() - 120
os.utime(path, (old, old))
PY

launch_app() {
    SIMCTL_CHILD_VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
        xcrun simctl launch --terminate-running-process "$DEVICE_UDID" "$BUNDLE_ID" \
        --runtime-queue-validation --disable-release-notes "$@" >"$WORK_ROOT/launch.log"
}

write_wav() {
    local path="$1"
    python3 - "$path" <<'PY'
import pathlib
import struct
import sys
import wave

path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(path), "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(16_000)
    wav.writeframes(struct.pack("<" + "h" * 1_600, *([0] * 1_600)))
PY
}

wait_for_manifest() {
    local manifest=""
    for _ in $(seq 1 300); do
        manifest="$(find "$RUNTIME_ROOT/Recordings/RecordingJobs/items" \
            -type f -name '*.json' -print -quit 2>/dev/null || true)"
        if [ -n "$manifest" ]; then
            printf '%s\n' "$manifest"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

wait_for_state() {
    local manifest="$1"
    local phase="$2"
    local status="$3"
    for _ in $(seq 1 300); do
        if python3 - "$manifest" "$phase" "$status" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(
    0 if data.get("phase") == sys.argv[2]
    and data.get("statusMessage") == sys.argv[3]
    else 1
)
PY
        then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

capture_screenshot() {
    local state="$1"
    local path="$2"
    sleep 2
    xcrun simctl io "$DEVICE_UDID" screenshot "$path" >/dev/null
    python3 - "$path" "$state" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
state = sys.argv[2]
data = path.read_bytes()
if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(f"iOS runtime screenshot is not a valid PNG: {path}")
width, height = struct.unpack(">II", data[16:24])
if width < 1_000 or height < 2_000:
    raise SystemExit(f"iOS runtime screenshot is unexpectedly small: {width}x{height}")
print(f"Isolated iOS Simulator {state} Recording Queue UI rendered at {width}x{height}.")
PY
    "$ROOT/scripts/validate-recording-queue-screenshot.swift" "$path" "ios-$state"
}

EVIDENCE_DIRECTORY="${VOXBOARD_IOS_RUNTIME_EVIDENCE_DIRECTORY:-}"
if [ -n "$EVIDENCE_DIRECTORY" ]; then
    mkdir -p "$EVIDENCE_DIRECTORY"
    FAILED_SCREENSHOT="$EVIDENCE_DIRECTORY/ios-recording-queue-runtime-ui-failed-2026-08-11.png"
    ACCESSIBILITY_SCREENSHOT="$EVIDENCE_DIRECTORY/ios-recording-queue-runtime-ui-failed-accessibility-2026-08-11.png"
    QUEUED_SCREENSHOT="$EVIDENCE_DIRECTORY/ios-recording-queue-runtime-ui-queued-2026-08-11.png"
    COPY_SCREENSHOT="$EVIDENCE_DIRECTORY/ios-recording-queue-runtime-ui-copy-2026-08-11.png"
    rm -f "$FAILED_SCREENSHOT" "$ACCESSIBILITY_SCREENSHOT" \
        "$QUEUED_SCREENSHOT" "$COPY_SCREENSHOT"
fi

launch_app
MANIFEST="$(wait_for_manifest)" || {
    echo "Timed out waiting for iOS orphan recovery manifest" >&2
    exit 1
}
python3 - "$MANIFEST" "$RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
data = json.loads(manifest.read_text())
expected = {
    "phase": "failed",
    "source": "recovered",
    "processingPolicy": "manual",
    "originalFilename": "recording_runtime_validation.wav",
    "failureStage": "storage",
    "statusMessage": "Recovered an interrupted recording; choose how to process it",
}
for key, value in expected.items():
    if data.get(key) != value:
        raise SystemExit(f"{key}={data.get(key)!r}, expected {value!r}")
audio = root / "Recordings" / "RecordingJobs" / "audio" / data["audioFilename"]
if not audio.is_file() or audio.stat().st_size <= 0:
    raise SystemExit(f"iOS durable queue audio is missing or empty: {audio}")
if (root / "Recordings" / expected["originalFilename"]).exists():
    raise SystemExit("iOS external source was not atomically imported")
print("Isolated iOS Simulator app-runtime orphan import passed.")
PY
if [ -n "$EVIDENCE_DIRECTORY" ]; then
    capture_screenshot "failed" "$FAILED_SCREENSHOT"
    xcrun simctl ui "$DEVICE_UDID" content_size accessibility-extra-extra-large
    capture_screenshot "failed-accessibility" "$ACCESSIBILITY_SCREENSHOT"
    xcrun simctl ui "$DEVICE_UDID" content_size large
fi

xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID"
python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
data = json.loads(manifest.read_text())
data["phase"] = "queued"
data["processingPolicy"] = "immediate"
data["failureStage"] = None
data["statusMessage"] = "Queued"
data["attemptCount"] = 0
data["modelID"] = "runtime-paused-executor"
manifest.write_text(json.dumps(data, indent=2, sort_keys=True))
PY
launch_app --runtime-queue-pause-after-claim
claimed=0
for _ in $(seq 1 300); do
    if python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(
    0 if data.get("phase") == "processing" and data.get("attemptCount") == 1 else 1
)
PY
    then
        claimed=1
        break
    fi
    sleep 0.1
done
if [ "$claimed" -ne 1 ]; then
    echo "Timed out waiting for the live iOS queue claim" >&2
    exit 1
fi
xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID"
python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
data = json.loads(manifest.read_text())
if data.get("phase") != "processing" or data.get("attemptCount") != 1:
    raise SystemExit("iOS termination did not leave one durable live claim")
data["processingPolicy"] = "manual"
manifest.write_text(json.dumps(data, indent=2, sort_keys=True))
PY
launch_app
if ! wait_for_state "$MANIFEST" queued "Recovered after Vox.md was interrupted"; then
    echo "Timed out waiting for iOS processing-state relaunch recovery" >&2
    exit 1
fi
python3 - "$MANIFEST" "$RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
audio = root / "Recordings" / "RecordingJobs" / "audio" / data["audioFilename"]
if not audio.is_file() or audio.stat().st_size <= 0:
    raise SystemExit(f"iOS relaunch recovery lost durable audio: {audio}")
print("Isolated iOS Simulator live claimed-job termination and relaunch recovery passed.")
PY
if [ -n "$EVIDENCE_DIRECTORY" ]; then
    capture_screenshot "queued" "$QUEUED_SCREENSHOT"
fi

xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID"
python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
data = json.loads(manifest.read_text())
data["phase"] = "completed"
data["processingPolicy"] = "manual"
data["delivery"] = {"clipboard": {}}
data["failureStage"] = None
data["statusMessage"] = "Completed; copy the transcript when ready"
data["transcriptText"] = "Isolated iOS runtime clipboard result"
manifest.write_text(json.dumps(data, indent=2, sort_keys=True))
PY
launch_app
if ! wait_for_state "$MANIFEST" completed "Completed; copy the transcript when ready"; then
    echo "Timed out waiting for iOS copy-ready runtime state" >&2
    exit 1
fi
if [ -n "$EVIDENCE_DIRECTORY" ]; then
    capture_screenshot "copy-ready" "$COPY_SCREENSHOT"
fi

# Exercise state-changing queue controls against disposable manifests. The
# DEBUG-only app hook invokes the exact queue methods used by Retry, Process
# Now, Copy acknowledgement, retention override, and Delete without relying on
# simulator background execution or mutating a real pasteboard.
xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID"
read -r QUEUED_ACTION_ID FAILED_ACTION_ID <<EOF
$(python3 - "$MANIFEST" "$RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys
import uuid

manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
items = manifest.parent
audio_dir = root / "Recordings" / "RecordingJobs" / "audio"
base = json.loads(manifest.read_text())
base["delivery"] = {"clipboard": {}}
base["modelID"] = "runtime-paused-executor"
base["processingPolicy"] = "manual"
base["initialProcessingPolicy"] = "manual"
base["transcriptText"] = None
base["failureStage"] = None
base["statusMessage"] = "Queued"
base["phase"] = "queued"
base["audioDeletedAt"] = None
base["audioDeletionDate"] = None
base["completedAt"] = None
base["attemptCount"] = 0
queued_id = str(uuid.uuid4())
queued_filename = f"{queued_id}.wav"
base["id"] = queued_id
base["audioFilename"] = queued_filename
source_audio = audio_dir / json.loads(manifest.read_text())["audioFilename"]
(audio_dir / queued_filename).write_bytes(source_audio.read_bytes())
manifest.unlink()
(items / f"{queued_id.lower()}.json").write_text(json.dumps(base, indent=2, sort_keys=True))

created_ids = {}
for role, phase in (("failed-action", "failed"), ("copy-action", "completed")):
    data = dict(base)
    job_id = str(uuid.uuid4())
    created_ids[role] = job_id
    filename = f"{job_id}.wav"
    data["id"] = job_id
    data["audioFilename"] = filename
    data["phase"] = phase
    data["statusMessage"] = "Failed" if phase == "failed" else "Completed; copy the transcript when ready"
    data["failureStage"] = "transcription" if phase == "failed" else None
    data["transcriptText"] = "Runtime action copy payload" if phase == "completed" else None
    (items / f"{job_id.lower()}.json").write_text(json.dumps(data, indent=2, sort_keys=True))
    source = audio_dir / base["audioFilename"]
    destination = audio_dir / filename
    destination.write_bytes(source.read_bytes())
print(queued_id.lower(), created_ids["failed-action"].lower())
PY
)
EOF
launch_app --runtime-queue-activate-actions
passed=0
for _ in $(seq 1 300); do
    if "$AXE" describe-ui --udid "$DEVICE_UDID" 2>/dev/null \
        | grep -q "Runtime queue actions passed $QUEUED_ACTION_ID $FAILED_ACTION_ID"; then
        passed=1
        break
    fi
    sleep 0.1
done
if [ "$passed" -ne 1 ]; then
    echo "Timed out waiting for iOS queue action activation" >&2
    "$AXE" describe-ui --udid "$DEVICE_UDID" >&2 || true
    exit 1
fi
python3 - "$RUNTIME_ROOT" "$QUEUED_ACTION_ID" "$FAILED_ACTION_ID" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
queued_id = sys.argv[2]
failed_id = sys.argv[3]
items = root / "Recordings" / "RecordingJobs" / "items"
jobs = [json.loads(path.read_text()) for path in items.glob("*.json")]
queued = next((job for job in jobs if job.get("id", "").lower() == queued_id), None)
if queued is None:
    raise SystemExit("Queued Process Now fixture disappeared")
if queued.get("processingPolicy") != "immediate" or queued.get("statusMessage") != "Discarded":
    raise SystemExit("Process Now did not durably change its queued fixture before deletion")
if queued.get("phase") != "discarded" or queued.get("retentionPolicy", {}).get("mode") != "permanent":
    raise SystemExit("Retention/Delete did not persist on the Process Now fixture")
failed = next((job for job in jobs if job.get("id", "").lower() == failed_id), None)
if failed is None or failed.get("phase") != "queued" or failed.get("processingPolicy") != "immediate":
    raise SystemExit("Retry did not durably requeue its failed fixture for immediate processing")
if any(job.get("transcriptText") == "Runtime action copy payload" for job in jobs):
    raise SystemExit("Copy acknowledgement did not clear the deferred transcript")
print("Isolated iOS Simulator queue action activation passed.")
PY

# Cover the toolbar-level Retry All action and both remaining retention modes.
# Recovered jobs intentionally stay unrouted, so they provide stable fixtures
# while Retry All immediately requeues only the two ordinary failed jobs.
xcrun simctl terminate "$DEVICE_UDID" "$BUNDLE_ID"
python3 - "$RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys
import uuid

root = pathlib.Path(sys.argv[1])
items = root / "Recordings" / "RecordingJobs" / "items"
audio_dir = root / "Recordings" / "RecordingJobs" / "audio"
source = next(audio_dir.glob("*.wav"))
for path in items.glob("*.json"):
    path.unlink()

base = {
    "schemaVersion": 1,
    "requestID": None,
    "draftRequestID": None,
    "liveSessionID": None,
    "originalFilename": "runtime-extended.wav",
    "createdAt": 808142400,
    "updatedAt": 808142400,
    "duration": 0.1,
    "source": "iOSApp",
    "modelID": "runtime-paused-executor",
    "fallbackModelID": None,
    "language": "en",
    "retentionPolicy": {"mode": "permanent"},
    "processingPolicy": "manual",
    "initialProcessingPolicy": "manual",
    "failureStage": "transcription",
    "statusMessage": "Runtime extended action fixture",
    "attemptCount": 0,
    "revision": 1,
    "transcriptText": None,
    "automaticClipboardDeliveryAttemptedAt": None,
    "exportedNotePath": None,
    "exportedAudioPath": None,
    "audioReferenceAttachedAt": None,
    "completedAt": None,
    "audioDeletionDate": None,
    "audioDeletedAt": None,
}
roles = (
    ("primary-failed", "failed", {"clipboard": {}}, "runtime-primary-failed.wav", None),
    ("primary-queued", "queued", {"clipboard": {}}, "runtime-primary-queued.wav", None),
    ("primary-copy", "completed", {"clipboard": {}}, "runtime-primary-copy.wav", "Extended runtime copy fixture"),
    ("retry-one", "failed", {"clipboard": {}}, "runtime-retry-one.wav", None),
    ("retry-two", "failed", {"clipboard": {}}, "runtime-retry-two.wav", None),
    ("timed", "failed", {"recovery": {}}, "runtime-timed.wav", None),
    ("delete-after", "queued", {"recovery": {}}, "runtime-delete-after.wav", None),
)
created_ids = {}
for role, phase, delivery, original_filename, transcript in roles:
    data = dict(base)
    job_id = str(uuid.uuid4())
    created_ids[role] = job_id.lower()
    filename = f"{job_id}.wav"
    data.update(
        id=job_id,
        audioFilename=filename,
        originalFilename=original_filename,
        phase=phase,
        delivery=delivery,
        transcriptText=transcript,
    )
    if phase != "failed":
        data["failureStage"] = None
    (audio_dir / filename).write_bytes(source.read_bytes())
    (items / f"{job_id.lower()}.json").write_text(json.dumps(data, indent=2, sort_keys=True))
expected = root / "extended-action-expected.json"
expected.write_text(json.dumps(created_ids, indent=2, sort_keys=True))
PY
launch_app --runtime-queue-activate-actions --runtime-queue-activate-extended-actions
extended=0
EXTENDED_ACTION_LABEL=""
for _ in $(seq 1 300); do
    EXTENDED_ACTION_LABEL="$("$AXE" describe-ui --udid "$DEVICE_UDID" 2>/dev/null \
        | grep -o 'Runtime extended queue actions passed [0-9a-f,-]* retention [0-9a-f,-]*' \
        | head -1 || true)"
    if [ -n "$EXTENDED_ACTION_LABEL" ]; then
        extended=1
        break
    fi
    sleep 0.1
done
if [ "$extended" -ne 1 ]; then
    echo "Timed out waiting for extended iOS queue action activation" >&2
    "$AXE" describe-ui --udid "$DEVICE_UDID" >&2 || true
    exit 1
fi
python3 - "$RUNTIME_ROOT" "$EXTENDED_ACTION_LABEL" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
items = root / "Recordings" / "RecordingJobs" / "items"
expected = json.loads((root / "extended-action-expected.json").read_text())
parts = sys.argv[2].split(" retention ")
retry_ids = parts[0].rsplit(" ", 1)[-1].split(",")
retention_ids = parts[1].split(",")
if set(retry_ids) != {expected["retry-one"], expected["retry-two"]}:
    raise SystemExit("Retry All emitted IDs do not match exact intended fixture roles")
if retention_ids != [expected["timed"], expected["delete-after"]]:
    raise SystemExit("Retention emitted IDs do not match exact intended fixture roles")
jobs = [json.loads(path.read_text()) for path in items.glob("*.json")]
ordinary = [job for job in jobs if job.get("id", "").lower() in retry_ids]
if len(ordinary) != 2 or any(
    job.get("phase") != "queued" or job.get("processingPolicy") != "immediate"
    for job in ordinary
):
    raise SystemExit("Retry All did not durably requeue both ordinary failed fixtures")
retention_jobs = [job for job in jobs if job.get("id", "").lower() in retention_ids]
if len(retention_jobs) != 2 or sorted(
    job.get("retentionPolicy", {}).get("mode") for job in retention_jobs
) != ["deleteAfterSuccess", "timed"]:
    raise SystemExit("Timed/delete-after-success retention actions did not persist")
print("Isolated iOS Simulator Retry All and complete retention activation passed.")
PY
printf '%s\n' "Isolated iOS Simulator runtime queue validation passed."
