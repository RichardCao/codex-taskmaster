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

start_send_request_responder() {
  local target="$1"
  local message="$2"
  local force_send="$3"
  (
    python3 - "${STATE_DIR}/requests/pending" "${STATE_DIR}/requests/results" "$target" "$message" "$force_send" <<'PY'
import json
import os
import pathlib
import sys
import time

pending_dir, results_dir, target, message, force_send = sys.argv[1:]
expected_force_send = force_send == "1"

deadline = time.time() + 8
while time.time() < deadline:
    if os.path.isdir(pending_dir):
        for name in sorted(os.listdir(pending_dir)):
            if not name.endswith(".request.json"):
                continue
            request_path = os.path.join(pending_dir, name)
            try:
                with open(request_path, "r", encoding="utf-8") as fh:
                    payload = json.load(fh)
            except Exception:
                continue
            if payload.get("target") != target:
                continue
            if payload.get("message") != message:
                continue
            if bool(payload.get("force_send")) != expected_force_send:
                continue
            request_id = payload.get("request_id") or name.removesuffix(".request.json")
            result_path = os.path.join(results_dir, f"{request_id}.result.json")
            pathlib.Path(results_dir).mkdir(parents=True, exist_ok=True)
            with open(result_path, "w", encoding="utf-8") as fh:
                json.dump(
                    {
                        "status": "success",
                        "reason": "sent",
                        "target": target,
                        "force_send": expected_force_send,
                        "detail": "test responder completed request",
                    },
                    fh,
                    ensure_ascii=False,
                )
            try:
                os.remove(request_path)
            except FileNotFoundError:
                pass
            raise SystemExit(0)
    time.sleep(0.1)

print(
    f"timed out waiting for send request target={target} force_send={force_send}",
    file=sys.stderr,
)
raise SystemExit(1)
PY
  ) &
  SEND_REQUEST_RESPONDER_PID="$!"
}

HOME_DIR="${TEST_TMP}/home"
CODEX_DIR="${TEST_TMP}/custom-codex-root"
STATE_DIR="${TEST_TMP}/state"
mkdir -p "$HOME_DIR" "$CODEX_DIR" "$STATE_DIR"

STATE_DB="${TEST_TMP}/state.sqlite"
LOGS_DB="${TEST_TMP}/logs.sqlite"
SESSION_INDEX="${TEST_TMP}/session_index.jsonl"
CONFIG_PATH="${CODEX_DIR}/config.toml"
ROLLOUT_A="${CODEX_DIR}/sessions/2026/03/31/rollout-a.jsonl"
ROLLOUT_B="${CODEX_DIR}/sessions/2026/03/31/rollout-b.jsonl"
ROLLOUT_C="${CODEX_DIR}/archived_sessions/rollout-c.jsonl"
ROLLOUT_D="${CODEX_DIR}/sessions/2026/03/31/rollout-d.jsonl"
ROLLOUT_F="${CODEX_DIR}/sessions/2026/03/31/rollout-f.jsonl"
ROLLOUT_G="${CODEX_DIR}/archived_sessions/rollout-g.jsonl"
ROLLOUT_ESCAPE="${TEST_TMP}/escape-rollout.jsonl"
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

