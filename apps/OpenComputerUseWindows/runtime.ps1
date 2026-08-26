param(
    [Parameter(Mandatory = $true)]
    [string]$OperationPath
)

$ErrorActionPreference = "Stop"
$DefaultTextLimit = 500
$AccessibilityTreeMaxNodeCount = 1200
$AccessibilityTreeMaxDepth = 64

# Set output encoding to UTF-8 to properly handle non-ASCII characters
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class OCUWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT {
        public uint type;
        public INPUTUNION U;
    }

    [DllImport("user32.dll")]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    public static INPUT NewMouseInput(int x, int y, uint flags) {
        return new INPUT {
            type = 0,
            U = new INPUTUNION {
                mi = new MOUSEINPUT { dx = x, dy = y, dwFlags = flags }
            }
        };
    }

    public static INPUT NewKeyboardInput(ushort virtualKey, uint flags) {
        return new INPUT {
            type = 1,
            U = new INPUTUNION {
                ki = new KEYBDINPUT { wVk = virtualKey, dwFlags = flags }
            }
        };
    }

    public static uint SendInputRecords(INPUT[] inputs) {
        if (inputs == null) {
            return 0;
        }
        if (inputs.Length == 0) {
            return 0;
        }
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ScreenToClient(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    public static extern IntPtr ChildWindowFromPointEx(IntPtr hWndParent, POINT point, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    public static extern bool IsChild(IntPtr hWndParent, IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool PostMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindow(IntPtr hWnd);
}
"@

try {
    # UIA, window bounds, and SendInput must share physical desktop coordinates.
    [void][OCUWin32]::SetThreadDpiAwarenessContext([IntPtr](-4))
} catch {
}

$WM_SETTEXT = 0x000C
$WM_MOUSEMOVE = 0x0200
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_RBUTTONDOWN = 0x0204
$WM_RBUTTONUP = 0x0205
$WM_MBUTTONDOWN = 0x0207
$WM_MBUTTONUP = 0x0208
$WM_MOUSEWHEEL = 0x020A
$WM_MOUSEHWHEEL = 0x020E
$WM_KEYDOWN = 0x0100
$WM_KEYUP = 0x0101
$WM_CHAR = 0x0102
$EM_SETSEL = 0x00B1
$EM_REPLACESEL = 0x00C2
$BM_CLICK = 0x00F5
$MOUSEEVENTF_MOVE = 0x0001
$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004
$MOUSEEVENTF_RIGHTDOWN = 0x0008
$MOUSEEVENTF_RIGHTUP = 0x0010
$MOUSEEVENTF_MIDDLEDOWN = 0x0020
$MOUSEEVENTF_MIDDLEUP = 0x0040
$MOUSEEVENTF_MOVE_NOCOALESCE = 0x2000
$MOUSEEVENTF_VIRTUALDESK = 0x4000
$MOUSEEVENTF_ABSOLUTE = 0x8000
$KEYEVENTF_EXTENDEDKEY = 0x0001
$KEYEVENTF_KEYUP = 0x0002
$SM_XVIRTUALSCREEN = 76
$SM_YVIRTUALSCREEN = 77
$SM_CXVIRTUALSCREEN = 78
$SM_CYVIRTUALSCREEN = 79
$CWP_SKIPINVISIBLE = 0x0001
$CWP_SKIPDISABLED = 0x0002
$CWP_SKIPTRANSPARENT = 0x0004

function Test-EnvFlagEnabled([string]$name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }
    $normalized = $value.Trim().ToLowerInvariant()
    return @("1", "true", "yes", "on") -contains $normalized
}

function Get-HwndProcessId([IntPtr]$hwnd) {
    if ($hwnd -eq [IntPtr]::Zero -or -not [OCUWin32]::IsWindow($hwnd)) {
        return 0
    }
    [uint32]$processId = 0
    [void][OCUWin32]::GetWindowThreadProcessId($hwnd, [ref]$processId)
    return [int]$processId
}

function Test-HwndOwnedByProcess([IntPtr]$hwnd, $process) {
    return ((Get-HwndProcessId $hwnd) -eq [int]$process.Id)
}

function Throw-TargetChanged {
    throw "Target changed; call get_app_state again."
}

function Get-ProcessStartTimeTicks($process) {
    try {
        return [int64]$process.StartTime.ToUniversalTime().Ticks
    } catch {
        Throw-TargetChanged
    }
}

function Resolve-SnapshotActionTarget($operation) {
    [int]$expectedPid = $operation.expectedPid
    [int64]$expectedStartTimeTicks = $operation.expectedProcessStartTimeTicks
    [int64]$expectedMainWindowHandle = $operation.expectedMainWindowHandle
    if ($expectedPid -le 0 -or $expectedStartTimeTicks -le 0 -or $expectedMainWindowHandle -eq 0) {
        Throw-TargetChanged
    }

    try {
        $process = Get-Process -Id $expectedPid -ErrorAction Stop
    } catch {
        Throw-TargetChanged
    }
    if ((Get-ProcessStartTimeTicks $process) -ne $expectedStartTimeTicks) {
        Throw-TargetChanged
    }

    try {
        $element = Get-MainElement $process
        $hwnd = Get-ProcessTargetHandle $process $element
    } catch {
        Throw-TargetChanged
    }
    if ($hwnd -eq [IntPtr]::Zero -or $hwnd.ToInt64() -ne $expectedMainWindowHandle) {
        Throw-TargetChanged
    }
    return [pscustomobject]@{
        process = $process
        hwnd = $hwnd
    }
}

function Test-ProcessOwnsForegroundWindow($process, [IntPtr]$expectedHwnd) {
    $foregroundHwnd = [OCUWin32]::GetForegroundWindow()
    return (Test-HwndOwnedByProcess $foregroundHwnd $process) -and (Test-HwndDescendantOf $expectedHwnd $foregroundHwnd)
}

function Assert-InteractiveInputAllowed([bool]$requiresPointer) {
    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT")) {
        throw "Interactive Windows input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 to enable it."
    }
    if ($requiresPointer -and -not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS")) {
        throw "Global pointer input is disabled by default; set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 to enable it."
    }
}

function Test-InteractivePointerInputEnabled() {
    return (
        (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT") -and
        (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS")
    )
}

function Ensure-InteractivePointerTarget($process, [IntPtr]$hwnd, [int]$screenX, [int]$screenY) {
    Assert-InteractiveInputAllowed $true
    if (-not (Test-HwndOwnedByProcess $hwnd $process)) {
        throw "The requested app no longer owns a valid top-level window."
    }

    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    $hitWindow = [OCUWin32]::WindowFromPoint($point)
    if (-not (Test-HwndDescendantOf $hwnd $hitWindow)) {
        throw "The requested app is not the topmost descendant of the snapshot window at the requested pointer coordinates; interactive input was not sent."
    }
}

function Assert-InteractiveDragPath($process, [IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY, [int]$steps) {
    if ($steps -lt 1) {
        throw "Interactive drag requires at least one movement step."
    }
    for ($i = 0; $i -le $steps; $i++) {
        $x = [int][math]::Round($fromX + (($toX - $fromX) * $i / $steps))
        $y = [int][math]::Round($fromY + (($toY - $fromY) * $i / $steps))
        Ensure-InteractivePointerTarget $process $hwnd $x $y
    }
}

function Ensure-InteractiveKeyboardTarget($process, [IntPtr]$hwnd) {
    Assert-InteractiveInputAllowed $false
    if (-not (Test-HwndOwnedByProcess $hwnd $process)) {
        throw "The requested app no longer owns a valid top-level window."
    }
    if (Test-ProcessOwnsForegroundWindow $process $hwnd) {
        return
    }
    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
        throw "The requested app is not foreground; focus it with an authorized global click or set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to permit a bounded foreground attempt."
    }

    if (-not [OCUWin32]::SetForegroundWindow($hwnd)) {
        throw "Windows rejected the bounded foreground request for interactive keyboard input; first focus the target with an authorized global click or use a non-elevated target."
    }
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 50
        if (Test-ProcessOwnsForegroundWindow $process $hwnd) {
            return
        }
    }

    throw "Windows could not foreground the requested app for interactive keyboard input; first focus it with an authorized global click or use a non-elevated target."
}

function New-Frame($x, $y, $width, $height) {
    if ($width -lt 0 -or $height -lt 0) {
        return $null
    }
    [pscustomobject]@{
        x = [double]$x
        y = [double]$y
        width = [double]$width
        height = [double]$height
    }
}

function ConvertTo-LParam([int]$x, [int]$y) {
    $packed = (($y -band 0xffff) -shl 16) -bor ($x -band 0xffff)
    [IntPtr]$packed
}

function ConvertTo-WheelWParam([int]$delta) {
    $packed = (($delta -band 0xffff) -shl 16)
    [IntPtr]$packed
}

function Get-WindowRectFrame([IntPtr]$hwnd) {
    $rect = New-Object OCUWin32+RECT
    if ([OCUWin32]::GetWindowRect($hwnd, [ref]$rect)) {
        return New-Frame $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top)
    }
    return $null
}

function Test-HwndDescendantOf([IntPtr]$rootHwnd, [IntPtr]$candidateHwnd) {
    if ($rootHwnd -eq [IntPtr]::Zero -or $candidateHwnd -eq [IntPtr]::Zero) {
        return $false
    }
    if (-not [OCUWin32]::IsWindow($rootHwnd) -or -not [OCUWin32]::IsWindow($candidateHwnd)) {
        return $false
    }
    if ($rootHwnd -eq $candidateHwnd) {
        return $true
    }
    return [OCUWin32]::IsChild($rootHwnd, $candidateHwnd)
}

function Test-ScreenPointInHwnd([IntPtr]$hwnd, [int]$screenX, [int]$screenY) {
    $bounds = Get-WindowRectFrame $hwnd
    if ($null -eq $bounds) {
        return $false
    }
    return (
        $screenX -ge [int][math]::Floor($bounds.x) -and
        $screenX -lt [int][math]::Ceiling($bounds.x + $bounds.width) -and
        $screenY -ge [int][math]::Floor($bounds.y) -and
        $screenY -lt [int][math]::Ceiling($bounds.y + $bounds.height)
    )
}

function Assert-ScreenPointInHwnd([IntPtr]$hwnd, [int]$screenX, [int]$screenY) {
    if (-not (Test-ScreenPointInHwnd $hwnd $screenX $screenY)) {
        Throw-TargetChanged
    }
}

function Assert-AppPostDescendant([IntPtr]$rootHwnd, [IntPtr]$targetHwnd, [int]$screenX, [int]$screenY) {
    if (-not (Test-HwndDescendantOf $rootHwnd $targetHwnd)) {
        Throw-TargetChanged
    }
    Assert-ScreenPointInHwnd $rootHwnd $screenX $screenY
    if (-not (Test-ScreenPointInHwnd $targetHwnd $screenX $screenY)) {
        Throw-TargetChanged
    }
}

function Assert-SnapshotCoordinateBounds([IntPtr]$hwnd, $expectedBounds) {
    if ($null -eq $expectedBounds -or $null -eq $expectedBounds.x -or $null -eq $expectedBounds.y -or $null -eq $expectedBounds.width -or $null -eq $expectedBounds.height) {
        Throw-TargetChanged
    }
    $currentBounds = Get-WindowRectFrame $hwnd
    if ($null -eq $currentBounds) {
        Throw-TargetChanged
    }

    $components = @(
        [pscustomobject]@{ expected = [double]$expectedBounds.x; actual = [double]$currentBounds.x },
        [pscustomobject]@{ expected = [double]$expectedBounds.y; actual = [double]$currentBounds.y },
        [pscustomobject]@{ expected = [double]$expectedBounds.width; actual = [double]$currentBounds.width },
        [pscustomobject]@{ expected = [double]$expectedBounds.height; actual = [double]$currentBounds.height }
    )
    foreach ($component in $components) {
        if ([math]::Abs($component.expected - $component.actual) -gt 1) {
            Throw-TargetChanged
        }
    }
}

function Assert-AppScopedMessageTarget($process, [IntPtr]$hwnd) {
    if (-not (Test-HwndOwnedByProcess $hwnd $process)) {
        Throw-TargetChanged
    }
}

function Convert-ScreenPointToAppClient($process, [IntPtr]$hwnd, [int]$screenX, [int]$screenY) {
    Assert-AppScopedMessageTarget $process $hwnd
    Assert-ScreenPointInHwnd $hwnd $screenX $screenY
    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    if (-not [OCUWin32]::ScreenToClient($hwnd, [ref]$point)) {
        throw "Windows could not convert the requested app-scoped coordinates."
    }
    return $point
}

function Get-ElementFrame($element, $windowBounds) {
    try {
        $rect = $element.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
            return $null
        }
        if ($null -ne $windowBounds) {
            return New-Frame ($rect.X - $windowBounds.x) ($rect.Y - $windowBounds.y) $rect.Width $rect.Height
        }
        return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
    } catch {
        return $null
    }
}

