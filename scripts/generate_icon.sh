#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_PATH="${1:-${ROOT}/CodexTaskmaster-1024.png}"

resolve_sdk_path() {
  if [[ -n "${MACOS_SDK_PATH:-}" ]]; then
    printf '%s\n' "$MACOS_SDK_PATH"
    return 0
  fi

  local sdk_dir="/Library/Developer/CommandLineTools/SDKs"
  local preferred=""

  if [[ -d "$sdk_dir" ]]; then
    preferred="$(
      find "$sdk_dir" -maxdepth 1 -type d \
        \( -name 'MacOSX15*.sdk' -o -name 'MacOSX14*.sdk' \) \
        | sort -V \
        | tail -n 1
    )"
  fi

  if [[ -n "$preferred" ]]; then
    printf '%s\n' "$preferred"
    return 0
  fi

  xcrun --sdk macosx --show-sdk-path
}

SDK_PATH="$(resolve_sdk_path)"

swift -sdk "$SDK_PATH" "${ROOT}/generate_icon.swift" -- "$OUTPUT_PATH"

if [[ ! -f "$OUTPUT_PATH" ]]; then
  echo "failed to generate icon png at: $OUTPUT_PATH" >&2
  exit 1
fi

echo "Generated icon at: $OUTPUT_PATH"
