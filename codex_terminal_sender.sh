#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

APP_NAME="codex-terminal-sender"
DEFAULT_INTERVAL=600
DEFAULT_MESSAGE="继续"
PASTE_DELAY_SECONDS="${CODEX_TASKMASTER_PASTE_DELAY_SECONDS:-0.35}"
SUBMIT_DELAY_SECONDS="${CODEX_TASKMASTER_SUBMIT_DELAY_SECONDS:-0.90}"
RESTORE_CLIPBOARD_DELAY_SECONDS="${CODEX_TASKMASTER_RESTORE_CLIPBOARD_DELAY_SECONDS:-1.20}"
LOOP_POST_SEND_COOLDOWN_SECONDS="${CODEX_TASKMASTER_LOOP_POST_SEND_COOLDOWN_SECONDS:-1.50}"
PROBE_RECENT_LOG_WINDOW_SECONDS="${CODEX_TASKMASTER_PROBE_RECENT_LOG_WINDOW_SECONDS:-45}"
SEND_STABLE_IDLE_SECONDS="${CODEX_TASKMASTER_SEND_STABLE_IDLE_SECONDS:-2}"
SEND_IDLE_TIMEOUT_SECONDS="${CODEX_TASKMASTER_SEND_IDLE_TIMEOUT_SECONDS:-20}"
LOOP_IDLE_TIMEOUT_SECONDS="${CODEX_TASKMASTER_LOOP_IDLE_TIMEOUT_SECONDS:-12}"
LOOP_BUSY_RETRY_SECONDS="${CODEX_TASKMASTER_LOOP_BUSY_RETRY_SECONDS:-5}"
LOOP_FAILURE_PAUSE_THRESHOLD="${CODEX_TASKMASTER_LOOP_FAILURE_PAUSE_THRESHOLD:-5}"
LOOP_ACCEPTED_RETRY_SECONDS="${CODEX_TASKMASTER_LOOP_ACCEPTED_RETRY_SECONDS:-30}"
LOOP_UNVERIFIED_RETRY_SECONDS="${CODEX_TASKMASTER_LOOP_UNVERIFIED_RETRY_SECONDS:-20}"
LOOP_FORCE_FAILURE_RETRY_SECONDS="${CODEX_TASKMASTER_LOOP_FORCE_FAILURE_RETRY_SECONDS:-15}"
REQUEST_STALE_GRACE_SECONDS="${CODEX_TASKMASTER_REQUEST_STALE_GRACE_SECONDS:-120}"

resolve_home_dir() {
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi

  local inferred_home=""
  inferred_home="$(cd ~ 2>/dev/null && pwd)" || true
  [[ -n "$inferred_home" ]] || die "HOME is not set and could not be inferred"
  printf '%s\n' "$inferred_home"
}

HOME_DIR="$(resolve_home_dir)"
export HOME="$HOME_DIR"

STATE_DIR="${CODEX_TASKMASTER_STATE_DIR:-${HOME_DIR}/.codex-terminal-sender}"
REQUESTS_DIR="${STATE_DIR}/requests"
PENDING_REQUEST_DIR="${REQUESTS_DIR}/pending"
PROCESSING_REQUEST_DIR="${REQUESTS_DIR}/processing"
RESULT_REQUEST_DIR="${REQUESTS_DIR}/results"
LOOPS_DIR="${STATE_DIR}/loops"
RUNTIME_DIR="${STATE_DIR}/runtime"
LOOP_STATE_DIR="${RUNTIME_DIR}/user-loop-state"
LOOP_LOG_DIR="${RUNTIME_DIR}/loop-logs"
LOOP_RUNNER_DIR="${RUNTIME_DIR}/loop-runners"
LOOP_DAEMON_PID_FILE="${RUNTIME_DIR}/loop-daemon.pid"
LOOP_DAEMON_LOG_FILE="${RUNTIME_DIR}/loop-daemon.log"
CODEX_STATE_DB_PATH="${CODEX_TASKMASTER_CODEX_STATE_DB_PATH:-${HOME_DIR}/.codex/state_5.sqlite}"
CODEX_SESSION_INDEX_PATH="${CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH:-${CODEX_TASKMASTER_SESSION_INDEX_PATH:-${HOME_DIR}/.codex/session_index.jsonl}}"
CODEX_LOGS_DB_PATH="${CODEX_TASKMASTER_CODEX_LOGS_DB_PATH:-${HOME_DIR}/.codex/logs_1.sqlite}"
CODEX_CONFIG_PATH="${CODEX_TASKMASTER_CODEX_CONFIG_PATH:-${HOME_DIR}/.codex/config.toml}"
CODEX_BIN_PATH="${CODEX_TASKMASTER_CODEX_BIN_PATH:-codex}"

mkdir -p "$STATE_DIR" "$REQUESTS_DIR" "$PENDING_REQUEST_DIR" "$PROCESSING_REQUEST_DIR" "$RESULT_REQUEST_DIR" "$LOOPS_DIR" "$RUNTIME_DIR" "$LOOP_STATE_DIR" "$LOOP_LOG_DIR" "$LOOP_RUNNER_DIR"

usage() {
  cat <<'EOF'
Usage:
  codex_terminal_sender.sh send        -t TARGET [-m MESSAGE] [-f]
  codex_terminal_sender.sh start       -t TARGET [-m MESSAGE] [-i SECONDS] [-f]
  codex_terminal_sender.sh stop        [-t TARGET | -k LOOP_ID | --all]
  codex_terminal_sender.sh loop-delete [-t TARGET | -k LOOP_ID]
  codex_terminal_sender.sh loop-save-stopped -t TARGET [-k LOOP_ID] [-m MESSAGE] [-i SECONDS] [-f] [-r REASON]
  codex_terminal_sender.sh status      [-t TARGET | -k LOOP_ID]
  codex_terminal_sender.sh probe       -t TARGET
  codex_terminal_sender.sh resolve-thread-id -t TARGET
  codex_terminal_sender.sh resolve-live-tty -t TARGET
  codex_terminal_sender.sh probe-all   [-l LIMIT] [-o OFFSET]
  codex_terminal_sender.sh session-count
  codex_terminal_sender.sh thread-name-set -t THREAD_ID -n NAME
  codex_terminal_sender.sh thread-archive  -t THREAD_ID
  codex_terminal_sender.sh thread-unarchive -t THREAD_ID
  codex_terminal_sender.sh thread-delete -t THREAD_ID
  codex_terminal_sender.sh thread-delete-plan -t THREAD_ID
  codex_terminal_sender.sh thread-family-plan -t THREAD_ID
  codex_terminal_sender.sh thread-list [--archived]
  codex_terminal_sender.sh thread-provider-plan -t THREAD_ID -p PROVIDER
  codex_terminal_sender.sh thread-provider-plan-all -p PROVIDER
  codex_terminal_sender.sh thread-provider-migrate -t THREAD_ID -p PROVIDER [--family]
  codex_terminal_sender.sh thread-provider-migrate-all -p PROVIDER
  codex_terminal_sender.sh config-model-provider
  codex_terminal_sender.sh wait-idle   -t TARGET [-s SECONDS] [-w SECONDS]
  codex_terminal_sender.sh loop-once
  codex_terminal_sender.sh loop-resume [-t TARGET | -k LOOP_ID]
  codex_terminal_sender.sh loop-daemon

Commands:
  send        Send one message to the matching Terminal tab via GUI paste + Return
  start       Create or update a repeating loop
  stop        Mark one loop as stopped by target or loop id, or all loops with --all
  loop-delete Remove one loop entry from local Active Loops state
  loop-save-stopped
              Save one loop entry directly in stopped state
  status      Show one loop status by target or loop id, or all loop statuses
  probe       Inspect the local Codex rollout/log state for one target
  resolve-thread-id
              Resolve one target to a unique Codex thread id
  resolve-live-tty
              Resolve the current live Terminal TTY for one target
  probe-all   Inspect known Codex sessions and summarize their statuses
  session-count
              Print the total number of non-archived Codex sessions
  thread-name-set
              Set a session name via Codex's native app-server API
  thread-archive
              Archive a session via Codex's native app-server API
  thread-unarchive
              Restore an archived session via Codex's native app-server API
  thread-delete
              Permanently delete a session from local Codex state and remove its rollout file
  thread-delete-plan
              Inspect which local artifacts would be removed by one permanent delete
  thread-family-plan
              Inspect one session's parent/child relationship in local state
  thread-list
              List Codex sessions via the native app-server API
  thread-provider-plan
              Inspect one session's provider migration scope
  thread-provider-plan-all
              Preview how many local sessions would migrate to one provider
  thread-provider-migrate
              Migrate one session, or one related family, to one provider in local state
  thread-provider-migrate-all
              Migrate all local sessions to one provider in local state
  config-model-provider
              Read model_provider from the current Codex config.toml
  wait-idle   Wait until the target appears stably idle
  loop-once   Internal command: run one loop scheduling tick
  loop-resume Clear a paused loop state and reschedule it immediately
  loop-daemon Internal command: user-owned background loop runner
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd command not found"
}

is_uuid_like() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

hash_target() {
  local target="$1"
  printf '%s' "$target" | shasum -a 256 | awk '{print $1}'
}

generate_loop_key() {
  local target="$1"
  printf '%s|%s|%s|%s\n' "$target" "$(date +%s)" "$$" "$RANDOM" | shasum -a 256 | awk '{print $1}'
}

paths_for_target() {
  local key="$1"
  LOOP_FILE="${LOOPS_DIR}/${key}.loop"
  LOOP_STATUS_FILE="${LOOP_STATE_DIR}/${key}.state"
  LOOP_LOG_FILE="${LOOP_LOG_DIR}/${key}.log"
  LOOP_RUNNER_PID_FILE="${LOOP_RUNNER_DIR}/${key}.pid"
}

loop_source_tag() {
  loop_source_tag_for_file "$LOOP_FILE"
}

loop_source_tag_for_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import os
import sys

path = sys.argv[1]
try:
    stat_result = os.stat(path)
except FileNotFoundError:
    print("missing")
    raise SystemExit(0)

print(f"{stat_result.st_mtime_ns}:{stat_result.st_size}")
PY
}

load_kv_file() {
  local file="$1"
  validate_kv_file_for_loading "$file"
  # shellcheck disable=SC1090
  source "$file"
}

validate_kv_file_for_loading() {
  local file="$1"
  require_cmd python3
  python3 - "$file" "$STATE_DIR" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
state_dir = os.path.realpath(sys.argv[2])

loop_root = os.path.realpath(os.path.join(state_dir, "loops"))
state_root = os.path.realpath(os.path.join(state_dir, "runtime", "user-loop-state"))

allowed_keys_by_suffix = {
    ".loop": {"LOOP_ID", "TARGET", "INTERVAL", "MESSAGE", "FORCE_SEND", "THREAD_ID"},
    ".state": {
        "STATE_TAG",
        "NEXT_RUN",
        "FAILURE_COUNT",
        "FAILURE_REASON",
        "PAUSED",
        "PAUSED_REASON",
        "STOPPED",
        "STOPPED_REASON",
    },
}

forbidden_unescaped = set(" \t\r\n\"'`$;&|<>(){}*?[]!")

def fail(message: str) -> None:
    raise SystemExit(message)

def within_root(real_path: str, root: str) -> bool:
    try:
        return os.path.commonpath([real_path, root]) == root
    except ValueError:
        return False

def ansi_c_quoted_safe(value: str) -> bool:
    if len(value) < 3 or not value.startswith("$'") or not value.endswith("'"):
        return False
    body = value[2:-1]
    idx = 0
    while idx < len(body):
        char = body[idx]
        if char == "\\":
            idx += 2
            continue
        if char == "'":
            return False
        idx += 1
    return True

def bare_value_safe(value: str) -> bool:
    if value == "":
        return True
    idx = 0
    while idx < len(value):
        char = value[idx]
        if char == "\\":
            if idx + 1 >= len(value):
                return False
            idx += 2
            continue
        if char in forbidden_unescaped:
            return False
        idx += 1
    return True

real_path = os.path.realpath(path)
if os.path.islink(path):
    fail(f"unsafe kv file: symlink not allowed: {path}")
if not os.path.exists(path):
    fail(f"kv file not found: {path}")

st = os.stat(path)
if not stat.S_ISREG(st.st_mode):
    fail(f"unsafe kv file: not a regular file: {path}")
if st.st_size > 65536:
    fail(f"unsafe kv file: file too large: {path}")

suffix = os.path.splitext(path)[1]
allowed_keys = allowed_keys_by_suffix.get(suffix)
if allowed_keys is None:
    fail(f"unsafe kv file: unsupported suffix: {path}")

if suffix == ".loop":
    if not within_root(real_path, loop_root):
        fail(f"unsafe kv file: outside loop root: {path}")
else:
    if not within_root(real_path, state_root):
        fail(f"unsafe kv file: outside state root: {path}")

with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
    for line_number, raw_line in enumerate(fh, start=1):
        line = raw_line.rstrip("\n")
        if not line:
            continue
        if "=" not in line:
            fail(f"unsafe kv file: malformed line {line_number}: {path}")
        key, value = line.split("=", 1)
        if key not in allowed_keys:
            fail(f"unsafe kv file: unexpected key {key!r} in {path}")
        if value == "''":
            continue
        if ansi_c_quoted_safe(value):
            continue
        if bare_value_safe(value):
            continue
        fail(f"unsafe kv file: unsupported value syntax for {key!r} in {path}")
PY
}