function Get-ScreenPoint($localFrame, $windowBounds) {
    if ($null -eq $localFrame -or $null -eq $windowBounds) {
        return $null
    }
    [pscustomobject]@{
        x = [int][math]::Round($windowBounds.x + $localFrame.x + ($localFrame.width / 2))
        y = [int][math]::Round($windowBounds.y + $localFrame.y + ($localFrame.height / 2))
    }
}

function Get-ValidatedScrollFallbackPoint($elementRecord, $windowBounds) {
    $errorMessage = "Scroll requires an element with a valid frame when ScrollPattern is unavailable."
    if ($null -eq $elementRecord) {
        throw $errorMessage
    }

    $frame = $elementRecord.frame
    if ($null -eq $frame -or $null -eq $windowBounds) {
        throw $errorMessage
    }
    if ($null -eq $frame.x -or $null -eq $frame.y -or $null -eq $frame.width -or $null -eq $frame.height) {
        throw $errorMessage
    }

    try {
        $values = @(
            [double]$frame.x
            [double]$frame.y
            [double]$frame.width
            [double]$frame.height
        )
    } catch {
        throw $errorMessage
    }

    foreach ($value in $values) {
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) {
            throw $errorMessage
        }
    }
    if ($values[2] -le 0 -or $values[3] -le 0) {
        throw $errorMessage
    }

    $point = Get-ScreenPoint $frame $windowBounds
    if ($null -eq $point) {
        throw $errorMessage
    }
    return $point
}

