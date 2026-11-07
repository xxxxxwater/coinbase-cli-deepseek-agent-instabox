#!/usr/bin/env bash
# Session lifecycle regression: no real CLI or Telegram calls.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
node "$ROOT/tests/unit/session.node.mjs"
