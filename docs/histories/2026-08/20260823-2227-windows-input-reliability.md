# Windows Interactive Input Reliability

## Request

Repair the Windows Computer Use runtime so its explicitly authorized interactive input paths work reliably while its default background behavior remains non-intrusive.

## Changes

- Added DPI-aware Windows `SendInput` helpers for authorized global pointer actions, drags, and keyboard input.
- Kept pointer and keyboard safeguards distinct: pointer input verifies the requested screen coordinate belongs to the target process; keyboard input requires confirmed foreground ownership.
- Added correct extended-key handling for navigation virtual keys.
- Kept `auto`, `accessibility`, and `app_post` out of the global-input route.
- Made `app_post` explicit for native controls: a native WinForms button receives `BM_CLICK`; WPF elements without a child HWND return a capability error.
- Added source-owned WPF and WinForms fixtures with visible counters and values.
- Documented the three deployment opt-ins, the foreground/UIPI limits, and the fixture-based verification process.

## Verification

- Go unit tests guard the embedded runtime contract.
- PowerShell static checks cover the runtime and both fixture scripts.
- Through the registered Go source launcher, a fresh WPF fixture reported semantic clicks and secondary invoke, exact text/value updates, `lastKey="End"; eventCount=2`, `dragValue=78`, and `scrollEvents=1`; global click first established the allowed foreground state.
- WPF `app_post` returned the required no-native-HWND capability error without global fallback. Authorized thumb-centered drag succeeded.
- Through the registered Go source launcher, a fresh native WinForms fixture accepted strict `BM_CLICK`, observed global button mouse down/up after foreground ownership, and moved the trackbar with a thumb-centered drag.
- `save_screenshot` produced a visually valid PNG file during the final WPF run; the accessibility tree carried the authoritative fixture state for this desktop configuration.

## Boundaries Observed

- A global pointer request whose screen coordinate was covered by another window was rejected before injection. After the native fixture was manually made foreground, authorized global click and drag succeeded; no focus bypass was used.
- The repair does not add privilege elevation, `AttachThreadInput`, UAC bypass, or a silent fallback from semantic/background actions to global desktop input. Elevated targets and applications that reject synthetic input remain bounded failure cases.

## Primary Files

- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/main_test.go`
- `apps/OpenComputerUseWindows/fixtures/`
- `docs/ARCHITECTURE.md`
- `docs/SECURITY.md`
- `docs/RELIABILITY.md`

## Post-review correction

- An independent review found that the disabled foreground-input branch of `press_key` still called an unguarded `PostMessage` helper. That violated the default non-intrusive keyboard contract.
- Removed the background key-message fallback. `press_key` now rejects before delivery unless `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1`; authorized calls use the existing foreground-ownership check and non-replayable `SendInput` batch.
- Added a Go embedded-runtime regression assertion and directly exercised the source runtime with authorization absent; it returned the bounded authorization error without changing the fixture.
- Added a second review correction for the non-global drag fallback: it is explicitly named app-scoped background messaging, validates that the HWND still belongs to the requested process, and checks every `PostMessage` result. It does not move the physical pointer or alter foreground focus.
- An earlier release-equivalent candidate (`98912E46F6280DA3476D97F6863ADC172A0E744CA54E70A2EB3D249B2C87016F`, `2675712` bytes) was removed by the host at first launch without a corresponding visible Code Integrity or Defender event. The live local DSH registration then used the trusted Go source launcher after direct MCP handshake and fixture verification; a signed release artifact remained required for standalone deployment.

## Follow-up safety review and correction

- Bound every action to snapshot PID, process creation time, and top-level HWND; post-action refresh now reuses the validated process. Coordinate actions compare physical bounds with a one-pixel tolerance and return `Target changed; call get_app_state again.` when stale.
- Shared Go snapshot aliases for the same executable are now marked ambiguous instead of allowing the last `pwsh.exe` instance to overwrite the previous target. Exact window titles and PIDs remain selectable.
- Hardened all retained app-scoped message helpers with process ownership and checked `PostMessage` results. `app_post` additionally requires a descendant of the snapshot-bound HWND and point containment in both root and child windows.
- Escaped literal app-title wildcard queries so fixture names containing `[` or `]` resolve correctly; checked foreground activation return values before keyboard injection.
- Added parameterized PowerShell 7 fixtures with atomic ready/state JSON and `run-interactive-smoke.ps1`. The runner passed two WPF plus one WinForms instances, identity isolation, mismatch/stale-bounds rejection, authorization negatives, WPF capability, outside-window app-post rejection, and native `BM_CLICK` counters.
- Go `vet` and PowerShell checker/parser pass. The host Application Control policy blocked newly generated Go test/source-launcher PE files during later verification, so the PowerShell 7 runtime runner is the executable desktop evidence; no policy bypass was attempted.
- Final amd64 source build produced candidate `F28AE58CFA9435C036CC44DC1881230ABAA58067F2640DE9AAFC480DDF4A23D8` (`2688000` bytes); Application Control blocked its `--version` launch. No policy bypass was attempted.
