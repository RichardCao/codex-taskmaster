#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/codex_terminal_sender.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-taskmaster-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'assertion failed: expected output to contain [%s]\n' "$needle" >&2
    printf 'full output:\n%s\n' "$haystack" >&2
    exit 1
  fi
}

HOME_DIR="${TEST_TMP}/home"
CODEX_DIR="${HOME_DIR}/.codex"
STATE_DIR="${TEST_TMP}/state"
mkdir -p "$CODEX_DIR" "$STATE_DIR"

STATE_DB="${TEST_TMP}/state.sqlite"
LOGS_DB="${TEST_TMP}/logs.sqlite"
SESSION_INDEX="${TEST_TMP}/session_index.jsonl"
ROLLOUT_A="${TEST_TMP}/rollout-a.jsonl"
ROLLOUT_B="${TEST_TMP}/rollout-b.jsonl"

cat >"$ROLLOUT_A" <<'EOF'
{"timestamp":"2026-03-31T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
{"timestamp":"2026-03-31T10:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}
EOF

cat >"$ROLLOUT_B" <<'EOF'
{"timestamp":"2026-03-31T11:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"second"}}
{"timestamp":"2026-03-31T11:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"b"}}
EOF

sqlite3 "$STATE_DB" <<EOF
create table threads (
  id text primary key,
  rollout_path text not null,
  updated_at integer not null,
  title text not null,
  first_user_message text not null default '',
  archived integer not null default 0
);
insert into threads(id, rollout_path, updated_at, title, first_user_message, archived) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '$ROLLOUT_A', 200, 'First prompt', 'First prompt', 0),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '$ROLLOUT_B', 100, 'Second prompt', 'Second prompt', 0);
EOF

sqlite3 "$LOGS_DB" <<'EOF'
create table logs (
  id integer primary key autoincrement,
  ts integer not null,
  ts_nanos integer not null default 0,
  level text,
  target text,
  message text,
  module_path text,
  file text,
  line integer,
  thread_id text,
  process_uuid text,
  estimated_bytes integer not null default 0
);
EOF

cat >"$SESSION_INDEX" <<'EOF'
{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","thread_name":"alpha","updated_at":"2026-03-31T10:00:02Z"}
EOF

export HOME="$HOME_DIR"
export CODEX_TASKMASTER_STATE_DIR="$STATE_DIR"
export CODEX_TASKMASTER_CODEX_STATE_DB_PATH="$STATE_DB"
export CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH="$SESSION_INDEX"
export CODEX_TASKMASTER_CODEX_LOGS_DB_PATH="$LOGS_DB"

count_output="$("$HELPER" session-count)"
[[ "$count_output" == "2" ]]

probe_named="$("$HELPER" probe -t alpha)"
assert_contains "$probe_named" "thread_id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
assert_contains "$probe_named" "name: alpha"
assert_contains "$probe_named" "target: alpha"
assert_contains "$probe_named" "status: idle_stable"

probe_named_legacy_env="$(
  env \
    -u CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH \
    CODEX_TASKMASTER_SESSION_INDEX_PATH="$SESSION_INDEX" \
    HOME="$HOME_DIR" \
    CODEX_TASKMASTER_STATE_DIR="$STATE_DIR" \
    CODEX_TASKMASTER_CODEX_STATE_DB_PATH="$STATE_DB" \
    CODEX_TASKMASTER_CODEX_LOGS_DB_PATH="$LOGS_DB" \
    "$HELPER" probe -t alpha
)"
assert_contains "$probe_named_legacy_env" "thread_id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

probe_unnamed="$("$HELPER" probe -t bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb)"
assert_contains "$probe_unnamed" "thread_id: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
assert_contains "$probe_unnamed" "name: "
assert_contains "$probe_unnamed" "target: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

probe_all="$("$HELPER" probe-all -l 2 -o 0)"
assert_contains "$probe_all" "name: alpha"
assert_contains "$probe_all" "target: alpha"
assert_contains "$probe_all" "name: "
assert_contains "$probe_all" "target: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

loop_key="$(printf 'alpha' | shasum -a 256 | awk '{print $1}')"
mkdir -p "${STATE_DIR}/loops" "${STATE_DIR}/runtime/user-loop-state" "${STATE_DIR}/runtime/loop-logs"
cat >"${STATE_DIR}/loops/${loop_key}.loop" <<'EOF'
TARGET=alpha
INTERVAL=30
MESSAGE=test-message
FORCE_SEND=1
EOF
cat >"${STATE_DIR}/runtime/user-loop-state/${loop_key}.state" <<'EOF'
STATE_TAG=manual
NEXT_RUN=1770000000
EOF
echo "[2026-03-31 12:00:00] sent: status: success | reason: forced_sent" > "${STATE_DIR}/runtime/loop-logs/${loop_key}.log"

status_output="$("$HELPER" status -t alpha)"
assert_contains "$status_output" "force_send: yes"
assert_contains "$status_output" "message: test-message"

printf 'helper smoke tests passed\n'
