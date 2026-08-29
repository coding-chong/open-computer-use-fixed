## [2026-08-29 07:56] | Task: Fail closed on missing-frame Windows clicks

### 🤖 Execution Context
* **Agent ID**: `DeepSeek Harness`
* **Base Model**: `gpt-5.6-terra`
* **Runtime**: `Windows / PowerShell 7`

### 📥 User Query
> 修复并审查 Windows Computer Use 中元素点击缺少 frame 时可能误落到窗口原点的问题。

### 🛠 Changes Overview
**Scope:** Windows Computer Use runtime and its disposable WPF/WinForms verification path.

**Key Actions:**
- **统一坐标解析**: 让 `auto`、`app_post` 和授权的 `global` fallback 只接受有限正尺寸 `frame` 或明确的有限 `x/y`。
- **Fail closed**: 缺少坐标来源时在计算点或投递输入前返回 bounded error，不再把省略值转换成 `(0,0)`。
- **回归覆盖**: 增加 omitted-versus-explicit-zero 的 Go 契约测试、三种 click policy 的 observable fixture 测试、semantic no-frame 和 native explicit-coordinate 兼容测试。
- **文档同步**: 更新 Windows MCP instructions、架构和安全边界说明。

### 🧠 Design Intent (Why)
元素 runtime identity 正确并不代表坐标来源可用。把缺失的坐标当作零值会把一个本应拒绝的请求变成真实输入。将 frame/显式坐标解析集中到一个 fail-closed 边界，同时保留语义 UIA action 和 coordinate-only action，可以关闭误点击路径而不改变合法调用。

### 📁 Files Modified
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/main_test.go`
- `apps/OpenComputerUseWindows/fixture_identity_smoke_test.go`
- `apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1`
- `docs/ARCHITECTURE.md`
- `docs/SECURITY.md`

### ✅ Verification
- Go unit suite, forced fresh Go/fixture suite, and `go vet` passed.
- PowerShell checker/parser and the PowerShell 7 WPF/WinForms runner passed.
- New observable flags passed: `missingFrameClickRejected`, `validFrameAutoClick`, `semanticClickWithoutFrame`, and `explicitCoordinateClickAccepted`.
- A release-equivalent temporary amd64 build was inspected and removed; it was not deployed.