cat >"$ROLLOUT_F" <<'EOF'
{"timestamp":"2026-03-31T13:30:00Z","type":"event_msg","payload":{"type":"user_message","message":"shared live title"}}
{"timestamp":"2026-03-31T13:30:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"f"}}
EOF

cat >"$ROLLOUT_G" <<'EOF'
{"timestamp":"2026-03-31T13:40:00Z","type":"event_msg","payload":{"type":"user_message","message":"shared archived title"}}
{"timestamp":"2026-03-31T13:40:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"g"}}
EOF

cat >"$ROLLOUT_ESCAPE" <<'EOF'
{"timestamp":"2026-03-31T14:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"escape me"}}
EOF

cat >"$CONFIG_PATH" <<'EOF'
model_provider = "openai"
EOF

sqlite3 "$STATE_DB" <<EOF
create table threads (
  id text primary key,
  rollout_path text not null,
  updated_at integer not null,
  cwd text not null,
  title text not null,
  first_user_message text not null default '',
  archived integer not null default 0,
  model_provider text not null default '',
  source text not null default '',
  agent_nickname text not null default '',
  agent_role text not null default ''
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
insert into threads(
  id, rollout_path, updated_at, cwd, title, first_user_message, archived,
  model_provider, source, agent_nickname, agent_role
) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '$ROLLOUT_A', 200, '/tmp/alpha-cwd', 'First prompt', 'First prompt', 0, 'openai', 'cli', '', ''),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '$ROLLOUT_B', 100, '/tmp/beta-cwd', 'Second prompt', 'Second prompt', 0, 'openai', 'cli', '', ''),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', '$ROLLOUT_C', 90, '/tmp/archived-cwd', 'Archived prompt', 'Archived prompt', 1, 'openai', 'cli', '', ''),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '$ROLLOUT_D', 80, '/tmp/delta-cwd', 'Delete prompt', 'Delete | prompt', 0, 'openai', '{"subagent":{"thread_spawn":{"parent_thread_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}}}|worker', 'worker|d', 'worker|role'),
  ('ffffffff-ffff-ffff-ffff-ffffffffffff', '$ROLLOUT_F', 95, '/tmp/shared-live-cwd', 'Shared prompt', 'Shared prompt', 0, 'openai', 'cli', '', ''),
  ('99999999-9999-9999-9999-999999999999', '$ROLLOUT_G', 85, '/tmp/shared-archived-cwd', 'Shared prompt', 'Shared prompt', 1, 'openai', 'cli', '', ''),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '$ROLLOUT_ESCAPE', 70, '/tmp/escape-cwd', 'Escape prompt', 'Escape prompt', 0, 'openai', 'cli', '', '');
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
{"id":"cccccccc-cccc-cccc-cccc-cccccccccccc","thread_name":"duplicate","updated_at":"2026-03-31T12:00:03Z"}
{"id":"dddddddd-dddd-dddd-dddd-dddddddddddd","thread_name":"duplicate","updated_at":"2026-03-31T13:00:03Z"}
EOF

export HOME="$HOME_DIR"
export CODEX_TASKMASTER_STATE_DIR="$STATE_DIR"
export CODEX_TASKMASTER_CODEX_STATE_DB_PATH="$STATE_DB"
export CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH="$SESSION_INDEX"
export CODEX_TASKMASTER_CODEX_LOGS_DB_PATH="$LOGS_DB"
export CODEX_TASKMASTER_CODEX_CONFIG_PATH="$CONFIG_PATH"

sqlite3 "$LOGS_DB" <<'EOF'
insert into logs(ts, level, target, message, thread_id, estimated_bytes) values
  (1, 'INFO', 'runtime', 'runtime log', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 0),
  (2, 'INFO', 'runtime', 'archived runtime log', 'cccccccc-cccc-cccc-cccc-cccccccccccc', 0);
EOF

count_output="$("$HELPER" session-count)"
[[ "$count_output" == "5" ]]

config_provider_output="$("$HELPER" config-model-provider)"
assert_contains "$config_provider_output" "status: success"
assert_contains "$config_provider_output" "model_provider: openai"

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

set +e
ambiguous_target_output="$("$HELPER" resolve-thread-id -t duplicate 2>&1)"
ambiguous_target_status=$?
set -e
[[ "$ambiguous_target_status" -ne 0 ]]
assert_contains "$ambiguous_target_output" "found multiple matching sessions for target 'duplicate'"

set +e
ambiguous_title_output="$("$HELPER" resolve-thread-id -t "Shared prompt" 2>&1)"
ambiguous_title_status=$?
set -e
[[ "$ambiguous_title_status" -ne 0 ]]
assert_contains "$ambiguous_title_output" "found multiple matching thread titles for target 'Shared prompt'"

probe_all="$("$HELPER" probe-all -l 2 -o 0)"
assert_contains "$probe_all" "name: alpha"
assert_contains "$probe_all" "target: alpha"
assert_contains "$probe_all" "name: "
assert_contains "$probe_all" "target: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
assert_not_contains "$probe_all" "cccccccc-cccc-cccc-cccc-cccccccccccc"
assert_not_contains "$probe_all" "gamma"

probe_all_json="$("$HELPER" probe-all --json -l 2 -o 0)"
probe_all_json_count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"]))' <<<"$probe_all_json")"
probe_all_json_first_target="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["sessions"][0]["target"])' <<<"$probe_all_json")"
assert_equals "$probe_all_json_count" "2"
assert_equals "$probe_all_json_first_target" "alpha"

TTY_FIXTURE="${TEST_TMP}/tty-ps.txt"
cat >"$TTY_FIXTURE" <<'EOF'
ttys101 codex resume alpha
ttys202 codex resume bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
ttys303 codex resume duplicate
ttys404 codex resume Shared prompt
EOF

TERMINAL_SNAPSHOT_FIXTURE="${TEST_TMP}/terminal-snapshots.json"
cat >"$TERMINAL_SNAPSHOT_FIXTURE" <<'EOF'
[
  {
    "tty": "/dev/ttys101",
    "window_id": "101",
    "tab_selected": false,
    "busy": false,
    "processes": "codex",
    "contents": "context line\n› Improve documentation in @filename\nmodel · ~/repo left"
  }
]
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

resolved_tty_alpha_by_thread_id="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" resolve-live-tty -t aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
)"
assert_equals "$resolved_tty_alpha_by_thread_id" "ttys101"

resolved_tty_duplicate_live_only="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" resolve-live-tty -t duplicate
)"
assert_equals "$resolved_tty_duplicate_live_only" "ttys303"

resolved_tty_shared_title_live_only="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" resolve-live-tty -t "Shared prompt"
)"
assert_equals "$resolved_tty_shared_title_live_only" "ttys404"

probe_metadata_pipe="$("$HELPER" probe -t dddddddd-dddd-dddd-dddd-dddddddddddd)"
assert_contains "$probe_metadata_pipe" "agent_nickname: worker|d"
assert_contains "$probe_metadata_pipe" "agent_role: worker|role"
assert_contains "$probe_metadata_pipe" "source: {\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\"}}}|worker"

probe_background_tab="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  CODEX_TASKMASTER_TERMINAL_SNAPSHOT_FIXTURE="$TERMINAL_SNAPSHOT_FIXTURE" \
  "$HELPER" probe -t alpha
)"
assert_contains "$probe_background_tab" "tty: ttys101"
assert_contains "$probe_background_tab" "terminal_state: prompt_ready"
assert_contains "$probe_background_tab" "terminal_reason: placeholder prompt and model footer are visible"

