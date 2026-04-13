#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SWIFT_SOURCES=(
  "${ROOT}/TaskMasterCore.swift"
  "${ROOT}/CodexTaskmasterApp.swift"
  "${ROOT}/TaskMasterSendRuntime.swift"
  "${ROOT}/main.swift"
)

printf '==> shell syntax\n'
bash -n "${ROOT}/codex_terminal_sender.sh"

printf '==> helper smoke tests\n'
bash "${ROOT}/tests/test_helper_smoke.sh"

printf '==> swift typecheck\n'
SDK_PATH="${MACOS_SDK_PATH:-}"
if [[ -z "$SDK_PATH" ]]; then
  for candidate in \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk \
    /Library/Developer/CommandLineTools/SDKs/MacOSX14.sdk
  do
    if [[ -d "$candidate" ]]; then
      SDK_PATH="$candidate"
      break
    fi
  done
fi

if [[ -n "$SDK_PATH" ]]; then
  swiftc -sdk "$SDK_PATH" -warnings-as-errors -typecheck "${APP_SWIFT_SOURCES[@]}"
else
  swiftc -warnings-as-errors -typecheck "${APP_SWIFT_SOURCES[@]}"
fi

printf '==> build app\n'
"${ROOT}/build_codex_taskmaster_app.sh"

printf 'all checks passed\n'
