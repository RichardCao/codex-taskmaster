#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SWIFT_SOURCES=(
  "${ROOT}/TaskMasterCore.swift"
  "${ROOT}/CodexTaskmasterApp.swift"
  "${ROOT}/TaskMasterSendRuntime.swift"
  "${ROOT}/main.swift"
)

run_step() {
  local label="$1"
  shift
  printf '==> %s\n' "$label"
  "$@"
}

run_step "shell syntax" bash -n "${ROOT}/codex_terminal_sender.sh"

run_step "helper smoke tests" bash "${ROOT}/tests/test_helper_smoke.sh"

run_step "taskmaster core regression" bash "${ROOT}/tests/test_taskmaster_core.sh"

run_step "loop history regression" bash "${ROOT}/tests/test_loop_history_model.sh"

SDK_PATH="${MACOS_SDK_PATH:-}"
if [[ -z "$SDK_PATH" ]]; then
  for sdk_root in \
    "$(xcode-select -p 2>/dev/null)/Platforms/MacOSX.platform/Developer/SDKs" \
    /Library/Developer/CommandLineTools/SDKs
  do
    [[ -d "$sdk_root" ]] || continue
    SDK_PATH="$(
      find "$sdk_root" -maxdepth 1 -type d \
        \( -name 'MacOSX15*.sdk' -o -name 'MacOSX14*.sdk' \) \
        | sort -V \
        | tail -n 1
    )"
    [[ -n "$SDK_PATH" ]] && break
  done
fi
if [[ -z "$SDK_PATH" ]]; then
  SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
fi

printf '==> swift typecheck\n'
if [[ -n "$SDK_PATH" ]]; then
  xcrun swiftc -sdk "$SDK_PATH" -warnings-as-errors -typecheck "${APP_SWIFT_SOURCES[@]}"
else
  xcrun swiftc -warnings-as-errors -typecheck "${APP_SWIFT_SOURCES[@]}"
fi

run_step "build app" "${ROOT}/build_codex_taskmaster_app.sh"

printf 'all checks passed\n'
