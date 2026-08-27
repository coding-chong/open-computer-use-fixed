## [2026-08-27 00:57] | Task: Harden Windows element identity safety

### 🤖 Execution Context
* **Agent ID**: `dsh_session-b18a6f99-4da9-456f-b15d-e53455dac25f`
* **Base Model**: `gpt-5.6-terra`
* **Runtime**: `DeepSeek Harness`

### 📥 User Query
> Re-audit the Windows Open Computer Use MCP work and continue under Trellis authorization.

### 🛠 Changes Overview
**Scope:** Windows Go runtime, embedded PowerShell bridge, disposable WPF/WinForms fixtures, and repository reliability documentation.

**Key Actions:**
- **[Exact child identity]**: Required non-empty runtime IDs whose components are numeric integral values within the signed 32-bit UIA range, and removed name/automation-ID/control-type retargeting.
- **[Bounded safety errors]**: Preserved the exact `Target changed; call get_app_state again.` response for identity and freshness failures instead of appending internal PowerShell stack details.
- **[Fail-closed dispatch]**: Added one resolver boundary that rejects supplied missing or changed elements before UIA patterns, coordinate calculation, window messages, or input injection, while coordinate-only click/drag structurally bypass the child resolver.
- **[Regression matrix]**: Added missing, empty, blank, null-member, non-numeric, fractional, and out-of-range ID cases plus a WPF replacement surface with duplicate settable-text presentation metadata; rejected stale reuse is checked through observable values.
- **[Knowledge sync]**: Documented the snapshot-local identity contract in source architecture, reliability, security, fixture guidance, execution plans, quality score, plugin metadata, and this source history.

### 🧠 Design Intent (Why)
A process and top-level window can remain unchanged while a virtualized or recreated child control is replaced. Presentation metadata is not proof of child identity, so an element-index action must prefer a bounded false negative and require a fresh snapshot rather than silently acting on the first similar control.

### ✅ Validation
- `go test ./... -count=1` and `go vet ./...`: the full Go test suite passed before the final bounded-error guard; after that guard, `go vet ./...` and `go test -c` compile-only passed, while the newly compiled Windows test executable was blocked by the existing host Application Control policy. No policy bypass was attempted.
- Trusted source `go run . mcp` persistent-process E2E passed on the same machine: MCP initialize reported `open-computer-use` `0.3.1`, `tools/list` exposed all 10 tools, an external fixture replacement was performed, and the persistent service rejected the cached stale `set_value` record with the exact bounded error without changing the fixture.
- PowerShell checker and parser: passed for `runtime.ps1`, the WPF fixture, and the interactive runner; the exact target-change error regression passed through the fixture runner.
- PowerShell 7 WPF/WinForms runner: passed. It rejected missing, empty, blank, null-member, non-numeric, fractional, and both-sided out-of-range runtime IDs without mutation; proved non-empty replacement runtime IDs differ from the old record and from each other; addressed both current same-metadata settable-text records independently; and rejected stale accessibility/app-post/global/auto click, secondary, scroll, and value actions without mutation.
- Documentation skeleton, plugin JSON parse, `git diff --check`, and Trellis validation: passed.
- Release-equivalent `windows/amd64` build: an isolated output produced PE magic `MZ`, SHA-256 `0E07F01357EC17D73440D6C736EB3AEFC3E282D6B09A1A0BC5EBD37A59FBCEBE`, and 2,691,072 bytes. Host Application Control blocked direct execution of the unsigned PE, so `go run . --version` was used to verify the final source launcher reports `0.3.1`; this is not release-artifact deployment evidence.

### ⚠️ Known Limitation
A UIA provider could theoretically reuse a runtime ID after a child is recreated. The WPF fixture proves IDs differ for this provider. Other providers require a future parent/path or provider-specific companion identity; the runtime must remain fail-closed rather than restoring metadata fallback.

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main_test.go`
- `apps/OpenComputerUseWindows/fixtures/wpf-test-bench.ps1`
- `apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1`
- `apps/OpenComputerUseWindows/fixtures/README.md`
- `docs/ARCHITECTURE.md`
- `docs/RELIABILITY.md`
- `docs/SECURITY.md`
- `docs/QUALITY_SCORE.md`
- `docs/exec-plans/active/20260422-windows-computer-use-runtime.md`
- `docs/exec-plans/active/20260423-cross-platform-npm-distribution.md`
- `plugins/open-computer-use/.codex-plugin/plugin.json`
- `docs/histories/2026-08/20260827-0057-windows-element-identity-safety.md`
