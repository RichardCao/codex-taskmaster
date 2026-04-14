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

if [[ -n "$SDK_PATH" ]]; then
  xcrun swiftc -sdk "$SDK_PATH" -warnings-as-errors -typecheck "${APP_SWIFT_SOURCES[@]}"
else
  xcrun swiftc -warnings-as-errors -typecheck "${APP_SWIFT_SOURCES[@]}"
fi

printf '==> build app\n'
"${ROOT}/build_codex_taskmaster_app.sh"

printf 'all checks passed\n'
