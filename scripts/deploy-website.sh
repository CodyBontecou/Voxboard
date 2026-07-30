#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

wrangler pages deploy "$REPO_ROOT/website" --project-name voxboard

if command -v indexnow >/dev/null 2>&1; then
  indexnow submit-sitemap vox.isolated.tech --recent-days 7 --confirm
else
  printf '%s\n' 'warning: indexnow CLI not found; production deployed without URL notification' >&2
fi