write_kv_file() {
  local file="$1"
  shift
  local tmp
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/${APP_NAME}.kv.XXXXXX")"
  {
    while [[ $# -gt 0 ]]; do
      local key="$1"
      local value="$2"
      printf '%s=%q\n' "$key" "$value"
      shift 2
    done
  } >"$tmp"
  mv "$tmp" "$file"
}

write_loop_status_kv() {
  local source_tag="$1"
  local next_run="$2"
  local failure_count="$3"
  local failure_reason="$4"
  local paused="$5"
  local paused_reason="$6"
  local stopped="$7"
  local stopped_reason="$8"
  write_kv_file "$LOOP_STATUS_FILE" \
    STATE_TAG "$source_tag" \
    NEXT_RUN "$next_run" \
    FAILURE_COUNT "$failure_count" \
    FAILURE_REASON "$failure_reason" \
    PAUSED "$paused" \
    PAUSED_REASON "$paused_reason" \
    STOPPED "$stopped" \
    STOPPED_REASON "$stopped_reason"
}

load_current_loop_status_file() {
  local source_tag="$1"

  STATE_TAG=""
  NEXT_RUN=""
  FAILURE_COUNT=""
  FAILURE_REASON=""
  PAUSED=""
  PAUSED_REASON=""
  STOPPED=""
  STOPPED_REASON=""

  [[ -f "$LOOP_STATUS_FILE" ]] || return 1
  load_kv_file "$LOOP_STATUS_FILE"
  [[ "${STATE_TAG:-}" == "$source_tag" ]]
}

write_loop_definition() {
  local loop_id="$1"
  shift
  local target="$1"
  local interval="$2"
  local message="$3"
  local force_send="${4:-0}"
  local thread_id="${5:-}"
  write_kv_file "$LOOP_FILE" \
    LOOP_ID "$loop_id" \
    TARGET "$target" \
    INTERVAL "$interval" \
    MESSAGE "$message" \
    FORCE_SEND "$force_send" \
    THREAD_ID "$thread_id"
  touch "$LOOP_LOG_FILE" 2>/dev/null || true
}

classify_loop_reason() {
  local detail="$1"
  if [[ "$detail" == *"found multiple matching sessions for target"* ]] || [[ "$detail" == *"found multiple matching thread titles for target"* ]] || [[ "$detail" == *"found multiple matching Terminal ttys for target"* ]]; then
    printf 'ambiguous_target\n'
  elif [[ "$detail" == *"tty not found"* ]] || [[ "$detail" == *"could not find a running 'codex resume"* ]] || [[ "$detail" == *"could not find a running non-resume 'codex' process"* ]] || [[ "$detail" == *"has no cwd metadata"* ]] || [[ "$detail" == *"tty unavailable"* ]]; then
    printf 'tty_unavailable\n'
  else
    printf 'start_failed\n'
  fi
}

mark_loop_stopped_entry() {
  local target="$1"
  local interval="$2"
  local message="$3"
  local force_send="${4:-0}"
  local stopped_reason="${5:-stopped_by_user}"
  local log_message="${6:-}"
  local thread_id="${7:-}"
  local key
  local source_tag

  key="$(generate_loop_key "$target")"
  paths_for_target "$key"
  write_loop_definition "$key" "$target" "$interval" "$message" "$force_send" "$thread_id"
  source_tag="$(loop_source_tag)"
  write_loop_status_kv "$source_tag" "" "0" "" "0" "" "1" "$stopped_reason"
  if [[ -n "$log_message" ]]; then
    append_loop_log_line "$LOOP_LOG_FILE" "$log_message"
  fi
}

resolve_loop_key() {
  local target="${1:-}"
  local loop_id="${2:-}"
  local loop_file
  local key
  local source_tag
  local matched_key=""
  local fallback_key=""

  if [[ -n "$loop_id" ]]; then
    if [[ -f "${LOOPS_DIR}/${loop_id}.loop" ]]; then
      printf '%s\n' "$loop_id"
      return 0
    fi

    shopt -s nullglob
    for loop_file in "$LOOPS_DIR"/*.loop; do
      key="$(basename "${loop_file%.loop}")"
      LOOP_ID=""
      load_kv_file "$loop_file"
      if [[ "${LOOP_ID:-}" == "$loop_id" ]]; then
        printf '%s\n' "$key"
        shopt -u nullglob
        return 0
      fi
    done
    shopt -u nullglob
    return 1
  fi

  [[ -n "$target" ]] || return 1

  key="$(hash_target "$target")"
  if [[ -f "${LOOPS_DIR}/${key}.loop" ]]; then
    paths_for_target "$key"
    if load_current_loop_status_file "$(loop_source_tag)" >/dev/null 2>&1; then
      if [[ "${STOPPED:-0}" != "1" && "${PAUSED:-0}" != "1" ]]; then
        printf '%s\n' "$key"
        return 0
      fi
    fi
    fallback_key="$key"
  fi

  shopt -s nullglob
  for loop_file in "$LOOPS_DIR"/*.loop; do
    key="$(basename "${loop_file%.loop}")"
    TARGET=""
    load_kv_file "$loop_file"
    [[ "${TARGET:-}" == "$target" ]] || continue
    paths_for_target "$key"
    source_tag="$(loop_source_tag)"
    if load_current_loop_status_file "$source_tag" >/dev/null 2>&1; then
      if [[ "${STOPPED:-0}" != "1" && "${PAUSED:-0}" != "1" ]]; then
        matched_key="$key"
        break
      fi
    fi
    [[ -n "$fallback_key" ]] || fallback_key="$key"
  done
  shopt -u nullglob

  if [[ -n "$matched_key" ]]; then
    printf '%s\n' "$matched_key"
    return 0
  fi
  if [[ -n "$fallback_key" ]]; then
    printf '%s\n' "$fallback_key"
    return 0
  fi
  return 1
}

find_conflicting_running_loop_target() {
  local thread_id="$1"
  local current_key="${2:-}"
  local require_higher_priority="${3:-0}"
  local loop_file
  local key

  [[ -n "$thread_id" ]] || return 1

  shopt -s nullglob
  for loop_file in "$LOOPS_DIR"/*.loop; do
    key="$(basename "${loop_file%.loop}")"
    [[ -n "$current_key" && "$key" == "$current_key" ]] && continue
    paths_for_target "$key"
    TARGET=""
    INTERVAL=""
    MESSAGE=""
    FORCE_SEND="0"
    THREAD_ID=""
    load_kv_file "$loop_file"
    [[ "${THREAD_ID:-}" == "$thread_id" ]] || continue

    load_current_loop_status_file "$(loop_source_tag)" >/dev/null 2>&1 || true
    [[ "${STOPPED:-0}" == "1" ]] && continue
    [[ "${PAUSED:-0}" == "1" ]] && continue
    if [[ "$require_higher_priority" == "1" && -n "$current_key" && "$key" > "$current_key" ]]; then
      continue
    fi

    printf '%s\n' "${TARGET:-$key}"
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

accepted_retry_delay_seconds() {
  local interval="$1"
  local accepted_reason="$2"
  local delay="$interval"

  case "$accepted_reason" in
    queued_pending_feedback|verification_pending|request_already_inflight)
      if (( LOOP_ACCEPTED_RETRY_SECONDS > delay )); then
        delay="$LOOP_ACCEPTED_RETRY_SECONDS"
      fi
      ;;
  esac

  printf '%s\n' "$delay"
}

failure_retry_delay_seconds() {
  local base_retry="$1"
  local failure_reason="$2"
  local force_send="${3:-0}"
  local delay="$base_retry"

  case "$failure_reason" in
    send_unverified|send_unverified_after_tty_fallback|request_already_inflight)
      if (( LOOP_UNVERIFIED_RETRY_SECONDS > delay )); then
        delay="$LOOP_UNVERIFIED_RETRY_SECONDS"
      fi
      ;;
  esac

  if [[ "$force_send" == "1" ]]; then
    case "$failure_reason" in
      not_sendable|send_unverified|send_unverified_after_tty_fallback|request_already_inflight|busy_with_stream_issue|post_finalizing|busy_turn_open)
        if (( LOOP_FORCE_FAILURE_RETRY_SECONDS > delay )); then
          delay="$LOOP_FORCE_FAILURE_RETRY_SECONDS"
        fi
        ;;
    esac
  fi

  printf '%s\n' "$delay"
}

has_active_loops() {
  local loop_file
  local key

  shopt -s nullglob
  for loop_file in "$LOOPS_DIR"/*.loop; do
    key="$(basename "${loop_file%.loop}")"
    paths_for_target "$key"
    load_current_loop_status_file "$(loop_source_tag)" >/dev/null 2>&1 || true
    if [[ "${STOPPED:-0}" != "1" ]]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

stop_loop_daemon_if_idle() {
  if ! has_active_loops; then
    stop_user_owned_sender_daemons || true
  fi
}

is_pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] && ps -p "$pid" -o pid= >/dev/null 2>&1
}

loop_daemon_pid() {
  [[ -f "$LOOP_DAEMON_PID_FILE" ]] || return 1
  cat "$LOOP_DAEMON_PID_FILE"
}

loop_daemon_running() {
  local pid
  pid="$(loop_daemon_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] && is_pid_running "$pid"
}

loop_runner_pid() {
  [[ -f "$LOOP_RUNNER_PID_FILE" ]] || return 1
  cat "$LOOP_RUNNER_PID_FILE"
}

loop_runner_running() {
  local pid
  pid="$(loop_runner_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] && is_pid_running "$pid"
}

wait_for_pid_exit() {
  local pid="$1"
  local timeout_seconds="${2:-5}"
  local started_at
  started_at="$(date +%s)"
  while is_pid_running "$pid"; do
    if (( $(date +%s) - started_at >= timeout_seconds )); then
      return 1
    fi
    sleep 0.05
  done
  return 0
}

stop_loop_runner_for_key() {
  local key="$1"
  local pid=""
  paths_for_target "$key"
  pid="$(loop_runner_pid 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 0
  is_pid_running "$pid" || return 0

  kill "$pid" 2>/dev/null || true
  if ! wait_for_pid_exit "$pid" 2; then
    kill -9 "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" 2 || true
  fi
  rm -f "$LOOP_RUNNER_PID_FILE" 2>/dev/null || true
}

runner_writeback_allowed() {
  local key="$1"
  local loop_file="$2"
  local source_tag="$3"

  paths_for_target "$key"
  [[ -f "$loop_file" ]] || return 1
  if load_current_loop_status_file "$source_tag" >/dev/null 2>&1; then
    [[ "${STOPPED:-0}" != "1" ]] || return 1
  fi
  return 0
}

sender_daemon_records() {
  ps -axo user=,pid=,command= | awk -v script="$0" '
    index($0, script " loop-daemon") > 0 || index($0, script " daemon") > 0 {
      user = $1
      pid = $2
      command = $0
      sub(/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", command)
      mode = "unknown"
      if (index(command, script " loop-daemon") > 0) {
        mode = "loop-daemon"
      } else if (index(command, script " daemon") > 0) {
        mode = "legacy-daemon"
      }
      state_dir = ""
      if (match(command, /--state-dir=[^[:space:]]+/)) {
        state_dir = substr(command, RSTART + 12, RLENGTH - 12)
      }
      print user "|" pid "|" mode "|" state_dir "|" command
    }
  '
}

legacy_sender_warning_lines() {
  local line
  local warning_found=1

  while IFS='|' read -r daemon_user daemon_pid daemon_mode daemon_state_dir daemon_command; do
    [[ -n "${daemon_pid:-}" ]] || continue
    warning_found=0
    if [[ "$daemon_user" != "$(id -un)" ]]; then
      printf 'warning: detected %s owned by %s pid=%s; it may keep sending until manually stopped\n' "$daemon_mode" "$daemon_user" "$daemon_pid"
    fi
  done < <(sender_daemon_records)

  return "$warning_found"
}

stop_user_owned_sender_daemons() {
  local target_state_dir="${1:-$STATE_DIR}"
  local current_user
  local stop_failed=0
  current_user="$(id -un)"

  while IFS='|' read -r daemon_user daemon_pid daemon_mode daemon_state_dir daemon_command; do
    [[ -n "${daemon_pid:-}" ]] || continue
    [[ "$daemon_user" == "$current_user" ]] || continue
    [[ -n "${daemon_state_dir:-}" ]] || continue
    [[ "$daemon_state_dir" == "$target_state_dir" ]] || continue
    kill "$daemon_pid" 2>/dev/null || stop_failed=1
  done < <(sender_daemon_records)

  rm -f "$LOOP_DAEMON_PID_FILE" 2>/dev/null || true

  return "$stop_failed"
}

append_loop_log_line() {
  local file="$1"
  shift
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  touch "$file" 2>/dev/null || true
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$file" 2>/dev/null || true
}

prune_stale_request_files() {
  python3 - "$PENDING_REQUEST_DIR" "$PROCESSING_REQUEST_DIR" "$REQUEST_STALE_GRACE_SECONDS" <<'PY'
import json
import os
import sys
import time

pending_dir, processing_dir, grace_seconds = sys.argv[1:]
grace_seconds = int(grace_seconds or 0)
now = int(time.time())

for directory in (pending_dir, processing_dir):
    if not os.path.isdir(directory):
        continue
    for name in os.listdir(directory):
        if not name.endswith(".request.json"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                payload = json.load(fh)
        except Exception:
            continue
        created_at = int(payload.get("created_at", 0) or 0)
        timeout_seconds = int(payload.get("timeout_seconds", 0) or 0)
        if created_at <= 0:
            continue
        expiry_age = max(30, timeout_seconds + grace_seconds)
        if now - created_at < expiry_age:
            continue
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
PY
}

last_nonempty_log_line() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk 'NF { line = $0 } END { if (line != "") print line }' "$file"
}

extract_probe_field() {
  local probe_text="$1"
  local field_name="$2"
  printf '%s\n' "$probe_text" | awk -F': ' -v name="$field_name" '$1==name { print $2; exit }'
}

make_request_id() {
  python3 - <<'PY'
import os
import time
print(f"{int(time.time()*1000)}-{os.getpid()}-{os.urandom(4).hex()}")
PY
}

request_paths_for_id() {
  local request_id="$1"
  REQUEST_FILE="${PENDING_REQUEST_DIR}/${request_id}.request.json"
  PROCESSING_FILE="${PROCESSING_REQUEST_DIR}/${request_id}.request.json"
  RESULT_FILE="${RESULT_REQUEST_DIR}/${request_id}.result.json"
}

find_matching_inflight_request() {
  local target="$1"
  local message="$2"
  local force_send="${3:-0}"

  prune_stale_request_files
  python3 - "$PENDING_REQUEST_DIR" "$PROCESSING_REQUEST_DIR" "$target" "$message" "$force_send" <<'PY'
import json
import os
import sys

pending_dir, processing_dir, target, message, force_send = sys.argv[1:]
candidates = []
expected_force_send = force_send == "1"

for queue_state, directory in (("pending", pending_dir), ("processing", processing_dir)):
    if not os.path.isdir(directory):
        continue
    for name in os.listdir(directory):
        if not name.endswith(".request.json"):
            continue
        path = os.path.join(directory, name)
        try:
            with open(path, "r", encoding="utf-8") as fh:
                payload = json.load(fh)
        except Exception:
            continue
        if str(payload.get("target", "")) != target:
            continue
        if str(payload.get("message", "")) != message:
            continue
        if bool(payload.get("force_send")) != expected_force_send:
            continue
        request_id = str(payload.get("request_id", "")) or name.removesuffix(".request.json")
        created_at = int(payload.get("created_at", 0) or 0)
        timeout_seconds = int(payload.get("timeout_seconds", 0) or 0)
        force_send = "yes" if payload.get("force_send") else "no"
        candidates.append((created_at, request_id, queue_state, timeout_seconds, force_send))

if not candidates:
    sys.exit(1)

created_at, request_id, queue_state, timeout_seconds, force_send = max(candidates)
print(f"request_id: {request_id}")
print(f"queue_state: {queue_state}")
print(f"created_at: {created_at}")
print(f"timeout_seconds: {timeout_seconds}")
print(f"force_send: {force_send}")
PY
}

current_request_queue_state() {
  local request_id="$1"
  prune_stale_request_files
  request_paths_for_id "$request_id"

  if [[ -f "$REQUEST_FILE" ]]; then
    printf 'pending\n'
    return 0
  fi

  if [[ -f "$PROCESSING_FILE" ]]; then
    printf 'processing\n'
    return 0
  fi

  return 1
}

print_request_accepted_result() {
  local reason="$1"
  local target="$2"
  local force_send="$3"
  local detail="$4"

  printf 'status: accepted\n'
  printf 'reason: %s\n' "$reason"
  printf 'target: %s\n' "$target"
  printf 'force_send: %s\n' "$force_send"
  printf 'detail: %s\n' "$detail"
}

queue_send_request() {
  local target="$1"
  local message="$2"
  local source_tag="$3"
  local timeout_seconds="$4"
  local force_send="${5:-0}"
  local request_id

  request_id="$(make_request_id)"
  request_paths_for_id "$request_id"
  python3 - "$REQUEST_FILE" "$request_id" "$target" "$message" "$source_tag" "$timeout_seconds" "$force_send" <<'PY'
import json
import sys
import time

path, request_id, target, message, source_tag, timeout_seconds, force_send = sys.argv[1:]
payload = {
    "request_id": request_id,
    "target": target,
    "message": message,
    "source_tag": source_tag,
    "timeout_seconds": int(timeout_seconds),
    "force_send": force_send == "1",
    "created_at": int(time.time()),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False)
PY
  printf '%s\n' "$request_id"
}

await_send_result() {
  local request_id="$1"
  local timeout_seconds="$2"
  local target="$3"
  local force_send="${4:-0}"
  local started_at
  started_at="$(date +%s)"
  request_paths_for_id "$request_id"

  while true; do
    if [[ -f "$RESULT_FILE" ]]; then
      local result_json
      local result_status
      local result_text
      result_json="$(cat "$RESULT_FILE")"
      rm -f "$RESULT_FILE" 2>/dev/null || true
      result_status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$result_json")"
      result_text="$(python3 -c '
import json
import sys

data = json.load(sys.stdin)
keys = [
    "status",
    "reason",
    "target",
    "force_send",
    "probe_status",
    "terminal_state",
    "detail",
]
for key in keys:
    if key not in data:
        continue
    value = data.get(key)
    if value in (None, ""):
        continue
    if isinstance(value, bool):
        value = "yes" if value else "no"
    print(f"{key}: {value}")
' <<<"$result_json")"

      if [[ "$result_status" == "success" ]]; then
        printf '%s\n' "$result_text"
        return 0
      fi

      if [[ "$result_status" == "accepted" ]]; then
        [[ -n "$result_text" ]] && printf '%s\n' "$result_text" >&2
        return 2
      fi

      [[ -n "$result_text" ]] && printf '%s\n' "$result_text" >&2
      return 1
    fi

    if (( $(date +%s) - started_at >= timeout_seconds )); then
      local queue_state=""
      queue_state="$(current_request_queue_state "$request_id" 2>/dev/null || true)"
      if [[ -n "$queue_state" ]]; then
        local elapsed_seconds
        elapsed_seconds="$(( $(date +%s) - started_at ))"
        print_request_accepted_result \
          "request_still_processing" \
          "$target" \
          "$([[ "$force_send" == "1" ]] && echo yes || echo no)" \
          "send request still ${queue_state} after ${elapsed_seconds}s; waiting for app feedback for request_id=${request_id}"
        return 2
      fi
      die "send request timed out after ${timeout_seconds}s waiting for app response"
    fi

    sleep 1
  done
}

resolve_thread_id() {
  local target="$1"
  local resolve_scope="${2:-any}"
  local thread_id=""

  thread_id="$(
    python3 - "$CODEX_STATE_DB_PATH" "$CODEX_SESSION_INDEX_PATH" "$target" "$resolve_scope" <<'PY'
import json
import os
import re
import sqlite3
import sys

db_path, session_index_path, target, resolve_scope = sys.argv[1:]
target = target.strip()
live_only = resolve_scope == "live_only"
uuid_pattern = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

conn = sqlite3.connect(db_path)
cur = conn.cursor()

def filter_matching_ids(thread_ids):
    if not live_only or not thread_ids:
        return thread_ids
    placeholders = ",".join("?" for _ in thread_ids)
    rows = cur.execute(
        f"select id from threads where id in ({placeholders}) and archived = 0",
        thread_ids,
    ).fetchall()
    live_ids = {row[0] for row in rows if row and row[0]}
    return [thread_id for thread_id in thread_ids if thread_id in live_ids]

if uuid_pattern.fullmatch(target):
    if not live_only:
        print(target, end="")
        conn.close()
        raise SystemExit(0)
    row = cur.execute(
        "select id from threads where id = ? and archived = 0",
        (target,),
    ).fetchone()
    conn.close()
    if row and row[0]:
        print(row[0], end="")
    raise SystemExit(0)

latest_names = {}
if os.path.exists(session_index_path):
    with open(session_index_path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            thread_id = obj.get("id")
            thread_name = (obj.get("thread_name") or "").strip()
            if thread_id and thread_name:
                latest_names[thread_id] = thread_name

matching_ids = [thread_id for thread_id, thread_name in latest_names.items() if thread_name == target]
matching_ids = filter_matching_ids(matching_ids)
if len(matching_ids) == 1:
    print(matching_ids[0], end="")
    conn.close()
    raise SystemExit(0)
if len(matching_ids) > 1:
    conn.close()
    raise SystemExit(f"found multiple matching sessions for target '{target}': {' '.join(matching_ids)}")

query = "select id from threads where title = ?"
if live_only:
    query += " and archived = 0"
query += " order by updated_at desc"
rows = cur.execute(query, (target,)).fetchall()
conn.close()
if len(rows) > 1:
    raise SystemExit(f"found multiple matching thread titles for target '{target}': {' '.join(row[0] for row in rows if row and row[0])}")
if len(rows) == 1 and rows[0][0]:
    print(rows[0][0], end="")
PY
  )"

  if [[ -z "$thread_id" ]]; then
    if [[ "$resolve_scope" == "live_only" ]]; then
      die "could not resolve live Codex thread id for target '$target'"
    fi
    die "could not resolve Codex thread id for target '$target'"
  fi
  printf '%s\n' "$thread_id"
}

resolve_live_thread_id() {
  local target="$1"
  resolve_thread_id "$target" "live_only"
}

load_target_metadata() {
  local thread_id="$1"

  python3 - "$CODEX_STATE_DB_PATH" "$CODEX_SESSION_INDEX_PATH" "$thread_id" <<'PY'
import json
import os
import sqlite3
import sys

db_path, session_index_path, thread_id = sys.argv[1:]

session_name = ""
if os.path.exists(session_index_path):
    with open(session_index_path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            if obj.get("id") != thread_id:
                continue
            candidate = (obj.get("thread_name") or "").replace("\n", " ").strip()
            if candidate:
                session_name = candidate

conn = sqlite3.connect(db_path)
cur = conn.cursor()
row = cur.execute(
    "select rollout_path, title, first_user_message, cwd, model_provider, source, agent_nickname, agent_role from threads where id = ? limit 1",
    (thread_id,),
).fetchone()
conn.close()
if row:
    print(json.dumps({
        "rollout_path": (row[0] or "").replace("\n", " "),
        "thread_title": (row[1] or "").replace("\n", " "),
        "first_user_message": (row[2] or "").replace("\n", " "),
        "target_cwd": (row[3] or "").replace("\n", " "),
        "session_name": session_name,
        "model_provider": (row[4] or "").replace("\n", " "),
        "session_source": (row[5] or "").replace("\n", " "),
        "agent_nickname": (row[6] or "").replace("\n", " "),
        "agent_role": (row[7] or "").replace("\n", " "),
    }, ensure_ascii=False))
PY
}

read_target_metadata_fields() {
  local metadata_json="$1"
  python3 - "$metadata_json" <<'PY'
import json
import sys

raw = sys.argv[1].strip()
data = json.loads(raw) if raw else {}
for key in (
    "rollout_path",
    "thread_title",
    "first_user_message",
    "target_cwd",
    "session_name",
    "model_provider",
    "session_source",
    "agent_nickname",
    "agent_role",
):
    sys.stdout.write(str(data.get(key, "")))
    sys.stdout.write("\0")
PY
}

resolve_target_tty() {
  local target="$1"
  local thread_id="$2"
  local thread_title="$3"
  local first_user_message="$4"
  local session_name="$5"
  local target_cwd="$6"
  local rollout_path="$7"
  local tty_name=""
  local tty_error=""
  local attempt_status=1
  local fallback_ambiguous=0
  local fallback_ambiguous_error=""

  try_candidate() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 1
    local output=""
    local error=""
    set +e
    output="$(find_unique_tty "$candidate" 2>&1)"
    attempt_status=$?
    set -e
    if [[ "$attempt_status" -eq 0 ]]; then
      tty_name="$output"
      return 0
    fi
    tty_error="$output"
    return "$attempt_status"
  }

  if ! try_candidate "$target"; then
    if [[ "$attempt_status" -eq 2 ]]; then
      printf '%s\n' "$tty_error" >&2
      return 2
    fi
  fi
  if [[ -z "$tty_name" && -n "${session_name:-}" && "$session_name" != "$target" ]]; then
    if ! try_candidate "$session_name"; then
      if [[ "$attempt_status" -eq 2 ]]; then
        printf '%s\n' "$tty_error" >&2
        return 2
      fi
    fi
  fi
  if [[ -z "$tty_name" && -n "${thread_id:-}" && "$thread_id" != "$target" ]]; then
    if ! try_candidate "$thread_id"; then
      if [[ "$attempt_status" -eq 2 ]]; then
        printf '%s\n' "$tty_error" >&2
        return 2
      fi
    fi
  fi
  if [[ -z "$tty_name" && -n "${thread_title:-}" && "$thread_title" != "$target" && "${thread_title:-}" != "${first_user_message:-}" ]]; then
    if ! try_candidate "$thread_title"; then
      if [[ "$attempt_status" -eq 2 ]]; then
        printf '%s\n' "$tty_error" >&2
        return 2
      fi
    fi
  fi

  if [[ -z "$tty_name" && -n "${target_cwd:-}" ]]; then
    local cwd_match_output=""
    set +e
    cwd_match_output="$(find_terminal_tty_by_process_cwd "$target" "$target_cwd" 2>&1)"
    attempt_status=$?
    set -e
    if [[ "$attempt_status" -eq 0 ]]; then
      tty_name="$cwd_match_output"
    else
      tty_error="$cwd_match_output"
      if [[ "$attempt_status" -eq 2 ]]; then
        fallback_ambiguous=1
        fallback_ambiguous_error="$cwd_match_output"
      fi
    fi
  fi

  if [[ -z "$tty_name" && -n "${rollout_path:-}" && -f "${rollout_path:-}" ]]; then
    local content_match_output=""
    set +e
    content_match_output="$(find_terminal_tty_by_session_content "$target" "$thread_id" "$session_name" "$thread_title" "$first_user_message" "$rollout_path" 2>&1)"
    attempt_status=$?
    set -e
    if [[ "$attempt_status" -eq 0 ]]; then
      tty_name="$content_match_output"
    else
      tty_error="$content_match_output"
      if [[ "$attempt_status" -eq 2 ]]; then
        printf '%s\n' "$tty_error" >&2
        return 2
      fi
    fi
  fi

  if [[ -n "$tty_name" ]]; then
    printf '%s\n' "$tty_name"
    return 0
  fi

  if [[ "$fallback_ambiguous" -eq 1 && -n "$fallback_ambiguous_error" ]]; then
    printf '%s\n' "$fallback_ambiguous_error" >&2
    return 2
  fi

  [[ -n "$tty_error" ]] && printf '%s\n' "$tty_error" >&2
  return 1
}

probe_session_status() {
  local target="$1"
  local thread_id
  local rollout_path
  local thread_title
  local first_user_message
  local session_name
  local tty_name=""

  require_cmd python3
  require_cmd sqlite3

  thread_id="$(resolve_live_thread_id "$target")"
  local target_cwd
  local model_provider
  local session_source
  local agent_nickname
  local agent_role
  {
    IFS= read -r -d '' rollout_path || true
    IFS= read -r -d '' thread_title || true
    IFS= read -r -d '' first_user_message || true
    IFS= read -r -d '' target_cwd || true
    IFS= read -r -d '' session_name || true
    IFS= read -r -d '' model_provider || true
    IFS= read -r -d '' session_source || true
    IFS= read -r -d '' agent_nickname || true
    IFS= read -r -d '' agent_role || true
  } < <(read_target_metadata_fields "$(load_target_metadata "$thread_id" 2>/dev/null)")

  [[ -n "${rollout_path:-}" && -f "${rollout_path:-}" ]] || die "could not find rollout path for target '$target'"
  tty_name="$(resolve_target_tty "$target" "$thread_id" "$thread_title" "$first_user_message" "$session_name" "$target_cwd" "$rollout_path" 2>/dev/null || true)"

  python3 - "$thread_id" "$thread_title" "$session_name" "$rollout_path" "$tty_name" "$CODEX_LOGS_DB_PATH" "$PROBE_RECENT_LOG_WINDOW_SECONDS" "$model_provider" "$session_source" "$agent_nickname" "$agent_role" "${CODEX_TASKMASTER_TERMINAL_SNAPSHOT_FIXTURE:-}" <<'PY'
import json
import sqlite3
import sys
import time
import subprocess
from pathlib import Path

thread_id, thread_title, session_name, rollout_path, tty_name, logs_db, recent_log_window, model_provider, session_source, agent_nickname, agent_role, terminal_snapshot_fixture = sys.argv[1:]
recent_log_window = int(recent_log_window)


def read_terminal_snapshot(tty_value: str):
    if not tty_value:
        return {
            "state": "unavailable",
            "reason": "tty not found",
            "window_id": "",
            "busy": None,
            "processes": "",
            "tail": [],
        }

    target_tty = tty_value if tty_value.startswith("/dev/") else f"/dev/{tty_value}"
    def parse_terminal_snapshot_record(window_id: str, busy_text: str, processes: str, nonempty_tail, tab_selected):
        prompt_line = ""
        for line in reversed(nonempty_tail):
            if line.startswith("› "):
                prompt_line = line
                break

        footer_visible = any(("· ~" in line or "· /" in line) and "left" in line for line in nonempty_tail)
        placeholder_visible = any("› Improve documentation in @filename" in line for line in nonempty_tail)
        queued_messages_visible = any(
            line.lstrip().startswith("↳ ") or "Messages to be submitted after next tool call" in line
            for line in nonempty_tail
        )

        state = "no_visible_prompt"
        reason = "prompt/footer not visible in terminal tail"
        if queued_messages_visible:
            state = "queued_messages_pending"
            reason = "queued messages are visible in the terminal tail"
        elif placeholder_visible and footer_visible:
            state = "prompt_ready"
            reason = "placeholder prompt and model footer are visible"
        elif prompt_line and footer_visible:
            state = "prompt_with_input"
            reason = "prompt line and model footer are visible with non-placeholder input"
        elif footer_visible:
            state = "footer_visible_only"
            reason = "model footer is visible without a clear prompt line"

        return {
            "state": state,
            "reason": reason,
            "window_id": window_id,
            "busy": (busy_text == "true"),
            "processes": processes,
            "tail": nonempty_tail,
            "tab_selected": tab_selected,
        }

    if terminal_snapshot_fixture:
        try:
            records = json.loads(Path(terminal_snapshot_fixture).read_text(encoding="utf-8"))
        except Exception as exc:
            return {
                "state": "unavailable",
                "reason": f"terminal snapshot fixture failed: {exc}",
                "window_id": "",
                "busy": None,
                "processes": "",
                "tail": [],
                "tab_selected": None,
            }

        for record in records if isinstance(records, list) else []:
            if str(record.get("tty", "")).strip() != target_tty:
                continue
            contents = str(record.get("contents", "") or "")
            nonempty_tail = [line.rstrip() for line in contents.splitlines() if line.strip()][-14:]
            return parse_terminal_snapshot_record(
                window_id=str(record.get("window_id", "") or ""),
                busy_text=str(record.get("busy", "") or ""),
                processes=str(record.get("processes", "") or ""),
                nonempty_tail=nonempty_tail,
                tab_selected=bool(record.get("tab_selected", False)),
            )
        return {
            "state": "unavailable",
            "reason": "tty not found",
            "window_id": "",
            "busy": None,
            "processes": "",
            "tail": [],
            "tab_selected": None,
        }

    applescript = f'''
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      try
        if (tty of t) is equal to "{target_tty}" then
          set selectedText to "false"
          try
            if t is equal to selected tab of w then
              set selectedText to "true"
            end if
          end try
          return (id of w as text) & linefeed & selectedText & linefeed & (busy of t as text) & linefeed & ((processes of t as text)) & linefeed & (contents of t)
        end if
      end try
    end repeat
  end repeat
end tell
return ""
'''
    try:
        proc = subprocess.run(
            ["osascript", "-"],
            input=applescript,
            text=True,
            capture_output=True,
            check=True,
        )
        raw = proc.stdout
    except Exception as exc:
        return {
            "state": "unavailable",
            "reason": f"osascript failed: {exc}",
            "window_id": "",
            "busy": None,
            "processes": "",
            "tail": [],
        }

    lines = raw.splitlines()
    window_id = lines[0].strip() if len(lines) >= 1 else ""
    tab_selected = lines[1].strip().lower() == "true" if len(lines) >= 2 else None
    busy_text = lines[2].strip().lower() if len(lines) >= 3 else ""
    processes = lines[3].strip() if len(lines) >= 4 else ""
    contents = "\n".join(lines[4:]) if len(lines) >= 5 else ""
    nonempty_tail = [line.rstrip() for line in contents.splitlines() if line.strip()][-14:]
    return parse_terminal_snapshot_record(
        window_id=window_id,
        busy_text=busy_text,
        processes=processes,
        nonempty_tail=nonempty_tail,
        tab_selected=tab_selected,
    )


events = []
for raw in Path(rollout_path).read_text().splitlines():
    try:
        obj = json.loads(raw)
    except Exception:
        continue
    payload = obj.get("payload", {})
    typ = obj.get("type")
    ptype = payload.get("type")
    if typ == "event_msg" and ptype in {"task_started", "task_complete", "turn_aborted", "user_message", "agent_message", "token_count"}:
        events.append(
            {
                "timestamp": obj.get("timestamp"),
                "kind": ptype,
                "turn_id": payload.get("turn_id"),
                "phase": payload.get("phase"),
                "message": payload.get("message"),
            }
        )
    elif typ == "response_item" and payload.get("type") == "message":
        role = payload.get("role")
        text = ""
        for item in payload.get("content", []):
            if item.get("type") in {"input_text", "output_text"}:
                text = item.get("text") or ""
                break
        events.append(
            {
                "timestamp": obj.get("timestamp"),
                "kind": f"response_{role}",
                "turn_id": payload.get("turn_id"),
                "phase": payload.get("phase"),
                "message": text,
            }
        )

last_started = None
last_complete = None
last_final = None
last_aborted = None
last_user = None
for event in events:
    kind = event["kind"]
    if kind == "task_started":
        last_started = event
    elif kind == "task_complete":
        last_complete = event
    elif kind == "turn_aborted":
        last_aborted = event
    elif kind == "agent_message" and event.get("phase") == "final_answer":
        last_final = event
    elif kind == "user_message":
        last_user = event

recent_logs = []
try:
    conn = sqlite3.connect(logs_db)
    cur = conn.cursor()
    cur.execute(
        """
        select ts, level, target, message
        from logs
        where thread_id = ?
        order by ts desc, ts_nanos desc, id desc
        limit 20
        """,
        (thread_id,),
    )
    recent_logs = cur.fetchall()
    conn.close()
except Exception:
    recent_logs = []

now_ts = time.time()
recent_time_window_logs = [row for row in recent_logs if (now_ts - row[0]) <= recent_log_window]
latest_log_message = recent_logs[0][3] if recent_logs else ""
latest_log_age_seconds = int(now_ts - recent_logs[0][0]) if recent_logs else None
has_recent_interrupt = any((row[3] or "").find("interrupt received") >= 0 for row in recent_time_window_logs)
has_recent_disconnect = any((row[3] or "").find("stream disconnected") >= 0 for row in recent_time_window_logs)
terminal = read_terminal_snapshot(tty_name)

status = "unknown"
reason = "insufficient local events"
if last_complete and (not last_started or last_complete["timestamp"] >= last_started["timestamp"]):
    status = "idle_stable"
    reason = "last completed turn is newer than the last started turn"
if last_started and (not last_complete or last_started["timestamp"] > last_complete["timestamp"]):
    status = "busy_turn_open"
    reason = "a started turn has no later task_complete"
if last_final and last_started and (not last_complete or last_complete["timestamp"] < last_final["timestamp"]):
    status = "post_finalizing"
    reason = "final answer emitted but task_complete not seen yet"
if has_recent_interrupt and status == "busy_turn_open":
    status = "interrupted_or_aborting"
    reason = "open turn with a recent interrupt log"
if has_recent_disconnect and status in {"busy_turn_open", "post_finalizing"}:
    status = "busy_with_stream_issue"
    reason = "open turn with recent stream disconnect warnings"
if last_aborted and (not last_complete or last_aborted["timestamp"] > last_complete["timestamp"]):
    if terminal["state"] == "prompt_ready":
        status = "interrupted_idle"
        reason = "a newer turn_aborted event is present and terminal is ready again"
    else:
        status = "interrupted_or_aborting"
        reason = "a newer turn_aborted event is present"
if status == "idle_stable" and terminal["state"] == "prompt_with_input":
    status = "idle_with_residual_input"
    reason = "turn is complete, but terminal still shows unsent input"
if status == "idle_stable" and terminal["state"] == "queued_messages_pending":
    status = "idle_with_queued_messages"
    reason = "turn is complete, but queued messages are still visible in Terminal"
if status in {"busy_turn_open", "post_finalizing"} and terminal["state"] == "prompt_ready":
    status = "idle_prompt_visible_rollout_stale"
    reason = "terminal is back at a ready prompt while rollout still looks open"
if status == "idle_stable" and has_recent_interrupt and terminal["state"] == "prompt_ready":
    status = "interrupted_idle"
    reason = "terminal is ready and a fresh interrupt log was recorded"

parent_thread_id = ""
if session_source:
    try:
        source_obj = json.loads(session_source)
        parent_thread_id = (((source_obj.get("subagent") or {}).get("thread_spawn") or {}).get("parent_thread_id") or "")
    except Exception:
        parent_thread_id = ""

effective_target = session_name or thread_id
print(f"target: {effective_target}")
print(f"thread_id: {thread_id}")
print(f"name: {session_name}")
print(f"provider: {model_provider}")
print(f"source: {session_source or '-'}")
print(f"parent_thread_id: {parent_thread_id or '-'}")
print(f"agent_nickname: {agent_nickname or '-'}")
print(f"agent_role: {agent_role or '-'}")
print(f"tty: {tty_name or '-'}")
print(f"status: {status}")
print(f"reason: {reason}")
print(f"terminal_state: {terminal['state']}")
print(f"terminal_reason: {terminal['reason']}")
print(f"terminal_window_id: {terminal['window_id'] or '-'}")
print(f"terminal_busy: {terminal['busy'] if terminal['busy'] is not None else '-'}")
print(f"terminal_processes: {terminal['processes'] or '-'}")
print(f"rollout_path: {rollout_path}")
if last_started:
    print(f"last_task_started_at: {last_started['timestamp']}")
if last_final:
    print(f"last_final_answer_at: {last_final['timestamp']}")
if last_complete:
    print(f"last_task_complete_at: {last_complete['timestamp']}")
if last_aborted:
    print(f"last_turn_aborted_at: {last_aborted['timestamp']}")
if last_user:
    print(f"last_user_message_at: {last_user['timestamp']}")
    snippet = (last_user.get("message") or "").replace("\n", "\\n")
    print(f"last_user_message: {snippet[:160]}")
if latest_log_message:
    print(f"latest_log: {latest_log_message[:220]}")
if latest_log_age_seconds is not None:
    print(f"latest_log_age_seconds: {latest_log_age_seconds}")
if recent_time_window_logs:
    print(f"recent_log_count_within_window: {len(recent_time_window_logs)}")
if terminal["tail"]:
    tail_text = " | ".join(line.replace("\n", "\\n") for line in terminal["tail"])
    print(f"terminal_tail: {tail_text[:400]}")
PY
}

session_count() {
  require_cmd sqlite3
  sqlite3 "$CODEX_STATE_DB_PATH" \
    "select count(*) from threads where archived = 0;"
}

codex_app_server_thread_rpc() {
  local action="$1"
  local thread_id="${2:-}"
  local name="${3:-}"
  local archived="${4:-0}"

  require_cmd node
  require_cmd "$CODEX_BIN_PATH"
  if [[ "$action" != "list" ]]; then
    is_uuid_like "$thread_id" || die "thread id must be a UUID"
  fi

  node - "$CODEX_BIN_PATH" "$action" "$thread_id" "$name" "$archived" <<'NODE'
const { spawn } = require("node:child_process");
const net = require("node:net");
const process = require("node:process");

const [codexBin, action, threadId = "", name = "", archivedFlag = "0"] = process.argv.slice(2);

async function getFreePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = typeof address === "object" && address ? address.port : null;
      server.close((err) => {
        if (err) {
          reject(err);
          return;
        }
        if (!port) {
          reject(new Error("failed to resolve a local port"));
          return;
        }
        resolve(port);
      });
    });
  });
}

async function waitForReady(url, child, timeoutMs) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (child.exitCode !== null) {
      throw new Error(`codex app-server exited early with code ${child.exitCode}`);
    }
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
    } catch {
      // Retry until timeout.
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for codex app-server readyz at ${url}`);
}

async function callRpc(wsUrl, method, params) {
  return await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const pending = new Map();
    let nextId = 1;
    let settled = false;

    const cleanup = () => {
      if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
        try {
          ws.close();
        } catch {
          // ignore
        }
      }
    };

    const fail = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(error);
    };

    const send = (sendMethod, sendParams) => {
      const id = nextId++;
      const payload = { jsonrpc: "2.0", id, method: sendMethod, params: sendParams };
      ws.send(JSON.stringify(payload));
      return new Promise((innerResolve, innerReject) => {
        pending.set(id, { resolve: innerResolve, reject: innerReject });
        setTimeout(() => {
          if (!pending.has(id)) {
            return;
          }
          pending.delete(id);
          innerReject(new Error(`timeout waiting for ${sendMethod}`));
        }, 10000);
      });
    };

    ws.addEventListener("open", async () => {
      try {
        await send("initialize", {
          clientInfo: {
            name: "codex-terminal-sender",
            version: "1.0",
          },
          capabilities: null,
        });
        const result = await send(method, params);
        if (settled) {
          return;
        }
        settled = true;
        cleanup();
        resolve(result);
      } catch (error) {
        fail(error);
      }
    });

    ws.addEventListener("message", (event) => {
      let parsed;
      try {
        parsed = JSON.parse(String(event.data));
      } catch (error) {
        fail(new Error(`failed to parse app-server message: ${error.message}`));
        return;
      }

      if (!Object.prototype.hasOwnProperty.call(parsed, "id")) {
        return;
      }

      const pendingRequest = pending.get(parsed.id);
      if (!pendingRequest) {
        return;
      }
      pending.delete(parsed.id);
      if (parsed.error) {
        pendingRequest.reject(new Error(typeof parsed.error === "object" ? JSON.stringify(parsed.error) : String(parsed.error)));
      } else {
        pendingRequest.resolve(parsed.result);
      }
    });

    ws.addEventListener("error", () => {
      fail(new Error("websocket transport error"));
    });

    ws.addEventListener("close", () => {
      if (!settled) {
        fail(new Error("websocket closed before app-server request completed"));
      }
    });
  });
}

async function main() {
  let method;
  let params;

  switch (action) {
    case "archive":
      method = "thread/archive";
      params = { threadId };
      break;
    case "unarchive":
      method = "thread/unarchive";
      params = { threadId };
      break;
    case "name-set":
      method = "thread/name/set";
      params = { threadId, name };
      break;
    case "list":
      method = "thread/list";
      params = {
        archived: archivedFlag === "1",
        limit: 100,
        sortKey: "updated_at",
      };
      break;
    default:
      throw new Error(`unsupported thread rpc action: ${action}`);
  }

  const port = await getFreePort();
  const wsUrl = `ws://127.0.0.1:${port}`;
  const readyUrl = `http://127.0.0.1:${port}/readyz`;
  const child = spawn(codexBin, ["app-server", "--listen", wsUrl], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  let stderrLog = "";
  child.stdout.resume();
  child.stderr.on("data", (chunk) => {
    stderrLog += chunk.toString("utf8");
  });

  try {
    await waitForReady(readyUrl, child, 10000);
    if (action === "list") {
      const data = [];
      let cursor = null;
      do {
        const result = await callRpc(wsUrl, method, {
          ...params,
          cursor,
        });
        if (Array.isArray(result?.data)) {
          data.push(...result.data);
        }
        cursor = result?.nextCursor ?? null;
      } while (cursor);
      process.stdout.write(JSON.stringify({ data }));
    } else {
      const result = await callRpc(wsUrl, method, params);
      process.stdout.write(JSON.stringify(result ?? {}));
    }
  } catch (error) {
    const cleanedStderr = stderrLog
      .split(/\r?\n/)
      .filter((line) => {
        const trimmed = line.trim();
        if (!trimmed) {
          return false;
        }
        return !(
          trimmed.startsWith("codex app-server (WebSockets)") ||
          trimmed.startsWith("listening on:") ||
          trimmed.startsWith("readyz:") ||
          trimmed.startsWith("healthz:") ||
          trimmed.startsWith("note: binds localhost only")
        );
      })
      .join("\n")
      .trim();
    const details = [
      error && error.message ? error.message : String(error),
      cleanedStderr,
    ].filter(Boolean);
    process.stderr.write(details.join("\n"));
    process.exitCode = 1;
  } finally {
    if (child.exitCode === null) {
      child.kill("SIGTERM");
      await new Promise((resolve) => {
        const timer = setTimeout(() => {
          if (child.exitCode === null) {
            child.kill("SIGKILL");
          }
          resolve();
        }, 2000);
        child.once("exit", () => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }
}

main().catch((error) => {
  process.stderr.write(error && error.message ? error.message : String(error));
  process.exit(1);
});
NODE
}

thread_name_set() {
  local thread_id="$1"
  local name="$2"
  codex_app_server_thread_rpc "name-set" "$thread_id" "$name" >/dev/null
  printf 'thread_id: %s\n' "$thread_id"
  printf 'name: %s\n' "$name"
}

thread_action_guard_live_session() {
  local thread_id="$1"
  local action="$2"
  local metadata=""
  local rollout_path=""
  local thread_title=""
  local first_user_message=""
  local target_cwd=""
  local session_name=""
  local model_provider=""
  local session_source=""
  local agent_nickname=""
  local agent_role=""
  local live_tty_output=""
  local live_tty_status=1

  metadata="$(load_target_metadata "$thread_id" 2>/dev/null || true)"
  [[ -n "$metadata" ]] || return 0
  {
    IFS= read -r -d '' rollout_path || true
    IFS= read -r -d '' thread_title || true
    IFS= read -r -d '' first_user_message || true
    IFS= read -r -d '' target_cwd || true
    IFS= read -r -d '' session_name || true
    IFS= read -r -d '' model_provider || true
    IFS= read -r -d '' session_source || true
    IFS= read -r -d '' agent_nickname || true
    IFS= read -r -d '' agent_role || true
  } < <(read_target_metadata_fields "$metadata")

  set +e
  live_tty_output="$(resolve_target_tty "$thread_id" "$thread_id" "$thread_title" "$first_user_message" "$session_name" "$target_cwd" "$rollout_path" 2>&1)"
  live_tty_status=$?
  set -e

  case "$live_tty_status" in
    0)
      printf 'status: failed\n' >&2
      printf 'reason: session_%s_live\n' "$action" >&2
      printf 'thread_id: %s\n' "$thread_id" >&2
      printf 'tty: %s\n' "$live_tty_output" >&2
      printf 'detail: session is still live on Terminal tty=%s; close that Codex session before this %s operation\n' "$live_tty_output" "$action" >&2
      return 1
      ;;
    2)
      printf 'status: failed\n' >&2
      printf 'reason: session_%s_live_ambiguous\n' "$action" >&2
      printf 'thread_id: %s\n' "$thread_id" >&2
      printf 'detail: session still appears live but maps to multiple Terminal targets; close the duplicate running sessions first before this %s operation | %s\n' "$action" "$live_tty_output" >&2
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

thread_archive() {
  local thread_id="$1"
  thread_action_guard_live_session "$thread_id" "archive"
  codex_app_server_thread_rpc "archive" "$thread_id" >/dev/null
  printf 'thread_id: %s\n' "$thread_id"
  printf 'archived: yes\n'
}

thread_unarchive() {
  local thread_id="$1"
  codex_app_server_thread_rpc "unarchive" "$thread_id" >/dev/null
  printf 'thread_id: %s\n' "$thread_id"
  printf 'unarchived: yes\n'
}

thread_delete() {
  local thread_id="$1"
  require_cmd python3
  is_uuid_like "$thread_id" || die "thread id must be a UUID"
  thread_action_guard_live_session "$thread_id" "delete"

  python3 - "$CODEX_STATE_DB_PATH" "$CODEX_LOGS_DB_PATH" "$CODEX_SESSION_INDEX_PATH" "$CODEX_CONFIG_PATH" "$thread_id" <<'PY'
import json
import os
import sqlite3
import sys

state_db_path, logs_db_path, session_index_path, config_path, thread_id = sys.argv[1:]

def remove_session_index_entry(path, target_thread_id):
    if not os.path.exists(path):
        return 0

    removed = 0
    entries = []
    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            stripped = raw_line.strip()
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError:
                entries.append(raw_line.rstrip("\n"))
                continue
            if obj.get("id") == target_thread_id:
                removed += 1
                continue
            entries.append(json.dumps(obj, ensure_ascii=False))

    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(entry + "\n")
    os.replace(tmp_path, path)
    return removed

def prune_empty_parent_dirs(path, stop_at):
    current = os.path.dirname(path)
    stop_at = os.path.abspath(stop_at)
    while current.startswith(stop_at) and current != stop_at:
        try:
            os.rmdir(current)
        except OSError:
            break
        current = os.path.dirname(current)

def candidate_codex_roots():
    roots = []
    for path in (state_db_path, logs_db_path, session_index_path, config_path):
        if not path:
            continue
        real_path = os.path.realpath(path)
        root = real_path if os.path.isdir(real_path) else os.path.dirname(real_path)
        if root and root not in roots:
            roots.append(root)
    default_root = os.path.realpath(os.path.join(os.path.expanduser("~"), ".codex"))
    if default_root not in roots:
        roots.append(default_root)
    return roots

def allowed_rollout_roots():
    roots = []
    for codex_root in candidate_codex_roots():
        for suffix in ("sessions", "archived_sessions"):
            root = os.path.realpath(os.path.join(codex_root, suffix))
            if root not in roots:
                roots.append(root)
    return roots

def matching_rollout_root(path):
    if not path:
        return None
    real_path = os.path.realpath(path)
    matches = []
    for root in allowed_rollout_roots():
        try:
            if os.path.commonpath([real_path, root]) == root:
                matches.append(root)
        except ValueError:
            continue
    if not matches:
        return None
    return max(matches, key=len)

def rollout_path_is_allowed(path):
    return matching_rollout_root(path) is not None

planned_steps = [
    "state_db_cleanup",
    "logs_db_cleanup",
    "session_index_cleanup",
    "rollout_cleanup",
]
completed_steps = []
failed_step = ""
error_message = ""
repair_hint = ""
rollout_path = ""
archived = 0
rollout_root = ""
logs_db_present = os.path.exists(logs_db_path)
rollout_exists_before = False
state_thread_deleted = False
dynamic_tool_rows_removed = 0
stage1_output_rows_removed = 0
state_log_rows_removed = 0
logs_db_rows_removed = 0
session_index_removed = 0
rollout_removed = False

def emit(exit_code, status, reason):
    pending_steps = [step for step in planned_steps if step not in completed_steps and step != failed_step]
    print(f"status: {status}")
    print(f"reason: {reason}")
    print(f"thread_id: {thread_id}")
    print(f"deleted: {'yes' if status == 'success' else 'no'}")
    print(f"rollout_path: {rollout_path}")
    print(f"archived: {'yes' if archived else 'no'}")
    print(f"logs_db_present: {'yes' if logs_db_present else 'no'}")
    print(f"rollout_exists_before: {'yes' if rollout_exists_before else 'no'}")
    print(f"state_thread_deleted: {'yes' if state_thread_deleted else 'no'}")
    print(f"dynamic_tool_rows_removed: {dynamic_tool_rows_removed}")
    print(f"stage1_output_rows_removed: {stage1_output_rows_removed}")
    print(f"state_log_rows_removed: {state_log_rows_removed}")
    print(f"logs_db_rows_removed: {logs_db_rows_removed}")
    print(f"session_index_removed: {session_index_removed}")
    print(f"rollout_removed: {'yes' if rollout_removed else 'no'}")
    print(f"completed_steps: {','.join(completed_steps)}")
    print(f"pending_steps: {','.join(pending_steps)}")
    if failed_step:
        print(f"failed_step: {failed_step}")
    if error_message:
        print(f"detail: {error_message}")
    if repair_hint:
        print(f"repair_hint: {repair_hint}")
    raise SystemExit(exit_code)

try:
    state_conn = sqlite3.connect(state_db_path)
    state_cur = state_conn.cursor()
    row = state_cur.execute(
        "select rollout_path, archived from threads where id = ?",
        (thread_id,),
    ).fetchone()
    if row is None:
        failed_step = "state_db_lookup"
        error_message = f"thread not found: {thread_id}"
        repair_hint = "会话在主状态库中不存在，无法继续本地永久删除。"
        emit(1, "failed", "thread_not_found")
    rollout_path, archived = row
    rollout_exists_before = bool(rollout_path and os.path.exists(rollout_path))
    rollout_root = matching_rollout_root(rollout_path) or ""
    if not rollout_root:
        failed_step = "rollout_path_validation"
        error_message = f"rollout_path is outside allowed Codex session roots: {rollout_path}"
        repair_hint = "为避免误删任意本地文件，已拒绝删除；请先修正状态库中的 rollout_path。"
        emit(1, "failed", "rollout_path_not_allowed")

    try:
        dynamic_tool_rows_removed = state_cur.execute(
            "select count(*) from thread_dynamic_tools where thread_id = ?",
            (thread_id,),
        ).fetchone()[0]
        stage1_output_rows_removed = state_cur.execute(
            "select count(*) from stage1_outputs where thread_id = ?",
            (thread_id,),
        ).fetchone()[0]
        state_log_rows_removed = state_cur.execute(
            "select count(*) from logs where thread_id = ?",
            (thread_id,),
        ).fetchone()[0]
        state_cur.execute("PRAGMA foreign_keys = ON")
        state_cur.execute("delete from thread_dynamic_tools where thread_id = ?", (thread_id,))
        state_cur.execute("delete from stage1_outputs where thread_id = ?", (thread_id,))
        state_cur.execute("delete from logs where thread_id = ?", (thread_id,))
        state_cur.execute("delete from threads where id = ?", (thread_id,))
        if state_cur.rowcount != 1:
            raise RuntimeError(f"failed to delete thread row: {thread_id}")
        state_conn.commit()
        state_thread_deleted = True
        completed_steps.append("state_db_cleanup")
    except Exception as exc:
        state_conn.rollback()
        failed_step = "state_db_cleanup"
        error_message = str(exc)
        repair_hint = "主状态库删除未完成，可以直接重试本地永久删除。"
        emit(1, "failed", "delete_step_failed")
    finally:
        state_conn.close()

    try:
        if logs_db_present:
            logs_conn = sqlite3.connect(logs_db_path)
            logs_cur = logs_conn.cursor()
            logs_db_rows_removed = logs_cur.execute(
                "select count(*) from logs where thread_id = ?",
                (thread_id,),
            ).fetchone()[0]
            logs_cur.execute("delete from logs where thread_id = ?", (thread_id,))
            logs_conn.commit()
            logs_conn.close()
        completed_steps.append("logs_db_cleanup")
    except Exception as exc:
        failed_step = "logs_db_cleanup"
        error_message = str(exc)
        repair_hint = "主状态库已删除；请继续清理 logs 数据库、session_index 和 rollout 文件。"
        emit(1, "failed", "delete_step_failed")

    try:
        session_index_removed = remove_session_index_entry(session_index_path, thread_id)
        completed_steps.append("session_index_cleanup")
    except Exception as exc:
        failed_step = "session_index_cleanup"
        error_message = str(exc)
        repair_hint = "数据库已删除；请继续清理 session_index 和 rollout 文件。"
        emit(1, "failed", "delete_step_failed")

    try:
        if rollout_exists_before:
            os.remove(rollout_path)
            rollout_removed = True
            prune_empty_parent_dirs(rollout_path, rollout_root)
        completed_steps.append("rollout_cleanup")
    except Exception as exc:
        failed_step = "rollout_cleanup"
        error_message = str(exc)
        repair_hint = "数据库与索引已删除；请手动清理 rollout 文件及空目录。"
        emit(1, "failed", "delete_step_failed")

    emit(0, "success", "delete_completed")
except SystemExit:
    raise
except Exception as exc:
    failed_step = failed_step or "unknown"
    error_message = str(exc)
    if not repair_hint:
        repair_hint = "本地永久删除中途失败，请根据 completed_steps 和 pending_steps 手动补清理。"
    emit(1, "failed", "delete_step_failed")
PY
}

thread_delete_plan() {
  local thread_id="$1"
  require_cmd python3
  is_uuid_like "$thread_id" || die "thread id must be a UUID"

  python3 - "$CODEX_STATE_DB_PATH" "$CODEX_LOGS_DB_PATH" "$CODEX_SESSION_INDEX_PATH" "$CODEX_CONFIG_PATH" "$thread_id" <<'PY'
import json
import os
import sqlite3
import sys

state_db_path, logs_db_path, session_index_path, config_path, thread_id = sys.argv[1:]

def candidate_codex_roots():
    roots = []
    for path in (state_db_path, logs_db_path, session_index_path, config_path):
        if not path:
            continue
        real_path = os.path.realpath(path)
        root = real_path if os.path.isdir(real_path) else os.path.dirname(real_path)
        if root and root not in roots:
            roots.append(root)
    default_root = os.path.realpath(os.path.join(os.path.expanduser("~"), ".codex"))
    if default_root not in roots:
        roots.append(default_root)
    return roots

def allowed_rollout_roots():
    roots = []
    for codex_root in candidate_codex_roots():
        for suffix in ("sessions", "archived_sessions"):
            root = os.path.realpath(os.path.join(codex_root, suffix))
            if root not in roots:
                roots.append(root)
    return roots

def rollout_path_is_allowed(path):
    if not path:
        return True
    real_path = os.path.realpath(path)
    for root in allowed_rollout_roots():
        real_root = os.path.realpath(root)
        try:
            if os.path.commonpath([real_path, real_root]) == real_root:
                return True
        except ValueError:
            continue
    return False

def count_session_index_entries(path, target_thread_id):
    if not os.path.exists(path):
        return 0
    count = 0
    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            stripped = raw_line.strip()
            if not stripped:
                continue
            try:
                obj = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if obj.get("id") == target_thread_id:
                count += 1
    return count

conn = sqlite3.connect(state_db_path)
cur = conn.cursor()
row = cur.execute(
    "select rollout_path, archived from threads where id = ?",
    (thread_id,),
).fetchone()
if row is None:
    print("status: failed")
    print("reason: thread_not_found")
    print(f"thread_id: {thread_id}")
    raise SystemExit(1)

rollout_path, archived = row
if not rollout_path_is_allowed(rollout_path):
    print("status: failed")
    print("reason: rollout_path_not_allowed")
    print(f"thread_id: {thread_id}")
    print(f"rollout_path: {rollout_path}")
    print("rollout_path_allowed: no")
    print("detail: rollout_path is outside allowed Codex session roots")
    raise SystemExit(1)

dynamic_tool_rows = cur.execute(
    "select count(*) from thread_dynamic_tools where thread_id = ?",
    (thread_id,),
).fetchone()[0]
stage1_output_rows = cur.execute(
    "select count(*) from stage1_outputs where thread_id = ?",
    (thread_id,),
).fetchone()[0]
state_log_rows = cur.execute(
    "select count(*) from logs where thread_id = ?",
    (thread_id,),
).fetchone()[0]
conn.close()

logs_db_present = os.path.exists(logs_db_path)
logs_db_rows = 0
if logs_db_present:
    logs_conn = sqlite3.connect(logs_db_path)
    logs_cur = logs_conn.cursor()
    logs_db_rows = logs_cur.execute(
        "select count(*) from logs where thread_id = ?",
        (thread_id,),
    ).fetchone()[0]
    logs_conn.close()

session_index_entries = count_session_index_entries(session_index_path, thread_id)
rollout_exists = bool(rollout_path and os.path.exists(rollout_path))

print("status: success")
print("reason: delete_plan_ready")
print(f"thread_id: {thread_id}")
print(f"rollout_path: {rollout_path}")
print("rollout_path_allowed: yes")
print(f"archived: {'yes' if archived else 'no'}")
print(f"dynamic_tool_rows: {dynamic_tool_rows}")
print(f"stage1_output_rows: {stage1_output_rows}")
print(f"state_log_rows: {state_log_rows}")
print(f"logs_db_present: {'yes' if logs_db_present else 'no'}")
print(f"logs_db_rows: {logs_db_rows}")
print(f"session_index_entries: {session_index_entries}")
print(f"rollout_exists: {'yes' if rollout_exists else 'no'}")
print("planned_steps: state_db_cleanup,logs_db_cleanup,session_index_cleanup,rollout_cleanup")
PY
}

thread_list() {
  local archived="${1:-0}"
  codex_app_server_thread_rpc "list" "" "" "$archived"
}

probe_all_sessions_text() {
  require_cmd sqlite3
  require_cmd python3

  local thread_id
  local updated_at
  local display_name
  local probe_output
  local encoded_name

  while IFS=$'\t' read -r thread_id updated_at encoded_name; do
    [[ -n "${thread_id:-}" ]] || continue
    display_name="$(printf '%s' "${encoded_name:-}" | python3 -c 'import base64,sys; data=sys.stdin.read().strip(); print(base64.b64decode(data).decode("utf-8") if data else "", end="")')"
    echo "---"
    if probe_output="$(probe_session_status "$thread_id" 2>&1)"; then
      printf '%s\n' "$probe_output"
    else
      printf 'target: %s\n' "$thread_id"
      printf 'thread_id: %s\n' "$thread_id"
      printf 'name: %s\n' "$display_name"
      printf 'status: probe_failed\n'
      printf 'reason: %s\n' "$(printf '%s' "$probe_output" | tail -n 1)"
      printf 'tty: -\n'
      printf 'terminal_state: unavailable\n'
    fi
    printf 'updated_at_epoch: %s\n' "${updated_at:-0}"
  done < <(
    python3 - "$CODEX_STATE_DB_PATH" "$CODEX_SESSION_INDEX_PATH" "${PROBE_LIMIT:-}" "${PROBE_OFFSET:-0}" <<'PY'
import base64
import json
import os
import sqlite3
import sys

db_path, session_index_path, limit_text, offset_text = sys.argv[1:]
limit = int(limit_text) if limit_text else None
offset = int(offset_text or "0")

latest_names = {}
if os.path.exists(session_index_path):
    with open(session_index_path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                obj = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            thread_id = obj.get("id")
            thread_name = (obj.get("thread_name") or "").strip()
            if thread_id and thread_name:
                latest_names[thread_id] = thread_name

conn = sqlite3.connect(db_path)
cur = conn.cursor()
query = """
select
  id,
  updated_at
from threads
where archived = 0
order by updated_at desc
"""
params = []
if limit is not None:
    query += " limit ? offset ?"
    params.extend([limit, offset])

for thread_id, updated_at in cur.execute(query, params):
    display_name = latest_names.get(thread_id, "")
    encoded_name = base64.b64encode((display_name or "").encode("utf-8")).decode("ascii")
    print(f"{thread_id}\t{updated_at}\t{encoded_name}")
conn.close()
PY
  )
}

probe_all_sessions_json() {
  local probe_output
  probe_output="$(probe_all_sessions_text)"
  printf '%s\n' "$probe_output" | python3 -c '
import json
import sys

text = sys.stdin.read()
sessions = []
current = {}

def flush_current():
    global current
    if "thread_id" in current:
        sessions.append(current.copy())
    current.clear()

for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line:
        continue
    if line == "---":
        flush_current()
        continue
    if ": " in line:
        key, value = line.split(": ", 1)
        current[key] = value

flush_current()
print(json.dumps({"sessions": sessions}, ensure_ascii=False))
'
}

probe_all_sessions() {
  if [[ "${PROBE_ALL_JSON:-0}" == "1" ]]; then
    probe_all_sessions_json
    return 0
  fi

  probe_all_sessions_text
}

config_model_provider() {
  require_cmd python3
  python3 - "$CODEX_CONFIG_PATH" <<'PY'
import os
import sys

config_path = sys.argv[1]

if not os.path.exists(config_path):
    print("status: failed")
    print("reason: config_not_found")
    print(f"config_path: {config_path}")
    raise SystemExit(1)

provider = ""
try:
    import tomllib

    with open(config_path, "rb") as fh:
        parsed = tomllib.load(fh)
    provider = str(parsed.get("model_provider") or "").strip()
except Exception:
    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line.startswith("model_provider"):
                    continue
                if "=" not in line:
                    continue
                raw_value = line.split("=", 1)[1].strip()
                provider = raw_value.strip("\"'").strip()
                if provider:
                    break
    except Exception:
        print("status: failed")
        print("reason: config_read_failed")
        print(f"config_path: {config_path}")
        raise SystemExit(1)

if not provider:
    print("status: failed")
    print("reason: model_provider_not_found")
    print(f"config_path: {config_path}")
    raise SystemExit(1)

print("status: success")
print("reason: config_loaded")
print(f"config_path: {config_path}")
print(f"model_provider: {provider}")
PY
}

thread_provider_plan() {
  local thread_id="$1"
  local target_provider="$2"
  python3 - "$CODEX_STATE_DB_PATH" "$thread_id" "$target_provider" <<'PY'
import json
import sqlite3
import sys

db_path, thread_id, target_provider = sys.argv[1:]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
rows = cur.execute("select id, model_provider, source from threads").fetchall()
conn.close()

threads = {}
children = {}
for tid, provider, source in rows:
    parent_id = ""
    if source:
        try:
            source_obj = json.loads(source)
            parent_id = (((source_obj.get("subagent") or {}).get("thread_spawn") or {}).get("parent_thread_id") or "")
        except Exception:
            parent_id = ""
    threads[tid] = {"provider": provider or "", "parent_id": parent_id}
    if parent_id:
        children.setdefault(parent_id, []).append(tid)

if thread_id not in threads:
    print("status: failed")
    print("reason: thread_not_found")
    print(f"thread_id: {thread_id}")
    raise SystemExit(1)

root_thread_id = thread_id
visited = set()
while threads[root_thread_id]["parent_id"] and threads[root_thread_id]["parent_id"] in threads and root_thread_id not in visited:
    visited.add(root_thread_id)
    root_thread_id = threads[root_thread_id]["parent_id"]

family = []
stack = [root_thread_id]
seen = set()
while stack:
    current = stack.pop()
    if current in seen or current not in threads:
        continue
    seen.add(current)
    family.append(current)
    stack.extend(reversed(children.get(current, [])))

family_migrate_needed_count = sum(1 for item in family if threads[item]["provider"] != target_provider)
direct_child_count = len(children.get(thread_id, []))

print("status: success")
print("reason: plan_ready")
print(f"thread_id: {thread_id}")
print(f"root_thread_id: {root_thread_id}")
print(f"current_provider: {threads[thread_id]['provider']}")
print(f"target_provider: {target_provider}")
print(f"parent_thread_id: {threads[thread_id]['parent_id'] or '-'}")
print(f"is_subagent: {'yes' if threads[thread_id]['parent_id'] else 'no'}")
print(f"direct_child_count: {direct_child_count}")
print(f"family_count: {len(family)}")
print(f"family_migrate_needed_count: {family_migrate_needed_count}")
print(f"family_ids: {','.join(family)}")
PY
}

thread_family_plan() {
  local thread_id="$1"
  python3 - "$CODEX_STATE_DB_PATH" "$thread_id" <<'PY'
import json
import sqlite3
import sys

db_path, thread_id = sys.argv[1:]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
rows = cur.execute("select id, source from threads").fetchall()
conn.close()

threads = {}
children = {}
for tid, source in rows:
    parent_id = ""
    if source:
        try:
            source_obj = json.loads(source)
            parent_id = (((source_obj.get("subagent") or {}).get("thread_spawn") or {}).get("parent_thread_id") or "")
        except Exception:
            parent_id = ""
    threads[tid] = {"parent_id": parent_id}
    if parent_id:
        children.setdefault(parent_id, []).append(tid)

if thread_id not in threads:
    print("status: failed")
    print("reason: thread_not_found")
    print(f"thread_id: {thread_id}")
    raise SystemExit(1)

parent_thread_id = threads[thread_id]["parent_id"] or "-"
root_thread_id = thread_id
visited = set()
while threads[root_thread_id]["parent_id"] and threads[root_thread_id]["parent_id"] in threads and root_thread_id not in visited:
    visited.add(root_thread_id)
    root_thread_id = threads[root_thread_id]["parent_id"]

family = []
stack = [root_thread_id]
seen = set()
while stack:
    current = stack.pop()
    if current in seen or current not in threads:
        continue
    seen.add(current)
    family.append(current)
    stack.extend(reversed(children.get(current, [])))

descendants = []
stack = list(reversed(children.get(thread_id, [])))
seen = set()
while stack:
    current = stack.pop()
    if current in seen or current not in threads:
        continue
    seen.add(current)
    descendants.append(current)
    stack.extend(reversed(children.get(current, [])))

print("status: success")
print("reason: plan_ready")
print(f"thread_id: {thread_id}")
print(f"parent_thread_id: {parent_thread_id}")
print(f"root_thread_id: {root_thread_id}")
print(f"is_subagent: {'yes' if parent_thread_id != '-' else 'no'}")
print(f"direct_child_count: {len(children.get(thread_id, []))}")
print(f"descendant_count: {len(descendants)}")
print(f"descendant_ids: {','.join(descendants)}")
print(f"family_count: {len(family)}")
print(f"family_ids: {','.join(family)}")
PY
}

thread_provider_plan_all() {
  local target_provider="$1"
  python3 - "$CODEX_STATE_DB_PATH" "$target_provider" <<'PY'
import sqlite3
import sys

db_path, target_provider = sys.argv[1:]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
rows = cur.execute("select model_provider from threads").fetchall()
conn.close()
total = len(rows)
migrate_needed = sum(1 for (provider,) in rows if (provider or "") != target_provider)
print("status: success")
print("reason: plan_ready")
print(f"target_provider: {target_provider}")
print(f"total_threads: {total}")
print(f"migrate_needed_count: {migrate_needed}")
print(f"already_matching_count: {total - migrate_needed}")
PY
}

thread_provider_migrate() {
  local thread_id="$1"
  local target_provider="$2"
  local migrate_family="${3:-0}"
  python3 - "$CODEX_STATE_DB_PATH" "$thread_id" "$target_provider" "$migrate_family" <<'PY'
import json
import sqlite3
import sys
import time

db_path, thread_id, target_provider, migrate_family_flag = sys.argv[1:]
migrate_family = migrate_family_flag == "1"
conn = sqlite3.connect(db_path)
cur = conn.cursor()
rows = cur.execute("select id, model_provider, source from threads").fetchall()

threads = {}
children = {}
for tid, provider, source in rows:
    parent_id = ""
    if source:
        try:
            source_obj = json.loads(source)
            parent_id = (((source_obj.get("subagent") or {}).get("thread_spawn") or {}).get("parent_thread_id") or "")
        except Exception:
            parent_id = ""
    threads[tid] = {"provider": provider or "", "parent_id": parent_id}
    if parent_id:
        children.setdefault(parent_id, []).append(tid)

if thread_id not in threads:
    print("status: failed")
    print("reason: thread_not_found")
    print(f"thread_id: {thread_id}")
    conn.close()
    raise SystemExit(1)

target_ids = [thread_id]
root_thread_id = thread_id
if migrate_family:
    visited = set()
    while threads[root_thread_id]["parent_id"] and threads[root_thread_id]["parent_id"] in threads and root_thread_id not in visited:
        visited.add(root_thread_id)
        root_thread_id = threads[root_thread_id]["parent_id"]
    target_ids = []
    stack = [root_thread_id]
    seen = set()
    while stack:
        current = stack.pop()
        if current in seen or current not in threads:
            continue
        seen.add(current)
        target_ids.append(current)
        stack.extend(reversed(children.get(current, [])))

changed = [tid for tid in target_ids if threads[tid]["provider"] != target_provider]
if changed:
    now = int(time.time())
    cur.executemany(
        "update threads set model_provider = ?, updated_at = ? where id = ?",
        [(target_provider, now, tid) for tid in changed],
    )
    conn.commit()
conn.close()

print("status: success")
print("reason: migrated")
print(f"thread_id: {thread_id}")
print(f"target_provider: {target_provider}")
print(f"scope: {'family' if migrate_family else 'current'}")
print(f"root_thread_id: {root_thread_id}")
print(f"migrated_count: {len(changed)}")
print(f"skipped_count: {len(target_ids) - len(changed)}")
print(f"target_ids: {','.join(target_ids)}")
PY
}

thread_provider_migrate_all() {
  local target_provider="$1"
  python3 - "$CODEX_STATE_DB_PATH" "$target_provider" <<'PY'
import sqlite3
import sys
import time

db_path, target_provider = sys.argv[1:]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
rows = cur.execute("select id, model_provider from threads").fetchall()
changed = [tid for tid, provider in rows if (provider or "") != target_provider]
if changed:
    now = int(time.time())
    cur.executemany(
        "update threads set model_provider = ?, updated_at = ? where id = ?",
        [(target_provider, now, tid) for tid in changed],
    )
    conn.commit()
conn.close()

print("status: success")
print("reason: migrated")
print(f"target_provider: {target_provider}")
print(f"migrated_count: {len(changed)}")
print(f"skipped_count: {len(rows) - len(changed)}")
print(f"total_threads: {len(rows)}")
PY
}

wait_until_idle() {
  local target="$1"
  local stable_seconds="$2"
  local timeout_seconds="$3"
  local started_at
  local stable_started=""

  started_at="$(date +%s)"
  while true; do
    local probe
    probe="$(probe_session_status "$target")"
    local status
    local terminal_state
    status="$(printf '%s\n' "$probe" | awk -F': ' '$1=="status"{print $2}')"
    terminal_state="$(printf '%s\n' "$probe" | awk -F': ' '$1=="terminal_state"{print $2}')"

    if [[ ( "$status" == "idle_stable" || "$status" == "interrupted_idle" ) && "$terminal_state" == "prompt_ready" ]]; then
      if [[ -z "$stable_started" ]]; then
        stable_started="$(date +%s)"
      fi
      if (( $(date +%s) - stable_started >= stable_seconds )); then
        printf '%s\n' "$probe"
        return 0
      fi
    else
      stable_started=""
    fi

    if (( $(date +%s) - started_at >= timeout_seconds )); then
      printf '%s\n' "$probe"
      return 1
    fi
    sleep 1
  done
}

send_message_when_ready() {
  local target="$1"
  local message="$2"
  local stable_seconds="${3:-$SEND_STABLE_IDLE_SECONDS}"
  local timeout_seconds="${4:-$SEND_IDLE_TIMEOUT_SECONDS}"
  local force_send="${5:-0}"
  if [[ -n "${CODEX_TASKMASTER_SEND_STUB:-}" ]]; then
    "$CODEX_TASKMASTER_SEND_STUB" "$target" "$message" "$stable_seconds" "$timeout_seconds" "$force_send"
    return $?
  fi
  local inflight_request=""
  inflight_request="$(find_matching_inflight_request "$target" "$message" "$force_send" 2>/dev/null || true)"
  if [[ -n "$inflight_request" ]]; then
    local inflight_request_id
    local inflight_queue_state
    local inflight_created_at
    inflight_request_id="$(extract_probe_field "$inflight_request" "request_id")"
    inflight_queue_state="$(extract_probe_field "$inflight_request" "queue_state")"
    inflight_created_at="$(extract_probe_field "$inflight_request" "created_at")"
    print_request_accepted_result \
      "request_already_inflight" \
      "$target" \
      "$([[ "$force_send" == "1" ]] && echo yes || echo no)" \
      "same target/message/force_send request is already ${inflight_queue_state:-pending} with request_id=${inflight_request_id:-unknown} created_at=${inflight_created_at:-0}"
    return 2
  fi
  local request_id
  request_id="$(queue_send_request "$target" "$message" "helper-send" "$timeout_seconds" "$force_send")"
  await_send_result "$request_id" "$(( timeout_seconds + 10 ))" "$target" "$force_send"
}

find_unique_tty() {
  local target="$1"
  local tty_list

  tty_list="$(
    if [[ -n "${CODEX_TASKMASTER_TTY_PS_FIXTURE:-}" ]]; then
      cat "$CODEX_TASKMASTER_TTY_PS_FIXTURE"
    else
      ps -axo tty=,command=
    fi | awk -v target="$target" '
      {
        needle = "codex resume " target
        pos = index($0, needle)
        if (pos > 0) {
          after = substr($0, pos + length(needle), 1)
          if (after == "" || after ~ /[[:space:]]/) {
            if (!seen[$1]++) {
              print $1
            }
          }
        }
      }
    '
  )"

  local count
  count="$(printf '%s\n' "$tty_list" | sed '/^$/d' | wc -l | tr -d ' ')"

  case "$count" in
    0)
      printf "could not find a running 'codex resume %s' process\n" "$target" >&2
      return 1
      ;;
    1) printf '%s\n' "$tty_list" | sed '/^$/d' ;;
    *)
      printf "found multiple matching Terminal ttys for target '%s': %s\n" "$target" "$(printf '%s' "$tty_list" | tr '\n' ' ')" >&2
      return 2
      ;;
  esac
}

find_terminal_tty_by_process_cwd() {
  local target="$1"
  local target_cwd="$2"

  python3 - "$target" "$target_cwd" "${CODEX_TASKMASTER_TTY_PROCESS_FIXTURE:-}" "${CODEX_TASKMASTER_TTY_CWD_FIXTURE:-}" <<'PY'
import os
import subprocess
import sys

target, target_cwd, process_fixture, cwd_fixture = sys.argv[1:]

def normalized_path(value: str) -> str:
    if not value:
        return ""
    return os.path.realpath(os.path.expanduser(value.strip()))

def parse_process_lines(raw: str):
    results = []
    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        pid, tty, command = parts
        if tty in {"", "-", "??"}:
            continue
        if "codex" not in command:
            continue
        if " resume " in command or command.endswith(" resume") or " fork " in command or command.endswith(" fork"):
            continue
        results.append((pid, tty, command))
    return results

def load_processes():
    if process_fixture:
        with open(process_fixture, "r", encoding="utf-8") as fh:
            return parse_process_lines(fh.read())
    proc = subprocess.run(
        ["ps", "-axo", "pid=,tty=,command="],
        text=True,
        capture_output=True,
        check=True,
    )
    return parse_process_lines(proc.stdout)

def load_cwd_fixture(path: str):
    mapping = {}
    if not path:
        return mapping
    with open(path, "r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            mapping[parts[0]] = normalized_path(parts[1])
    return mapping

fixture_cwds = load_cwd_fixture(cwd_fixture)

def resolve_process_cwd(pid: str) -> str:
    if pid in fixture_cwds:
        return fixture_cwds[pid]
    proc = subprocess.run(
        ["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        return ""
    for raw_line in proc.stdout.splitlines():
        if raw_line.startswith("n"):
            return normalized_path(raw_line[1:])
    return ""

target_cwd = normalized_path(target_cwd)
if not target_cwd:
    print(f"target '{target}' has no cwd metadata to resolve a live non-resume TTY", file=sys.stderr)
    raise SystemExit(1)

matches = []
seen_ttys = set()
for pid, tty, _command in load_processes():
    process_cwd = resolve_process_cwd(pid)
    if process_cwd != target_cwd:
        continue
    if tty in seen_ttys:
        continue
    seen_ttys.add(tty)
    matches.append(tty)

if not matches:
    print(
        f"could not find a running non-resume 'codex' process with cwd '{target_cwd}' for target '{target}'",
        file=sys.stderr,
    )
    raise SystemExit(1)

if len(matches) > 1:
    print(
        f"found multiple matching Terminal ttys for target '{target}': {' '.join(matches)}",
        file=sys.stderr,
    )
    raise SystemExit(2)

print(matches[0])
PY
}

find_terminal_tty_by_session_content() {
  local target="$1"
  local thread_id="$2"
  local session_name="$3"
  local thread_title="$4"
  local first_user_message="$5"
  local rollout_path="$6"

  python3 - "$target" "$thread_id" "$session_name" "$thread_title" "$first_user_message" "$rollout_path" "${CODEX_TASKMASTER_TTY_PROCESS_FIXTURE:-}" "${CODEX_TASKMASTER_TTY_PS_FIXTURE:-}" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

target, thread_id, session_name, thread_title, first_user_message, rollout_path, process_fixture, tty_ps_fixture = sys.argv[1:]

def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip()).lower()

def add_candidate(candidates, seen, text: str, weight: int, label: str):
    value = normalize(text)
    if not value:
        return
    if len(value) > 140:
        value = value[:140].rstrip()
    key = (value, label)
    if key in seen:
        return
    seen.add(key)
    candidates.append((value, weight, label))

def iter_process_lines():
    if process_fixture:
        return Path(process_fixture).read_text().splitlines()
    if tty_ps_fixture:
        return Path(tty_ps_fixture).read_text().splitlines()
    proc = subprocess.run(
        ["ps", "-axo", "pid=,tty=,command="],
        text=True,
        capture_output=True,
        check=True,
    )
    return proc.stdout.splitlines()

bare_codex_ttys = set()
try:
    for raw_line in iter_process_lines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) >= 3:
            _, tty, command = parts[0], parts[1], parts[2]
        elif len(parts) == 2:
            tty, command = parts
        else:
            continue
        if tty in {"??", "-", ""}:
            continue
        if "codex" not in command:
            continue
        if " resume " in command or command.endswith(" resume") or " fork " in command or command.endswith(" fork"):
            continue
        bare_codex_ttys.add(tty)
except Exception:
    bare_codex_ttys = set()

if not bare_codex_ttys:
    print(f"could not find a running non-resume 'codex' process for target '{target}'", file=sys.stderr)
    raise SystemExit(1)

record_separator = "<<<CTM_TAB>>>"
field_separator = "<<<CTM_FIELD>>>"
applescript = f'''
set recordSeparator to "{record_separator}"
set fieldSeparator to "{field_separator}"
set outputLines to {{}}
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      try
        set ttyValue to tty of t
        if ttyValue is not "" then
          set processText to ""
          try
            set processText to (processes of t as text)
          end try
          if processText contains "codex" then
            set contentText to ""
            try
              set contentText to contents of t
            end try
            set end of outputLines to ttyValue & fieldSeparator & processText & fieldSeparator & contentText
          end if
        end if
      end try
    end repeat
  end repeat
end tell
set AppleScript's text item delimiters to recordSeparator
return outputLines as text
'''

try:
    proc = subprocess.run(
        ["osascript", "-"],
        input=applescript,
        text=True,
        capture_output=True,
        check=True,
    )
    raw = proc.stdout
except Exception as exc:
    print(f"failed to inspect Terminal tabs for target '{target}': {exc}", file=sys.stderr)
    raise SystemExit(1)

candidates = []
seen = set()
add_candidate(candidates, seen, target, 20, "target")
add_candidate(candidates, seen, session_name, 40, "session_name")
add_candidate(candidates, seen, thread_id, 10, "thread_id")
add_candidate(candidates, seen, thread_title, 90, "thread_title")
add_candidate(candidates, seen, first_user_message, 90, "first_user_message")

rollout_candidates = []
try:
    for raw_line in Path(rollout_path).read_text().splitlines():
        try:
            obj = json.loads(raw_line)
        except Exception:
            continue
        if obj.get("type") != "event_msg":
            continue
        payload = obj.get("payload", {})
        if payload.get("type") != "user_message":
            continue
        message = payload.get("message") or ""
        if message.strip():
            rollout_candidates.append(message)
except Exception:
    rollout_candidates = []

for index, message in enumerate(reversed(rollout_candidates[-3:])):
    add_candidate(candidates, seen, message, 130 - (index * 10), f"recent_user_{index + 1}")

best_matches = []
for record in raw.split(record_separator):
    if not record.strip():
        continue
    parts = record.split(field_separator, 2)
    if len(parts) != 3:
        continue
    tty_value, process_text, contents = parts
    tty_value = tty_value.strip()
    if tty_value.startswith("/dev/"):
        tty_value = tty_value[5:]
    if tty_value not in bare_codex_ttys:
        continue

    normalized_contents = normalize(contents)
    score = 0
    matched_labels = []
    for candidate_text, weight, label in candidates:
        if candidate_text and candidate_text in normalized_contents:
            score += weight
            matched_labels.append(label)
    if score <= 0:
        continue
    best_matches.append((score, tty_value, ",".join(matched_labels)))

if not best_matches:
    tty_list = " ".join(sorted(bare_codex_ttys))
    print(f"could not match a running non-resume 'codex' Terminal tab for target '{target}' among ttys: {tty_list}", file=sys.stderr)
    raise SystemExit(1)

best_matches.sort(key=lambda item: (-item[0], item[1]))
top_score = best_matches[0][0]
top = [item for item in best_matches if item[0] == top_score]

if len(top) > 1:
    details = " ".join(f"{tty}({labels})" for _, tty, labels in top)
    print(f"found multiple matching non-resume Terminal ttys for target '{target}': {details}", file=sys.stderr)
    raise SystemExit(2)

print(top[0][1])
PY
}

resolve_live_tty() {
  local target="$1"
  local thread_id
  local rollout_path
  local thread_title
  local first_user_message
  local session_name

  thread_id="$(resolve_live_thread_id "$target")"
  local target_cwd
  local model_provider
  local session_source
  local agent_nickname
  local agent_role
  {
    IFS= read -r -d '' rollout_path || true
    IFS= read -r -d '' thread_title || true
    IFS= read -r -d '' first_user_message || true
    IFS= read -r -d '' target_cwd || true
    IFS= read -r -d '' session_name || true
    IFS= read -r -d '' model_provider || true
    IFS= read -r -d '' session_source || true
    IFS= read -r -d '' agent_nickname || true
    IFS= read -r -d '' agent_role || true
  } < <(read_target_metadata_fields "$(load_target_metadata "$thread_id" 2>/dev/null)")
  resolve_target_tty "$target" "$thread_id" "$thread_title" "$first_user_message" "$session_name" "$target_cwd" "$rollout_path"
}

send_once_via_terminal_gui() {
  local target="$1"
  local message="$2"
  local tty_name
  local tty_path

  require_cmd osascript
  tty_name="$(resolve_live_tty "$target")"
  tty_path="$tty_name"
  [[ "$tty_path" == /dev/* ]] || tty_path="/dev/${tty_path}"

  osascript - "$tty_path" "$message" "$PASTE_DELAY_SECONDS" "$SUBMIT_DELAY_SECONDS" "$RESTORE_CLIPBOARD_DELAY_SECONDS" <<'APPLESCRIPT'
on run argv
  set targetTTY to item 1 of argv
  set payload to item 2 of argv
  set pasteDelay to (item 3 of argv) as real
  set submitDelay to (item 4 of argv) as real
  set restoreDelay to (item 5 of argv) as real
  set oldClipboard to the clipboard
  set foundWindow to false

  tell application "Terminal"
    activate
    repeat with w in windows
      try
        if (tty of selected tab of w) is equal to targetTTY then
          set index of w to 1
          set foundWindow to true
          exit repeat
        end if
      end try
    end repeat
  end tell

  if foundWindow is false then
    error "could not focus Terminal window for " & targetTTY
  end if

  set the clipboard to payload
  delay pasteDelay

  tell application "System Events"
    tell process "Terminal"
      keystroke "v" using command down
      delay submitDelay
      key code 36
    end tell
  end tell

  delay restoreDelay
  set the clipboard to oldClipboard
end run
APPLESCRIPT

  printf 'sent message via Terminal GUI to target=%s tty=%s\n' "$target" "$tty_name"
}

process_loops_once() {
  local loop_file
  local now
  now="$(date +%s)"

  shopt -s nullglob
  for loop_file in "$LOOPS_DIR"/*.loop; do
    local key
    key="$(basename "${loop_file%.loop}")"
    dispatch_loop_if_due "$key" "$loop_file" "$now"
  done
  shopt -u nullglob
}

dispatch_loop_if_due() {
  local key="$1"
  local loop_file="$2"
  local now="$3"
  local source_tag
  local next_run=0

  paths_for_target "$key"
  loop_runner_running && return 0

  source_tag="$(loop_source_tag_for_file "$loop_file")"
  load_current_loop_status_file "$source_tag" >/dev/null 2>&1 || true
  [[ "${STOPPED:-0}" == "1" ]] && return 0
  [[ "${PAUSED:-0}" == "1" ]] && return 0
  if [[ "${NEXT_RUN:-}" =~ ^[0-9]+$ ]]; then
    next_run="$NEXT_RUN"
  fi
  if [[ "$next_run" =~ ^[0-9]+$ ]] && (( now < next_run )); then
    return 0
  fi

  (
    paths_for_target "$key"
    printf '%s\n' "${BASHPID:-$$}" >"$LOOP_RUNNER_PID_FILE"
    trap 'rm -f "$LOOP_RUNNER_PID_FILE"' EXIT
    run_loop_iteration_for_key "$key" "$loop_file"
  ) &
}

run_loop_iteration_for_key() {
  local key="$1"
  local loop_file="$2"
  local now
  now="$(date +%s)"

  TARGET=""
  INTERVAL=""
  MESSAGE=""
  FORCE_SEND="0"
  THREAD_ID=""
  load_kv_file "$loop_file"

  local target="$TARGET"
  local interval="$INTERVAL"
  local message="$MESSAGE"
  local force_send="${FORCE_SEND:-0}"
  local thread_id="${THREAD_ID:-}"
  local source_tag
  local next_run=0
  local failure_count=0
  local failure_reason=""

  paths_for_target "$key"
  source_tag="$(loop_source_tag_for_file "$loop_file")"

  load_current_loop_status_file "$source_tag" >/dev/null 2>&1 || true
  [[ "${STOPPED:-0}" == "1" ]] && return 0
  [[ "${PAUSED:-0}" == "1" ]] && return 0
  if [[ "${NEXT_RUN:-}" =~ ^[0-9]+$ ]]; then
    next_run="$NEXT_RUN"
  fi
  if [[ "${FAILURE_COUNT:-}" =~ ^[0-9]+$ ]]; then
    failure_count="$FAILURE_COUNT"
  fi
  failure_reason="${FAILURE_REASON:-}"
  if [[ "$next_run" =~ ^[0-9]+$ ]] && (( now < next_run )); then
    return 0
  fi

  local conflicting_target=""
  conflicting_target="$(find_conflicting_running_loop_target "$thread_id" "$key" "1" 2>/dev/null || true)"
  if [[ -n "$conflicting_target" ]]; then
    append_loop_log_line "$LOOP_LOG_FILE" "paused: active loop conflict target=${target} conflicting_target=${conflicting_target} thread_id=${thread_id}"
    runner_writeback_allowed "$key" "$loop_file" "$source_tag" || return 0
    write_loop_status_kv "$source_tag" "$now" "1" "loop_conflict_active_session" "1" "loop_conflict_active_session" "0" ""
    return 0
  fi

  local send_output
  local send_status
  local current_failure_reason
  if send_output="$(send_message_when_ready "$target" "$message" "$SEND_STABLE_IDLE_SECONDS" "$LOOP_IDLE_TIMEOUT_SECONDS" "$force_send" 2>&1)"; then
    append_loop_log_line "$LOOP_LOG_FILE" "sent: ${send_output//$'\n'/ | }"
    sleep "$LOOP_POST_SEND_COOLDOWN_SECONDS"
    now="$(date +%s)"
    runner_writeback_allowed "$key" "$loop_file" "$source_tag" || return 0
    write_loop_status_kv "$source_tag" "$(( now + interval ))" "0" "" "0" "" "0" ""
    return 0
  fi

  send_status=$?
  if [[ "$send_status" -eq 2 ]]; then
    local accepted_reason
    local accepted_delay
    accepted_reason="$(extract_probe_field "$send_output" "reason")"
    [[ -n "$accepted_reason" ]] || accepted_reason="accepted"
    accepted_delay="$(accepted_retry_delay_seconds "$interval" "$accepted_reason")"
    append_loop_log_line "$LOOP_LOG_FILE" "accepted: ${send_output//$'\n'/ | }"
    now="$(date +%s)"
    runner_writeback_allowed "$key" "$loop_file" "$source_tag" || return 0
    write_loop_status_kv "$source_tag" "$(( now + accepted_delay ))" "0" "" "0" "" "0" ""
    return 0
  fi

  local retry_delay
  current_failure_reason="$(extract_probe_field "$send_output" "reason")"
  [[ -n "$current_failure_reason" ]] || current_failure_reason="unknown_failure"

  append_loop_log_line "$LOOP_LOG_FILE" "deferred: ${send_output//$'\n'/ | }"
  now="$(date +%s)"
  if [[ "$force_send" == "1" ]]; then
    if [[ "$failure_reason" == "$current_failure_reason" ]]; then
      failure_count="$(( failure_count + 1 ))"
    else
      failure_count=1
    fi
  else
    failure_count=0
  fi

  if [[ "$force_send" == "1" ]] && [[ "$LOOP_FAILURE_PAUSE_THRESHOLD" =~ ^[1-9][0-9]*$ ]] && (( failure_count >= LOOP_FAILURE_PAUSE_THRESHOLD )); then
    append_loop_log_line "$LOOP_LOG_FILE" "paused: consecutive forced-send failure threshold reached count=${failure_count} reason=${current_failure_reason}"
    runner_writeback_allowed "$key" "$loop_file" "$source_tag" || return 0
    write_loop_status_kv "$source_tag" "$now" "$failure_count" "$current_failure_reason" "1" "$current_failure_reason" "0" ""
  else
    retry_delay="$(failure_retry_delay_seconds "$LOOP_BUSY_RETRY_SECONDS" "$current_failure_reason" "$force_send")"
    runner_writeback_allowed "$key" "$loop_file" "$source_tag" || return 0
    write_loop_status_kv "$source_tag" "$(( now + retry_delay ))" "$failure_count" "$current_failure_reason" "0" "" "0" ""
  fi
}

loop_daemon_loop() {
  mkdir -p "$LOOPS_DIR" "$RUNTIME_DIR" "$LOOP_STATE_DIR" "$LOOP_LOG_DIR"
  printf '%s\n' "$$" >"$LOOP_DAEMON_PID_FILE"
  trap 'rm -f "$LOOP_DAEMON_PID_FILE"' EXIT

  while true; do
    process_loops_once
    sleep 1
  done
}

ensure_loop_daemon() {
  require_cmd python3
  require_cmd osascript

  stop_user_owned_sender_daemons || true

  if loop_daemon_running; then
    return 0
  fi

  python3 - "$0" "$STATE_DIR" "$LOOP_DAEMON_LOG_FILE" <<'PY'
import os
import sys

script = sys.argv[1]
state_dir = sys.argv[2]
log_file = sys.argv[3]

pid = os.fork()
if pid > 0:
    os.waitpid(pid, 0)
    sys.exit(0)

os.setsid()

pid = os.fork()
if pid > 0:
    sys.exit(0)

fd0 = os.open("/dev/null", os.O_RDONLY)
fd1 = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
fd2 = os.open(log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
os.dup2(fd0, 0)
os.dup2(fd1, 1)
os.dup2(fd2, 2)
for fd in (fd0, fd1, fd2):
    if fd > 2:
        os.close(fd)

env = os.environ.copy()
env["CODEX_TASKMASTER_STATE_DIR"] = state_dir
os.execve(script, [script, "loop-daemon", f"--state-dir={state_dir}"], env)
PY

  sleep 1
  loop_daemon_running || die "failed to start loop daemon"
}

start_loop() {
  local target="$1"
  local interval="$2"
  local message="$3"
  local force_send="${4:-0}"
  local key
  local source_tag
  local thread_id
  local rollout_path
  local thread_title
  local first_user_message
  local session_name
  local start_detail
  local failure_reason
  local conflicting_target

  key="$(hash_target "$target")"
  paths_for_target "$key"

  if ! start_detail="$(resolve_live_thread_id "$target" 2>&1)"; then
    failure_reason="$(classify_loop_reason "$start_detail")"
    mark_loop_stopped_entry "$target" "$interval" "$message" "$force_send" "$failure_reason" "loop start failed target=${target} reason=${failure_reason} detail=${start_detail//$'\n'/ | }"
    stop_loop_daemon_if_idle
    printf '%s\n' "$start_detail" >&2
    return 1
  fi
  thread_id="$start_detail"

  conflicting_target="$(find_conflicting_running_loop_target "$thread_id" "$key" 2>/dev/null || true)"
  if [[ -n "$conflicting_target" ]]; then
    failure_reason="loop_conflict_active_session"
    mark_loop_stopped_entry "$target" "$interval" "$message" "$force_send" "$failure_reason" "loop start blocked target=${target} reason=${failure_reason} conflicting_target=${conflicting_target} thread_id=${thread_id}" "$thread_id"
    stop_loop_daemon_if_idle
    printf 'another active loop already targets this session: %s\n' "$conflicting_target" >&2
    return 1
  fi

  if ! start_detail="$(load_target_metadata "$thread_id" 2>/dev/null)"; then
    failure_reason="start_failed"
    mark_loop_stopped_entry "$target" "$interval" "$message" "$force_send" "$failure_reason" "loop start failed target=${target} reason=${failure_reason} detail=failed_to_load_target_metadata" "$thread_id"
    stop_loop_daemon_if_idle
    die "failed to load target metadata for thread '${thread_id}'"
  fi
  local target_cwd
  local model_provider
  local session_source
  local agent_nickname
  local agent_role
  {
    IFS= read -r -d '' rollout_path || true
    IFS= read -r -d '' thread_title || true
    IFS= read -r -d '' first_user_message || true
    IFS= read -r -d '' target_cwd || true
    IFS= read -r -d '' session_name || true
    IFS= read -r -d '' model_provider || true
    IFS= read -r -d '' session_source || true
    IFS= read -r -d '' agent_nickname || true
    IFS= read -r -d '' agent_role || true
  } < <(read_target_metadata_fields "$start_detail")

  if ! start_detail="$(resolve_target_tty "$target" "$thread_id" "$thread_title" "$first_user_message" "$session_name" "$target_cwd" "$rollout_path" 2>&1)"; then
    failure_reason="$(classify_loop_reason "$start_detail")"
    mark_loop_stopped_entry "$target" "$interval" "$message" "$force_send" "$failure_reason" "loop start failed target=${target} reason=${failure_reason} detail=${start_detail//$'\n'/ | }" "$thread_id"
    stop_loop_daemon_if_idle
    printf '%s\n' "$start_detail" >&2
    return 1
  fi

  if ! start_detail="$(ensure_loop_daemon 2>&1)"; then
    failure_reason="start_failed"
    mark_loop_stopped_entry "$target" "$interval" "$message" "$force_send" "$failure_reason" "loop start failed target=${target} reason=${failure_reason}${start_detail:+ detail=${start_detail//$'\n'/ | }}" "$thread_id"
    stop_loop_daemon_if_idle
    printf '%s\n' "${start_detail:-failed to start loop daemon}" >&2
    return 1
  fi

  write_loop_definition "$key" "$target" "$interval" "$message" "$force_send" "$thread_id"
  source_tag="$(loop_source_tag)"
  write_loop_status_kv "$source_tag" "$(date +%s)" "0" "" "0" "" "0" ""
  append_loop_log_line "$LOOP_LOG_FILE" "loop started target=${target} interval=${interval}s force_send=$([[ "$force_send" == "1" ]] && echo yes || echo no) message=${message}"

  printf 'started loop\n'
  printf 'loop_id: %s\n' "$key"
  printf 'target: %s\n' "$target"
  printf 'interval_seconds: %s\n' "$interval"
  printf 'force_send: %s\n' "$([[ "$force_send" == "1" ]] && echo yes || echo no)"
  printf 'log: %s\n' "$LOOP_LOG_FILE"
}

resume_loop() {
  local target="${1:-}"
  local loop_id="${2:-}"
  local key
  local source_tag
  local failure_reason=""
  local thread_id
  local rollout_path
  local thread_title
  local first_user_message
  local session_name
  local conflicting_target
  key="$(resolve_loop_key "$target" "$loop_id")" || die "no loop found for selector"
  paths_for_target "$key"
  [[ -f "$LOOP_FILE" ]] || die "no loop found for selector"

  LOOP_ID="$key"
  TARGET=""
  INTERVAL=""
  MESSAGE=""
  FORCE_SEND="0"
  load_kv_file "$LOOP_FILE"
  target="${TARGET:-$target}"
  [[ -n "$target" ]] || die "loop file is missing target metadata"
  source_tag="$(loop_source_tag)"

  if load_current_loop_status_file "$source_tag"; then
    failure_reason="${PAUSED_REASON:-${STOPPED_REASON:-${FAILURE_REASON:-}}}"
  fi

  thread_id="$(resolve_live_thread_id "$target")"
  conflicting_target="$(find_conflicting_running_loop_target "$thread_id" "$key" 2>/dev/null || true)"
  [[ -z "$conflicting_target" ]] || die "another active loop already targets this session: ${conflicting_target}"
  local target_cwd
  local model_provider
  local session_source
  local agent_nickname
  local agent_role
  {
    IFS= read -r -d '' rollout_path || true
    IFS= read -r -d '' thread_title || true
    IFS= read -r -d '' first_user_message || true
    IFS= read -r -d '' target_cwd || true
    IFS= read -r -d '' session_name || true
    IFS= read -r -d '' model_provider || true
    IFS= read -r -d '' session_source || true
    IFS= read -r -d '' agent_nickname || true
    IFS= read -r -d '' agent_role || true
  } < <(read_target_metadata_fields "$(load_target_metadata "$thread_id" 2>/dev/null)")
  resolve_target_tty "$target" "$thread_id" "$thread_title" "$first_user_message" "$session_name" "$target_cwd" "$rollout_path" >/dev/null
  ensure_loop_daemon
  write_loop_definition "$key" "$target" "${INTERVAL:-$DEFAULT_INTERVAL}" "${MESSAGE:-$DEFAULT_MESSAGE}" "${FORCE_SEND:-0}" "$thread_id"

  write_loop_status_kv "$source_tag" "$(date +%s)" "0" "" "0" "" "0" ""
  append_loop_log_line "$LOOP_LOG_FILE" "loop resumed target=${target}${failure_reason:+ previous_reason=${failure_reason}}"

  printf 'resumed loop\n'
  printf 'loop_id: %s\n' "$key"
  printf 'target: %s\n' "$target"
  if [[ -n "$failure_reason" ]]; then
    printf 'previous_reason: %s\n' "$failure_reason"
  fi
  printf 'log: %s\n' "$LOOP_LOG_FILE"
}

stop_one() {
  local target="${1:-}"
  local loop_id="${2:-}"
  local key
  local source_tag
  key="$(resolve_loop_key "$target" "$loop_id")" || die "no loop found for selector"
  paths_for_target "$key"
  stop_loop_runner_for_key "$key"
  [[ -f "$LOOP_FILE" ]] || die "no loop found for selector"
  TARGET=""
  INTERVAL=""
  MESSAGE=""
  FORCE_SEND="0"
  load_kv_file "$LOOP_FILE"
  source_tag="$(loop_source_tag)"
  append_loop_log_line "$LOOP_LOG_FILE" "loop stopped target=${target}"
  write_loop_status_kv "$source_tag" "" "0" "" "0" "" "1" "stopped_by_user"
  stop_loop_daemon_if_idle
  printf 'stopped loop for target=%s\n' "$target"
}

stop_all() {
  local found=0
  local loop_file
  local target
  local key
  local source_tag

  shopt -s nullglob
  for loop_file in "$LOOPS_DIR"/*.loop; do
    found=1
    TARGET=""
    load_kv_file "$loop_file"
    target="${TARGET:-unknown}"
    key="$(basename "${loop_file%.loop}")"
    paths_for_target "$key"
    stop_loop_runner_for_key "$key"
    source_tag="$(loop_source_tag)"
    append_loop_log_line "$LOOP_LOG_FILE" "loop stopped target=${target}"
    write_loop_status_kv "$source_tag" "" "0" "" "0" "" "1" "stopped_by_user"
    printf 'stopped loop for target=%s\n' "$target"
  done
  shopt -u nullglob

  stop_loop_daemon_if_idle

  if [[ "$found" -eq 0 ]]; then
    echo "no loops"
  fi
}

delete_loop() {
  local target="${1:-}"
  local loop_id="${2:-}"
  local key
  key="$(resolve_loop_key "$target" "$loop_id")" || die "no loop found for selector"
  paths_for_target "$key"
  stop_loop_runner_for_key "$key"
  [[ -f "$LOOP_FILE" ]] || die "no loop found for selector"
  rm -f "$LOOP_FILE"
  rm -f "$LOOP_STATUS_FILE" 2>/dev/null || true
  rm -f "$LOOP_LOG_FILE" 2>/dev/null || true
  stop_loop_daemon_if_idle
  printf 'deleted loop for target=%s\n' "${target:-$key}"
}

save_loop_stopped() {
  local target="$1"
  local interval="$2"
  local message="$3"
  local force_send="${4:-0}"
  local stopped_reason="${5:-start_failed}"
  local loop_id="${6:-}"
  [[ -n "$loop_id" ]] || loop_id="$(generate_loop_key "$target")"
  paths_for_target "$loop_id"
  write_loop_definition "$loop_id" "$target" "$interval" "$message" "$force_send"
  local source_tag
  source_tag="$(loop_source_tag)"
  write_loop_status_kv "$source_tag" "" "0" "" "0" "" "1" "$stopped_reason"
  append_loop_log_line "$LOOP_LOG_FILE" "loop saved as stopped target=${target} reason=${stopped_reason}"
  printf 'saved stopped loop\n'
  printf 'loop_id: %s\n' "$loop_id"
  printf 'target: %s\n' "$target"
  printf 'interval_seconds: %s\n' "$interval"
  printf 'force_send: %s\n' "$([[ "$force_send" == "1" ]] && echo yes || echo no)"
  printf 'reason: %s\n' "$stopped_reason"
  printf 'log: %s\n' "$LOOP_LOG_FILE"
}

status_json_from_text() {
  local status_text="$1"
  printf '%s\n' "$status_text" | python3 -c '
import json
import sys

text = sys.stdin.read()
loops = []
warnings = []
current = {}

def flush_current():
    global current
    if "target" in current:
        loops.append(current.copy())
    current.clear()

for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line:
        continue
    if line == "---":
        flush_current()
        continue
    if line in {"no loops", "no active loops"}:
        continue
    if line.startswith("warning: "):
        warnings.append(line)
        continue
    if ": " in line:
        key, value = line.split(": ", 1)
        current[key] = value

flush_current()
print(json.dumps({"loops": loops, "warnings": warnings}, ensure_ascii=False))
'
}

status_one_text_by_key() {
  local key="$1"
  paths_for_target "$key"
  [[ -f "$LOOP_FILE" ]] || die "no loop status found for key '${key}'"

  LOOP_ID="$key"
  TARGET=""
  INTERVAL=""
  MESSAGE=""
  FORCE_SEND="0"
  THREAD_ID=""
  load_kv_file "$LOOP_FILE"

  local next_run="unknown"
  local last_log_line=""
  local paused="no"
  local pause_reason=""
  local stopped="no"
  local stopped_reason=""
  local failure_count="0"
  local failure_reason=""
  if load_current_loop_status_file "$(loop_source_tag)"; then
    next_run="${NEXT_RUN:-unknown}"
    [[ "${FAILURE_COUNT:-}" =~ ^[0-9]+$ ]] && failure_count="$FAILURE_COUNT"
    failure_reason="${FAILURE_REASON:-}"
    if [[ "${PAUSED:-0}" == "1" ]]; then
      paused="yes"
      pause_reason="${PAUSED_REASON:-$failure_reason}"
    fi
    if [[ "${STOPPED:-0}" == "1" ]]; then
      stopped="yes"
      stopped_reason="${STOPPED_REASON:-}"
    fi
  fi
  last_log_line="$(last_nonempty_log_line "$LOOP_LOG_FILE")"

  printf 'loop_id: %s\n' "${LOOP_ID:-$key}"
  printf 'target: %s\n' "${TARGET:-$key}"
  printf 'loop_daemon_running: %s\n' "$(loop_daemon_running && echo yes || echo no)"
  printf 'interval_seconds: %s\n' "${INTERVAL:-unknown}"
  printf 'force_send: %s\n' "$([[ "${FORCE_SEND:-0}" == "1" ]] && echo yes || echo no)"
  printf 'message: %s\n' "${MESSAGE:-unknown}"
  printf 'next_run_epoch: %s\n' "$next_run"
  printf 'stopped: %s\n' "$stopped"
  printf 'paused: %s\n' "$paused"
  printf 'failure_count: %s\n' "$failure_count"
  if [[ -n "$failure_reason" ]]; then
    printf 'failure_reason: %s\n' "$failure_reason"
  fi
  if [[ -n "$stopped_reason" ]]; then
    printf 'stopped_reason: %s\n' "$stopped_reason"
  fi
  if [[ -n "$pause_reason" ]]; then
    printf 'pause_reason: %s\n' "$pause_reason"
  fi
  printf 'log: %s\n' "$LOOP_LOG_FILE"
  if [[ -n "$last_log_line" ]]; then
    printf 'last_log_line: %s\n' "$last_log_line"
  fi
}

status_one_text() {
  local target="${1:-}"
  local loop_id="${2:-}"
  local key
  key="$(resolve_loop_key "$target" "$loop_id")" || die "no loop status found for selector"
  status_one_text_by_key "$key"
}

status_one() {
  local target="${1:-}"
  local loop_id="${2:-}"
  if [[ "${STATUS_JSON:-0}" == "1" ]]; then
    local status_text=""
    set +e
    status_text="$(status_one_text "$target" "$loop_id" 2>&1)"
    local exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
      printf '%s\n' "$status_text" >&2
      return "$exit_code"
    fi
    status_json_from_text "$status_text"
    return 0
  fi

  status_one_text "$target" "$loop_id"
}

status_all_text() {
  local loop_file
  local found=0

  shopt -s nullglob
  for loop_file in "$LOOPS_DIR"/*.loop; do
    found=1
    local key
    key="$(basename "${loop_file%.loop}")"
    echo "---"
    status_one_text_by_key "$key"
  done
  shopt -u nullglob

  if [[ "$found" -eq 0 ]]; then
    echo "no loops"
  fi

  legacy_sender_warning_lines || true
}

status_all() {
  if [[ "${STATUS_JSON:-0}" == "1" ]]; then
    local status_text
    status_text="$(status_all_text)"
    status_json_from_text "$status_text"
    return 0
  fi

  status_all_text
}

parse_send_args() {
  TARGET=""
  MESSAGE="$DEFAULT_MESSAGE"
  FORCE_SEND=0
  while getopts ":t:m:fh" opt; do
    case "$opt" in
      t) TARGET="$OPTARG" ;;
      m) MESSAGE="$OPTARG" ;;
      f) FORCE_SEND=1 ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$TARGET" ]] || die "send requires -t TARGET"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_loop_args() {
  TARGET=""
  MESSAGE="$DEFAULT_MESSAGE"
  INTERVAL="$DEFAULT_INTERVAL"
  FORCE_SEND=0
  while getopts ":t:m:i:fh" opt; do
    case "$opt" in
      t) TARGET="$OPTARG" ;;
      m) MESSAGE="$OPTARG" ;;
      i) INTERVAL="$OPTARG" ;;
      f) FORCE_SEND=1 ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$TARGET" ]] || die "command requires -t TARGET"
  [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "interval must be a positive integer in seconds"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_loop_save_stopped_args() {
  TARGET=""
  LOOP_ID=""
  MESSAGE="$DEFAULT_MESSAGE"
  INTERVAL="$DEFAULT_INTERVAL"
  FORCE_SEND=0
  LOOP_STOPPED_REASON="start_failed"
  while getopts ":t:k:m:i:r:fh" opt; do
    case "$opt" in
      t) TARGET="$OPTARG" ;;
      k) LOOP_ID="$OPTARG" ;;
      m) MESSAGE="$OPTARG" ;;
      i) INTERVAL="$OPTARG" ;;
      r) LOOP_STOPPED_REASON="$OPTARG" ;;
      f) FORCE_SEND=1 ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$TARGET" ]] || die "loop-save-stopped requires -t TARGET"
  [[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "interval must be a positive integer in seconds"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_stop_args() {
  TARGET=""
  LOOP_ID=""
  STOP_ALL=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t)
        [[ $# -ge 2 ]] || die "option -t requires an argument"
        TARGET="$2"
        shift 2
        ;;
      -k)
        [[ $# -ge 2 ]] || die "option -k requires an argument"
        LOOP_ID="$2"
        shift 2
        ;;
      --all)
        STOP_ALL=1
        shift
        ;;
      -h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
  if [[ "$STOP_ALL" -eq 0 && -z "$TARGET" && -z "$LOOP_ID" ]]; then
    die "stop requires -t TARGET, -k LOOP_ID or --all"
  fi
}

parse_loop_delete_args() {
  TARGET=""
  LOOP_ID=""
  while getopts ":t:k:h" opt; do
    case "$opt" in
      t) TARGET="$OPTARG" ;;
      k) LOOP_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$TARGET" || -n "$LOOP_ID" ]] || die "loop-delete requires -t TARGET or -k LOOP_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_status_args() {
  TARGET=""
  LOOP_ID=""
  STATUS_JSON=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t)
        [[ $# -ge 2 ]] || die "option -t requires an argument"
        TARGET="$2"
        shift 2
        ;;
      -k)
        [[ $# -ge 2 ]] || die "option -k requires an argument"
        LOOP_ID="$2"
        shift 2
        ;;
      --json)
        STATUS_JSON=1
        shift
        ;;
      -h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_probe_args() {
  TARGET=""
  LOOP_ID=""
  while getopts ":t:k:h" opt; do
    case "$opt" in
      t) TARGET="$OPTARG" ;;
      k) LOOP_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$TARGET" || -n "$LOOP_ID" ]] || die "command requires -t TARGET or -k LOOP_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_probe_all_args() {
  PROBE_LIMIT=""
  PROBE_OFFSET=0
  PROBE_ALL_JSON=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -l)
        [[ $# -ge 2 ]] || die "option -l requires an argument"
        PROBE_LIMIT="$2"
        shift 2
        ;;
      -o)
        [[ $# -ge 2 ]] || die "option -o requires an argument"
        PROBE_OFFSET="$2"
        shift 2
        ;;
      --json)
        PROBE_ALL_JSON=1
        shift
        ;;
      -h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        break
        ;;
    esac
  done
  [[ -z "$PROBE_LIMIT" || "$PROBE_LIMIT" =~ ^[1-9][0-9]*$ ]] || die "limit must be a positive integer"
  [[ "$PROBE_OFFSET" =~ ^[0-9]+$ ]] || die "offset must be a non-negative integer"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_session_count_args() {
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_config_model_provider_args() {
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_name_set_args() {
  THREAD_ID=""
  THREAD_NAME=""
  while getopts ":t:n:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      n) THREAD_NAME="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-name-set requires -t THREAD_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_archive_args() {
  THREAD_ID=""
  while getopts ":t:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-archive requires -t THREAD_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_unarchive_args() {
  THREAD_ID=""
  while getopts ":t:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-unarchive requires -t THREAD_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_delete_args() {
  THREAD_ID=""
  while getopts ":t:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-delete requires -t THREAD_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_delete_plan_args() {
  THREAD_ID=""
  while getopts ":t:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-delete-plan requires -t THREAD_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_family_plan_args() {
  THREAD_ID=""
  while getopts ":t:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-family-plan requires -t THREAD_ID"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_list_args() {
  THREAD_LIST_ARCHIVED=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --archived)
        THREAD_LIST_ARCHIVED=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

parse_thread_provider_plan_args() {
  THREAD_ID=""
  THREAD_PROVIDER=""
  while getopts ":t:p:h" opt; do
    case "$opt" in
      t) THREAD_ID="$OPTARG" ;;
      p) THREAD_PROVIDER="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_ID" ]] || die "thread-provider-plan requires -t THREAD_ID"
  [[ -n "$THREAD_PROVIDER" ]] || die "thread-provider-plan requires -p PROVIDER"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_provider_plan_all_args() {
  THREAD_PROVIDER=""
  while getopts ":p:h" opt; do
    case "$opt" in
      p) THREAD_PROVIDER="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_PROVIDER" ]] || die "thread-provider-plan-all requires -p PROVIDER"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_thread_provider_migrate_args() {
  THREAD_ID=""
  THREAD_PROVIDER=""
  THREAD_MIGRATE_FAMILY=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t)
        [[ $# -ge 2 ]] || die "option -t requires an argument"
        THREAD_ID="$2"
        shift 2
        ;;
      -p)
        [[ $# -ge 2 ]] || die "option -p requires an argument"
        THREAD_PROVIDER="$2"
        shift 2
        ;;
      --family)
        THREAD_MIGRATE_FAMILY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
  [[ -n "$THREAD_ID" ]] || die "thread-provider-migrate requires -t THREAD_ID"
  [[ -n "$THREAD_PROVIDER" ]] || die "thread-provider-migrate requires -p PROVIDER"
}

parse_thread_provider_migrate_all_args() {
  THREAD_PROVIDER=""
  while getopts ":p:h" opt; do
    case "$opt" in
      p) THREAD_PROVIDER="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$THREAD_PROVIDER" ]] || die "thread-provider-migrate-all requires -p PROVIDER"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_wait_idle_args() {
  TARGET=""
  STABLE_SECONDS=3
  TIMEOUT_SECONDS=30
  while getopts ":t:s:w:h" opt; do
    case "$opt" in
      t) TARGET="$OPTARG" ;;
      s) STABLE_SECONDS="$OPTARG" ;;
      w) TIMEOUT_SECONDS="$OPTARG" ;;
      h) usage; exit 0 ;;
      :) die "option -$OPTARG requires an argument" ;;
      \?) die "unknown option: -$OPTARG" ;;
    esac
  done
  shift $((OPTIND - 1))
  [[ -n "$TARGET" ]] || die "wait-idle requires -t TARGET"
  [[ "$STABLE_SECONDS" =~ ^[0-9]+$ ]] || die "stable seconds must be a non-negative integer"
  [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "timeout seconds must be a positive integer"
  [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
}

parse_loop_daemon_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state-dir=*)
        shift
        ;;
      --state-dir)
        [[ $# -ge 2 ]] || die "--state-dir requires a value"
        shift 2
        ;;
      *)
        die "unexpected positional arguments: $*"
        ;;
    esac
  done
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 2; }
  shift

  case "$cmd" in
    send)
      parse_send_args "$@"
      send_message_when_ready "$TARGET" "$MESSAGE" "$SEND_STABLE_IDLE_SECONDS" "$SEND_IDLE_TIMEOUT_SECONDS" "$FORCE_SEND"
      ;;
    start)
      parse_loop_args "$@"
      start_loop "$TARGET" "$INTERVAL" "$MESSAGE" "$FORCE_SEND"
      ;;
    stop)
      parse_stop_args "$@"
      if [[ "${STOP_ALL:-0}" -eq 1 ]]; then
        stop_all
      else
        stop_one "$TARGET" "$LOOP_ID"
      fi
      ;;
    loop-delete)
      parse_loop_delete_args "$@"
      delete_loop "$TARGET" "$LOOP_ID"
      ;;
    loop-save-stopped)
      parse_loop_save_stopped_args "$@"
      save_loop_stopped "$TARGET" "$INTERVAL" "$MESSAGE" "$FORCE_SEND" "$LOOP_STOPPED_REASON" "$LOOP_ID"
      ;;
    status)
      parse_status_args "$@"
      if [[ -n "$TARGET" || -n "$LOOP_ID" ]]; then
        status_one "$TARGET" "$LOOP_ID"
      else
        status_all
      fi
      ;;
    probe)
      parse_probe_args "$@"
      probe_session_status "$TARGET"
      ;;
    resolve-thread-id)
      parse_probe_args "$@"
      resolve_thread_id "$TARGET"
      ;;
    resolve-live-tty)
      parse_probe_args "$@"
      resolve_live_tty "$TARGET"
      ;;
    probe-all)
      parse_probe_all_args "$@"
      probe_all_sessions
      ;;
    session-count)
      parse_session_count_args "$@"
      session_count
      ;;
    thread-name-set)
      parse_thread_name_set_args "$@"
      thread_name_set "$THREAD_ID" "$THREAD_NAME"
      ;;
    thread-archive)
      parse_thread_archive_args "$@"
      thread_archive "$THREAD_ID"
      ;;
    thread-unarchive)
      parse_thread_unarchive_args "$@"
      thread_unarchive "$THREAD_ID"
      ;;
    thread-delete)
      parse_thread_delete_args "$@"
      thread_delete "$THREAD_ID"
      ;;
    thread-delete-plan)
      parse_thread_delete_plan_args "$@"
      thread_delete_plan "$THREAD_ID"
      ;;
    thread-family-plan)
      parse_thread_family_plan_args "$@"
      thread_family_plan "$THREAD_ID"
      ;;
    thread-list)
      parse_thread_list_args "$@"
      thread_list "$THREAD_LIST_ARCHIVED"
      ;;
    thread-provider-plan)
      parse_thread_provider_plan_args "$@"
      thread_provider_plan "$THREAD_ID" "$THREAD_PROVIDER"
      ;;
    thread-provider-plan-all)
      parse_thread_provider_plan_all_args "$@"
      thread_provider_plan_all "$THREAD_PROVIDER"
      ;;
    thread-provider-migrate)
      parse_thread_provider_migrate_args "$@"
      thread_provider_migrate "$THREAD_ID" "$THREAD_PROVIDER" "$THREAD_MIGRATE_FAMILY"
      ;;
    thread-provider-migrate-all)
      parse_thread_provider_migrate_all_args "$@"
      thread_provider_migrate_all "$THREAD_PROVIDER"
      ;;
    config-model-provider)
      parse_config_model_provider_args "$@"
      config_model_provider
      ;;
    wait-idle)
      parse_wait_idle_args "$@"
      wait_until_idle "$TARGET" "$STABLE_SECONDS" "$TIMEOUT_SECONDS"
      ;;
    loop-once)
      [[ $# -eq 0 ]] || die "unexpected positional arguments: $*"
      process_loops_once
      ;;
    loop-resume)
      parse_probe_args "$@"
      resume_loop "$TARGET" "$LOOP_ID"
      ;;
    loop-daemon)
      parse_loop_daemon_args "$@"
      loop_daemon_loop
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
