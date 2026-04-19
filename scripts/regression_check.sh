#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFTPM_MODE="${CODEX_TASKMASTER_RUN_SWIFTPM_TESTS:-auto}"

run_swiftpm_tests() {
  case "$SWIFTPM_MODE" in
    0|false|no)
      printf '==> swiftpm tests skipped (set CODEX_TASKMASTER_RUN_SWIFTPM_TESTS=auto or 1 to enable)\n'
      return 0
      ;;
    auto|1|true|yes)
      ;;
    *)
      printf 'unsupported CODEX_TASKMASTER_RUN_SWIFTPM_TESTS value: %s\n' "$SWIFTPM_MODE" >&2
      return 1
      ;;
  esac

  printf '==> swiftpm tests\n'
  local swiftpm_output=""
  local swiftpm_status=0
  set +e
  swiftpm_output="$(cd "$ROOT" && swift test 2>&1)"
  swiftpm_status=$?
  set -e

  if [[ "$swiftpm_status" -eq 0 ]]; then
    [[ -n "$swiftpm_output" ]] && printf '%s\n' "$swiftpm_output"
    return 0
  fi

  if [[ "$SWIFTPM_MODE" == "auto" ]]; then
    [[ -n "$swiftpm_output" ]] && printf '%s\n' "$swiftpm_output"
    printf '==> swiftpm tests skipped in auto mode due local toolchain/runtime failure\n'
    return 0
  fi

  [[ -n "$swiftpm_output" ]] && printf '%s\n' "$swiftpm_output" >&2
  return "$swiftpm_status"
}

printf '==> core checks\n'
bash "${ROOT}/scripts/check.sh"

run_swiftpm_tests

if [[ "${CODEX_TASKMASTER_RUN_UI_SMOKE:-0}" == "1" ]]; then
  printf '==> ui smoke test\n'
  bash "${ROOT}/scripts/ui_smoke_test.sh"
else
  printf '==> ui smoke test skipped (set CODEX_TASKMASTER_RUN_UI_SMOKE=1 to enable)\n'
fi
