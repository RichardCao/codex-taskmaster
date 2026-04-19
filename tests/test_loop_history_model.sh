#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/codex_terminal_sender.sh"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-taskmaster-loop-history.XXXXXX")"
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

assert_equals() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    printf 'assertion failed: expected [%s] but got [%s]\n' "$expected" "$actual" >&2
    exit 1
  fi
}

assert_not_equals() {
  local left="$1"
  local right="$2"
  if [[ "$left" == "$right" ]]; then
    printf 'assertion failed: expected [%s] and [%s] to differ\n' "$left" "$right" >&2
    exit 1
  fi
}

HOME_DIR="${TEST_TMP}/home"
STATE_DIR="${TEST_TMP}/state"
mkdir -p "$HOME_DIR" "$STATE_DIR"

export HOME="$HOME_DIR"
export CODEX_TASKMASTER_STATE_DIR="$STATE_DIR"

first_save="$("$HELPER" loop-save-stopped -t demo -m first -i 30 -r start_failed)"
second_save="$("$HELPER" loop-save-stopped -t demo -m second -i 60 -r stopped_by_user)"

assert_contains "$first_save" "saved stopped loop"
assert_contains "$second_save" "saved stopped loop"

loop_id_1="$(printf '%s\n' "$first_save" | awk -F': ' '$1=="loop_id"{print $2}')"
loop_id_2="$(printf '%s\n' "$second_save" | awk -F': ' '$1=="loop_id"{print $2}')"
assert_not_equals "$loop_id_1" "$loop_id_2"

state_tag_1="$(sed -n "s/^STATE_TAG=//p" "${STATE_DIR}/runtime/user-loop-state/${loop_id_1}.state")"
assert_contains "$state_tag_1" ":"
assert_not_equals "$state_tag_1" "missing"

all_status_json="$("$HELPER" status --json)"
all_loop_count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["loops"]))' <<<"$all_status_json")"
demo_loop_count="$(python3 -c 'import json,sys; data=json.load(sys.stdin)["loops"]; print(sum(1 for loop in data if loop.get("target") == "demo"))' <<<"$all_status_json")"
all_loop_ids="$(
  python3 -c 'import json,sys; data=json.load(sys.stdin)["loops"]; print("\n".join(sorted(loop.get("loop_id", "") for loop in data)))' <<<"$all_status_json"
)"
assert_equals "$all_loop_count" "2"
assert_equals "$demo_loop_count" "2"
assert_contains "$all_loop_ids" "$loop_id_1"
assert_contains "$all_loop_ids" "$loop_id_2"

first_status_json="$("$HELPER" status -k "$loop_id_1" --json)"
first_status_message="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["loops"][0]["message"])' <<<"$first_status_json")"
first_status_interval="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["loops"][0]["interval_seconds"])' <<<"$first_status_json")"
first_status_reason="$(python3 -c 'import json,sys; data=json.load(sys.stdin)["loops"][0]; print(data.get("stopped_reason", ""))' <<<"$first_status_json")"
assert_equals "$first_status_message" "first"
assert_equals "$first_status_interval" "30"
assert_equals "$first_status_reason" "start_failed"

delete_output="$("$HELPER" loop-delete -k "$loop_id_1")"
assert_contains "$delete_output" "deleted loop"

remaining_status_json="$("$HELPER" status --json)"
remaining_loop_count="$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)["loops"]))' <<<"$remaining_status_json")"
remaining_loop_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["loops"][0]["loop_id"])' <<<"$remaining_status_json")"
assert_equals "$remaining_loop_count" "1"
assert_equals "$remaining_loop_id" "$loop_id_2"

legacy_key="legacy-loop-key"
mkdir -p "${STATE_DIR}/loops"
cat >"${STATE_DIR}/loops/${legacy_key}.loop" <<'EOF'
TARGET=legacy-target
INTERVAL=45
MESSAGE=legacy-message
FORCE_SEND=0
THREAD_ID=
EOF

legacy_status_json="$("$HELPER" status -k "$legacy_key" --json)"
legacy_loop_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["loops"][0]["loop_id"])' <<<"$legacy_status_json")"
legacy_target="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["loops"][0]["target"])' <<<"$legacy_status_json")"
legacy_message="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["loops"][0]["message"])' <<<"$legacy_status_json")"
assert_equals "$legacy_loop_id" "$legacy_key"
assert_equals "$legacy_target" "legacy-target"
assert_equals "$legacy_message" "legacy-message"

echo "test_loop_history_model_ok"
