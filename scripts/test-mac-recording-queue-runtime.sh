#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vox-mac-queue-runtime.XXXXXX")"
RUNTIME_PARENT="/tmp/VoxQueueRuntimeValidation"
RUNTIME_ROOT=""
DERIVED_DATA="$WORK_ROOT/DerivedData"
APP_STDOUT="$WORK_ROOT/app.stdout"
APP_STDERR="$WORK_ROOT/app.stderr"
APP_PID=""
SECOND_APP_PID=""

cleanup() {
    for pid in "$APP_PID" "$SECOND_APP_PID"; do
        if [ -n "$pid" ]; then
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
        fi
    done
    rm -rf "$WORK_ROOT"
    if [ "${VOXBOARD_KEEP_MAC_RUNTIME_ROOT:-0}" != "1" ] \
        && [ -n "$RUNTIME_ROOT" ]; then
        rm -rf "$RUNTIME_ROOT"
        rmdir "$RUNTIME_PARENT" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

wait_for_screenshot() {
    local path="$1"
    local state="$2"
    for _ in $(seq 1 100); do
        [ -s "$path" ] && break
        sleep 0.1
    done
    if [ ! -s "$path" ]; then
        echo "Timed out waiting for the isolated $state Recording Queue screenshot" >&2
        cat "$APP_STDERR" >&2
        exit 1
    fi
    python3 - "$path" "$state" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
state = sys.argv[2]
data = path.read_bytes()
if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
    raise SystemExit(f"runtime screenshot is not a valid PNG: {path}")
width, height = struct.unpack(">II", data[16:24])
if width < 800 or height < 400:
    raise SystemExit(f"runtime screenshot is unexpectedly small: {width}x{height}")
print(f"Isolated macOS {state} Recording Queue UI rendered at {width}x{height}.")
PY
    "$ROOT/scripts/validate-recording-queue-screenshot.swift" "$path" "mac-$state"
}

# Always build the current checkout's Debug target into this disposable root.
# Accepting a caller-supplied app could accidentally launch a Release build,
# where the isolation hooks are absent and real user storage would be visible.
xcodebuild \
    -project "$ROOT/Voxboard.xcodeproj" \
    -scheme 'Voxboard Mac' \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$WORK_ROOT/build.log" 2>&1
APP="$DERIVED_DATA/Build/Products/Debug/Vox.md.app"
EXECUTABLE="$APP/Contents/MacOS/Vox.md"
if [ ! -x "$EXECUTABLE" ]; then
    echo "Runtime validation executable is unavailable: $EXECUTABLE" >&2
    exit 1
fi
if [ "${VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE:-0}" = "1" ]; then
    # A CODE_SIGNING_ALLOWED=NO app cannot obtain TCC microphone identity.
    # Ad-hoc sign only this disposable build with the audio-input entitlement
    # but without App Sandbox, so its isolated /tmp validation root remains
    # writable. This does not touch project signing or provisioning assets.
    cat >"$WORK_ROOT/runtime-microphone.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
PLIST
    codesign --force --deep --sign - \
        --entitlements "$WORK_ROOT/runtime-microphone.entitlements" \
        "$APP" >"$WORK_ROOT/codesign.log" 2>&1
fi

if [ -L "$RUNTIME_PARENT" ]; then
    echo "Refusing symlinked runtime validation parent: $RUNTIME_PARENT" >&2
    exit 1
fi
mkdir -p "$RUNTIME_PARENT"
chmod 700 "$RUNTIME_PARENT"
if [ "$(stat -f '%u:%p' "$RUNTIME_PARENT")" != "$(id -u):40700" ]; then
    echo "Runtime validation parent must be owned by this user with mode 0700" >&2
    exit 1
fi
RUNTIME_ROOT="$(mktemp -d "$RUNTIME_PARENT/mac.XXXXXX")"
RUNTIME_ROOT="$(realpath "$RUNTIME_ROOT")"
RUNTIME_PARENT="$(realpath "$RUNTIME_PARENT")"
if [ -L "$RUNTIME_ROOT" ] \
    || [[ "$RUNTIME_ROOT" != "$RUNTIME_PARENT"/* ]]; then
    echo "Runtime validation root is not a real isolated directory" >&2
    exit 1
fi
mkdir -p "$RUNTIME_ROOT/Recordings"

if [ "${VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE:-0}" = "1" ]; then
    MICROPHONE_RESULT="$RUNTIME_ROOT/runtime-microphone-result.txt"
    VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
        "$EXECUTABLE" --runtime-queue-validation --runtime-microphone-capture \
        >"$WORK_ROOT/microphone.stdout" 2>"$WORK_ROOT/microphone.stderr" &
    APP_PID=$!
    captured=0
    for _ in $(seq 1 400); do
        if [ -s "$MICROPHONE_RESULT" ] \
            && grep -Eq '^(queued|permission-denied|start-failed|queue-timeout)\b' "$MICROPHONE_RESULT"; then
            captured=1
            break
        fi
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            echo "Vox.md exited before real microphone validation completed" >&2
            cat "$WORK_ROOT/microphone.stderr" >&2
            exit 1
        fi
        sleep 0.1
    done
    if [ "$captured" -ne 1 ]; then
        echo "Timed out waiting for real macOS microphone capture" >&2
        if [ -s "$MICROPHONE_RESULT" ]; then
            echo "Last runtime microphone state: $(cat "$MICROPHONE_RESULT")" >&2
        fi
        cat "$WORK_ROOT/microphone.stderr" >&2
        exit 1
    fi
    if grep -qx 'permission-denied' "$MICROPHONE_RESULT"; then
        echo "BLOCKED: the exact disposable Vox.md app was denied macOS Microphone access." >&2
        echo "Grant Vox.md access interactively, then rerun with VOXBOARD_VALIDATE_REAL_MAC_MICROPHONE=1." >&2
        exit 3
    fi
    if ! grep -Eq '^queued [0-9a-f-]{36} [1-9][0-9]*$' "$MICROPHONE_RESULT"; then
        echo "Real macOS microphone validation failed: $(cat "$MICROPHONE_RESULT")" >&2
        exit 1
    fi
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
    rm -rf "$RUNTIME_ROOT"
    mkdir -p "$RUNTIME_ROOT/Recordings"
    echo "Isolated real macOS microphone capture and durable queue handoff passed."
fi

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

FIRST_APP_ARGS=(--runtime-queue-validation)
SCREENSHOT_OUTPUT="${VOXBOARD_RUNTIME_SCREENSHOT_OUTPUT:-}"
QUEUED_SCREENSHOT_OUTPUT=""
COPY_SCREENSHOT_OUTPUT=""
if [ -n "$SCREENSHOT_OUTPUT" ]; then
    screenshot_stem="${SCREENSHOT_OUTPUT%.png}"
    QUEUED_SCREENSHOT_OUTPUT="${screenshot_stem}-queued.png"
    COPY_SCREENSHOT_OUTPUT="${screenshot_stem}-copy.png"
    mkdir -p "$(dirname "$SCREENSHOT_OUTPUT")"
    rm -f "$SCREENSHOT_OUTPUT" "$QUEUED_SCREENSHOT_OUTPUT" "$COPY_SCREENSHOT_OUTPUT"
    FIRST_APP_ARGS+=(
        --localization-screenshot 06-recording-queue
        --localization-screenshot-output "$SCREENSHOT_OUTPUT"
    )
fi
VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
    "$EXECUTABLE" "${FIRST_APP_ARGS[@]}" >"$APP_STDOUT" 2>"$APP_STDERR" &
APP_PID=$!

MANIFEST=""
for _ in $(seq 1 200); do
    MANIFEST="$(find "$RUNTIME_ROOT/Recordings/RecordingJobs/items" \
        -type f -name '*.json' -print -quit 2>/dev/null || true)"
    [ -n "$MANIFEST" ] && break
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "Vox.md exited before recovering the fixture" >&2
        cat "$APP_STDERR" >&2
        exit 1
    fi
    sleep 0.1
done
if [ -z "$MANIFEST" ]; then
    echo "Timed out waiting for the isolated recovery manifest" >&2
    cat "$APP_STDERR" >&2
    exit 1
fi
if [ -n "$SCREENSHOT_OUTPUT" ]; then
    wait_for_screenshot "$SCREENSHOT_OUTPUT" "failed"
fi

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
    raise SystemExit(f"durable queue audio is missing or empty: {audio}")
source = root / "Recordings" / expected["originalFilename"]
if source.exists():
    raise SystemExit(f"external source was not atomically imported: {source}")
print("Isolated macOS app-runtime orphan import passed.")
PY

# Start a real durable claim with a DEBUG-only paused executor, terminate that
# live process, then launch another app against the persisted processing state.
kill "$APP_PID" >/dev/null 2>&1 || true
wait "$APP_PID" >/dev/null 2>&1 || true
APP_PID=""
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
VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
    "$EXECUTABLE" --runtime-queue-validation --runtime-queue-pause-after-claim \
    >"$APP_STDOUT" 2>"$APP_STDERR" &
APP_PID=$!
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
    echo "Timed out waiting for the live macOS queue claim" >&2
    exit 1
fi
kill "$APP_PID" >/dev/null 2>&1 || true
wait "$APP_PID" >/dev/null 2>&1 || true
APP_PID=""
python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
data = json.loads(manifest.read_text())
if data.get("phase") != "processing" or data.get("attemptCount") != 1:
    raise SystemExit("macOS termination did not leave one durable live claim")
data["processingPolicy"] = "manual"
manifest.write_text(json.dumps(data, indent=2, sort_keys=True))
PY

SECOND_APP_ARGS=(--runtime-queue-validation)
if [ -n "$QUEUED_SCREENSHOT_OUTPUT" ]; then
    SECOND_APP_ARGS+=(
        --localization-screenshot 06-recording-queue
        --localization-screenshot-output "$QUEUED_SCREENSHOT_OUTPUT"
    )
fi
VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
    "$EXECUTABLE" "${SECOND_APP_ARGS[@]}" >"$APP_STDOUT" 2>"$APP_STDERR" &
APP_PID=$!
recovered=0
for _ in $(seq 1 200); do
    if python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(
    0 if data.get("phase") == "queued"
    and data.get("statusMessage") == "Recovered after Vox.md was interrupted"
    else 1
)
PY
    then
        recovered=1
        break
    fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "Vox.md exited before restoring the interrupted claim" >&2
        cat "$APP_STDERR" >&2
        exit 1
    fi
    sleep 0.1
done
if [ "$recovered" -ne 1 ]; then
    echo "Timed out waiting for processing-state relaunch recovery" >&2
    cat "$APP_STDERR" >&2
    exit 1
fi
python3 - "$MANIFEST" "$RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
data = json.loads(manifest.read_text())
audio = root / "Recordings" / "RecordingJobs" / "audio" / data["audioFilename"]
if data.get("phase") != "queued":
    raise SystemExit(f"relaunch phase={data.get('phase')!r}, expected 'queued'")
if data.get("statusMessage") != "Recovered after Vox.md was interrupted":
    raise SystemExit(f"unexpected relaunch status: {data.get('statusMessage')!r}")
if not audio.is_file() or audio.stat().st_size <= 0:
    raise SystemExit(f"relaunch recovery lost durable audio: {audio}")
print("Isolated macOS live claimed-job termination and relaunch recovery passed.")
PY
if [ -n "$QUEUED_SCREENSHOT_OUTPUT" ]; then
    wait_for_screenshot "$QUEUED_SCREENSHOT_OUTPUT" "queued"
fi

# If UI evidence was requested, render a completed deferred clipboard result
# from the same durable job. This exercises the explicit Copy state without
# touching the real pasteboard because the control is not activated.
if [ -n "$COPY_SCREENSHOT_OUTPUT" ]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
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
data["transcriptText"] = "Isolated runtime clipboard result"
manifest.write_text(json.dumps(data, indent=2, sort_keys=True))
PY
    VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
        "$EXECUTABLE" --runtime-queue-validation \
        --localization-screenshot 06-recording-queue \
        --localization-screenshot-output "$COPY_SCREENSHOT_OUTPUT" \
        >"$APP_STDOUT" 2>"$APP_STDERR" &
    APP_PID=$!
    wait_for_screenshot "$COPY_SCREENSHOT_OUTPUT" "copy-ready"
fi

# Finally, place the same durable job back in immediate queued state and start
# two real app processes against one isolated container. The flock worker lease
# must permit exactly one claim/attempt even though both processes request a
# drain.
kill "$APP_PID" >/dev/null 2>&1 || true
wait "$APP_PID" >/dev/null 2>&1 || true
APP_PID=""
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
data["transcriptText"] = None
data["delivery"] = {"recovery": {}}
data["modelID"] = "missing-runtime-validation-model"
manifest.write_text(json.dumps(data, indent=2, sort_keys=True))
PY

VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
    "$EXECUTABLE" --runtime-queue-validation >"$WORK_ROOT/worker-one.stdout" \
    2>"$WORK_ROOT/worker-one.stderr" &
APP_PID=$!
VOXBOARD_SHARED_CONTAINER_OVERRIDE="$RUNTIME_ROOT" \
    "$EXECUTABLE" --runtime-queue-validation >"$WORK_ROOT/worker-two.stdout" \
    2>"$WORK_ROOT/worker-two.stderr" &
SECOND_APP_PID=$!
sleep 0.2
for pid in "$APP_PID" "$SECOND_APP_PID"; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "A concurrent Vox.md validation process exited unexpectedly" >&2
        exit 1
    fi
done
failed=0
for _ in $(seq 1 300); do
    if python3 - "$MANIFEST" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(
    0 if data.get("phase") == "failed" and data.get("attemptCount") == 1 else 1
)
PY
    then
        failed=1
        break
    fi
    sleep 0.1
done
if [ "$failed" -ne 1 ]; then
    echo "Timed out waiting for the isolated concurrent worker attempt" >&2
    cat "$WORK_ROOT/worker-one.stderr" "$WORK_ROOT/worker-two.stderr" >&2
    exit 1
fi
# Give the second worker ample time to acquire the handed-off lease. It must
# observe the terminal failed phase rather than claiming the same job again.
sleep 1
python3 - "$MANIFEST" "$RUNTIME_ROOT" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
data = json.loads(manifest.read_text())
if data.get("phase") != "failed" or data.get("attemptCount") != 1:
    raise SystemExit(
        f"duplicate cross-process execution: phase={data.get('phase')!r}, "
        f"attemptCount={data.get('attemptCount')!r}"
    )
audio = root / "Recordings" / "RecordingJobs" / "audio" / data["audioFilename"]
if not audio.is_file() or audio.stat().st_size <= 0:
    raise SystemExit(f"concurrent worker failure lost durable audio: {audio}")
print("Isolated macOS two-process worker lease passed.")
PY