TTY_AMBIGUOUS_FIXTURE="${TEST_TMP}/tty-ps-ambiguous.txt"
cat >"$TTY_AMBIGUOUS_FIXTURE" <<'EOF'
ttys301 codex resume alpha
ttys302 codex resume alpha
ttys401 codex resume duplicate
ttys402 codex resume duplicate
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

set +e
ambiguous_duplicate_tty_output="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_AMBIGUOUS_FIXTURE" \
  "$HELPER" resolve-live-tty -t cccccccc-cccc-cccc-cccc-cccccccccccc 2>&1
)"
ambiguous_duplicate_tty_status=$?
set -e
[[ "$ambiguous_duplicate_tty_status" -ne 0 ]]
assert_contains "$ambiguous_duplicate_tty_output" "could not resolve live Codex thread id for target 'cccccccc-cccc-cccc-cccc-cccccccccccc'"

set +e
archived_only_live_output="$("$HELPER" probe -t gamma 2>&1)"
archived_only_live_status=$?
set -e
[[ "$archived_only_live_status" -ne 0 ]]
assert_contains "$archived_only_live_output" "could not resolve live Codex thread id for target 'gamma'"

TTY_PROCESS_FIXTURE="${TEST_TMP}/tty-processes.txt"
TTY_CWD_FIXTURE="${TEST_TMP}/tty-cwds.txt"
TTY_EMPTY_FIXTURE="${TEST_TMP}/tty-empty.txt"
: >"$TTY_EMPTY_FIXTURE"
cat >"$TTY_PROCESS_FIXTURE" <<'EOF'
5101 ttys501 codex
5102 ttys501 /path/to/vendor/codex
5201 ttys502 codex
5202 ttys502 /path/to/vendor/codex
EOF
cat >"$TTY_CWD_FIXTURE" <<'EOF'
5101 /tmp/alpha-cwd
5102 /tmp/alpha-cwd
5201 /tmp/beta-cwd
5202 /tmp/beta-cwd
EOF

resolved_tty_by_cwd="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_EMPTY_FIXTURE" \
  CODEX_TASKMASTER_TTY_PROCESS_FIXTURE="$TTY_PROCESS_FIXTURE" \
  CODEX_TASKMASTER_TTY_CWD_FIXTURE="$TTY_CWD_FIXTURE" \
  "$HELPER" resolve-live-tty -t alpha
)"
assert_equals "$resolved_tty_by_cwd" "ttys501"

