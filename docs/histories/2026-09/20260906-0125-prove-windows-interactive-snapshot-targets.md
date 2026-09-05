## [2026-09-06 01:25] | Task: Prove Windows interactive snapshot targets

### Execution Context
- Agent ID: `Main`
- Base Model: `jws/gpt-5.6-sol`
- Runtime: `OMP on Windows`

### User Query
> Validate the KiCad schematic MCP and verify the Computer Use path against the live KiCad surface without modifying the design.

### Changes Overview
**Scope:** Windows Computer Use runtime and its documentation.

**Key Actions:**
- Replaced ownership-only top-level-window acceptance with shared native/UIA target proof across snapshot publication, action refresh, coordinate validation, and capture.
- Added an off-screen WPF fixture regression while retaining visible WPF and native WinForms smoke coverage.
- Documented the preferred-but-proven main-window rule, bounded unavailable-target behavior, and the cross-process Go/PowerShell contract.

### Design Intent
A process can own invisible proxy HWNDs. A snapshot is actionable only when one top-level native window is visible on the virtual desktop and exactly corroborated by UI Automation; otherwise the runtime fails closed before pixels or input.

### Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/main_test.go`
- `apps/OpenComputerUseWindows/fixture_identity_smoke_test.go`
- `apps/OpenComputerUseWindows/fixtures/wpf-test-bench.ps1`
- `apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1`
- `docs/ARCHITECTURE.md`
- `docs/RELIABILITY.md`

### Verification
- `go test -count=1 ./...` passed in `apps/OpenComputerUseWindows`.
- The PowerShell interactive runner passed its complete WPF/native WinForms/action matrix, including the off-screen proxy regression.
- A live KiCad `get_app_state(include_image=true)` through the rebuilt source returned the bounded unavailable-interactive-window error. The fail-closed branch sent no KiCad action and did not export a screenshot.