function ConvertTo-AbsolutePointerPoint([int]$screenX, [int]$screenY) {
    $left = [OCUWin32]::GetSystemMetrics($SM_XVIRTUALSCREEN)
    $top = [OCUWin32]::GetSystemMetrics($SM_YVIRTUALSCREEN)
    $width = [OCUWin32]::GetSystemMetrics($SM_CXVIRTUALSCREEN)
    $height = [OCUWin32]::GetSystemMetrics($SM_CYVIRTUALSCREEN)
    if ($width -le 1 -or $height -le 1) {
        throw "Windows did not report a usable virtual desktop for global pointer input."
    }
    if ($screenX -lt $left -or $screenX -ge ($left + $width) -or $screenY -lt $top -or $screenY -ge ($top + $height)) {
        throw "Global pointer coordinates are outside the virtual desktop."
    }
    return [pscustomobject]@{
        x = [int][math]::Round((($screenX - $left) * 65535.0) / ($width - 1))
        y = [int][math]::Round((($screenY - $top) * 65535.0) / ($height - 1))
    }
}

function Submit-InteractiveInputRecords($records, [string]$operation) {
    [OCUWin32+INPUT[]]$typedRecords = @($records)
    $recordCount = $typedRecords.Length
    if ($recordCount -eq 0) {
        throw "No Windows input records were generated for ${operation}."
    }
    $accepted = [OCUWin32]::SendInputRecords($typedRecords)
    if ([int]$accepted -eq $recordCount) {
        return
    }
    if ([int]$accepted -eq 0) {
        throw "Windows accepted 0 of $recordCount interactive input records for $operation; SendInput does not provide a reliable error code for rejected records, and the batch may be blocked by foreground policy or UIPI. No retry was attempted because SendInput submission is not safely replayable."
    }
    throw "Windows accepted $accepted of $recordCount interactive input records for $operation; SendInput does not provide a reliable error code for rejected records, and the target may be blocked by foreground policy or UIPI. No retry was attempted because SendInput submission is not safely replayable."
}

function Get-GlobalMouseButtonFlags([string]$button) {
    if ($button -eq "left") {
        return [pscustomobject]@{ down = $MOUSEEVENTF_LEFTDOWN; up = $MOUSEEVENTF_LEFTUP }
    }
    if ($button -eq "right") {
        return [pscustomobject]@{ down = $MOUSEEVENTF_RIGHTDOWN; up = $MOUSEEVENTF_RIGHTUP }
    }
    if ($button -eq "middle") {
        return [pscustomobject]@{ down = $MOUSEEVENTF_MIDDLEDOWN; up = $MOUSEEVENTF_MIDDLEUP }
    }
    throw "Unsupported mouse button: $button"
}

function New-GlobalMouseInput([int]$screenX, [int]$screenY, [uint32]$eventFlags) {
    $point = ConvertTo-AbsolutePointerPoint $screenX $screenY
    $flags = [uint32]($MOUSEEVENTF_MOVE -bor $MOUSEEVENTF_MOVE_NOCOALESCE -bor $MOUSEEVENTF_VIRTUALDESK -bor $MOUSEEVENTF_ABSOLUTE -bor $eventFlags)
    return [OCUWin32]::NewMouseInput($point.x, $point.y, $flags)
}

function Send-InteractiveMouseClick($process, [IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count) {
    Ensure-InteractivePointerTarget $process $hwnd $screenX $screenY
    $buttonFlags = Get-GlobalMouseButtonFlags $button
    $records = @()
    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        $records += New-GlobalMouseInput $screenX $screenY 0
        $records += New-GlobalMouseInput $screenX $screenY $buttonFlags.down
        $records += New-GlobalMouseInput $screenX $screenY $buttonFlags.up
    }
    Submit-InteractiveInputRecords $records "mouse click"
}

function Send-InteractiveDrag($process, [IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY) {
    $steps = 12
    Assert-InteractiveDragPath $process $hwnd $fromX $fromY $toX $toY $steps
    $records = @()
    $records += New-GlobalMouseInput $fromX $fromY 0
    $records += New-GlobalMouseInput $fromX $fromY $MOUSEEVENTF_LEFTDOWN
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int][math]::Round($fromX + (($toX - $fromX) * $i / $steps))
        $y = [int][math]::Round($fromY + (($toY - $fromY) * $i / $steps))
        $records += New-GlobalMouseInput $x $y 0
    }
    $records += New-GlobalMouseInput $toX $toY $MOUSEEVENTF_LEFTUP
    Submit-InteractiveInputRecords $records "drag"
}

function Test-NativeButtonElement($element) {
    if ($null -eq $element) {
        return $false
    }
    $controlType = Get-ElementControlTypeName $element
    $className = Get-ElementString $element "ClassName"
    return (
        ($controlType -like "*Button*" -and $className -like "WindowsForms*.BUTTON*") -or
        ($className -like "WindowsForms*.BUTTON*")
    )
}

function Send-NativeButtonClick($process, [IntPtr]$hwnd, [int]$count) {
    Assert-AppScopedMessageTarget $process $hwnd
    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        if (-not [OCUWin32]::PostMessage($hwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)) {
            throw "Windows could not queue the requested native button click message."
        }
        Start-Sleep -Milliseconds 50
    }
}

function Send-MouseClick($process, [IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$button, [int]$count) {
    $point = Convert-ScreenPointToAppClient $process $hwnd $screenX $screenY
    $lParam = ConvertTo-LParam $point.X $point.Y

    $down = $WM_LBUTTONDOWN
    $up = $WM_LBUTTONUP
    $downFlag = 0x0001
    if ($button -eq "right") {
        $down = $WM_RBUTTONDOWN
        $up = $WM_RBUTTONUP
        $downFlag = 0x0002
    } elseif ($button -eq "middle") {
        $down = $WM_MBUTTONDOWN
        $up = $WM_MBUTTONUP
        $downFlag = 0x0010
    }

    $repeat = [math]::Max(1, $count)
    for ($i = 0; $i -lt $repeat; $i++) {
        Assert-AppScopedMessageTarget $process $hwnd
        if (-not [OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $lParam)) {
            throw "Windows could not queue the requested mouse move message."
        }
        if (-not [OCUWin32]::PostMessage($hwnd, $down, [IntPtr]$downFlag, $lParam)) {
            throw "Windows could not queue the requested mouse-down message."
        }
        Start-Sleep -Milliseconds 35
        if (-not [OCUWin32]::PostMessage($hwnd, $up, [IntPtr]::Zero, $lParam)) {
            throw "Windows could not queue the requested mouse-up message."
        }
        Start-Sleep -Milliseconds 50
    }
}

function Send-BackgroundDrag($process, [IntPtr]$hwnd, [int]$fromX, [int]$fromY, [int]$toX, [int]$toY) {
    Assert-AppScopedMessageTarget $process $hwnd
    $start = Convert-ScreenPointToAppClient $process $hwnd $fromX $fromY
    $end = Convert-ScreenPointToAppClient $process $hwnd $toX $toY

    # App-scoped messages are a non-physical best-effort path; they never move the system pointer.
    $steps = 12
    $startParam = ConvertTo-LParam $start.X $start.Y
    Assert-AppScopedMessageTarget $process $hwnd
    if (-not [OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]::Zero, $startParam)) {
        throw "Windows could not queue the requested background drag move message."
    }
    Assert-AppScopedMessageTarget $process $hwnd
    if (-not [OCUWin32]::PostMessage($hwnd, $WM_LBUTTONDOWN, [IntPtr]1, $startParam)) {
        throw "Windows could not queue the requested background drag mouse-down message."
    }
    for ($i = 1; $i -le $steps; $i++) {
        $x = [int][math]::Round($start.X + (($end.X - $start.X) * $i / $steps))
        $y = [int][math]::Round($start.Y + (($end.Y - $start.Y) * $i / $steps))
        Assert-AppScopedMessageTarget $process $hwnd
        if (-not [OCUWin32]::PostMessage($hwnd, $WM_MOUSEMOVE, [IntPtr]1, (ConvertTo-LParam $x $y))) {
            throw "Windows could not queue the requested background drag move message."
        }
        Start-Sleep -Milliseconds 20
    }
    Assert-AppScopedMessageTarget $process $hwnd
    if (-not [OCUWin32]::PostMessage($hwnd, $WM_LBUTTONUP, [IntPtr]::Zero, (ConvertTo-LParam $end.X $end.Y))) {
        throw "Windows could not queue the requested background drag mouse-up message."
    }
}

