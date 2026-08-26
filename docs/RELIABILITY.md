# 稳定性与可运维性

## 当前最低验证线

- 构建：`swift build`
- 单元测试：`swift test`
- 端到端 smoke：`./scripts/run-tool-smoke-tests.sh`
- macOS SkyLight 实机回归：`OPEN_COMPUTER_USE_RUN_SKY_CLICK_LIVE_TEST=1 swift test --filter SkyClickLiveTests`
- Linux runtime：`(cd apps/OpenComputerUseLinux && go test ./...)`、`./scripts/build-open-computer-use-linux.sh --arch arm64`
- Windows runtime：`(cd apps/OpenComputerUseWindows && go test ./...)`、`./scripts/build-open-computer-use-windows.sh --arch amd64`，以及 `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1`；普通 WPF/WinForms fixture 脚本也可单独运行做交互式桌面验证。
- 本地诊断：
  - `open-computer-use doctor`
  - `open-computer-use snapshot <app>`

## 已知关键依赖

- macOS 上必须给 `Open Computer Use.app` 授权 `Accessibility` 与 `Screen Recording`；终端本身不应该再是必需授权对象。
- macOS `click_method=sky_click` 额外依赖 SkyLight / ApplicationServices 私有符号 `SLEventPostToPid`、`SLEventSetIntegerValueField`、`CGEventSetWindowLocation`、`SLPSPostEventRecordTo` 和 `GetProcessForPID`。运行时会动态探测并 fail closed，但 macOS 更新、签名方式或目标 app 输入策略变化仍可能让后台投递失效。受控实机回归除 DOM、前台 PID、鼠标和 z-order 外，还必须验证前台 AppKit active、key window、first responder 以及 resign/key-loss 计数。
- smoke suite 依赖本地 GUI session，不能把它当成无头环境命令。
- 普通 app 的 `get_app_state` 结果依赖 AX tree 和窗口截图，复杂 app 上输出会有差异；Electron/WebView app 的 AX tree 通常很深，当前会压缩空 wrapper 并放宽遍历深度，以优先保留可操作文本、按钮和输入框。
- Linux runtime 依赖已登录桌面用户 session；缺少 `XDG_RUNTIME_DIR`、`DBUS_SESSION_BUS_ADDRESS` 或 display 环境时，会尝试从 `/run/user/<uid>` 和常见桌面进程自动发现当前用户的 session env。纯 SSH tty 如果找不到桌面 session 仍不能直接访问 AT-SPI GUI tree。
- GNOME Wayland 截图可能被 compositor 限制，当前 Linux bridge 会把黑图视为无效截图并省略 image block。
- Windows runtime 也依赖已登录的交互式桌面 session。UIA/窗口 tree 在 SSH 或 service context 中可能为空。每个 action 都绑定 preceding snapshot 的 PID、process start time 和 top-level HWND；共享 executable alias 会在 Go cache 中标记为 ambiguous，必须改用精确标题或 PID。坐标 action 的物理 bounds 变化超过 1 pixel 会要求重新 snapshot，`app_post` 还要求 native target 是 snapshot window 的 descendant 且坐标在窗口内。需要真实 pointer 或 keyboard 输入时，部署进程必须显式配置 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1`；pointer 额外需要 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`；未授权的 `press_key` 在发送任何键消息前 fail closed。keyboard 仍可能因 foreground policy 或 UIPI 被拒绝，pointer 则会在目标不处于请求坐标最上层时 fail closed。
- Windows Enterprise Code Integrity 或其他主机控制可能拒绝或移除本地新构建的未签名 `.exe`（Code Integrity 事件可包括 3033/3077）。不要禁用策略或替换为未验证 executable。仅在受控本地开发中，可由受信任的已安装 Go toolchain 通过 `go run . mcp` 运行经审查 checkout；PowerShell 7 fixture runner 只验证 source `runtime.ps1` 和桌面边界。这些都是诊断路径，不是签名 release 的替代方案，独立部署仍必须换回经策略批准的 release artifact。

## 当前故障排查顺序

1. 先跑 `open-computer-use doctor`，确认权限状态；如果缺权限，命令会通过 `.app` app agent 拉起权限 onboarding 窗口，已全部授权则只打印状态并退出。
2. 用 `open-computer-use list-apps` 确认目标 app 是否被发现。
3. 用 `open-computer-use snapshot <app>` 看是 transport 问题还是 snapshot / action 问题。
4. 如果只有 `sky_click` 失败，先重新执行 `get_app_state`，确认窗口仍为 on-screen、未隐藏/最小化且没有切换 Space；错误里出现 `missing SkyLight symbols` 时不要改用隐式 fallback，应按当前 macOS 版本重新验证私有 SPI。被遮挡的 Chromium 页面仍无效果时，再用受控页面区分 renderer 策略变化与坐标/window-local 映射问题。
5. 如果只想验证仓库基线，直接跑 fixture + smoke，不要先在复杂第三方 app 上排查。
6. 排查 Linux runtime 时，先确认目标命令是否由桌面用户运行，再用 `open-computer-use call list_apps` 和 `open-computer-use snapshot <app>` 区分 session/env 问题与 AT-SPI tree/action 问题。如果是 Codex MCP，重新执行 `open-computer-use install-codex-mcp` 后重启 Codex，确认配置仍是 `open-computer-use mcp`。
7. 排查 Windows runtime 时，先用 PowerShell 7 执行 `apps/OpenComputerUseWindows/fixtures/run-interactive-smoke.ps1`，再在 WPF/WinForms 夹具中区分 UIA pattern、strict `app_post` 和已授权 interactive input。若 selector 是 executable name 且存在多个实例，改用 fixture window title 或 PID；不要依赖 ambiguous alias。WPF `app_post` 无 child HWND 时应返回 capability error；不要把它当作可退到 global 的信号。需要键盘时先聚焦目标，仍失败时检查 foreground ownership、UIPI/elevation 和三个显式环境变量。

## 后续补强方向

- 增加结构化日志和失败原因分类。
- 继续补充 screenshot capture / AX traversal 的失败上下文和普通 app 回归样本。
- 增加普通 app 回归样本，而不是只覆盖 fixture。

CI/CD 流程结构和 release 自动化的默认方案，统一写在 `docs/CICD.md`。