TTY_PROCESS_AMBIGUOUS_FIXTURE="${TEST_TMP}/tty-processes-ambiguous.txt"
TTY_CWD_AMBIGUOUS_FIXTURE="${TEST_TMP}/tty-cwds-ambiguous.txt"
cat >"$TTY_PROCESS_AMBIGUOUS_FIXTURE" <<'EOF'
6101 ttys601 codex
6102 ttys602 codex
EOF
cat >"$TTY_CWD_AMBIGUOUS_FIXTURE" <<'EOF'
6101 /tmp/alpha-cwd
6102 /tmp/alpha-cwd
EOF

set +e
ambiguous_cwd_output="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_EMPTY_FIXTURE" \
  CODEX_TASKMASTER_TTY_PROCESS_FIXTURE="$TTY_PROCESS_AMBIGUOUS_FIXTURE" \
  CODEX_TASKMASTER_TTY_CWD_FIXTURE="$TTY_CWD_AMBIGUOUS_FIXTURE" \
  "$HELPER" resolve-live-tty -t alpha 2>&1
)"
ambiguous_cwd_status=$?
set -e
[[ "$ambiguous_cwd_status" -ne 0 ]]
assert_contains "$ambiguous_cwd_output" "found multiple matching Terminal ttys for target 'alpha'"

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

LOOP_SEND_STUB="${TEST_TMP}/loop-send-stub.sh"
LOOP_SEND_COUNTER="${TEST_TMP}/loop-send-counter.txt"
cat >"$LOOP_SEND_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="${CODEX_TASKMASTER_TEST_COUNTER_FILE:?}"
count=0
if [[ -f "$counter_file" ]]; then
  count="$(cat "$counter_file")"
fi
count="$((count + 1))"
printf '%s' "$count" >"$counter_file"
printf 'status: failed\n'
printf 'reason: tty_focus_failed\n'
printf 'detail: simulated tty focus failure\n'
exit 1
EOF
chmod +x "$LOOP_SEND_STUB"

rm -f "${STATE_DIR}/runtime/user-loop-state/${loop_key}.state"
echo > "${STATE_DIR}/runtime/loop-logs/${loop_key}.log"

for _ in 1 2 3; do
  CODEX_TASKMASTER_SEND_STUB="$LOOP_SEND_STUB" \
  CODEX_TASKMASTER_TEST_COUNTER_FILE="$LOOP_SEND_COUNTER" \
  CODEX_TASKMASTER_LOOP_BUSY_RETRY_SECONDS=0 \
  CODEX_TASKMASTER_LOOP_FAILURE_PAUSE_THRESHOLD=3 \
  "$HELPER" loop-once
done

paused_status="$("$HELPER" status -t alpha)"
assert_contains "$paused_status" "paused: yes"
assert_contains "$paused_status" "failure_count: 3"
assert_contains "$paused_status" "failure_reason: tty_focus_failed"
assert_contains "$paused_status" "pause_reason: tty_focus_failed"
paused_log="$(cat "${STATE_DIR}/runtime/loop-logs/${loop_key}.log")"
assert_contains "$paused_log" "paused: consecutive forced-send failure threshold reached count=3 reason=tty_focus_failed"

paused_counter_before="$(cat "$LOOP_SEND_COUNTER")"
CODEX_TASKMASTER_SEND_STUB="$LOOP_SEND_STUB" \
CODEX_TASKMASTER_TEST_COUNTER_FILE="$LOOP_SEND_COUNTER" \
CODEX_TASKMASTER_LOOP_BUSY_RETRY_SECONDS=0 \
CODEX_TASKMASTER_LOOP_FAILURE_PAUSE_THRESHOLD=3 \
"$HELPER" loop-once
paused_counter_after="$(cat "$LOOP_SEND_COUNTER")"
assert_equals "$paused_counter_after" "$paused_counter_before"

nonforce_target="nonforce-loop"
nonforce_key="$(printf '%s' "$nonforce_target" | shasum -a 256 | awk '{print $1}')"
cat >"${STATE_DIR}/loops/${nonforce_key}.loop" <<EOF
TARGET=${nonforce_target}
INTERVAL=9
MESSAGE=nonforce-message
FORCE_SEND=0
THREAD_ID=nonforce-thread
EOF
: > "${STATE_DIR}/runtime/loop-logs/${nonforce_key}.log"

