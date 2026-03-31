# Codex Taskmaster

`Codex Taskmaster` is a native macOS utility for sending messages into Terminal-hosted Codex sessions, either once or on a loop, while tracking session state, loop state, and delivery outcomes.

It targets a local Codex CLI workflow on macOS and is built around three ideas:

- detect which session is actually sendable before typing into Terminal
- support controlled loop sending with logs and stop controls
- make session name handling match local `codex resume` behavior by using `~/.codex/session_index.jsonl`

## Features

- Native single-window AppKit UI
- `Session Status` scan with sortable columns
- `Active Loops` tracking with per-loop logs
- Send-once and repeating loop modes
- Optional `force send` mode
- Prompt-history viewer for a selected session
- Rename support backed by `~/.codex/session_index.jsonl`
- State-aware sending:
  - default mode only sends when the session is considered sendable
  - force mode bypasses session-state gating and still reports success or failure

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- Terminal.app
- A local Codex CLI installation that writes state under `~/.codex`
- Accessibility permission for the app if you want it to post keystrokes

## Build

From the project root:

```bash
./build_codex_biancezhe_app.sh
```

The script will:

- generate the app icon from `generate_icon.swift`
- build `Codex Taskmaster.app`
- bundle `codex_terminal_sender.sh` into the app resources

SDK selection:

- by default the build script prefers locally installed macOS 15.x or 14.x Command Line Tools SDKs when available
- if you need to force a specific SDK, set `MACOS_SDK_PATH`

Example:

```bash
MACOS_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk ./build_codex_biancezhe_app.sh
```

## Run

Open the app:

```bash
open -na "./Codex Taskmaster.app"
```

Or launch it from Finder after building.

## Checks

Run the local project checks:

```bash
bash ./scripts/check.sh
```

This runs:

- shell syntax validation
- helper smoke tests
- Swift typecheck with warnings treated as errors
- app build

## How It Works

There are two main components:

- `CodexBianCeZheApp.swift`
  - the AppKit desktop UI
  - scans sessions
  - manages queued send requests
  - posts keystrokes into Terminal
- `codex_terminal_sender.sh`
  - helper CLI used by the app
  - session probing
  - loop persistence
  - loop daemon lifecycle

The app queues send requests, probes the target session, and only sends in default mode when the session is in a sendable state. Delivery results are written back to the UI and loop logs.

## Session Name Semantics

This project intentionally does not treat `threads.title` as the authoritative session name.

Instead:

- a real renamed session is identified by `~/.codex/session_index.jsonl`
- if no entry exists there, the session is treated as unnamed
- the UI distinguishes:
  - `Name`: actual renamed name only
  - `Target`: the value you can use to resume or target the session

This matches local `codex resume` behavior better than comparing `title` and `first_user_message` alone.

## Sending Modes

Default mode:

- allows send only when the target is in a sendable state
- currently accepts:
  - `idle_stable`
  - `interrupted_idle`
- still requires Terminal to be at a clean `prompt_ready` state

Force mode:

- ignores session-state gating
- still requires a resolvable Terminal TTY
- still verifies whether the user message actually advanced

Both modes report:

- success or failure
- reason
- target
- force flag
- probe status
- terminal state
- detail

## Logs

`Activity Log` in the UI records:

- command execution
- send success
- send failure
- send refusal due to state
- verification failure

Per-loop logs are stored under:

```text
~/.codex-terminal-sender/runtime/loop-logs/
```

Each loop log records:

- loop start
- loop stop
- sent results
- deferred results

## Repository Layout

- `CodexBianCeZheApp.swift`: main macOS app
- `codex_terminal_sender.sh`: helper CLI and loop engine
- `build_codex_biancezhe_app.sh`: build script
- `generate_icon.swift`: app icon generator
- `scripts/check.sh`: local validation entrypoint
- `tests/test_helper_smoke.sh`: helper smoke tests
- `legacy/`: early AppleScript/JXA prototypes

Generated artifacts such as `.app` bundles and icon outputs are ignored by git.

## Notes

- This project is macOS-specific.
- It currently targets Terminal.app, not iTerm2 or other terminal emulators.
- It expects Codex local state files under the current user's home directory, unless overridden via environment variables supported by the helper script.
- For `session_index.jsonl`, the helper accepts both `CODEX_TASKMASTER_CODEX_SESSION_INDEX_PATH` and the older `CODEX_TASKMASTER_SESSION_INDEX_PATH` override.

## License

MIT. See [LICENSE](LICENSE).