function Send-Scroll($process, [IntPtr]$hwnd, [int]$screenX, [int]$screenY, [string]$direction, [double]$pages) {
    $point = Convert-ScreenPointToAppClient $process $hwnd $screenX $screenY
    $lParam = ConvertTo-LParam $point.X $point.Y
    $delta = [int][math]::Round(120 * $pages)
    $message = $WM_MOUSEWHEEL
    if ($direction -eq "down" -or $direction -eq "right") {
        $delta = -1 * $delta
    }
    if ($direction -eq "left" -or $direction -eq "right") {
        $message = $WM_MOUSEHWHEEL
    }
    Assert-AppScopedMessageTarget $process $hwnd
    if (-not [OCUWin32]::PostMessage($hwnd, $message, (ConvertTo-WheelWParam $delta), $lParam)) {
        throw "Windows could not queue the requested app-scoped scroll message."
    }
}

function Send-Text($process, [IntPtr]$hwnd, [string]$text) {
    Assert-AppScopedMessageTarget $process $hwnd
    foreach ($char in $text.ToCharArray()) {
        Assert-AppScopedMessageTarget $process $hwnd
        if (-not [OCUWin32]::PostMessage($hwnd, $WM_CHAR, [IntPtr][int][char]$char, [IntPtr]::Zero)) {
            throw "Windows could not queue the requested app-scoped text message."
        }
        Start-Sleep -Milliseconds 8
    }
}

function Send-TextToEditHandle($process, [IntPtr]$hwnd, [string]$text, $element) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return $false
    }
    if (-not (Test-HwndOwnedByProcess $hwnd $process)) {
        return $false
    }

    try {
        [void][OCUWin32]::SendMessage($hwnd, $EM_SETSEL, [IntPtr](-1), [IntPtr](-1))
        [void][OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL, [IntPtr]1, $text)
        return $true
    } catch {
    }

    try {
        $current = ""
        if ($null -ne $element) {
            $current = Get-ElementValue $element
        }
        [void][OCUWin32]::SendMessage($hwnd, $WM_SETTEXT, [IntPtr]::Zero, ($current + $text))
        return $true
    } catch {
        return $false
    }
}

function Get-VirtualKey([string]$key) {
    $normalized = $key.ToLowerInvariant()
    $map = @{
        "return" = 0x0D; "enter" = 0x0D; "tab" = 0x09; "escape" = 0x1B; "esc" = 0x1B
        "backspace" = 0x08; "back_space" = 0x08; "delete" = 0x2E; "space" = 0x20
        "left" = 0x25; "up" = 0x26; "right" = 0x27; "down" = 0x28
        "home" = 0x24; "end" = 0x23; "page_up" = 0x21; "prior" = 0x21; "page_down" = 0x22; "next" = 0x22
    }
    if ($map.ContainsKey($normalized)) {
        return $map[$normalized]
    }
    if ($normalized -match "^f([1-9]|1[0-2])$") {
        return 0x70 + [int]$Matches[1] - 1
    }
    if ($normalized -match "^kp_([0-9])$") {
        return 0x60 + [int]$Matches[1]
    }
    if ($normalized.Length -eq 1) {
        $code = [int][char]$normalized.ToUpperInvariant()[0]
        if (($code -ge 0x30 -and $code -le 0x39) -or ($code -ge 0x41 -and $code -le 0x5A)) {
            return $code
        }
    }
    throw "Unsupported key: $key"
}

function Get-KeyInputEventFlags([int]$virtualKey) {
    switch ($virtualKey) {
        0x21 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x22 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x23 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x24 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x25 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x26 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x27 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x28 { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x2D { return [uint32]$KEYEVENTF_EXTENDEDKEY }
        0x2E { return [uint32]$KEYEVENTF_EXTENDEDKEY }
    }
    return [uint32]0
}

function Get-KeyInputParts([string]$key) {
    $parts = $key -split "\+"
    $main = $parts[$parts.Length - 1]
    $modifiers = @()
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            "ctrl" { $modifiers += 0x11 }
            "control" { $modifiers += 0x11 }
            "shift" { $modifiers += 0x10 }
            "alt" { $modifiers += 0x12 }
            "super" { $modifiers += 0x5B }
            "win" { $modifiers += 0x5B }
            "cmd" { $modifiers += 0x5B }
            default { throw "Unsupported modifier: $($parts[$i])" }
        }
    }
    $virtualKey = [int](Get-VirtualKey $main)
    return [pscustomobject]@{
        modifiers = @($modifiers)
        virtualKey = $virtualKey
        eventFlags = Get-KeyInputEventFlags $virtualKey
    }
}

function Send-InteractiveKey($process, [IntPtr]$hwnd, [string]$key) {
    Ensure-InteractiveKeyboardTarget $process $hwnd
    $keyParts = Get-KeyInputParts $key
    $records = @()
    foreach ($modifier in $keyParts.modifiers) {
        $records += [OCUWin32]::NewKeyboardInput([uint16]$modifier, 0)
    }
    $records += [OCUWin32]::NewKeyboardInput([uint16]$keyParts.virtualKey, $keyParts.eventFlags)
    $records += [OCUWin32]::NewKeyboardInput([uint16]$keyParts.virtualKey, [uint32]($keyParts.eventFlags -bor $KEYEVENTF_KEYUP))
    $releaseModifiers = @($keyParts.modifiers)
    [array]::Reverse($releaseModifiers)
    foreach ($modifier in $releaseModifiers) {
        $records += [OCUWin32]::NewKeyboardInput([uint16]$modifier, $KEYEVENTF_KEYUP)
    }

    Submit-InteractiveInputRecords $records "key press"
}

