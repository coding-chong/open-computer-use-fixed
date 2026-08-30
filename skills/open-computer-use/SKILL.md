---
name: open-computer-use
description: Platform-neutral guidance for using Open Computer Use, the open-source Computer Use MCP server and CLI for macOS, Linux, and Windows. Use when an agent needs to install, verify, troubleshoot, configure, or operate Open Computer Use through its native CLI, stdio MCP server, or direct Computer Use tool calls.
---

# Open Computer Use

## Overview

Open Computer Use exposes Computer Use as a local CLI and stdio MCP server. It is not Codex.app-specific; adapt the commands and MCP config to the agent runtime you are operating in.

The macOS runtime requires macOS 14.0 or later. Windows and Linux use their own platform runtimes and are not subject to this macOS minimum.

It supports the same core tool surface across macOS, Linux, and Windows:
`list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`,
`drag`, `type_text`, `press_key`, and `set_value`.

## Core Workflow

1. On macOS, run `sw_vers -productVersion` before invoking the CLI and require macOS 14.0 or later. On older versions, explain that the runtime cannot launch; do not recommend `doctor` or permission changes as a fix for binary incompatibility.
2. Check the CLI is installed with `open-computer-use -h` or `ocu -h`. If installation or setup is missing, read [references/installation.md](references/installation.md).
3. On supported macOS versions, run `open-computer-use doctor` before the first real GUI task. If permissions are missing, ask the user to approve Accessibility and Screen Recording in the onboarding UI.
4. Inspect available apps before acting: `open-computer-use call list_apps`.
5. Capture current UI state with `open-computer-use call get_app_state --args '{"app":"TextEdit"}'`. The default state is usually enough for UI operation.
6. When the task needs longer semantic text, such as chat history, email bodies, document text, or long form content, call `get_app_state` with `text_limit: 1000` or `text_limit: "max"`.
7. When visible long pages or lists appear incomplete even after scrolling, call `get_app_state` with a larger `max_tree_nodes` or `max_tree_depth`.
8. Prefer element-targeted actions using the complete generation-bound opaque `element_index` identifier from the latest Windows `get_app_state` result (macOS/Linux retain their platform-specific snapshot identity behavior).
9. For multi-step CLI work, use `open-computer-use call --calls '<json-array>'` so one process can reuse the latest element index mapping.
10. For agent runtimes that support local MCP servers, configure `open-computer-use mcp` or `ocu mcp` and call the exposed Computer Use tools directly. Read [references/usage.md](references/usage.md).
11. If communication, permission, or desktop-session access fails, read [references/troubleshooting.md](references/troubleshooting.md).

## Operating Rules

- Treat the target desktop as the user's real session. Do not inspect password managers, unrelated private content, or sensitive apps unless the user explicitly asked for that task.
- Ask before sending, deleting, purchasing, approving, uploading, or making other externally visible changes.
- Do not assume Codex.app plugin helpers are available. Use the installed `open-computer-use` / `ocu` CLI or an explicit MCP config.
- Always run `get_app_state` before using `element_index`; on Windows copy the complete generation-bound identifier exactly, do not use a bare numeric ordinal, and do not reuse an identifier after an action refresh or UI change.
- Prefer semantic actions and `set_value` for editable controls. Use coordinate `click`, `scroll`, and `drag` only when the element tree does not expose a safer target.
- On macOS, do not enable `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` unless the user explicitly requested `click_method: "global"` or other diagnostic behavior that may move the real pointer.
- On Windows and Linux, confirm the command is running inside the logged-in desktop session before assuming GUI automation is available.
- On Windows, `scroll.pages` supports positive values up to 100; semantic scrolling uses one viewport-percent operation and the fallback uses one app-scoped wheel message. If the call times out, refresh with `get_app_state` before deciding whether to retry because the operation may already have been applied.
- On Windows, `type_text` writes only to the current focused writable text control after process/window ownership validation. Click or select the field first; it never scans the current UIA tree for a substitute, establishes focus implicitly, or falls back to top-level keyboard messages. Native edit delivery appends using the current UTF-16 value length and verifies the result without replay after a failed postcondition. Use `set_value` with the complete generation-bound identifier in `element_index` when exact element-indexed assignment is required.

## Common CLI Actions

```sh
open-computer-use -h
ocu -h
open-computer-use doctor
open-computer-use call list_apps
ocu call list_apps
open-computer-use call get_app_state --args '{"app":"TextEdit"}'
open-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
open-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":"max"}'
open-computer-use call get_app_state --args '{"app":"Google Chrome","max_tree_nodes":3000,"max_tree_depth":96}'
open-computer-use call click --args '{"app":"TextEdit","element_index":"<token-from-latest-get_app_state>"}'
open-computer-use call type_text --args '{"app":"TextEdit","text":"Hello from Open Computer Use"}'
```

On Windows, the `type_text` example assumes the intended text field was focused or selected immediately beforehand; use `set_value` with `element_index` for exact element-indexed assignment.

For a short sequence that reuses state in one process:

```sh
open-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"TextEdit"}},
  {"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}
]'
```

## MCP Usage

For runtimes that can launch local MCP servers over stdio, use:

```toml
[mcp_servers.open_computer_use]
command = "open-computer-use"
args = ["mcp"]
```

Read [references/usage.md](references/usage.md) for JSON config examples, direct tool-call patterns, and platform notes.

## References

- [references/installation.md](references/installation.md): one-time CLI install, agent MCP install commands, and macOS permissions.
- [references/usage.md](references/usage.md): MCP config, direct CLI calls, sequencing, and platform behavior.
- [references/troubleshooting.md](references/troubleshooting.md): permission, desktop-session, app discovery, and action failures.
