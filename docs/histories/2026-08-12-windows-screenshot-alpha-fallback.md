# Windows screenshot alpha/fallback repair

- Added `get_app_state.include_image`, defaulting to `false`, so accessibility-only calls do not create a PNG payload.
- Preserved screenshots for action-tool refreshes and explicit `include_image: true` calls.
- Windows capture now tries `PrintWindow`, samples for black/empty output, falls back to `CopyFromScreen`, and normalizes bitmap Alpha to opaque before PNG encoding.
- Added Go source-contract coverage for the request/schema/runtime wiring.

Validation completed in this environment:

- PowerShell parser: PASS
- `git diff --check`: PASS
- Go tests/build: BLOCKED because `go` is not installed or available in PATH.
- Real KiCad screenshot smoke: BLOCKED pending a built Windows executable; the existing Pi Computer Use comparison remains the reference evidence.
