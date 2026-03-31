#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

printf '==> core checks\n'
bash "${ROOT}/scripts/check.sh"

if [[ "${CODEX_TASKMASTER_RUN_UI_SMOKE:-0}" == "1" ]]; then
  printf '==> ui smoke test\n'
  bash "${ROOT}/scripts/ui_smoke_test.sh"
else
  printf '==> ui smoke test skipped (set CODEX_TASKMASTER_RUN_UI_SMOKE=1 to enable)\n'
fi