function Resolve-App([string]$query) {
    $normalized = $query.Trim()
    $processQuery = $normalized
    if ($processQuery.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $processQuery = $processQuery.Substring(0, $processQuery.Length - 4)
    }
    $processes = @(Get-Process | Where-Object { $PSItem.MainWindowHandle -ne 0 })
    $pidValue = 0
    if ([int]::TryParse($normalized, [ref]$pidValue)) {
        $match = $processes | Where-Object { $PSItem.Id -eq $pidValue } | Select-Object -First 1
        if ($null -ne $match) {
            return $match
        }
    }

    $escapedQuery = [System.Management.Automation.WildcardPattern]::Escape($normalized)
    $match = $processes | Where-Object {
        $PSItem.ProcessName -ieq $processQuery -or
        ("{0}.exe" -f $PSItem.ProcessName) -ieq $normalized -or
        $PSItem.MainWindowTitle -ieq $normalized -or
        $PSItem.MainWindowTitle -ilike "*$escapedQuery*"
    } | Select-Object -First 1
    if ($null -ne $match) {
        return $match
    }

    if (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_APP_LAUNCH") {
        try {
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $normalized
            $startInfo.UseShellExecute = $true
            $started = [System.Diagnostics.Process]::Start($startInfo)
            for ($i = 0; $i -lt 20; $i++) {
                Start-Sleep -Milliseconds 250
                $candidate = Get-Process -Id $started.Id -ErrorAction SilentlyContinue
                if ($null -ne $candidate -and $candidate.MainWindowHandle -ne 0) {
                    return $candidate
                }
            }
        } catch {
        }
    }

    throw "appNotFound(`"$query`")"
}

function Get-MainElement($process) {
    if ($process.MainWindowHandle -ne 0) {
        return [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$process.MainWindowHandle)
    }
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $process.Id
    $children = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
    if ($children.Count -gt 0) {
        return $children.Item(0)
    }
    $processName = $process.ProcessName
    throw "No top-level UI Automation window is available for ${processName}. Run the Windows runtime in the signed-in desktop session."
}

function Get-WindowBounds($process, $element) {
    $hwnd = [IntPtr]$process.MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
        $fromWin32 = Get-WindowRectFrame $hwnd
        if ($null -ne $fromWin32) {
            return $fromWin32
        }
    }
    try {
        $rect = $element.Current.BoundingRectangle
        if (-not $rect.IsEmpty -and $rect.Width -gt 0 -and $rect.Height -gt 0) {
            return New-Frame $rect.X $rect.Y $rect.Width $rect.Height
        }
    } catch {
    }
    return $null
}

function Get-PatternNames($element) {
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $element.GetSupportedPatterns()) {
        $programmatic = $pattern.ProgrammaticName
        if ($programmatic -like "InvokePatternIdentifiers.Pattern") { $names.Add("Invoke") }
        elseif ($programmatic -like "TogglePatternIdentifiers.Pattern") { $names.Add("Toggle") }
        elseif ($programmatic -like "SelectionItemPatternIdentifiers.Pattern") { $names.Add("Select") }
        elseif ($programmatic -like "ExpandCollapsePatternIdentifiers.Pattern") {
            try {
                $state = $element.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState
                if ($state -eq [Windows.Automation.ExpandCollapseState]::Collapsed) { $names.Add("Expand") }
                elseif ($state -eq [Windows.Automation.ExpandCollapseState]::Expanded) { $names.Add("Collapse") }
            } catch {
                $names.Add("Expand")
                $names.Add("Collapse")
            }
        }
        elseif ($programmatic -like "ScrollItemPatternIdentifiers.Pattern") { $names.Add("ScrollIntoView") }
        elseif ($programmatic -like "ScrollPatternIdentifiers.Pattern") { $names.Add("Scroll") }
        elseif ($programmatic -like "ValuePatternIdentifiers.Pattern") { $names.Add("SetValue") }
    }
    if ($names.Count -gt 0) {
        return @($names | Select-Object -Unique)
    }
    return @()
}

function Get-ElementString($element, [string]$propertyName) {
    try {
        $value = $element.Current.$propertyName
        if ($null -eq $value) {
            return ""
        }
        return [string]$value
    } catch {
        return ""
    }
}

function Get-ElementInt64($element, [string]$propertyName) {
    try {
        return [int64]$element.Current.$propertyName
    } catch {
        return 0
    }
}

function Get-ElementControlTypeName($element) {
    try {
        $controlType = $element.Current.ControlType
        if ($null -eq $controlType) {
            return ""
        }
        return [string]$controlType.ProgrammaticName
    } catch {
        return ""
    }
}

function Resolve-TextLimit($Value) {
    if ($null -eq $Value) {
        return $script:DefaultTextLimit
    }
    if ($Value -is [string] -and $Value.Trim().ToLowerInvariant() -eq "max") {
        return $null
    }
    if ($Value -is [bool]) {
        return $script:DefaultTextLimit
    }
    try {
        $integer = [int]$Value
        if ($integer -gt 0) {
            return $integer
        }
    } catch {
    }
    return $script:DefaultTextLimit
}

function Limit-Text([string]$Text, $TextLimit = $script:DefaultTextLimit) {
    if ($null -eq $Text) {
        return ""
    }
    if ($null -eq $TextLimit) {
        return $Text
    }
    $effectiveTextLimit = [int]$TextLimit
    if ($Text.Length -gt $effectiveTextLimit) {
        return $Text.Substring(0, $effectiveTextLimit) + "..."
    }
    return $Text
}

function Get-ElementValue($element, $TextLimit = $script:DefaultTextLimit) {
    try {
        $valuePattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
        $value = $valuePattern.Current.Value
        if ($null -eq $value) {
            return ""
        }
        $text = [string]$value
        return Limit-Text $text $TextLimit
    } catch {
        return ""
    }
}

function Get-ElementRecord($element, [int]$index, $windowBounds, $TextLimit = $script:DefaultTextLimit) {
    $frame = Get-ElementFrame $element $windowBounds
    $runtimeId = @()
    try { $runtimeId = @($element.GetRuntimeId()) } catch {}
    [pscustomobject]@{
        index = $index
        runtimeId = $runtimeId
        automationId = Get-ElementString $element "AutomationId"
        name = Limit-Text (Get-ElementString $element "Name") $TextLimit
        controlType = Get-ElementControlTypeName $element
        localizedControlType = Get-ElementString $element "LocalizedControlType"
        className = Get-ElementString $element "ClassName"
        value = Get-ElementValue $element $TextLimit
        nativeWindowHandle = Get-ElementInt64 $element "NativeWindowHandle"
        frame = $frame
        actions = @(Get-PatternNames $element)
    }
}

function Get-ElementTitle($record) {
    if (-not [string]::IsNullOrWhiteSpace($record.name)) {
        return $record.name
    }
    if (-not [string]::IsNullOrWhiteSpace($record.automationId)) {
        return ("ID: " + $record.automationId)
    }
    return ""
}

function Render-Tree($element, $windowBounds, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth) {
    $records = New-Object System.Collections.Generic.List[object]
    $lines = New-Object System.Collections.Generic.List[string]
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $nextIndex = 0
    $effectiveMaxTreeNodes = if ($MaxTreeNodes -gt 0) { $MaxTreeNodes } else { $script:AccessibilityTreeMaxNodeCount }
    $effectiveMaxTreeDepth = if ($MaxTreeDepth -gt 0) { $MaxTreeDepth } else { $script:AccessibilityTreeMaxDepth }

    function Visit($node, [int]$depth) {
        if ($script:nextIndex -ge $script:MaxTreeNodes -or $depth -gt $script:MaxTreeDepth) {
            return
        }
        $runtime = ""
        try { $runtime = (@($node.GetRuntimeId()) -join ".") } catch { $runtime = [guid]::NewGuid().ToString() }
        if (-not $script:visited.Add($runtime)) {
            return
        }

        $index = $script:nextIndex
        $script:nextIndex++
        $record = Get-ElementRecord $node $index $script:windowBounds $TextLimit
        $script:records.Add($record)

        $role = $record.localizedControlType
        if ([string]::IsNullOrWhiteSpace($role)) {
            $role = $record.controlType
        }
        $title = Get-ElementTitle $record
        $actionsSegment = ""
        if ($record.actions.Count -gt 0) {
            $actionsSegment = " Secondary Actions: " + ($record.actions -join ", ")
        }
        $valueSegment = ""
        if (-not [string]::IsNullOrWhiteSpace($record.value) -and $record.value -ne $title) {
            $safeValue = (($record.value -replace "`r", "\\r") -replace "`n", "\\n")
            $valueSegment = " Value: $safeValue"
        }
        $frameSegment = ""
        if ($null -ne $record.frame) {
            $frameSegment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}" -f [int][math]::Round($record.frame.x), [int][math]::Round($record.frame.y), [int][math]::Round($record.frame.width), [int][math]::Round($record.frame.height)
        }
        $script:lines.Add(("`t" * ($depth + 1)) + "$index $role $title$valueSegment$actionsSegment$frameSegment")

        try {
            $children = $node.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
            for ($i = 0; $i -lt $children.Count; $i++) {
                Visit $children.Item($i) ($depth + 1)
            }
        } catch {
        }
    }

    $script:records = $records
    $script:lines = $lines
    $script:visited = $visited
    $script:nextIndex = $nextIndex
    $script:windowBounds = $windowBounds
    $script:MaxTreeNodes = $effectiveMaxTreeNodes
    $script:MaxTreeDepth = $effectiveMaxTreeDepth
    Visit $element 0

    [pscustomobject]@{
        records = $records.ToArray()
        lines = $lines.ToArray()
    }
}

