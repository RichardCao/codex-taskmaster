#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${CODEX_TASKMASTER_APP_PATH:-${ROOT}/Codex Taskmaster.app}"
APP_NAME="${CODEX_TASKMASTER_APP_NAME:-Codex Taskmaster}"
WINDOW_TITLE="${CODEX_TASKMASTER_WINDOW_TITLE:-Codex Taskmaster}"
LAUNCH_TIMEOUT_SECONDS="${CODEX_TASKMASTER_UI_TIMEOUT_SECONDS:-15}"

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    printf '%s command not found\n' "$cmd" >&2
    exit 1
  }
}

cleanup() {
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
}

require_cmd open
require_cmd osascript

if [[ ! -d "$APP_PATH" ]]; then
  printf 'App bundle not found, building first: %s\n' "$APP_PATH"
  "${ROOT}/build_code_taskmaster_app.sh"
fi

trap cleanup EXIT

printf 'Launching app: %s\n' "$APP_PATH"
open -na "$APP_PATH"

printf 'Waiting for main window to appear...\n'
python3 - "$LAUNCH_TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys
import time

timeout = float(sys.argv[1])
deadline = time.time() + timeout
script = r'''
on run argv
  set processName to item 1 of argv
  set expectedTitle to item 2 of argv
  tell application "System Events"
    if not (exists process processName) then
      error "process not running"
    end if
    tell process processName
      if (count of windows) is 0 then
        error "no windows"
      end if
      set frontName to name of front window
      if frontName is not expectedTitle then
        error "unexpected window title: " & frontName
      end if
      return frontName
    end tell
  end tell
end run
'''

while time.time() < deadline:
    completed = subprocess.run(
        ["osascript", "-", "Codex Taskmaster", "Codex Taskmaster"],
        input=script,
        capture_output=True,
        text=True,
    )
    if completed.returncode == 0:
        print(completed.stdout.strip() or "window-ok")
        sys.exit(0)
    time.sleep(0.5)

stderr = completed.stderr.strip() if 'completed' in locals() else "timed out"
if "not allowed assistive access" in stderr.lower() or "不允许发送按键" in stderr:
    print("UI smoke test requires Accessibility permission for System Events.", file=sys.stderr)
else:
    print(f"UI smoke test failed: {stderr or 'window did not appear in time'}", file=sys.stderr)
sys.exit(1)
PY

printf 'App window is visible.\n'
