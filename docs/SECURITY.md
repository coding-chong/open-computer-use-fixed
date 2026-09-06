# 安全默认约束

## 当前实现边界

- 对 MCP host 暴露的接口仍是本地 `stdio`；macOS CLI 与 `.app` app agent 之间会使用用户临时目录下的 Unix domain socket，socket 创建后会收紧为当前用户读写，且不对外监听 TCP/HTTP 端口。未设置 `OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE` 时继续使用历史 Socket；设置后仅以 namespace 摘要派生私有文件名，不把宿主目录或原始 namespace 写入 Socket 路径。
- 所有动作都必须显式带 `app` 参数；当前不会在后台自动扫描并控制任意 app。
- macOS 真实 app 路径依赖 `Open Computer Use.app` 已获得 `Accessibility` 与 `Screen Recording` 权限；终端里的 CLI / Node launcher 会把 `mcp`、`doctor`、`call`、`snapshot` 和 `list-apps` 转发给由 LaunchServices 启动的本地 app agent，避免把权限要求落到 iTerm / Terminal 身上。
- 实验性 Linux runtime 依赖已登录桌面用户的 AT-SPI2 / D-Bus session；coordinate mouse、drag、keyboard synthesis 只是 best-effort fallback，不应被视为跨 Wayland compositor 的通用后台输入授权。

## 数据处理

- 普通 app 的 screenshot 默认只在内存中编码成 PNG，并通过 MCP `image` content block 直接回传；默认不长期持久化。
- Linux runtime 的 screenshot 是 best-effort；如果 GNOME Wayland 返回黑图，bridge 会省略 image block，避免把无效截图误当成真实画面。
- fixture app 的合成状态只写到本地临时 JSON 文件，目的是支撑 deterministic smoke test；当前写入走原子替换，减少测试期间的读写竞争。
- Windows screenshot capture is best-effort but must not mislabel desktop pixels as target pixels: a foreground target is rechecked immediately before `CopyFromScreen` and the foreground HWND must still be the exact snapshot-bound HWND (or an explicitly proven descendant); a background target uses only nonblank `PrintWindow` output, and a failed/blank capture omits the image rather than falling back to an unowned screen rectangle. `include_image` therefore may return no image when target ownership cannot be proven.

## 授权与最小权限

- 当前只保留一层密码管理器 bundle denylist / bundle-id gate：
  - 会阻止对 1Password、Bitwarden、Dashlane、LastPass、NordPass 和 Proton Pass 做直接 `get_app_state` / action 调用。
  - 终端类 app、Chrome / Atlas 和系统组件不再属于内置阻止目标。
  - 对 bundle identifier 直传时返回 safety denial；对 app name 查询时默认不把这些密码管理器暴露成可解析目标。
- 但当前仍然没有官方闭源实现里的 session approval / 动态 app policy。
- 这意味着开源版当前的安全边界主要由：
  - 明确的 tool 调用参数
  - 内置密码管理器 denylist
  - `Open Computer Use.app` 的系统权限
  - 本地使用场景
  共同提供。
