#!/usr/bin/env bash
set -euo pipefail
workspace="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$workspace/../.." && pwd)"
# Python's default Linux cache location is inside the checkout. Hosted evidence
# imports tracked validators but must leave the authenticated source tree pristine.
export PYTHONDONTWRITEBYTECODE=1
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "error: hosted M2 evidence requires GitHub Actions" >&2; exit 1; }
[[ "${GITHUB_JOB:-}" == m2-evidence ]] || { echo "error: hosted M2 evidence requires the canonical m2-evidence job" >&2; exit 1; }
[[ "${GITHUB_WORKSPACE:-}" == "$repo" ]] || { echo "error: hosted M2 evidence workspace mismatch" >&2; exit 1; }
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] || { echo "error: hosted M2 evidence requires a clean checkout" >&2; exit 1; }
root="${RUNNER_TEMP:?RUNNER_TEMP is required}/vox-m2-evidence"
campaign="$root/campaign"; external="$root/external"
export VOX_M2_EVIDENCE_STARTED_AT="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
PY
)"
rm -rf "$root"; mkdir -p "$campaign/evidence" "$campaign/approvals" "$campaign/artifacts" "$external"
producer="$repo/Packages/vox-core-rust/scripts/run-m2-core-exit-evidence.py"
python3 "$producer" execute-core --repository-root "$repo" --campaign-dir "$campaign" --external-root "$external"
"$repo/Packages/vox-core-rust/scripts/run-m2-materialization-evidence.sh" "$campaign" "$external"
"$repo/Packages/vox-core-rust/scripts/build-m2-native-evidence.sh" "$campaign" "$external"
python3 "$producer" archive --repository-root "$repo" --campaign-dir "$campaign" --external-root "$external" --archive-relative archives/m2-evidence.tar
python3 "$producer" finalize --repository-root "$repo" --campaign-dir "$campaign" --external-root "$external" --archive-relative archives/m2-evidence.tar
python3 "$repo/Packages/contracts/scripts/validate_validation_definitions.py" \
  --campaign-dir "$campaign" --repository-root "$repo" --qualification hostedRun --external-artifact-root "$external"
printf 'M2_EVIDENCE_ROOT=%s\nM2_EVIDENCE_CAMPAIGN=%s\nM2_EVIDENCE_EXTERNAL=%s\n' "$root" "$campaign" "$external" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
