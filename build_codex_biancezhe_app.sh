#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Codex Taskmaster"
APP_DIR="${ROOT}/${APP_NAME}.app"
BIN_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"
BIN_PATH="${BIN_DIR}/CodexTaskmaster"
ICONSET_DIR="${ROOT}/CodexBianCeZhe.iconset"
ICON_PNG="${ROOT}/CodexBianCeZhe-1024.png"
ICON_ICNS="${RES_DIR}/AppIcon.icns"
HELPER_SRC="${ROOT}/codex_terminal_sender.sh"
HELPER_DST="${RES_DIR}/codex_terminal_sender.sh"

mkdir -p "$BIN_DIR" "$RES_DIR"

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

swift -sdk "$SDK_PATH" "$ROOT/generate_icon.swift" "$ICON_PNG"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"

cp "$HELPER_SRC" "$HELPER_DST"
chmod 755 "$HELPER_DST"

swiftc \
  -O \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -o "$BIN_PATH" \
  "$ROOT/CodexBianCeZheApp.swift"

cat >"${APP_DIR}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleDisplayName</key>
  <string>Codex Taskmaster</string>
  <key>CFBundleExecutable</key>
  <string>CodexTaskmaster</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.codex-taskmaster</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Codex Taskmaster</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' >"${APP_DIR}/Contents/PkgInfo"

touch "$APP_DIR"

echo "Built app at: $APP_DIR"
