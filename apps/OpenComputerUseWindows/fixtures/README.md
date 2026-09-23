# Windows Runtime Fixtures

These disposable desktop fixtures provide observable targets for manual and MCP end-to-end verification of the Windows runtime. They must be run from an interactive Windows desktop session; they do not automate or control third-party applications.

## Start

Run either fixture script with PowerShell 7 (or Windows PowerShell 5.1 where WPF/WinForms components are available) from an interactive desktop session:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\wpf-test-bench.ps1
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\native-pointer-bench.ps1
```

For deterministic smoke runs, both scripts accept `-InstanceName`, `-ReadyPath`, `-StatePath`, `-Left`, and `-Top`. `ReadyPath` is written after the native window exists. `StatePath` is atomically updated as UTF-8 without a BOM with the instance, PID, HWND, bounds, counters, and values after observable mutations. Without these parameters the original centered, fixed-title manual fixture behavior is retained.

## WPF Fixture

`wpf-test-bench.ps1` exposes named controls and visible counters for:

- automatic, accessibility, app-post, and secondary actions;
- focus-only `type_text` on the current writable text control, including the explicitly authorized UIA fallback, and `set_value`;
- printable and navigation keyboard input;
- pointer drag on a `Slider`;
- scrolling;
- a controlled element-identity replacement surface with duplicate presentation metadata among settable text controls; and
- screenshot capture.

`app_post` intentionally has no native child HWND on this WPF target. It should return the explicit capability error rather than moving the real pointer.

## Native Fixture

`native-pointer-bench.ps1` exposes a WinForms `BUTTON`, editable native text box, and `TrackBar`. The button reports `Click`, mouse-down, and mouse-up counters. The native `app_post` path uses the button's `BM_CLICK` message and should raise the `Click` counter without falling back to global input; the native text box verifies the focused child-HWND `type_text` path without UIA fallback authorization, including appending to a pre-existing value.

## Chromium Fixture

`chromium-test-page.ps1` is the third fixture target and the only one with a real Chromium/Electron content area. It serves its page from a loopback `HttpListener` and opens it with `--app=<url>` plus its own `--user-data-dir` in a throwaway temp profile, so the page always runs in a browser instance the fixture owns and never as a tab of a browser that is already running. The page reports its own geometry (CSS rectangles, `devicePixelRatio`, `screenX`/`screenY`) back through `POST /event`, which is what lets the runner derive physical click points from measurements instead of from a hard-coded DPI factor.

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\chromium-test-page.ps1 -InstanceName Chrome
```

It accepts the same `-InstanceName`, `-ReadyPath`, `-StatePath`, `-Left`, `-Top` protocol as the other fixtures, plus `-Width`, `-Height`, `-Port`, `-BrowserPath`, `-ReadyTimeoutSeconds`, `-RendererAccessibility`, and `-KeepArtifacts`. Without `-BrowserPath` it resolves `%ProgramFiles%\Google\Chrome\Application\chrome.exe`, `%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe`, then the same two roots for `msedge.exe`; when none of them exist it throws, so a silently mis-targeted run is impossible.

### Chromium core-surface smoke

