# Windows MCP Generation-Bound Element Identifiers

Date: 2026-08-29

## Finding

The Windows Go dispatcher previously rendered a bare numeric `element_index` and resolved that number against the latest cached snapshot. When a control was replaced or reordered at the same ordinal, a caller could reuse the old public value and address the replacement. The embedded PowerShell runtime's exact `runtimeId` check could not protect this dispatcher-level rebinding because the Go layer supplied the record from the new snapshot.

## Decision

The public Windows `element_index` remains the schema property name but is now a generation-qualified opaque string such as `s-0000000000000001:15`. Each successful snapshot publication receives a fresh token. The dispatcher retains a bounded immutable token binding containing the original element record and stable target identity `(PID, process start time, top-level HWND)`. Legacy bare numeric values, malformed values, stale tokens, unknown tokens, and app/token mismatches fail closed with:

`Target changed; call get_app_state again.`

Coordinate-only click and drag, and focus-only `type_text`, remain outside the element-token lookup path.

## Cache and concurrency

Snapshot aliases are keyed by stable target identity, reject ambiguous shared process selectors, expire stale entries, and are bounded by both target-per-key and global-key limits. Snapshot-dependent selection and runtime delivery are serialized so a concurrent refresh cannot supersede a selected record between lookup and dispatch. A refreshed snapshot updates older query aliases for the same target instead of leaving a stale alias pointing at a previous generation.

## Verification

- `gofmt`, full compiled `go test ./...` from `apps/OpenComputerUseWindows` (fixture integration opt-in skipped in the default Go suite), focused and full source regressions
- `go test -race ./...`, `go vet ./...`, and release-equivalent Windows amd64 build are required final gates; their receipts are recorded with the final Trellis check before commit
- Windows PowerShell checker and Windows PowerShell 5.1 parser pass for `runtime.ps1` and the PS7/PS5.1-capable fixture runner
- Disposable WPF/WinForms fixture matrix passes generation-bound identity, replacement/stale actions, duplicate metadata, screenshot PNG-or-safe-omission, malformed/partial pinned identity, numeric/enum rejection, coordinate/focus/native-HWND paths, and diagnostic non-leakage. The default PS7 runner -> PS5.1 runtime run passed with exit 0 (`runnerPowerShell=7.6.5`, `fixtureHost=pwsh.exe`, `runtimeHost=powershell.exe`, `nativeFixtureHost=pwsh.exe`); the PS5.1 runner -> PS5.1 runtime run also passed with exit 0 (`runnerPowerShell=5.1.26100.9168`, `fixtureHost=powershell.exe`, `runtimeHost=powershell.exe`, `nativeFixtureHost=pwsh.exe`), and every computed flag was true.
- A direct PS5.1-hosted WinForms diagnostic was intentionally negative: its .NET Framework UIA provider consistently exposed the ten child controls as generic `Pane` records, even after repeated snapshots and explicit `AccessibleRole`; this fixture limitation is why the native host is independently selectable and is not used to weaken runtime safety conclusions.
- The runtime's `Render-Tree` traversal uses invocation-local state; screenshot capture is process/start/HWND/bounds-bound; native text derives `EM_SETSEL` offsets from the current UTF-16 length, verifies `before + text`, and never retries after mutation; Go child output is bounded and MCP envelopes validate version/ID/notification shape
- Registered-route working-tree verification was completed after a supported DSH restart and is recorded separately below; immutable commit binding remains pending the user's manual source commit

## Residual limitations and owner/trigger

- **UIA provider runtime-ID reuse:** the generation token prevents Go ordinal rebinding and exact matching rejects missing/replaced IDs, but it cannot prove a provider did not reuse the same runtime ID for a semantically new child. Owner/action: future Windows identity task adds provider/path/parent identity; trigger: any replacement that preserves an exact runtime ID. Metadata fallback remains prohibited.
- **Child-frame TOCTOU:** top-level identity and one-pixel bounds are checked, but a child can still move after its frame is read. Owner/action: future child-frame freshness task; trigger: any moving/virtualized-child misdelivery report.
- **Native text final race:** revalidation surrounds both messages and postcondition read, and failed mutation is never replayed; the final check/message interval is not atomic. Owner/action: future native-delivery design; trigger: duplicate or cross-control text evidence.
- **Physical input/UIPI:** foreground, authorization, and partial-input guards remain dependent on Windows policy and target behavior. Owner/action: deployment/integration owner; trigger: a supported signed environment with reproducible input rejection.
- **Registered-route provenance:** the restarted development child passed the patched working-tree disposable route matrix, including the native non-empty append correction. Because the PE has no embedded VCS revision and the checkout was dirty, immutable source-commit binding remains a user-owned follow-up after manual commit.
- **Independent scope:** any future explicitly allowlisted app-launch feature, save-path policy, release signing/deployment, broad third-party-app coverage, and browser/UI interaction remain outside this child.

