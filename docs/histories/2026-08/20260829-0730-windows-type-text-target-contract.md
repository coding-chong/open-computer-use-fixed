## [2026-08-29] | Task: Define safe Windows `type_text` target identity

### 🛠 Changes Overview
- **[Focus-only contract]**: Kept the public Windows request as `type_text(app, text)` and made the action-time `AutomationElement.FocusedElement` the only implicit target.
- **[Ownership validation]**: Require a writable `ControlType.Edit` or `ControlType.Document` element owned by the validated process and either a descendant native HWND or a UI Automation descendant of the snapshot-bound window.
- **[No retargeting]**: Removed first-writable/current-tree element and native-window searches, and removed the top-level `WM_CHAR` fallback. A focus or ownership failure now returns a bounded actionable error without mutating another control.
- **[Delivery boundary]**: Preserve the existing child-edit-HWND-first route; use the same focused element's `ValuePattern` only when `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1` is explicitly enabled.
- **[Documentation]**: Synchronized Windows model-facing instructions, usage guidance, architecture, and security notes. `set_value` remains the explicit element-indexed alternative.

### 🧪 Baseline Finding
A disposable WPF fixture was run before the change with a non-editable replacement button focused and the UIA text fallback explicitly enabled. The old runtime returned success but changed `identityPrimaryValue` from `identity-primary-1` to `identity-primary-1TYPE_BASELINE`; the intended `typed` field remained unchanged. This confirmed the pre-existing current-tree retargeting gap.

### ✅ Validation
- PowerShell 7 fixture smoke covers focused WPF success, non-editable focus rejection, focused duplicate isolation, outside-window focus rejection, disabled UIA fallback, and native child-HWND success.
- Existing WPF/WinForms identity, click, scroll, drag, authorization, and screenshot checks remain in the same runner.
- Go module tests and static runtime contract tests pass after the implementation.
- PowerShell checker and AST parser pass for the runtime, WPF fixture, WinForms fixture, and smoke runner.

### ⚠️ Boundaries / Follow-ups
- The public API intentionally remains focus-only; callers needing a snapshot-indexed direct assignment must use `set_value`.
- Generic PowerShell operational-error stack sanitization, `SetFocus` policy hardening, release signing/provenance, and DSH live verification remain separate parent/follow-up work.
- The UIA provider runtime-ID reuse limitation remains scoped to element-indexed actions and is not masked by metadata fallback.