for _ in 1 2 3 4; do
  CODEX_TASKMASTER_SEND_STUB="$LOOP_SEND_STUB" \
  CODEX_TASKMASTER_TEST_COUNTER_FILE="$LOOP_SEND_COUNTER" \
  CODEX_TASKMASTER_LOOP_BUSY_RETRY_SECONDS=0 \
  CODEX_TASKMASTER_LOOP_FAILURE_PAUSE_THRESHOLD=3 \
  "$HELPER" loop-once
done

nonforce_status="$("$HELPER" status -t "$nonforce_target")"
assert_contains "$nonforce_status" "paused: no"
assert_contains "$nonforce_status" "failure_count: 0"
assert_contains "$nonforce_status" "failure_reason: tty_focus_failed"
assert_not_contains "$nonforce_status" "pause_reason:"
nonforce_log="$(cat "${STATE_DIR}/runtime/loop-logs/${nonforce_key}.log")"
assert_not_contains "$nonforce_log" "paused: consecutive forced-send failure threshold reached"
"$HELPER" loop-delete -t "$nonforce_target" >/dev/null

CONFLICT_SEND_STUB="${TEST_TMP}/loop-send-success-stub.sh"
CONFLICT_SEND_COUNTER="${TEST_TMP}/loop-send-success-counter.txt"
cat >"$CONFLICT_SEND_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter_file="${CODEX_TASKMASTER_TEST_COUNTER_FILE:?}"
count=0
if [[ -f "$counter_file" ]]; then
  count="$(cat "$counter_file")"
fi
count="$((count + 1))"
printf '%s' "$count" >"$counter_file"
printf 'status: success\n'
printf 'reason: sent\n'
printf 'detail: sent once\n'
exit 0
EOF
chmod +x "$CONFLICT_SEND_STUB"

mutex_a="mutex-a"
mutex_b="mutex-b"
mutex_thread_id="shared-thread"
mutex_a_key="$(printf '%s' "$mutex_a" | shasum -a 256 | awk '{print $1}')"
mutex_b_key="$(printf '%s' "$mutex_b" | shasum -a 256 | awk '{print $1}')"
cat >"${STATE_DIR}/loops/${mutex_a_key}.loop" <<EOF
TARGET=${mutex_a}
INTERVAL=30
MESSAGE=mutex-message-a
FORCE_SEND=0
THREAD_ID=${mutex_thread_id}
EOF
cat >"${STATE_DIR}/loops/${mutex_b_key}.loop" <<EOF
TARGET=${mutex_b}
INTERVAL=30
MESSAGE=mutex-message-b
FORCE_SEND=0
THREAD_ID=${mutex_thread_id}
EOF
: > "${STATE_DIR}/runtime/loop-logs/${mutex_a_key}.log"
: > "${STATE_DIR}/runtime/loop-logs/${mutex_b_key}.log"

CODEX_TASKMASTER_SEND_STUB="$CONFLICT_SEND_STUB" \
CODEX_TASKMASTER_TEST_COUNTER_FILE="$CONFLICT_SEND_COUNTER" \
"$HELPER" loop-once

assert_equals "$(cat "$CONFLICT_SEND_COUNTER")" "1"
if [[ "$mutex_a_key" > "$mutex_b_key" ]]; then
  mutex_loser="$mutex_a"
else
  mutex_loser="$mutex_b"
fi
mutex_loser_status="$("$HELPER" status -t "$mutex_loser")"
assert_contains "$mutex_loser_status" "paused: yes"
assert_contains "$mutex_loser_status" "failure_reason: loop_conflict_active_session"
assert_contains "$mutex_loser_status" "pause_reason: loop_conflict_active_session"

same_force_request_id="same-force-inflight-request"
fresh_request_created_at="$(date +%s)"
cat >"${STATE_DIR}/requests/pending/${same_force_request_id}.request.json" <<EOF
{"request_id":"${same_force_request_id}","target":"dedupe-target","message":"dedupe-message","source_tag":"helper-send","timeout_seconds":12,"force_send":false,"created_at":${fresh_request_created_at}}
EOF
set +e
same_force_output="$("$HELPER" send -t dedupe-target -m dedupe-message 2>&1)"
same_force_status=$?
set -e
[[ "$same_force_status" -eq 2 ]]
assert_contains "$same_force_output" "status: accepted"
assert_contains "$same_force_output" "reason: request_already_inflight"
assert_contains "$same_force_output" "force_send: no"
assert_contains "$same_force_output" "same target/message/force_send request is already pending"
rm -f "${STATE_DIR}/requests/pending/${same_force_request_id}.request.json"