## Follow-up correction (2026-08-30)

The source fix now uses the current .NET string's UTF-16 length for both selection offsets. The runner seeds a non-empty field and asserts exact append semantics; the patched full disposable matrix and Go/source gates pass. The earlier registered child predates this correction; the subsequent restarted child passed the corrected route behavior, as recorded in the live receipt. Immutable commit binding remains pending the user's manual source commit.

## Follow-up audit corrections (2026-08-30)

The final pre-commit review also bounded Windows `scroll.pages` to 100 page-equivalents and replaced the timeout-prone semantic multi-page loop with one viewport-percent operation. Fractional values are preserved for the semantic operation and the single app-scoped wheel fallback; fallback is not replayed after a semantic operation has been attempted. A deadline now returns a bounded scroll-specific message requiring a fresh `get_app_state` because the operation may already have been applied. Native text now marks a mutation attempt only after the final pre-mutation focus/identity check and immediately before `EM_REPLACESEL`; a pre-mutation race can therefore still use the authorized fallback, while any native text mutation remains non-replayable. Usage examples now use an explicit latest-snapshot token placeholder instead of a copyable stale identifier.

- Re-ran Go tests, race, vet, PowerShell checker/parser, disposable WPF/WinForms smoke, secret-pattern scan, and release-equivalent Windows amd64 build after these corrections.
- No browser control, persistent registration edit, unsigned deployment, host-policy/UIPI bypass, push, merge, PR, or release was performed.

## Patched Registered-Route Receipt (2026-08-30)

After the user performed a supported DSH restart, the registered `go run . mcp` child loaded the current working-tree runtime and was exercised with disposable fixtures only.

- DSH Web Node: PID `18352`, started `09:48:20`; Go launcher: PID `2096`, started `09:48:23`; Open Computer Use child: PID `8244`, started `09:48:25`.
- Child executable: `C:\Users\Alice\AppData\Local\Temp\go-build1054973390\b001\exe\opencomputerusewindows.exe`; size `2,801,152` bytes; SHA-256 `6FEF1FA0B03AD244ECB16FCDF7B70228949535E26B466502B22A6C3F58AF3827`; development PE with no embedded VCS revision.
- The registered namespace contained the expected 10 Windows tools: `list_apps`, `get_app_state`, `save_screenshot`, `click`, `perform_secondary_action`, `scroll`, `drag`, `type_text`, `press_key`, and `set_value`.
- WPF replacement validation: stale generation tokens failed closed for `set_value`, `click`, secondary action, and `scroll`; legacy bare `15` and cross-app token use failed closed; fresh tokens independently addressed the replacement and duplicate; the other app remained unchanged; semantic scroll incremented the fixture counter.
- Native validation: `app_post` produced `clicks=1`, `buttonDown=0`, `buttonUp=0`. A seeded `native-seed-中文` received `type_text("-后缀✅")` and ended exactly as `native-seed-中文-后缀✅`, proving the non-empty append correction through the registered route.

- The registered PE's embedded runtime was inspected read-only: `$currentLength = [int]$current.Length` and the explicit length-based `EM_SETSEL` call were present, while the old `EM_SETSEL` `-1` sentinel form was absent. This corroborates the live non-empty append result; the PE still has no immutable VCS revision.

Classification: patched registered-route functional verification PASS. Immutable source-commit provenance remains pending the user's manual commit because the development child has no VCS revision and the source checkout is still dirty.

No browser/DSH GUI control, persistent registration edit, deployment, host-policy/UIPI bypass, push, merge, PR, or secret access occurred.