function Test-BitmapHasVisiblePixels($bitmap) {
    $stepX = [Math]::Max(1, [int]($bitmap.Width / 32))
    $stepY = [Math]::Max(1, [int]($bitmap.Height / 32))
    for ($y = 0; $y -lt $bitmap.Height; $y += $stepY) {
        for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
            $pixel = $bitmap.GetPixel($x, $y)
            if ($pixel.A -gt 8 -and ($pixel.R -gt 8 -or $pixel.G -gt 8 -or $pixel.B -gt 8)) {
                return $true
            }
        }
    }
    return $false
}

function Normalize-BitmapAlpha($bitmap) {
    for ($y = 0; $y -lt $bitmap.Height; $y++) {
        for ($x = 0; $x -lt $bitmap.Width; $x++) {
            $pixel = $bitmap.GetPixel($x, $y)
            if ($pixel.A -ne 255) {
                $bitmap.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, $pixel.R, $pixel.G, $pixel.B))
            }
        }
    }
}

function Capture-WindowPngBase64($bounds, $hwnd, [bool]$IncludeImage) {
    if (-not $IncludeImage -or $null -eq $bounds -or $bounds.width -le 0 -or $bounds.height -le 0) {
        return $null
    }
    $bitmap = $null
    $graphics = $null
    try {
        $width = [int][math]::Round($bounds.width)
        $height = [int][math]::Round($bounds.height)
        $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Black)
        $captured = $false
        $foregroundHwnd = [OCUWin32]::GetForegroundWindow()
        if ($foregroundHwnd -eq [IntPtr]$hwnd) {
            $graphics.CopyFromScreen([int][math]::Round($bounds.x), [int][math]::Round($bounds.y), 0, 0, $bitmap.Size)
            $captured = $true
        } elseif ($null -ne $hwnd -and [OCUWin32]::IsWindow([IntPtr]$hwnd)) {
            $hdc = $graphics.GetHdc()
            try {
                $captured = [OCUWin32]::PrintWindow([IntPtr]$hwnd, $hdc, 0)
            } finally {
                $graphics.ReleaseHdc($hdc)
            }
        }
        if (-not $captured -or -not (Test-BitmapHasVisiblePixels $bitmap)) {
            $graphics.CopyFromScreen([int][math]::Round($bounds.x), [int][math]::Round($bounds.y), 0, 0, $bitmap.Size)
        }
        if (-not (Test-BitmapHasVisiblePixels $bitmap)) {
            return $null
        }
        Normalize-BitmapAlpha $bitmap
        $stream = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            return [Convert]::ToBase64String($stream.ToArray())
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $graphics) { $graphics.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
    }
}

function Get-FocusedSummary($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $processId) {
            $role = $focused.Current.LocalizedControlType
            $name = Limit-Text $focused.Current.Name $TextLimit
            if ([string]::IsNullOrWhiteSpace($name)) {
                return $role
            }
            return "$role $name"
        }
    } catch {
    }
    return $null
}

function Get-SelectedText($processId, $TextLimit = $script:DefaultTextLimit) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $focused -or $focused.Current.ProcessId -ne $processId) {
            return $null
        }
        $textPattern = $focused.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern)
        $selection = $textPattern.GetSelection()
        if ($selection.Count -gt 0) {
            $maxLength = if ($null -eq $TextLimit) { -1 } else { [int]$TextLimit + 1 }
            return Limit-Text ($selection.Item(0).GetText($maxLength)) $TextLimit
        }
    } catch {
    }
    return $null
}

function Get-ProcessTargetHandle($process, $element) {
    $mainHwnd = [IntPtr]$process.MainWindowHandle
    if (Test-HwndOwnedByProcess $mainHwnd $process) {
        return $mainHwnd
    }
    $elementHwnd = Get-NativeWindowHandle $element
    if (Test-HwndOwnedByProcess $elementHwnd $process) {
        return $elementHwnd
    }
    return [IntPtr]::Zero
}

function Build-SnapshotForProcess($process, [string]$query, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth, [bool]$IncludeImage = $false) {
    $element = Get-MainElement $process
    $targetHwnd = Get-ProcessTargetHandle $process $element
    if ($targetHwnd -eq [IntPtr]::Zero) {
        Throw-TargetChanged
    }
    $bounds = Get-WindowBounds $process $element
    $startTimeTicks = Get-ProcessStartTimeTicks $process
    $rendered = Render-Tree $element $bounds $TextLimit $MaxTreeNodes $MaxTreeDepth
    [pscustomobject]@{
        app = [pscustomobject]@{
            name = $process.ProcessName
            bundleIdentifier = $process.ProcessName
            pid = [int]$process.Id
            processStartTimeTicks = $startTimeTicks
            mainWindowHandle = [int64]$targetHwnd.ToInt64()
        }
        windowTitle = Limit-Text $process.MainWindowTitle $TextLimit
        windowBounds = $bounds
        screenshotPngBase64 = Capture-WindowPngBase64 $bounds $targetHwnd $IncludeImage
        treeLines = @($rendered.lines)
        focusedSummary = Get-FocusedSummary $process.Id $TextLimit
        selectedText = Get-SelectedText $process.Id $TextLimit
        elements = @($rendered.records)
    }
}

function Build-Snapshot([string]$query, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth, [bool]$IncludeImage = $false) {
    $process = Resolve-App $query
    return Build-SnapshotForProcess $process $query $TextLimit $MaxTreeNodes $MaxTreeDepth $IncludeImage
}