force_mismatch_request_id="force-mismatch-inflight-request"
cat >"${STATE_DIR}/requests/pending/${force_mismatch_request_id}.request.json" <<EOF
{"request_id":"${force_mismatch_request_id}","target":"dedupe-target","message":"dedupe-message","source_tag":"helper-send","timeout_seconds":12,"force_send":false,"created_at":${fresh_request_created_at}}
EOF
start_send_request_responder "dedupe-target" "dedupe-message" "1"
force_mismatch_output="$("$HELPER" send -t dedupe-target -m dedupe-message -f)"
wait "$SEND_REQUEST_RESPONDER_PID"
assert_contains "$force_mismatch_output" "status: success"
assert_contains "$force_mismatch_output" "reason: sent"
assert_contains "$force_mismatch_output" "force_send: yes"
[[ -f "${STATE_DIR}/requests/pending/${force_mismatch_request_id}.request.json" ]]
rm -f "${STATE_DIR}/requests/pending/${force_mismatch_request_id}.request.json"

ACCEPTED_SEND_STUB="${TEST_TMP}/loop-send-accepted-stub.sh"
cat >"$ACCEPTED_SEND_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'status: accepted\n'
printf 'reason: request_already_inflight\n'
printf 'detail: same target/message request is already processing\n'
exit 2
EOF
chmod +x "$ACCEPTED_SEND_STUB"

accepted_target="accepted-loop"
accepted_key="$(printf '%s' "$accepted_target" | shasum -a 256 | awk '{print $1}')"
cat >"${STATE_DIR}/loops/${accepted_key}.loop" <<EOF
TARGET=${accepted_target}
INTERVAL=5
MESSAGE=accepted-message
FORCE_SEND=0
THREAD_ID=accepted-thread
EOF
: > "${STATE_DIR}/runtime/loop-logs/${accepted_key}.log"
accepted_now_before="$(date +%s)"
CODEX_TASKMASTER_SEND_STUB="$ACCEPTED_SEND_STUB" \
CODEX_TASKMASTER_LOOP_ACCEPTED_RETRY_SECONDS=40 \
"$HELPER" loop-once
accepted_status="$("$HELPER" status -t "$accepted_target")"
accepted_next_run="$(printf '%s\n' "$accepted_status" | awk -F': ' '$1=="next_run_epoch"{print $2}')"
(( accepted_next_run - accepted_now_before >= 35 ))

stale_request_id="stale-processing-request"
cat >"${STATE_DIR}/requests/processing/${stale_request_id}.request.json" <<EOF
{"request_id":"${stale_request_id}","target":"linuxkernel","message":"继续","source_tag":"helper-send","timeout_seconds":12,"force_send":false,"created_at":1}
EOF
stale_target="linuxkernel"
stale_key="$(printf '%s' "$stale_target" | shasum -a 256 | awk '{print $1}')"
cat >"${STATE_DIR}/loops/${stale_key}.loop" <<EOF
TARGET=${stale_target}
INTERVAL=5
MESSAGE=继续
FORCE_SEND=0
THREAD_ID=stale-thread
EOF
: > "${STATE_DIR}/runtime/loop-logs/${stale_key}.log"
printf '0' >"$CONFLICT_SEND_COUNTER"
CODEX_TASKMASTER_SEND_STUB="$CONFLICT_SEND_STUB" \
CODEX_TASKMASTER_TEST_COUNTER_FILE="$CONFLICT_SEND_COUNTER" \
"$HELPER" loop-once
assert_equals "$(cat "$CONFLICT_SEND_COUNTER")" "1"
[[ ! -f "${STATE_DIR}/requests/processing/${stale_request_id}.request.json" ]]
"$HELPER" loop-delete -t "$stale_target" >/dev/null

FORCE_FAILURE_STUB="${TEST_TMP}/loop-send-force-failure-stub.sh"
cat >"$FORCE_FAILURE_STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'status: failed\n'
printf 'reason: send_unverified\n'
printf 'detail: verification still pending\n'
exit 1
EOF
chmod +x "$FORCE_FAILURE_STUB"

