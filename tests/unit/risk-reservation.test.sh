#!/usr/bin/env bash
# Offline process-level tests: every Coinbase executable is an isolated stub.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/unit/risk-reservation.py
