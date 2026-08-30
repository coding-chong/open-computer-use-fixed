# 质量评分

## 评分标准

- `A`：覆盖完整、行为稳定、文档清楚、运行风险低。
- `B`：整体可接受，但还有明确短板。
- `C`：能用，但需要针对性补强。
- `D`：脆弱、缺少规范，或很多行为尚未定义。

## 当前水位

| 区域 | 评分 | 原因 | 下一步 |
| --- | --- | --- | --- |
| 产品面 | B | 已经有 Swift 本地 `computer-use` MCP server、默认 app 模式权限引导，以及一轮按官方 surface / result 行为收敛过的 9 个 tools。 | 继续收敛复杂 AX 场景下的 state rendering 细节、权限 UI 和更清晰的用户错误提示。 |
| Windows runtime | B | 独立 Go `.exe` 通过 Windows UI Automation、strict native HWND messages 和显式授权的 DPI-aware `SendInput` 暴露同样 10 个 tools、MCP server 和 `call --calls`；每个 action 绑定 snapshot PID/start/HWND，公开 `element_index` 使用 generation-qualified opaque token，immutable token bindings 有界保留并在 stale/unknown/legacy/ambiguous 情况下 fail closed，元素记录要求从 snapshot HWND 解析非空、类型有效且处于 signed 32-bit UIA component range 的 exact runtime ID，坐标 bounds 有一像素 freshness guard，Go cache/alias/action dispatcher 有并发回归，PowerShell checker/parser 与runner 可由 PS7 或 PS5.1 运行、native fixture host 独立选择的 disposable WPF/WinForms safety matrix（PS5.1/.NET Framework WinForms UIA provider 对 child controls 的 Pane 限制已记录） 已覆盖 identity、截图 provenance、numeric/enum 和 native text end-selection/append/no-replay 边界。 | 补完整 action matrix 与真实第三方 app smoke、installer/signing，以及更原生的 Go UIA 实现或更稳定的 bridge。 |
| Linux runtime | C | 已新增独立 Go binary，通过 Python GI / AT-SPI2 暴露同样 9 个 tools、MCP server 和 `call --calls`；Ubuntu GNOME VM 已跑通 `list_apps`、MCP tools list 和 Text Editor 8-tool sequence，并已接入 npm bundled artifact 分发，但截图在 GNOME Wayland 下仍只能 best-effort，coordinate input 也不是通用后台模型。 | 补 Linux fixture、可重复 smoke runner、portal/compositor screenshot 路径，以及更原生的 Go D-Bus/libatspi bridge。 |
| 架构文档 | B | 顶层结构、fixture bridge、app 模式和验证路径已经落文档。 | 后续补 release artifact、code signing / notarization 和 host 集成方式。 |
| 测试 | B | `swift test` + smoke suite 已覆盖 9 个 tools 的回归；Windows Go tests、PowerShell checker/parser、Go identity integration 和可由 PS7 或 PS5.1 运行的 WPF/WinForms safety runner 均有覆盖，当前还包括 generation-bound token/cache、stale/legacy rejection、bounded retention、并发 dispatcher/cache、截图 provenance、native text end-selection/append/no-replay 与 numeric/identity validation，但主机策略可能阻断新 PE 执行。 | 增加更多普通 app 的录制回归，减少只依赖 fixture 和一次性手工检查。 |
| 可观测性 | C | 已有 `doctor`、`snapshot`、smoke 输出，以及一组仓库内留档的官方 `computer-use` / 本仓库实现对比样本。 | 补统一日志级别、失败上下文和 release artifact 里的诊断信息，把一次性样本收敛成可重复采集流程。 |
| 安全 | B | 已明确本地-only、权限边界和 fixture test bridge 的作用域，并将内置 denylist 收缩到密码管理器。 | 增加 session approval 和更清楚的敏感 app policy，避免策略长期硬编码在仓库里。 |