force_target="force-loop"
force_key="$(printf '%s' "$force_target" | shasum -a 256 | awk '{print $1}')"
cat >"${STATE_DIR}/loops/${force_key}.loop" <<EOF
TARGET=${force_target}
INTERVAL=5
MESSAGE=force-message
FORCE_SEND=1
THREAD_ID=force-thread
EOF
: > "${STATE_DIR}/runtime/loop-logs/${force_key}.log"
force_now_before="$(date +%s)"
CODEX_TASKMASTER_SEND_STUB="$FORCE_FAILURE_STUB" \
CODEX_TASKMASTER_LOOP_UNVERIFIED_RETRY_SECONDS=22 \
CODEX_TASKMASTER_LOOP_FORCE_FAILURE_RETRY_SECONDS=17 \
"$HELPER" loop-once
force_status="$("$HELPER" status -t "$force_target")"
force_next_run="$(printf '%s\n' "$force_status" | awk -F': ' '$1=="next_run_epoch"{print $2}')"
(( force_next_run - force_now_before >= 18 ))

stop_output="$("$HELPER" stop -t alpha)"
assert_contains "$stop_output" "stopped loop for target=alpha"
stopped_status="$("$HELPER" status -t alpha)"
assert_contains "$stopped_status" "stopped: yes"
assert_contains "$stopped_status" "stopped_reason: stopped_by_user"
assert_contains "$stopped_status" "message: test-message"

status_all_with_stopped="$("$HELPER" status)"
assert_contains "$status_all_with_stopped" "target: alpha"
assert_contains "$status_all_with_stopped" "stopped: yes"

status_all_json="$("$HELPER" status --json)"
status_all_json_has_alpha="$(python3 -c 'import json,sys; data=json.load(sys.stdin); print("yes" if any(loop.get("target") == "alpha" and loop.get("stopped") == "yes" for loop in data["loops"]) else "no")' <<<"$status_all_json")"
assert_equals "$status_all_json_has_alpha" "yes"

status_without_home="$(
  env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    CODEX_TASKMASTER_STATE_DIR="$STATE_DIR" \
    CODEX_TASKMASTER_CODEX_STATE_DB_PATH="$STATE_DB" \
    CODEX_TASKMASTER_CODEX_LOGS_DB_PATH="$LOGS_DB" \
    CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH="$SESSION_INDEX" \
    "$HELPER" status -t alpha
)"
assert_contains "$status_without_home" "target: alpha"
assert_contains "$status_without_home" "stopped: yes"

start_failed_save_output="$("$HELPER" loop-save-stopped -t alpha -i 45 -m start-failure -r tty_unavailable)"
start_failed_loop_id="$(printf '%s\n' "$start_failed_save_output" | awk -F': ' '$1=="loop_id"{print $2}')"
start_failed_loop_status="$("$HELPER" status -k "$start_failed_loop_id")"
assert_contains "$start_failed_loop_status" "stopped: yes"
assert_contains "$start_failed_loop_status" "stopped_reason: tty_unavailable"
assert_contains "$start_failed_loop_status" "interval_seconds: 45"
assert_contains "$start_failed_loop_status" "message: start-failure"

"$HELPER" loop-save-stopped -t duplicate -i 50 -m duplicate-message -r stopped_by_user >/dev/null
set +e
duplicate_resume_output="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_AMBIGUOUS_FIXTURE" \
  "$HELPER" loop-resume -t duplicate 2>&1
)"
duplicate_resume_status=$?
set -e
[[ "$duplicate_resume_status" -ne 0 ]]
assert_contains "$duplicate_resume_output" "found multiple matching Terminal ttys for target 'duplicate'"

delete_loop_output="$("$HELPER" loop-delete -t alpha)"
assert_contains "$delete_loop_output" "deleted loop for target=alpha"
"$HELPER" loop-delete -k "$start_failed_loop_id" >/dev/null
"$HELPER" loop-delete -t duplicate >/dev/null
"$HELPER" loop-delete -t "$mutex_a" >/dev/null
"$HELPER" loop-delete -t "$mutex_b" >/dev/null
"$HELPER" loop-delete -t "$accepted_target" >/dev/null
"$HELPER" loop-delete -t "$force_target" >/dev/null
status_after_loop_delete="$("$HELPER" status)"
assert_contains "$status_after_loop_delete" "no loops"

set +e
live_archive_output="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" thread-archive -t aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa 2>&1
)"
live_archive_status=$?
set -e
[[ "$live_archive_status" -ne 0 ]]
assert_contains "$live_archive_output" "reason: session_archive_live"
assert_contains "$live_archive_output" "tty: ttys101"
assert_equals "$(sqlite3 "$STATE_DB" "select archived from threads where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';")" "0"