function List-Apps {
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($process in (Get-Process | Where-Object { $PSItem.MainWindowHandle -ne 0 } | Sort-Object ProcessName, Id)) {
        $title = $process.MainWindowTitle
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "untitled"
        }
        $lines.Add(("{0} -- {1} [running, pid={2}, window={3}]" -f $process.ProcessName, $process.ProcessName, $process.Id, $title))
    }
    return ($lines -join "`n")
}

function Same-RuntimeId($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.Count -ne $right.Count) {
        return $false
    }
    for ($i = 0; $i -lt $left.Count; $i++) {
        if ([int]$left[$i] -ne [int]$right[$i]) {
            return $false
        }
    }
    return $true
}

function Get-AllElements($root) {
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add($root)
    try {
        $descendants = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $descendants.Count; $i++) {
            $items.Add($descendants.Item($i))
        }
    } catch {
    }
    return $items.ToArray()
}

function Find-Element($process, $record) {
    if ($null -eq $record) {
        return $null
    }
    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        try {
            if (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId)) {
                return $element
            }
        } catch {
        }
    }
    foreach ($element in (Get-AllElements $root)) {
        try {
            $sameAutomationId = -not [string]::IsNullOrWhiteSpace($record.automationId) -and $element.Current.AutomationId -eq $record.automationId
            $sameName = -not [string]::IsNullOrWhiteSpace($record.name) -and $element.Current.Name -eq $record.name
            $sameType = $element.Current.ControlType.ProgrammaticName -eq $record.controlType
            if (($sameAutomationId -or $sameName) -and $sameType) {
                return $element
            }
        } catch {
        }
    }
    return $null
}

function Get-CurrentPatternOrNull($element, $pattern) {
    try {
        return $element.GetCurrentPattern($pattern)
    } catch {
        return $null
    }
}

function Invoke-PreferredClick($element) {
    $invoke = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
    if ($null -ne $invoke) {
        $invoke.Invoke()
        return $true
    }
    $selection = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
    if ($null -ne $selection) {
        $selection.Select()
        return $true
    }
    $toggle = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
    if ($null -ne $toggle) {
        $toggle.Toggle()
        return $true
    }
    return $false
}

function Invoke-SecondaryAction($element, [string]$action) {
    switch ($action.ToLowerInvariant()) {
        "invoke" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.InvokePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Invoke(); return }
        }
        "toggle" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.TogglePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Toggle(); return }
        }
        "select" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.SelectionItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Select(); return }
        }
        "expand" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Expand(); return }
        }
        "collapse" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -ne $pattern) { $pattern.Collapse(); return }
        }
        "scrollintoview" {
            $pattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollItemPattern]::Pattern)
            if ($null -ne $pattern) { $pattern.ScrollIntoView(); return }
        }
        "setfocus" {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS")) {
                throw "SetFocus is disabled by default to avoid stealing user focus; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to enable it."
            }
            $element.SetFocus()
            return
        }
    }
    throw ("$action is not a valid secondary action for " + $operation.element.index)
}

function Invoke-Scroll($element, [string]$direction, [double]$pages) {
    $scroll = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollPattern]::Pattern)
    if ($null -eq $scroll) {
        return $false
    }
    $horizontal = [Windows.Automation.ScrollAmount]::NoAmount
    $vertical = [Windows.Automation.ScrollAmount]::NoAmount
    if ($direction -eq "up") { $vertical = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "down") { $vertical = [Windows.Automation.ScrollAmount]::LargeIncrement }
    elseif ($direction -eq "left") { $horizontal = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "right") { $horizontal = [Windows.Automation.ScrollAmount]::LargeIncrement }
    $repeat = [math]::Max(1, [int][math]::Ceiling($pages))
    for ($i = 0; $i -lt $repeat; $i++) {
        $scroll.Scroll($horizontal, $vertical)
        Start-Sleep -Milliseconds 40
    }
    return $true
}

function Find-TextEntryElement($process) {
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        if ($null -ne $focused -and $focused.Current.ProcessId -eq $process.Id) {
            $focusedValue = Get-CurrentPatternOrNull $focused ([Windows.Automation.ValuePattern]::Pattern)
            if ($null -ne $focusedValue -and -not $focusedValue.Current.IsReadOnly) {
                return $focused
            }
        }
    } catch {
    }

    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            continue
        }
        $controlType = Get-ElementControlTypeName $element
        if ($controlType -like "*Edit*" -or $controlType -like "*Document*") {
            return $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return $element
        }
    }

    return $null
}

function Get-NativeWindowHandle($element) {
    $handle = Get-ElementInt64 $element "NativeWindowHandle"
    if ($handle -le 0) {
        return [IntPtr]::Zero
    }
    return [IntPtr]$handle
}

function Resolve-AppPostTargetHandle($process, [IntPtr]$mainHwnd, $element, [int]$screenX, [int]$screenY) {
    Assert-AppScopedMessageTarget $process $mainHwnd
    Assert-ScreenPointInHwnd $mainHwnd $screenX $screenY

    if ($null -ne $element) {
        $elementHwnd = Get-NativeWindowHandle $element
        if ($elementHwnd -ne [IntPtr]::Zero) {
            if (-not (Test-HwndOwnedByProcess $elementHwnd $process)) {
                Throw-TargetChanged
            }
            Assert-AppPostDescendant $mainHwnd $elementHwnd $screenX $screenY
            return $elementHwnd
        }
        if ((Get-ElementString $element "FrameworkId") -eq "WPF") {
            throw "click_method 'app_post' requires a native HWND target for this WPF element; use click_method 'global' with the explicit interactive-input configuration."
        }
    } elseif ((Get-ElementString (Get-MainElement $process) "FrameworkId") -eq "WPF") {
        throw "click_method 'app_post' cannot target WPF coordinate input without a native child HWND; use click_method 'global' with the explicit interactive-input configuration."
    }

    $point = New-Object OCUWin32+POINT
    $point.X = $screenX
    $point.Y = $screenY
    if (-not [OCUWin32]::ScreenToClient($mainHwnd, [ref]$point)) {
        throw "Windows could not convert the requested app-post coordinates."
    }
    $child = [OCUWin32]::ChildWindowFromPointEx($mainHwnd, $point, ($CWP_SKIPINVISIBLE -bor $CWP_SKIPDISABLED -bor $CWP_SKIPTRANSPARENT))
    if ($child -ne [IntPtr]::Zero) {
        if (-not (Test-HwndOwnedByProcess $child $process)) {
            Throw-TargetChanged
        }
        Assert-AppPostDescendant $mainHwnd $child $screenX $screenY
        return $child
    }
    Assert-AppPostDescendant $mainHwnd $mainHwnd $screenX $screenY
    return $mainHwnd
}

function Test-TextWindowHandleCandidate($process, $element) {
    if ($null -eq $element) {
        return $false
    }
    $handle = Get-NativeWindowHandle $element
    if ($handle -eq [IntPtr]::Zero -or $handle -eq [IntPtr]$process.MainWindowHandle) {
        return $false
    }
    $controlType = Get-ElementControlTypeName $element
    $className = Get-ElementString $element "ClassName"
    return (
        $controlType -like "*Edit*" -or
        $controlType -like "*Document*" -or
        $className -like "*Edit*" -or
        $className -like "*Rich*" -or
        $className -like "*Text*"
    )
}

