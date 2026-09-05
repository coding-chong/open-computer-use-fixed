# KiCad proxy-window target-selection repair

## Status

Implemented and verified on 2026-09-06.

## Goal

Prevent the Windows runtime from publishing a process-owned proxy HWND as an actionable application window when it cannot prove a physical native target consistent with UI Automation. This removes misdirected coordinate clicks and tiny proxy screenshots without weakening snapshot identity guards.

## Scope

- `apps/OpenComputerUseWindows/runtime.ps1`: centralize native-window usability validation and use it for initial target selection, snapshot refresh, and screenshot/action revalidation.
- `apps/OpenComputerUseWindows/main_test.go`: assert the runtime contains the proxy-window rejection contract and preserves the existing identity/capture contract.
- `apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1`: exercise the new positive window-usability invariant through the normal fixture path if a focused behavioral assertion can be added without making the fixture host fragile.
- `docs/ARCHITECTURE.md`, `docs/RELIABILITY.md`, and `docs/histories/`: document the explicit proxy-window boundary and investigation result.

## Out of Scope

- KiCad edits, saves, conversion, or host configuration rewrites.
- Synthetic input authorization changes, global pointer fallback, and weakened stale-snapshot behavior.
- Treating non-invokable KiCad panels as semantic-click bugs.

## Root-cause evidence

The active KiCad process reports `MainWindowHandle=460720`. Win32 reports that same process-owned HWND as a `157 × 25` window at `(-14222, -14222)`, while the UIA tree presents the schematic canvas/control layout at roughly `2716 × 1705`. The runtime currently accepts any process-owned main handle, uses the `157 × 25` rectangle as snapshot bounds, and sends auto-click's coordinate fallback to that proxy HWND. The panel click fails because it supplies no invoke pattern and the native fallback has no valid key window to target.

## Design

1. Define one usable-window predicate at the PowerShell/Win32 boundary:
   - HWND belongs to the process and is a real top-level window.
   - `GetWindowRect` has positive finite dimensions.
   - Its rectangle intersects the virtual desktop, so sentinel/off-screen proxy coordinates are rejected.
   - The UIA root is nonempty, has a positive physical rectangle, and agrees with the native rectangle within a small tolerance.
2. `Get-MainElement` tries the process main handle only through this predicate, then scans process-owned UIA root windows for exactly one usable candidate. It rejects zero or ambiguous candidates with a bounded unavailable-interactive-window error.
3. `Get-ProcessTargetHandle`, snapshot refresh checks, coordinate checks, and `Capture-WindowPngBase64` retain the selected HWND and revalidate it through the same predicate. Thus no later stage can resurrect the invalid proxy handle.
4. Use the existing generation-bound snapshot identity unchanged. A runtime unable to prove an interactive target returns an error before publishing a snapshot, so the Go cache never carries an unsafe target.

## Verification

1. `go test -count=1 ./...` passed from `apps/OpenComputerUseWindows`.
2. `fixtures/run-interactive-smoke.ps1` passed its full visible WPF/native WinForms and off-screen proxy matrix.
3. A live `go run . call --calls` request for KiCad with `include_image=true` returned `No usable top-level interactive window is available for the requested app.` No KiCad action, save, conversion, or screenshot export was attempted.
4. The bounded KiCad result is the required fail-closed branch: no proxy PNG or coordinate input was published.

## Rollback

The change is isolated to native target validation. Revert the target-selection helper and its call sites if it rejects ordinary visible fixtures; do not add a proxy exception for KiCad.
