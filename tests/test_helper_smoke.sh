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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'assertion failed: expected output to NOT contain [%s]\n' "$needle" >&2
    printf 'full output:\n%s\n' "$haystack" >&2
    exit 1
  fi
}

assert_equals() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    printf 'assertion failed: expected [%s] but got [%s]\n' "$expected" "$actual" >&2
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
ROLLOUT_A="${CODEX_DIR}/sessions/2026/03/31/rollout-a.jsonl"
ROLLOUT_B="${CODEX_DIR}/sessions/2026/03/31/rollout-b.jsonl"
ROLLOUT_C="${CODEX_DIR}/archived_sessions/rollout-c.jsonl"
ROLLOUT_D="${CODEX_DIR}/sessions/2026/03/31/rollout-d.jsonl"
mkdir -p "$(dirname "$ROLLOUT_A")" "$(dirname "$ROLLOUT_C")"

cat >"$ROLLOUT_A" <<'EOF'
{"timestamp":"2026-03-31T10:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"hello"}}
{"timestamp":"2026-03-31T10:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"a"}}
EOF

cat >"$ROLLOUT_B" <<'EOF'
{"timestamp":"2026-03-31T11:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"second"}}
{"timestamp":"2026-03-31T11:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"b"}}
EOF

cat >"$ROLLOUT_C" <<'EOF'
{"timestamp":"2026-03-31T12:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"archived thread"}}
{"timestamp":"2026-03-31T12:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"c"}}
EOF

cat >"$ROLLOUT_D" <<'EOF'
{"timestamp":"2026-03-31T13:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"delete me"}}
{"timestamp":"2026-03-31T13:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"d"}}
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
create table thread_dynamic_tools (
  thread_id text not null,
  position integer not null,
  name text not null,
  description text not null,
  input_schema text not null,
  defer_loading integer not null default 0,
  primary key(thread_id, position)
);
create table stage1_outputs (
  thread_id text primary key,
  source_updated_at integer not null,
  raw_memory text not null,
  rollout_summary text not null,
  generated_at integer not null
);
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
insert into threads(id, rollout_path, updated_at, title, first_user_message, archived) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '$ROLLOUT_A', 200, 'First prompt', 'First prompt', 0),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '$ROLLOUT_B', 100, 'Second prompt', 'Second prompt', 0),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', '$ROLLOUT_C', 90, 'Archived prompt', 'Archived prompt', 1),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '$ROLLOUT_D', 80, 'Delete prompt', 'Delete prompt', 0);
insert into thread_dynamic_tools(thread_id, position, name, description, input_schema, defer_loading) values
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 0, 'tool-a', 'desc', '{}', 0);
insert into stage1_outputs(thread_id, source_updated_at, raw_memory, rollout_summary, generated_at) values
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 10, 'raw', 'summary', 11);
insert into logs(ts, level, target, message, thread_id, estimated_bytes) values
  (1, 'INFO', 'state', 'state log', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 0),
  (2, 'INFO', 'state', 'archived state log', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 0);
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
{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd","thread_name":"delta","updated_at":"2026-03-31T13:00:02Z"}
{"id":"cccccccc-cccc-cccc-cccc-cccccccccccc","thread_name":"gamma","updated_at":"2026-03-31T12:00:02Z"}
EOF

export HOME="$HOME_DIR"
export CODEX_TASKMASTER_STATE_DIR="$STATE_DIR"
export CODEX_TASKMASTER_CODEX_STATE_DB_PATH="$STATE_DB"
export CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH="$SESSION_INDEX"
export CODEX_TASKMASTER_CODEX_LOGS_DB_PATH="$LOGS_DB"

sqlite3 "$LOGS_DB" <<'EOF'
insert into logs(ts, level, target, message, thread_id, estimated_bytes) values
  (1, 'INFO', 'runtime', 'runtime log', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 0),
  (2, 'INFO', 'runtime', 'archived runtime log', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 0);
EOF

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
assert_not_contains "$probe_all" "cccccccc-cccc-cccc-cccc-cccccccccccc"
assert_not_contains "$probe_all" "gamma"

TTY_FIXTURE="${TEST_TMP}/tty-ps.txt"
cat >"$TTY_FIXTURE" <<'EOF'
ttys101 codex resume alpha
ttys202 codex resume bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
EOF

resolved_tty="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" resolve-live-tty -t alpha
)"
assert_equals "$resolved_tty" "ttys101"

resolved_tty_by_id="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" resolve-live-tty -t bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
)"
assert_equals "$resolved_tty_by_id" "ttys202"

TTY_AMBIGUOUS_FIXTURE="${TEST_TMP}/tty-ps-ambiguous.txt"
cat >"$TTY_AMBIGUOUS_FIXTURE" <<'EOF'
ttys301 codex resume alpha
ttys302 codex resume alpha
EOF

set +e
ambiguous_output="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_AMBIGUOUS_FIXTURE" \
  "$HELPER" resolve-live-tty -t alpha 2>&1
)"
ambiguous_status=$?
set -e
[[ "$ambiguous_status" -ne 0 ]]
assert_contains "$ambiguous_output" "found multiple matching Terminal ttys for target 'alpha'"

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

delete_output="$("$HELPER" thread-delete -t dddddddd-dddd-dddd-dddd-dddddddddddd)"
assert_contains "$delete_output" "deleted: yes"
assert_contains "$delete_output" "rollout_removed: yes"
assert_contains "$delete_output" "session_index_removed: 1"

assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from thread_dynamic_tools where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from stage1_outputs where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from logs where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$LOGS_DB" "select count(*) from logs where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where archived = 0;")" "2"
[[ ! -e "$ROLLOUT_D" ]]
assert_not_contains "$(cat "$SESSION_INDEX")" "dddddddd-dddd-dddd-dddd-dddddddddddd"

delete_archived_output="$("$HELPER" thread-delete -t cccccccc-cccc-cccc-cccc-cccccccccccc)"
assert_contains "$delete_archived_output" "deleted: yes"
assert_contains "$delete_archived_output" "rollout_removed: yes"
assert_contains "$delete_archived_output" "session_index_removed: 1"

assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from logs where thread_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';")" "0"
assert_equals "$(sqlite3 "$LOGS_DB" "select count(*) from logs where thread_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';")" "0"
[[ ! -e "$ROLLOUT_C" ]]
[[ ! -d "${CODEX_DIR}/archived_sessions" ]]
assert_not_contains "$(cat "$SESSION_INDEX")" "cccccccc-cccc-cccc-cccc-cccccccccccc"

printf 'helper smoke tests passed\n'