The runner drives this fixture through `-IncludeChromium` (off by default):

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\run-interactive-smoke.ps1 -IncludeChromium
```

- `-IncludeChromium` appends the Chromium result keys to the result JSON. Without it the key set is unchanged. Progress and skip lines are written to stderr, so stdout stays a single machine-parseable JSON object either way.
- `-ChromiumBrowserPath <chrome.exe|msedge.exe>` overrides browser resolution. The path is validated as given: an explicit path that does not exist **skips** the section rather than falling back to a discovered browser.
- `-ChromiumRendererAccessibility` passes `--force-renderer-accessibility` to the fixture. Chromium normally keeps its renderer accessibility tree off, so the page contributes no nodes to the tree; forcing it on makes the page's own controls appear, which is the falsification switch for the first assertion below (that assertion must turn false when this flag is set).
- No Chromium-family browser found (or an unusable `-ChromiumBrowserPath`): the section prints a skip line, sets `chromiumSkipped`/`chromiumSkippedReason`, leaves the remaining Chromium keys `false`/empty, and the run still exits 0.

The section stays opt-in because it needs a real browser install and an interactive desktop; neither is available to the repository's default test surface.

What it covers against a real browser:

1. `chromiumContentAreaOpaque` — the content area contributes no node an element-targeted action could reach: no element carries the page's own control texts (`click target`, `text input`) and no content-control type (`ControlType.Edit`/`ControlType.Document`) carries a frame. The window frame (title bar, `最小化`/`最大化`/`关闭`, renderer panes) and the frameless address-bar `Edit` are expected to be present.
2. `chromiumTypeTextNewMessage` — `type_text` on that content area returns the exact bounded message the runtime publishes, byte for byte.
3. `chromiumSetValueRejected` — `set_value` against a real non-settable window element returns `Cannot set a value for an element that is not settable` with the page's `inputEvents` counter unchanged, and a bare legacy element index is still rejected as an expired target (`Target changed; call get_app_state again.`).
4. `chromiumAppPostLanded` — with explicit coordinates, `click_method='app_post'` lands on the page through the window-message path (page `clicks` increments and the event reports `target='#click-target'`), and `click_method='auto'` reproduces it. WPF's app-post capability error is deliberately **not** expected here: Chromium is a native HWND target, so a landed click is the observable result.
5. `chromiumGlobalOcclusionFailClosed` — with no authorization present, `click_method='global'` is refused with `Interactive Windows input is disabled by default...` before any injection, and the page observes no click.
6. `chromiumCoordinateLanding` — closed-loop coordinate calibration, described below.

### Chromium coordinates

The fixture process and the runtime do not have to report the same coordinate space, and which space the runtime reports can differ between runs (measured: a run where the fixture state said bounds `40,760 x 900x680` while the runtime snapshot said `90,1710 x 2025x1530`). Mixing them pushes the effective click point off the physical screen, where the runtime rejects it as `Target changed`. The section therefore derives every point from `snapshot.windowBounds` alone — the value the runtime itself adds to explicit `x`/`y` — and uses the fixture state only for page-reported quantities (CSS rectangles, `devicePixelRatio`, counters), never for an origin.

The runner does not trust the scaling either. It sends the window centre through `click_method='app_post'`, reads the `clientX`/`clientY` the page reports for that click (a click on the target and a page-level click both count), and derives the anchor `anchor = sent - reported x devicePixelRatio`. A second probe adds a known 120-unit offset and measures the effective scale, which must match the page's `devicePixelRatio` within 0.1; that assertion is what makes a changed coordinate space fail loudly instead of silently mis-landing. The final click re-aims with the anchor and requires the page's reported point to match the target centre it reports for that click within 4 CSS pixels. `chromiumCoordinateAnchor` (in runtime units relative to `snapshot.windowBounds`), `chromiumCoordinateScale`, and `chromiumDevicePixelRatio` are written into the result, so the numbers are data instead of assumptions.

The apparent constant offset between the computed origin and the page's reported client point is now explained: explicit `x`/`y` are **window-relative** (the runtime adds `windowBounds` itself), and the anchor the calibration recovers — `15.75,65.50` in runtime units on this machine — is the content-area origin, meaning the point the browser actually treats as its client origin. An `--app` window draws its own title bar inside the OS client area, so the fixture's own `clientOrigin` is the window client area and sits ~66 physical units above the page viewport at 225% scaling. The earlier "unexplained offset" was an artifact of feeding a screen point where a window-relative point belongs. One observation from the same measurement round is still open: a single UIA tree reporting logical and physical quantities side by side (a child pane claiming `1997x1516` while the same window reports `900x680` and the page viewport is `873x601` physical). That is recorded in `research/chromium-runtime-measured-facts.md` of the `09-23-chromium-core-fixture` task rather than worked around here.

### Physical pointer input (opt-in, and only while you are away)

Test discipline for this fixture, after a real incident (recorded in `research/incident-physical-pointer-hijack.md`): the smoke runner injects no physical pointer or keyboard input on its default path, and the Chromium section refuses to start at all when `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT` or `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS` is already present in the environment.

This is test discipline, **not** a product limitation. The runtime's `global` pointer and keyboard injection paths are supported capabilities and are unchanged; what the runner refuses to do is take over the operator's mouse as a side effect of an ordinary verification run.

The occluded-physical-click case is implemented but stays inert unless the operator opts in:

```powershell
$env:OCU_FIXTURE_ALLOW_PHYSICAL_POINTER = '1'
```

**Running with that flag really moves your mouse and can take foreground focus**, because that is exactly what the physical path does. Run it only when you are away from the machine. Without the flag the runner prints a skip line, `chromiumGlobalPhysicalFailClosed` stays `null`, and the run still passes. With it, the branch covers the target point with an unrelated window, requires the physical click to fail closed on occlusion, and requires the cursor position to be unchanged. The pointer witness in the result is a read-only `GetCursorPos` sample before and after the section: an operator using the machine moves the cursor during any run, so it is evidence for a human reader and never a pass criterion.

## Repeatable Smoke

Run the source-owned runner from `apps/OpenComputerUseWindows`:

```powershell
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\run-interactive-smoke.ps1
```

The runner itself is compatible with Windows PowerShell 5.1; by default it launches the WPF and WinForms fixtures with `pwsh.exe` and executes the embedded `runtime.ps1` with `powershell.exe` to exercise the runtime's 5.1 compatibility. Use `-FixtureHostPath` and `-RuntimeHostPath` to select the WPF/runtime executables, and `-NativeFixtureHostPath` to select the WinForms host separately. The native fixture defaults to `pwsh.exe` because the .NET Framework WinForms UIA provider used by Windows PowerShell 5.1 exposes its child controls as generic panes; this is a fixture-host limitation, not a runtime fallback. For the Windows PowerShell 5.1 runner/runtime boundary with native-HWND coverage, use `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fixtures\run-interactive-smoke.ps1 -FixtureHostPath powershell.exe -RuntimeHostPath powershell.exe -NativeFixtureHostPath pwsh.exe`; the output records the runner version and each resolved host basename.

It launches two WPF instances and one WinForms instance, verifies identity-pinned A behavior, rejects a pinned A record under B's selector, rejects missing/empty/blank/null-member/non-numeric/fractional/both-sided-out-of-range element runtime IDs, and exercises a synchronized same-metadata replacement surface for settable text controls. The runner proves the original runtime ID differs from both current duplicate settable-text records, writes each fresh duplicate independently, then verifies a stale old record is rejected before accessibility/app-post/global/auto click, secondary action, scroll, or `set_value` can mutate either replacement. The runner also proves focused WPF `type_text` success, non-editable/outside-window focus rejection, duplicate-control isolation, disabled UIA fallback rejection, and native focused child-HWND typing without the UIA fallback flag. It checks unchanged B state, mismatched identity, moved-window stale bounds, unauthorized global/keyboard rejection, WPF app-post capability handling, native `BM_CLICK`, outside-window app-post rejection, strict bounded runtime JSON/diagnostics, and timeout cleanup, then terminates all fixtures. Add `-KeepArtifacts` only when diagnosing a failed run.

The Go integration test `TestWindowsFixtureIdentityAndBoundsSmoke` remains an additional request-propagation check and is explicitly opt-in with `$env:OPEN_COMPUTER_USE_RUN_WINDOWS_FIXTURE_SMOKE = '1'`.

## Public MCP Element Identifiers

The Go/MCP route exposes each element as a generation-bound opaque `element_index` string (for example `s-0000000000000001:15`). Use the complete identifier from the latest `get_app_state`; every successful snapshot/action refresh publishes a new generation and expires the prior identifiers. Legacy bare numeric indices are rejected instead of being mapped to the current ordinal. The PowerShell fixture runner may still use its internal numeric `record.index` when it passes a full record directly to the embedded runtime; that is not the public MCP identifier. Windows `scroll.pages` accepts positive numbers up to 100; fractional values are preserved for one viewport-percent semantic operation or one app-scoped fallback message. A scroll timeout may mean that operation was already applied, so refresh with `get_app_state` before retrying.

## Interactive Input Authorization
The real pointer and keyboard paths are off by default. For a positive physical-input run, configure only the deliberate capabilities being tested:

- `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` enables the repository-wide physical pointer gate.
- `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1` enables Windows foreground keyboard/pointer injection.
- `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1` is separate and is needed only to test the potentially foreground-affecting UIA text fallback; child edit-HWND text messaging does not require it.

Physical click and drag injection verify the target process owns the requested screen point and fail closed when another window covers it; global drag also validates every sampled path point. Without pointer authorization, `drag` uses only a guarded app-scoped background message path that does not move the physical pointer or alter foreground focus and may not work in every toolkit. Keyboard injection requires the target process to own the foreground window. To let the runtime make a bounded foreground attempt when a keyboard target is not already foreground, separately set `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1`; an authorized global click can establish focus without that extra permission. `press_key` is fail-closed when `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT` is absent; when enabled, the target must own the foreground window (or the separate focus-actions opt-in must permit a bounded focus attempt).