- `click_method=global` 和 physical `drag` 是显式的系统级指针路径，可能移动真实鼠标、改变前台焦点或命中坐标处的其他窗口。调用参数本身不视为足够授权；macOS 和支持该模式的 Linux runtime 要求进程环境中设置 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`。Windows 还要求 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1`，并在任何输入注入前验证目标进程拥有请求坐标处、且属于 snapshot-bound top-level HWND ancestry 的窗口；physical drag 还验证整条路径。未设置授权或窗口归属不匹配时，必须在任何可见 cursor 移动或真实输入事件之前拒绝请求。
- Windows 未授权 `drag` 只可使用已验证目标 HWND 的 app-scoped `PostMessage` best-effort fallback；它检查每次投递结果，不移动系统 pointer 或改变 foreground，且不得被表述为 global input。
- `Resolve-App` only resolves an already-running process with a top-level window. A model-provided selector is never passed to `ProcessStartInfo`, `UseShellExecute`, a URL handler, or a shell/document launcher; missing targets fail closed. `SetFocus` remains separately gated by `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1`.
- 每个 action 都携带 preceding snapshot 的 PID、process creation time 和 top-level HWND。PowerShell runtime 在任何 UIA pattern、window message、foreground 或 `SendInput` 之前验证三者；不匹配统一返回 `Target changed; call get_app_state again.`。Go snapshot cache 对共享的 executable/process-name alias 发现多个 immutable targets 时标记为 ambiguous 并拒绝 action；精确 window title 或 PID 仍可选择单一实例。
- 坐标 action 还携带 snapshot 的物理 window bounds；当前位置或尺寸任一分量变化超过 1 physical pixel 时 fail closed，必须重新 snapshot。semantic UIA action 只要求 identity，不因窗口移动而被错误拒绝。
- `app_post` 的 native target 必须是 snapshotted top-level HWND 本身或其 descendant，且请求点必须仍在目标窗口和 child HWND 内；同 PID 的另一 top-level window、窗口外坐标或失效的 ScreenToClient 都拒绝，不会借道发送到其他窗口。
- Windows element-bearing click 的坐标 fallback 只接受 snapshot element 的有限、正尺寸 `frame`，或请求中明确提供的有限 window-relative `x/y`；两者都缺失时，在 point calculation、HWND message 或 `SendInput` 之前返回 bounded frame/capability error。semantic UIA click 可以在没有 frame 时继续，coordinate-only click/drag 不进入这条 element-frame 规则。
- Windows 的 `element_index` 是 generation-bound opaque snapshot identifier，不是 durable selector。Go dispatcher 只从仍然有效的 immutable snapshot token 取回完整 element record；旧的裸数字、过期/未知 token、name、automation ID、control type 和旧 frame 都不能替代子元素身份。只有每个 stable target 的最新 generation 可执行 action；旧 token 即使暂存用于确定性 stale 响应也不能执行，alias inactivity TTL 为 5 分钟且 cache key/token binding 有界。PowerShell 继续只接受 snapshot record 中非空、类型有效且处于 signed 32-bit UIA component range 的 `runtimeId`，以已经验证的 snapshot HWND 作为当前 UIA 树根做 exact 比较。找不到 exact 元素或 token 过期时，在任何 UIA pattern、坐标计算、窗口消息、foreground 或 `SendInput` 之前返回 `Target changed; call get_app_state again.`，避免同窗口的替换或重复控件接收旧动作。runtime-ID reuse 是个别 provider 的残余风险，必须用未来更强身份方案解决，不能降级到 metadata 匹配。
- Windows `press_key` 同样要求 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1`，并要求目标进程已经持有 foreground window；如果另外设置既有的 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1`，运行时才会做有界的 `SetForegroundWindow` 尝试，否则必须先通过授权的 global click 聚焦目标。运行时不使用 `AttachThreadInput`、权限提升或 UAC 绕过来改变该限制。已提升进程或主动拦截 synthetic input 的应用可能仍然拒绝输入。
- Windows 的 UIA `ValuePattern` 文本 fallback 可能带来前台焦点风险，因此需要单独设置 `OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1`；child edit HWND 路径不依赖该标志。`type_text` 只允许动作时刻当前聚焦、通过目标进程和 snapshot-bound window 归属校验、且可写的 `Edit` / `Document` 控件；调用方必须先 click/select 字段。运行时不扫描当前 UIA 树、不按名称/顺序选择替代控件、不隐式 `SetFocus`，也不向顶层 HWND 发送键盘兜底消息；无有效焦点目标时返回 bounded actionable error，精确元素赋值应使用 `set_value` + `element_index`。
- Windows `type_text` 的 native `EM_SETSEL`/`EM_REPLACESEL` 路径在 selection setup、真正替换消息前后重新验证 focus、元素 runtime ID、进程归属和 HWND；`EM_SETSEL` 使用当前值的 UTF-16 长度显式把选择位置放到末尾，只有在即将发送 `EM_REPLACESEL` 时才标记 native mutation attempted。`EM_REPLACESEL` 的返回值不作为成功证明，写入后必须读取同一元素并验证 `before + text` postcondition。只要 text mutation 已尝试，失败时不得再通过 UIA `ValuePattern`、`WM_SETTEXT` 或键盘路径重放；postcondition 错误不代表事务性回滚，可能已经发生一次 native 写入。最后一次 revalidation 与 Win32 message 之间仍有不可消除的极窄 TOCTOU 窗口，属于已记录残余风险。
- Windows `scroll.pages` is bounded to 100 page-equivalents so the semantic UIA path performs one viewport-percent operation within the bounded 30-second PowerShell subprocess deadline; fractional values are preserved for that operation and for the single app-scoped wheel message. If semantic delivery cannot produce a valid percent target, the runtime only uses the existing fallback path when no semantic operation was attempted. A deadline response is explicitly `Windows scroll timed out; refresh with get_app_state before retrying because the operation may have been applied.`; callers must not blindly replay it.
- Go MCP 入口在 target lookup 前拒绝非字符串 click/scroll 枚举、非有限/越界数值、malformed JSON-RPC version/ID/params；通知请求不回包。子进程输出与 runtime errors 有界且 allowlist 化，不向 MCP 泄露本地路径、行号或 stack trace。
- `click_method=app_post`、`sky_click` 与 `accessibility` 不允许静默切换到 `global`。Windows `app_post` 只向同进程、同 snapshot-window ancestry 的 native HWND 投递消息；WPF/no-child-HWND 目标必须返回 capability error。这保证调用方选择的非侵入边界在失败时仍然成立。
- `click_method=sky_click` 是显式 macOS 私有 SPI 能力，不进入 `auto`。它不移动系统指针、不改变 WindowServer frontmost app，也不 raise 或切换目标窗口；内部只让目标应用短暂进入 synthetic-active 状态，绝不向真实前台应用发送 defocus record，renderer settle 后也只撤销目标的合成状态。点击后的 action-result snapshot 禁止 activate / `AXRaise` 恢复。它仍会向指定 PID/window 注入真实输入语义，因此只允许使用当前 snapshot 的 on-screen、同 PID 窗口，并在窗口身份不匹配、target-focus record 失败或私有符号缺失时 fail closed。第一版仅支持同一 Space 内的左键单击/双击。
- SkyLight ABI、raw event field 和 Chromium 接收行为都不受 Apple 公共兼容性承诺保护。系统升级后的失败不得触发静默 global fallback；应先重新验证符号和受控目标，再决定是否更新实现。
- 下一阶段应优先补：
  - session 级审批
  - 更清楚的敏感 app / 系统设置防护策略

## Fixture Bridge 约束

- `FixtureBridge` 只用于仓库内测试夹具，不是给第三方 app 的控制平面。
- 任何面向真实 app 的能力新增，都不应该复用这条测试专用通道。

仓库级的依赖、SBOM 和 provenance 默认能力，统一写在 `docs/SUPPLY_CHAIN_SECURITY.md`。