set +e
live_delete_output="$(
  CODEX_TASKMASTER_TTY_PS_FIXTURE="$TTY_FIXTURE" \
  "$HELPER" thread-delete -t aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa 2>&1
)"
live_delete_status=$?
set -e
[[ "$live_delete_status" -ne 0 ]]
assert_contains "$live_delete_output" "reason: session_delete_live"
assert_contains "$live_delete_output" "tty: ttys101"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';")" "1"

delete_plan_output="$("$HELPER" thread-delete-plan -t dddddddd-dddd-dddd-dddd-dddddddddddd)"
assert_contains "$delete_plan_output" "status: success"
assert_contains "$delete_plan_output" "reason: delete_plan_ready"
assert_contains "$delete_plan_output" "dynamic_tool_rows: 1"
assert_contains "$delete_plan_output" "stage1_output_rows: 1"
assert_contains "$delete_plan_output" "state_log_rows: 1"
assert_contains "$delete_plan_output" "logs_db_rows: 1"
assert_contains "$delete_plan_output" "session_index_entries: 2"
assert_contains "$delete_plan_output" "rollout_exists: yes"
assert_contains "$delete_plan_output" "planned_steps: state_db_cleanup,logs_db_cleanup,session_index_cleanup,rollout_cleanup"

delete_output="$("$HELPER" thread-delete -t dddddddd-dddd-dddd-dddd-dddddddddddd)"
assert_contains "$delete_output" "status: success"
assert_contains "$delete_output" "reason: delete_completed"
assert_contains "$delete_output" "deleted: yes"
assert_contains "$delete_output" "completed_steps: state_db_cleanup,logs_db_cleanup,session_index_cleanup,rollout_cleanup"
assert_contains "$delete_output" "rollout_removed: yes"
assert_contains "$delete_output" "session_index_removed: 2"

assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from thread_dynamic_tools where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from stage1_outputs where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from logs where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$LOGS_DB" "select count(*) from logs where thread_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where archived = 0;")" "4"
[[ ! -e "$ROLLOUT_D" ]]
assert_not_contains "$(cat "$SESSION_INDEX")" "dddddddd-dddd-dddd-dddd-dddddddddddd"

delete_archived_output="$("$HELPER" thread-delete -t cccccccc-cccc-cccc-cccc-cccccccccccc)"
assert_contains "$delete_archived_output" "status: success"
assert_contains "$delete_archived_output" "reason: delete_completed"
assert_contains "$delete_archived_output" "deleted: yes"
assert_contains "$delete_archived_output" "rollout_removed: yes"
assert_contains "$delete_archived_output" "session_index_removed: 2"

assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';")" "0"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from logs where thread_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';")" "0"
assert_equals "$(sqlite3 "$LOGS_DB" "select count(*) from logs where thread_id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';")" "0"
[[ ! -e "$ROLLOUT_C" ]]
[[ ! -d "${CODEX_DIR}/archived_sessions" ]]
assert_not_contains "$(cat "$SESSION_INDEX")" "cccccccc-cccc-cccc-cccc-cccccccccccc"

set +e
escaped_delete_plan_output="$("$HELPER" thread-delete-plan -t eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee 2>&1)"
escaped_delete_plan_status=$?
set -e
[[ "$escaped_delete_plan_status" -ne 0 ]]
assert_contains "$escaped_delete_plan_output" "status: failed"
assert_contains "$escaped_delete_plan_output" "reason: rollout_path_not_allowed"
assert_contains "$escaped_delete_plan_output" "rollout_path_allowed: no"

set +e
escaped_delete_output="$("$HELPER" thread-delete -t eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee 2>&1)"
escaped_delete_status=$?
set -e
[[ "$escaped_delete_status" -ne 0 ]]
assert_contains "$escaped_delete_output" "status: failed"
assert_contains "$escaped_delete_output" "reason: rollout_path_not_allowed"
assert_contains "$escaped_delete_output" "deleted: no"
assert_contains "$escaped_delete_output" "failed_step: rollout_path_validation"
assert_contains "$escaped_delete_output" "rollout_removed: no"
assert_equals "$(sqlite3 "$STATE_DB" "select count(*) from threads where id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';")" "1"
[[ -f "$ROLLOUT_ESCAPE" ]]

printf 'helper smoke tests passed\n'
