# Windows Runtime Fixtures

These disposable desktop fixtures provide observable targets for manual and MCP end-to-end verification of the Windows runtime. They must be run from an interactive Windows desktop session; they do not automate or control third-party applications.

## Start

Run either script with PowerShell 7 from an interactive desktop session:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\wpf-test-bench.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\native-pointer-bench.ps1
```

For deterministic smoke runs, both scripts accept `-InstanceName`, `-ReadyPath`, `-StatePath`, `-Left`, and `-Top`. `ReadyPath` is written after the native window exists. `StatePath` is atomically updated as UTF-8 without a BOM with the instance, PID, HWND, bounds, counters, and values after observable mutations. Without these parameters the original centered, fixed-title manual fixture behavior is retained.

## WPF Fixture

`wpf-test-bench.ps1` exposes named controls and visible counters for:

- automatic, accessibility, app-post, and secondary actions;
- UIA text fallback and `set_value`;
- printable and navigation keyboard input;
- pointer drag on a `Slider`;
- scrolling; and
- screenshot capture.

`app_post` intentionally has no native child HWND on this WPF target. It should return the explicit capability error rather than moving the real pointer.

## Native Fixture

`native-pointer-bench.ps1` exposes a WinForms `BUTTON` and `TrackBar`. The button reports `Click`, mouse-down, and mouse-up counters. The native `app_post` path uses the button's `BM_CLICK` message and should raise the `Click` counter without falling back to global input.

## Repeatable Smoke

Run the source-owned runner with PowerShell 7 from `apps/OpenComputerUseWindows`:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\run-interactive-smoke.ps1
```

It launches two WPF instances and one WinForms instance, verifies identity-pinned A behavior, unchanged B state, mismatched identity, moved-window stale bounds, unauthorized global/keyboard rejection, WPF app-post capability handling, native `BM_CLICK`, and outside-window app-post rejection, then terminates all fixtures. Add `-KeepArtifacts` only when diagnosing a failed run.

The Go integration test `TestWindowsFixtureIdentityAndBoundsSmoke` remains an additional request-propagation check and is explicitly opt-in with `$env:OPEN_COMPUTER_USE_RUN_WINDOWS_FIXTURE_SMOKE = '1'`.

## Interactive Input Authorization

The real pointer and keyboard paths are off by default. For a positive physical-input run, configure only the deliberate capabilities being tested:

- `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` enables the repository-wide physical pointer gate.
- `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1` enables Windows foreground keyboard/pointer injection.
- `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1` is separate and is needed only to test the potentially foreground-affecting UIA text fallback; child edit-HWND text messaging does not require it.

Physical click and drag injection verify the target process owns the requested screen point and fail closed when another window covers it; global drag also validates every sampled path point. Without pointer authorization, `drag` uses only a guarded app-scoped background message path that does not move the physical pointer or alter foreground focus and may not work in every toolkit. Keyboard injection requires the target process to own the foreground window. To let the runtime make a bounded foreground attempt when a keyboard target is not already foreground, separately set `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1`; an authorized global click can establish focus without that extra permission. `press_key` is fail-closed when `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT` is absent; when enabled, the target must own the foreground window (or the separate focus-actions opt-in must permit a bounded focus attempt).