function Find-TextEntryWindowHandle($process, $preferredElement) {
    if (Test-TextWindowHandleCandidate $process $preferredElement) {
        return Get-NativeWindowHandle $preferredElement
    }

    $root = Get-MainElement $process
    foreach ($element in (Get-AllElements $root)) {
        if (-not (Test-TextWindowHandleCandidate $process $element)) {
            continue
        }
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            return Get-NativeWindowHandle $element
        }
    }

    foreach ($element in (Get-AllElements $root)) {
        if (Test-TextWindowHandleCandidate $process $element) {
            return Get-NativeWindowHandle $element
        }
    }

    return [IntPtr]::Zero
}

function Invoke-TypeText($process, [string]$text) {
    $element = Find-TextEntryElement $process
    $targetHwnd = Find-TextEntryWindowHandle $process $element
    if ($targetHwnd -ne [IntPtr]::Zero -and (Send-TextToEditHandle $process $targetHwnd $text $element)) {
        return $true
    }

    if ($null -ne $element) {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $valuePattern -and -not $valuePattern.Current.IsReadOnly) {
            if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK")) {
                throw "UIA ValuePattern text fallback is disabled by default because it may bring the target app to the foreground; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 to enable it."
            }
            $current = ""
            try { $current = [string]$valuePattern.Current.Value } catch {}
            $valuePattern.SetValue($current + $text)
            return $true
        }
    }
    return $false
}

# Read the operation file as UTF-8 explicitly. Windows PowerShell 5.1's
# Get-Content defaults to the system ANSI code page (e.g. GBK on Chinese
# systems) for files without a BOM, which corrupts non-ASCII input such as
# Chinese text passed to set_value/type_text.
$operationJson = [System.IO.File]::ReadAllText($OperationPath, [System.Text.Encoding]::UTF8)
$operation = $operationJson | ConvertFrom-Json

try {
    if ($operation.tool -eq "list_apps") {
        $response = [pscustomobject]@{ ok = $true; text = (List-Apps) }
    } elseif ($operation.tool -eq "get_app_state") {
        if ([int]$operation.expectedPid -gt 0) {
            $target = Resolve-SnapshotActionTarget $operation
            $response = [pscustomobject]@{ ok = $true; snapshot = (Build-SnapshotForProcess $target.process $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) ([bool]$operation.include_image)) }
        } else {
            $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) ([bool]$operation.include_image)) }
        }
    } else {
        $target = Resolve-SnapshotActionTarget $operation
        $process = $target.process
        $hwnd = $target.hwnd
        $windowBounds = $operation.windowBounds
        $element = Find-Element $process $operation.element

        switch ($operation.tool) {
            "click" {
                $clickMethod = [string]$operation.click_method
                if ([string]::IsNullOrWhiteSpace($clickMethod)) { $clickMethod = "auto" }

                if ($clickMethod -eq "accessibility") {
                    if ($null -eq $element) { throw "click_method 'accessibility' requires element_index" }
                    if ($operation.mouse_button -eq "right" -or $operation.mouse_button -eq "middle") {
                        throw ("click_method 'accessibility' does not support mouse_button '" + $operation.mouse_button + "'")
                    }
                    if (-not (Invoke-PreferredClick $element)) {
                        throw "click_method 'accessibility' could not click the requested element"
                    }
                } elseif ($clickMethod -eq "app_post") {
                    Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
                    }
                    $targetHwnd = Resolve-AppPostTargetHandle $process $hwnd $element $point.x $point.y
                    if ($operation.mouse_button -eq "left" -and (Test-NativeButtonElement $element)) {
                        Send-NativeButtonClick $process $targetHwnd ([int]$operation.click_count)
                    } else {
                        Send-MouseClick $process $targetHwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                    }
                } elseif ($clickMethod -eq "global") {
                    Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                    if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                        $point = Get-ScreenPoint $operation.element.frame $windowBounds
                    } else {
                        $point = [pscustomobject]@{
                            x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                            y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                        }
                    }
                    Send-InteractiveMouseClick $process $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                } elseif ($clickMethod -eq "sky_click") {
                    throw "click_method 'sky_click' is not supported on Windows"
                } elseif ($clickMethod -eq "auto") {
                    $handled = $false
                    if ($null -ne $element -and $operation.mouse_button -ne "right" -and $operation.mouse_button -ne "middle") {
                        $handled = Invoke-PreferredClick $element
                    }
                    if (-not $handled) {
                        Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                        if ($null -ne $operation.element -and $null -ne $operation.element.frame) {
                            $point = Get-ScreenPoint $operation.element.frame $windowBounds
                        } else {
                            $point = [pscustomobject]@{
                                x = [int][math]::Round($windowBounds.x + [double]$operation.x)
                                y = [int][math]::Round($windowBounds.y + [double]$operation.y)
                            }
                        }
                        Send-MouseClick $process $hwnd $point.x $point.y $operation.mouse_button ([int]$operation.click_count)
                    }
                } else {
                    throw "Invalid click_method '$clickMethod'"
                }
            }
            "perform_secondary_action" {
                if ($null -eq $element) { throw ("unknown element_index '" + $operation.element.index + "'") }
                Invoke-SecondaryAction $element $operation.action
            }
            "scroll" {
                $handled = $false
                if ($null -ne $element) {
                    $handled = Invoke-Scroll $element $operation.direction ([double]$operation.pages)
                }
                if (-not $handled) {
                    Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                    $point = Get-ValidatedScrollFallbackPoint $operation.element $windowBounds
                    Send-Scroll $process $hwnd $point.x $point.y $operation.direction ([double]$operation.pages)
                }
            }
            "drag" {
                Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                $fromX = [int][math]::Round($windowBounds.x + [double]$operation.from_x)
                $fromY = [int][math]::Round($windowBounds.y + [double]$operation.from_y)
                $toX = [int][math]::Round($windowBounds.x + [double]$operation.to_x)
                $toY = [int][math]::Round($windowBounds.y + [double]$operation.to_y)
                if (Test-InteractivePointerInputEnabled) {
                    Send-InteractiveDrag $process $hwnd $fromX $fromY $toX $toY
                } else {
                    Send-BackgroundDrag $process $hwnd $fromX $fromY $toX $toY
                }
            }
            "type_text" {
                if (-not (Invoke-TypeText $process $operation.text)) {
                    Send-Text $process $hwnd $operation.text
                }
            }
            "press_key" {
                if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT")) {
                    throw "Interactive Windows keyboard input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 and focus the target before sending a key."
                }
                Send-InteractiveKey $process $hwnd $operation.key
            }
            "set_value" {
                if ($null -eq $element) { throw ("unknown element_index '" + $operation.element.index + "'") }
                $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
                if ($null -eq $valuePattern) {
                    throw "Cannot set a value for an element that is not settable"
                }
                $valuePattern.SetValue($operation.value)
            }
            default {
                throw ('unsupportedTool(' + [char]34 + $operation.tool + [char]34 + ')')
            }
        }

        Start-Sleep -Milliseconds 120
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-SnapshotForProcess $process $operation.app $null $AccessibilityTreeMaxNodeCount $AccessibilityTreeMaxDepth $true) }
    }
} catch {
    $message = $PSItem.Exception.Message
    $stackTrace = $PSItem.ScriptStackTrace
    if (-not [string]::IsNullOrWhiteSpace($stackTrace)) {
        $message = "$message at $stackTrace"
    }
    $response = [pscustomobject]@{ ok = $false; error = $message }
}

$response | ConvertTo-Json -Depth 50 -Compress
