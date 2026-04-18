#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_BIN="$(mktemp "${TMPDIR:-/tmp}/taskmaster-core-regression.XXXXXX")"
cleanup() {
  rm -f "$OUTPUT_BIN"
}
trap cleanup EXIT

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
  swiftc -sdk "$SDK_PATH" \
    "$ROOT_DIR/TaskMasterCore.swift" \
    "$ROOT_DIR/tests/taskmaster_core_regression.swift" \
    -o "$OUTPUT_BIN"
else
  swiftc \
    "$ROOT_DIR/TaskMasterCore.swift" \
    "$ROOT_DIR/tests/taskmaster_core_regression.swift" \
    -o "$OUTPUT_BIN"
fi

"$OUTPUT_BIN"
