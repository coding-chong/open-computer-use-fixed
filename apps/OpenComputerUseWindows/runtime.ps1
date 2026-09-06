param(
    [Parameter(Mandatory = $true)]
    [string]$OperationPath
)

$ErrorActionPreference = "Stop"
$DefaultTextLimit = 500
$AccessibilityTreeMaxNodeCount = 1200
$AccessibilityTreeMaxDepth = 64
$AccessibilityTreeMaxEnumeratedNodeCount = 10000
$MaxRuntimeElementSearchCount = 4096
$MaxClickCount = 100
$MaxScrollPages = 100.0
$MaxCoordinateMagnitude = 1073741823.0
$MinPositiveDecimal = [System.Decimal]::Parse("1", [System.Globalization.CultureInfo]::InvariantCulture)
$MaxSignedInt32Decimal = [System.Decimal]::Parse("2147483647", [System.Globalization.CultureInfo]::InvariantCulture)
$MaxSignedInt64Decimal = [System.Decimal]::Parse("9223372036854775807", [System.Globalization.CultureInfo]::InvariantCulture)

# Set output encoding to UTF-8 to properly handle non-ASCII characters
try {
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
} catch {
    [Console]::WriteLine('{"ok":false,"error":"Windows runtime initialization failed."}')
    exit 0
}

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

function Test-FiniteNumber($value) {
    if ($null -eq $value) {
        return $false
    }
    $isNumeric = (
        ($value -is [System.Byte]) -or ($value -is [System.SByte]) -or
        ($value -is [System.Int16]) -or ($value -is [System.UInt16]) -or
        ($value -is [System.Int32]) -or ($value -is [System.UInt32]) -or
        ($value -is [System.Int64]) -or ($value -is [System.UInt64]) -or
        ($value -is [System.Single]) -or ($value -is [System.Double]) -or
        ($value -is [System.Decimal])
    )
    if (-not $isNumeric) {
        return $false
    }
    try {
        $number = [double]$value
    } catch {
        return $false
    }
    return -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)
}

function Assert-FiniteCoordinate($value, [string]$name) {
    if (-not (Test-FiniteNumber $value)) {
        throw ($name + " must be a finite coordinate.")
    }
    $number = [double]$value
    if ([math]::Abs($number) -gt $MaxCoordinateMagnitude) {
        throw ($name + " must be within the supported coordinate range.")
    }
}

function Assert-ValidFrame($candidate, [string]$errorMessage, [bool]$requirePositiveSize) {
    if ($null -eq $candidate -or $null -eq $candidate.x -or $null -eq $candidate.y -or $null -eq $candidate.width -or $null -eq $candidate.height) {
        throw $errorMessage
    }
    foreach ($name in @("x", "y", "width", "height")) {
        $property = $candidate.PSObject.Properties[$name]
        if ($null -eq $property -or -not (Test-FiniteNumber $property.Value)) {
            throw $errorMessage
        }
    }
    $values = @()
    try {
        $values = @(
            [double]$candidate.x
            [double]$candidate.y
            [double]$candidate.width
            [double]$candidate.height
        )
    } catch {
        throw $errorMessage
    }
    foreach ($value in $values) {
        if (-not (Test-FiniteNumber $value) -or [math]::Abs([double]$value) -gt $MaxCoordinateMagnitude) {
            throw $errorMessage
        }
    }
    if ($requirePositiveSize -and ($values[2] -le 0 -or $values[3] -le 0)) {
        throw $errorMessage
    }
    if (-not $requirePositiveSize -and ($values[2] -lt 0 -or $values[3] -lt 0)) {
        throw $errorMessage
    }
}

function Assert-OperationNumericValues($operation) {
    if ($null -eq $operation -or [string]::IsNullOrWhiteSpace([string]$operation.tool)) {
        throw "Operation JSON requires a non-empty tool."
    }
    [void](Get-SnapshotIdentity $operation $false)
    switch ([string]$operation.tool) {
        "click" {
            [void](Get-OperationClickMethod $operation)
            [void](Get-OperationMouseButton $operation)
            $clickProperty = $operation.PSObject.Properties["click_count"]
            if ($null -ne $clickProperty) {
                if (-not (Test-FiniteNumber $clickProperty.Value)) {
                    throw "click_count must be an integer between 1 and 100."
                }
                $clickCount = [double]$clickProperty.Value
                if ([math]::Truncate($clickCount) -ne $clickCount -or $clickCount -lt 1 -or $clickCount -gt $MaxClickCount) {
                    throw "click_count must be an integer between 1 and 100."
                }
            }
            $xProperty = $operation.PSObject.Properties["x"]
            $yProperty = $operation.PSObject.Properties["y"]
            if (($null -ne $xProperty) -xor ($null -ne $yProperty)) {
                throw "Click coordinates x and y must be provided together."
            }
            foreach ($name in @("x", "y")) {
                $property = $operation.PSObject.Properties[$name]
                if ($null -ne $property) {
                    Assert-FiniteCoordinate $property.Value $name
                }
            }
        }
        "drag" {
            foreach ($name in @("from_x", "from_y", "to_x", "to_y")) {
                $property = $operation.PSObject.Properties[$name]
                if ($null -eq $property -or $null -eq $property.Value) {
                    throw ("Missing required argument: " + $name)
                }
                Assert-FiniteCoordinate $property.Value $name
            }
        }
        "scroll" {
            [void](Get-OperationDirection $operation)
            $pagesProperty = $operation.PSObject.Properties["pages"]
            if ($null -ne $pagesProperty) {
                if ($null -eq $pagesProperty.Value -or -not (Test-FiniteNumber $pagesProperty.Value)) {
                    throw "pages must be finite and in (0,100]."
                }
                $pages = [double]$pagesProperty.Value
                if ($pages -le 0 -or $pages -gt $MaxScrollPages) {
                    throw "pages must be finite and in (0,100]."
                }
            }
        }
    }
}

function Test-IntegerInRange($value, [decimal]$minimum, [decimal]$maximum) {
    if (-not (Test-FiniteNumber $value)) {
        return $false
    }
    try {
        $number = [decimal]$value
        return $number -eq [decimal]::Truncate($number) -and $number -ge $minimum -and $number -le $maximum
    } catch {
        return $false
    }
}

function Get-SnapshotIdentity($operation, [bool]$required) {
    if ($null -eq $operation) {
        if ($required) { Throw-TargetChanged }
        return $null
    }
    $names = @('expectedPid', 'expectedProcessStartTimeTicks', 'expectedMainWindowHandle')
    $present = @()
    foreach ($name in $names) {
        if ($null -ne $operation.PSObject.Properties[$name]) {
            $present += $name
        }
    }
    if ($present.Count -eq 0) {
        if ($required) { Throw-TargetChanged }
        return $null
    }
    if ($present.Count -ne $names.Count) {
        Throw-TargetChanged
    }

    $pidValue = $operation.expectedPid
    $startValue = $operation.expectedProcessStartTimeTicks
    $hwndValue = $operation.expectedMainWindowHandle
    if (-not (Test-IntegerInRange $pidValue $MinPositiveDecimal $MaxSignedInt32Decimal) -or
        -not (Test-IntegerInRange $startValue $MinPositiveDecimal $MaxSignedInt64Decimal) -or
        -not (Test-IntegerInRange $hwndValue $MinPositiveDecimal $MaxSignedInt64Decimal)) {
        Throw-TargetChanged
    }
    try {
        return [pscustomobject]@{
            pid = [int]$pidValue
            startTimeTicks = [int64]$startValue
            mainWindowHandle = [int64]$hwndValue
        }
    } catch {
        Throw-TargetChanged
    }
}

function Get-OperationPages($operation) {
    $property = $operation.PSObject.Properties["pages"]
    if ($null -eq $property) {
        return 1.0
    }
    return [double]$property.Value
}

function Get-OperationClickCount($operation) {
    $property = $operation.PSObject.Properties["click_count"]
    if ($null -eq $property) {
        return 1
    }
    return [int]$property.Value
}

function Get-OperationClickMethod($operation) {
    $property = $operation.PSObject.Properties["click_method"]
    $method = "auto"
    if ($null -ne $property) {
        if ($null -eq $property.Value -or -not ($property.Value -is [string])) {
            throw "Invalid click_method value."
        }
        $method = ([string]$property.Value).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($method)) {
            $method = "auto"
        }
    }
    if (@("auto", "accessibility", "app_post", "sky_click", "global") -notcontains $method) {
        throw ("Invalid click_method '" + $method + "'")
    }
    return $method
}

function Get-OperationMouseButton($operation) {
    $property = $operation.PSObject.Properties["mouse_button"]
    $button = "left"
    if ($null -ne $property) {
        if ($null -eq $property.Value -or -not ($property.Value -is [string])) {
            throw "Unsupported mouse button."
        }
        $button = ([string]$property.Value).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($button)) {
            $button = "left"
        }
    }
    if (@("left", "right", "middle") -notcontains $button) {
        throw ("Unsupported mouse button: " + $button)
    }
    return $button
}

function Get-OperationDirection($operation) {
    $property = $operation.PSObject.Properties["direction"]
    if ($null -eq $property -or $null -eq $property.Value -or -not ($property.Value -is [string])) {
        throw "Invalid scroll direction."
    }
    $direction = ([string]$property.Value).Trim().ToLowerInvariant()
    if (@("up", "down", "left", "right") -notcontains $direction) {
        throw "Invalid scroll direction."
    }
    return $direction
}

function Get-ProcessStartTimeTicks($process) {
    try {
        return [int64]$process.StartTime.ToUniversalTime().Ticks
    } catch {
        Throw-TargetChanged
    }
}


function Test-ProcessMatchesSelector($process, [string]$query) {
    if ($null -eq $process -or [string]::IsNullOrWhiteSpace($query)) {
        return $false
    }
    $normalized = $query.Trim()
    $processQuery = $normalized
    if ($processQuery.EndsWith(".exe", [System.StringComparison]::OrdinalIgnoreCase)) {
        $processQuery = $processQuery.Substring(0, $processQuery.Length - 4)
    }
    $pidValue = 0
    if ([int]::TryParse($normalized, [ref]$pidValue)) {
        return ([int]$process.Id -eq $pidValue)
    }
    $escapedQuery = [System.Management.Automation.WildcardPattern]::Escape($normalized)
    return (
        $process.ProcessName -ieq $processQuery -or
        ("{0}.exe" -f $process.ProcessName) -ieq $normalized -or
        $process.MainWindowTitle -ieq $normalized -or
        $process.MainWindowTitle -ilike "*$escapedQuery*"
    )
}

function Resolve-SnapshotActionTarget($operation) {
    $identity = Get-SnapshotIdentity $operation $true
    $expectedPid = $identity.pid
    $expectedStartTimeTicks = $identity.startTimeTicks
    $expectedMainWindowHandle = $identity.mainWindowHandle
    try {
        $process = Get-Process -Id $expectedPid -ErrorAction Stop
        if ((Get-ProcessStartTimeTicks $process) -ne $expectedStartTimeTicks) {
            Throw-TargetChanged
        }
        if (-not (Test-ProcessMatchesSelector $process ([string]$operation.app))) {
            Throw-TargetChanged
        }
        $target = Resolve-InteractiveWindowTarget $process
        $hwnd = $target.hwnd
        if ($hwnd.ToInt64() -ne $expectedMainWindowHandle) {
            Throw-TargetChanged
        }
        return [pscustomobject]@{ process = $process; hwnd = $hwnd; element = $target.element; bounds = $target.bounds }
    } catch {
        if ($PSItem.Exception.Message -eq "Target changed; call get_app_state again.") { throw }
        Throw-TargetChanged
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
    $deltaX = [double]$toX - [double]$fromX
    $deltaY = [double]$toY - [double]$fromY
    for ($i = 0; $i -le $steps; $i++) {
        $x = ConvertTo-SafePixelCoordinate ($fromX + ($deltaX * $i / $steps))
        $y = ConvertTo-SafePixelCoordinate ($fromY + ($deltaY * $i / $steps))
        if ($null -eq $x -or $null -eq $y) {
            Throw-TargetChanged
        }
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
    if (-not (Test-FiniteNumber $x) -or -not (Test-FiniteNumber $y) -or -not (Test-FiniteNumber $width) -or -not (Test-FiniteNumber $height)) {
        return $null
    }
    $values = @([double]$x, [double]$y, [double]$width, [double]$height)
    foreach ($value in $values) {
        if ([math]::Abs($value) -gt $MaxCoordinateMagnitude) {
            return $null
        }
    }
    if ($values[2] -lt 0 -or $values[3] -lt 0) {
        return $null
    }
    [pscustomobject]@{
        x = $values[0]
        y = $values[1]
        width = $values[2]
        height = $values[3]
    }
}

function ConvertTo-SafePixelCoordinate($value) {
    if (-not (Test-FiniteNumber $value)) {
        return $null
    }
    $rounded = [math]::Round([double]$value)
    if (-not (Test-FiniteNumber $rounded) -or [math]::Abs($rounded) -gt $MaxCoordinateMagnitude) {
        return $null
    }
    return [int]$rounded
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
function Get-VirtualDesktopFrame {
    $x = [OCUWin32]::GetSystemMetrics($SM_XVIRTUALSCREEN)
    $y = [OCUWin32]::GetSystemMetrics($SM_YVIRTUALSCREEN)
    $width = [OCUWin32]::GetSystemMetrics($SM_CXVIRTUALSCREEN)
    $height = [OCUWin32]::GetSystemMetrics($SM_CYVIRTUALSCREEN)
    return New-Frame $x $y $width $height
}

function Test-FrameIntersects($candidate, $desktop) {
    if ($null -eq $candidate -or $null -eq $desktop) {
        return $false
    }
    foreach ($frame in @($candidate, $desktop)) {
        foreach ($name in @('x', 'y', 'width', 'height')) {
            try {
                if (-not (Test-FiniteNumber $frame.$name)) {
                    return $false
                }
            } catch {
                return $false
            }
        }
    }
    try {
        if ([double]$candidate.width -le 0 -or [double]$candidate.height -le 0 -or [double]$desktop.width -le 0 -or [double]$desktop.height -le 0) {
            return $false
        }
        return (
            ([double]$candidate.x -lt ([double]$desktop.x + [double]$desktop.width)) -and
            (([double]$candidate.x + [double]$candidate.width) -gt [double]$desktop.x) -and
            ([double]$candidate.y -lt ([double]$desktop.y + [double]$desktop.height)) -and
            (([double]$candidate.y + [double]$candidate.height) -gt [double]$desktop.y)
        )
    } catch {
        return $false
    }
}

function Test-FramesMatch($left, $right, [double]$tolerance = 1) {
    if ($null -eq $left -or $null -eq $right -or -not (Test-FiniteNumber $tolerance) -or $tolerance -lt 0) {
        return $false
    }
    foreach ($name in @('x', 'y', 'width', 'height')) {
        try {
            if (-not (Test-FiniteNumber $left.$name) -or -not (Test-FiniteNumber $right.$name) -or [math]::Abs(([double]$left.$name) - ([double]$right.$name)) -gt $tolerance) {
                return $false
            }
        } catch {
            return $false
        }
    }
    return $true
}

function Test-UsableTopLevelWindow($process, $element, [IntPtr]$hwnd) {
    if ($null -eq $process -or $null -eq $element -or $hwnd -eq [IntPtr]::Zero) {
        return $false
    }
    if (-not [OCUWin32]::IsWindow($hwnd) -or -not (Test-HwndOwnedByProcess $hwnd $process)) {
        return $false
    }
    $rootHwnd = [OCUWin32]::GetAncestor($hwnd, 2)
    if ($rootHwnd -eq [IntPtr]::Zero -or $rootHwnd -ne $hwnd) {
        return $false
    }
    $nativeBounds = Get-WindowRectFrame $hwnd
    $desktopBounds = Get-VirtualDesktopFrame
    if ($null -eq $nativeBounds -or $nativeBounds.width -le 0 -or $nativeBounds.height -le 0 -or -not (Test-FrameIntersects $nativeBounds $desktopBounds)) {
        return $false
    }
    try {
        if ([int]$element.Current.ProcessId -ne [int]$process.Id -or (Get-NativeWindowHandle $element) -ne $hwnd) {
            return $false
        }
        $rect = $element.Current.BoundingRectangle
        if ($rect.IsEmpty -or $rect.Width -le 0 -or $rect.Height -le 0) {
            return $false
        }
        $uiaBounds = New-Frame $rect.X $rect.Y $rect.Width $rect.Height
        if ($null -eq $uiaBounds -or $uiaBounds.width -le 0 -or $uiaBounds.height -le 0) {
            return $false
        }
        return Test-FramesMatch $nativeBounds $uiaBounds 1
    } catch {
        return $false
    }
}

function Resolve-InteractiveWindowTarget($process) {
    if ($null -eq $process) {
        throw "No usable top-level interactive window is available for the requested app."
    }
    $candidates = New-Object System.Collections.Generic.List[object]
    $handles = New-Object 'System.Collections.Generic.HashSet[Int64]'
    $mainHwnd = [IntPtr]$process.MainWindowHandle
    if ($mainHwnd -ne [IntPtr]::Zero -and $handles.Add($mainHwnd.ToInt64())) {
        try {
            $mainElement = [Windows.Automation.AutomationElement]::FromHandle($mainHwnd)
            if (Test-UsableTopLevelWindow $process $mainElement $mainHwnd) {
                return [pscustomobject]@{
                    hwnd = $mainHwnd
                    element = $mainElement
                    bounds = Get-WindowRectFrame $mainHwnd
                }
            }
        } catch {
        }
    }
    try {
        $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::ProcessIdProperty), $process.Id
        $children = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $condition)
        $limit = [math]::Min([int]$children.Count, 256)
        for ($i = 0; $i -lt $limit; $i++) {
            $element = $children.Item($i)
            $hwnd = Get-NativeWindowHandle $element
            if ($hwnd -ne [IntPtr]::Zero -and $handles.Add($hwnd.ToInt64())) {
                [void]$candidates.Add([pscustomobject]@{ hwnd = $hwnd; element = $element })
            }
        }
    } catch {
    }
    $usable = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in $candidates) {
        if (Test-UsableTopLevelWindow $process $candidate.element $candidate.hwnd) {
            [void]$usable.Add([pscustomobject]@{
                hwnd = $candidate.hwnd
                element = $candidate.element
                bounds = Get-WindowRectFrame $candidate.hwnd
            })
        }
    }
    if ($usable.Count -ne 1) {
        throw "No usable top-level interactive window is available for the requested app."
    }
    return $usable[0]
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
    $errorMessage = "Target changed; call get_app_state again."
    try {
        Assert-ValidFrame $expectedBounds $errorMessage $true
    } catch {
        Throw-TargetChanged
    }
    $currentBounds = Get-WindowRectFrame $hwnd
    if ($null -eq $currentBounds) {
        Throw-TargetChanged
    }
    try {
        Assert-ValidFrame $currentBounds $errorMessage $true
    } catch {
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
    try {
        Assert-ValidFrame $windowBounds "invalid window bounds" $true
        Assert-ValidFrame $localFrame "invalid local frame" $false
        $xValue = [double]$windowBounds.x + [double]$localFrame.x + ([double]$localFrame.width / 2.0)
        $yValue = [double]$windowBounds.y + [double]$localFrame.y + ([double]$localFrame.height / 2.0)
        if (-not (Test-FiniteNumber $xValue) -or -not (Test-FiniteNumber $yValue) -or
            [math]::Abs($xValue) -gt $MaxCoordinateMagnitude -or [math]::Abs($yValue) -gt $MaxCoordinateMagnitude) {
            return $null
        }
        $x = ConvertTo-SafePixelCoordinate $xValue
        $y = ConvertTo-SafePixelCoordinate $yValue
    } catch {
        return $null
    }
    if ($null -eq $x -or $null -eq $y) {
        return $null
    }
    [pscustomobject]@{
        x = $x
        y = $y
    }
}

function Get-ValidatedClickPoint($elementRecord, $operation, $windowBounds) {
    $errorMessage = "Click requires an element with a valid frame or explicit finite x/y coordinates."
    try {
        Assert-ValidFrame $windowBounds $errorMessage $true
    } catch {
        throw $errorMessage
    }

    $frame = $null
    if ($null -ne $elementRecord) {
        $frame = $elementRecord.frame
    }
    $validFrame = $false
    if ($null -ne $frame) {
        try {
            Assert-ValidFrame $frame $errorMessage $true
            $validFrame = $true
        } catch {
            $validFrame = $false
        }
    }

    if ($validFrame) {
        $point = Get-ScreenPoint $frame $windowBounds
        if ($null -ne $point) {
            return $point
        }
    }

    if ($null -eq $operation -or $null -eq $operation.x -or $null -eq $operation.y) {
        throw $errorMessage
    }
    try {
        Assert-FiniteCoordinate $operation.x "x"
        Assert-FiniteCoordinate $operation.y "y"
        $coordinateValues = @(
            [double]$operation.x
            [double]$operation.y
        )
        $explicitFrame = [pscustomobject]@{ x = $coordinateValues[0]; y = $coordinateValues[1]; width = 0.0; height = 0.0 }
        $explicitPoint = Get-ScreenPoint $explicitFrame $windowBounds
    } catch {
        throw $errorMessage
    }
    if ($null -eq $explicitPoint) {
        throw $errorMessage
    }
    return $explicitPoint
}

function Get-ValidatedScrollFallbackPoint($elementRecord, $windowBounds) {
    $errorMessage = "Scroll requires an element with a valid frame when ScrollPattern is unavailable."
    if ($null -eq $elementRecord) {
        throw $errorMessage
    }

    try {
        Assert-ValidFrame $windowBounds $errorMessage $true
        Assert-ValidFrame $elementRecord.frame $errorMessage $true
        $point = Get-ScreenPoint $elementRecord.frame $windowBounds
    } catch {
        throw $errorMessage
    }
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
    $deltaX = [double]$end.X - [double]$start.X
    $deltaY = [double]$end.Y - [double]$start.Y
    for ($i = 1; $i -le $steps; $i++) {
        $x = ConvertTo-SafePixelCoordinate ($start.X + ($deltaX * $i / $steps))
        $y = ConvertTo-SafePixelCoordinate ($start.Y + ($deltaY * $i / $steps))
        if ($null -eq $x -or $null -eq $y) {
            Throw-TargetChanged
        }
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

function Send-TextToEditHandle($process, [IntPtr]$hwnd, [string]$text, $element, [IntPtr]$rootHwnd) {
    if ($hwnd -eq [IntPtr]::Zero) {
        return [pscustomobject]@{ attempted = $false; succeeded = $false }
    }
    if (-not (Test-HwndOwnedByProcess $hwnd $process)) {
        return [pscustomobject]@{ attempted = $false; succeeded = $false }
    }

    # Focus/ownership failures happen before the first mutating message and may
    # still be handled by the same focused-element UIA capability path.
    [void](Assert-FocusedTextTarget $process $rootHwnd $element $hwnd)
    $current = $null
    try {
        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            throw $TypeTextDeliveryError
        }
        $current = [string]$valuePattern.Current.Value
    } catch {
        throw $TypeTextDeliveryError
    }

    # Once a native mutation is attempted, never fall back to a second write:
    # EM_REPLACESEL has no defined return value, so verify the postcondition and
    # report failure rather than risking duplicate text through WM_SETTEXT/UIA.
    # Use UTF-16 offsets so the native edit control appends after the current value.
    $currentLength = [int]$current.Length
    $attempted = $false
    try {
        [void](Assert-FocusedTextTarget $process $rootHwnd $element $hwnd)
        # EM_SETSEL changes only the selection; defer the no-replay marker until
        # the first message that can mutate the text value.
        [void][OCUWin32]::SendMessage($hwnd, $EM_SETSEL, [IntPtr]$currentLength, [IntPtr]$currentLength)
        [void](Assert-FocusedTextTarget $process $rootHwnd $element $hwnd)
        $attempted = $true
        [void][OCUWin32]::SendMessage($hwnd, $EM_REPLACESEL, [IntPtr]1, $text)
        [void](Assert-FocusedTextTarget $process $rootHwnd $element $hwnd)
        $afterPattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $afterPattern) {
            return [pscustomobject]@{ attempted = $true; succeeded = $false }
        }
        $after = [string]$afterPattern.Current.Value
        if ($after -ne ($current + $text)) {
            return [pscustomobject]@{ attempted = $true; succeeded = $false }
        }
        return [pscustomobject]@{ attempted = $true; succeeded = $true }
    } catch {
        if ($attempted) {
            return [pscustomobject]@{ attempted = $true; succeeded = $false }
        }
        throw $TypeTextDeliveryError
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

    throw "appNotFound(`"$query`")"
}

function Get-MainElement($process) {
    return (Resolve-InteractiveWindowTarget $process).element
}

function Get-WindowBounds($process, $element, [IntPtr]$expectedHwnd = [IntPtr]::Zero) {
    $target = Resolve-InteractiveWindowTarget $process
    if ($expectedHwnd -ne [IntPtr]::Zero -and $target.hwnd -ne $expectedHwnd) {
        Throw-TargetChanged
    }
    return $target.bounds
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

function Get-ElementRecord($element, [int]$index, $windowBounds, $TextLimit = $script:DefaultTextLimit, $RuntimeId = $null) {
    if ($null -eq $RuntimeId) {
        try { $RuntimeId = @($element.GetRuntimeId()) } catch { $RuntimeId = @() }
    }
    if ($null -eq $RuntimeId -or @($RuntimeId).Count -eq 0) {
        return $null
    }
    $frame = Get-ElementFrame $element $windowBounds
    [pscustomobject]@{
        index = $index
        runtimeId = @($RuntimeId)
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
    $renderState = [pscustomobject]@{
        records = New-Object System.Collections.Generic.List[object]
        lines = New-Object System.Collections.Generic.List[string]
        visited = New-Object System.Collections.Generic.HashSet[string]
        nextIndex = 0
        maxTreeNodes = if ($MaxTreeNodes -gt 0) { $MaxTreeNodes } else { $script:AccessibilityTreeMaxNodeCount }
        maxTreeDepth = if ($MaxTreeDepth -gt 0) { $MaxTreeDepth } else { $script:AccessibilityTreeMaxDepth }
        maxEnumeratedNodes = $script:AccessibilityTreeMaxEnumeratedNodeCount
        enumeratedNodes = 0
        windowBounds = $windowBounds
    }

    function Visit($state, $node, [int]$depth) {
        if ($state.enumeratedNodes -ge $state.maxEnumeratedNodes) {
            return
        }
        $state.enumeratedNodes = $state.enumeratedNodes + 1
        if ($state.nextIndex -ge $state.maxTreeNodes -or $depth -gt $state.maxTreeDepth) {
            return
        }
        $runtimeParts = @()
        try { $runtimeParts = @($node.GetRuntimeId()) } catch { $runtimeParts = @() }
        $runtimeIsValid = ($runtimeParts.Count -gt 0)
        if ($runtimeIsValid) {
            foreach ($runtimePart in $runtimeParts) {
                if (-not (Test-IntegerRuntimeIdValue $runtimePart)) {
                    $runtimeIsValid = $false
                    break
                }
            }
        }
        if (-not $runtimeIsValid) {
            Visit-Children $state $node $depth
            return
        }
        $runtime = ($runtimeParts -join ".")
        if (-not $state.visited.Add($runtime)) {
            return
        }

        $index = $state.nextIndex
        $record = Get-ElementRecord $node $index $state.windowBounds $TextLimit $runtimeParts
        if ($null -eq $record) {
            Visit-Children $state $node $depth
            return
        }
        $state.nextIndex++
        [void]$state.records.Add($record)

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
        [void]$state.lines.Add(("`t" * ($depth + 1)) + "$index $role $title$valueSegment$actionsSegment$frameSegment")

        Visit-Children $state $node $depth
    }

    function Visit-Children($state, $node, [int]$depth) {
        try {
            $children = $node.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
            for ($i = 0; $i -lt $children.Count; $i++) {
                Visit $state $children.Item($i) ($depth + 1)
                if ($state.nextIndex -ge $state.maxTreeNodes -or $state.enumeratedNodes -ge $state.maxEnumeratedNodes) {
                    break
                }
            }
        } catch {
        }
    }

    Visit $renderState $element 0

    [pscustomobject]@{
        records = $renderState.records.ToArray()
        lines = $renderState.lines.ToArray()
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
    # Fast gate: sample a 32x32 grid. Screen copies are always fully opaque, so
    # the common case skips the expensive full-surface scan entirely.
    $stepX = [Math]::Max(1, [int]($bitmap.Width / 32))
    $stepY = [Math]::Max(1, [int]($bitmap.Height / 32))
    $needsNormalize = $false
    for ($y = 0; $y -lt $bitmap.Height -and -not $needsNormalize; $y += $stepY) {
        for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
            if ($bitmap.GetPixel($x, $y).A -ne 255) {
                $needsNormalize = $true
                break
            }
        }
    }
    if (-not $needsNormalize) {
        return
    }
    # Slow path: batch-rewrite alpha through LockBits + Marshal.Copy instead of
    # per-pixel GetPixel/SetPixel interop (1080p would be ~2M interop calls).
    # Format32bppArgb is stored little-endian BGRA, so alpha lives at offset 3 mod 4.
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bitmap.Width, $bitmap.Height
    $data = $bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $bytes = New-Object byte[] ($stride * $bitmap.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        for ($offset = 3; $offset -lt $bytes.Length; $offset += 4) {
            if ($bytes[$offset] -ne 255) {
                $bytes[$offset] = 255
            }
        }
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $bytes.Length)
    } finally {
        $bitmap.UnlockBits($data)
    }
}

function Capture-WindowPngBase64($bounds, $hwnd, [bool]$IncludeImage, $process = $null, [int64]$ExpectedStartTimeTicks = 0) {
    if (-not $IncludeImage -or $null -eq $bounds) {
        return $null
    }
    try {
        Assert-ValidFrame $bounds "Target changed; call get_app_state again." $true
    } catch {
        return $null
    }
    if ($null -eq $process) {
        return $null
    }
    $bitmap = $null
    $graphics = $null
    try {
        $captureBounds = Assert-SnapshotCaptureTarget $process $hwnd $ExpectedStartTimeTicks $bounds
        $width = [int][math]::Round($captureBounds.width)
        $height = [int][math]::Round($captureBounds.height)
        if ($width -le 0 -or $height -le 0) {
            return $null
        }
        $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Black)
        $captured = $false
        $foregroundHwnd = [OCUWin32]::GetForegroundWindow()
        if ($foregroundHwnd -eq [IntPtr]$hwnd -and (Test-HwndDescendantOf ([IntPtr]$hwnd) $foregroundHwnd)) {
            # Desktop pixels are accepted only after the exact target identity and
            # bounds/foreground ancestry are revalidated immediately before the copy.
            $captureBounds = Assert-SnapshotCaptureTarget $process $hwnd $ExpectedStartTimeTicks $bounds
            $foregroundHwnd = [OCUWin32]::GetForegroundWindow()
            if (-not (Test-HwndDescendantOf ([IntPtr]$hwnd) $foregroundHwnd)) {
                return $null
            }
            $graphics.CopyFromScreen([int][math]::Round($captureBounds.x), [int][math]::Round($captureBounds.y), 0, 0, $bitmap.Size)
            $captured = $true
        } else {
            # PrintWindow is HWND-scoped, but still revalidate ownership and the
            # exact process/window identity immediately before asking the target to paint.
            $captureBounds = Assert-SnapshotCaptureTarget $process $hwnd $ExpectedStartTimeTicks $bounds
            $hdc = $graphics.GetHdc()
            try {
                $captured = [OCUWin32]::PrintWindow([IntPtr]$hwnd, $hdc, 0)
            } finally {
                $graphics.ReleaseHdc($hdc)
            }
            # GPU-composited windows (Chrome/Electron) often paint blank pixels
            # with flags=0. Retry once with PW_RENDERFULLCONTENT (2) on the same
            # bitmap before failing closed. The retry is still HWND-scoped, so
            # the ownership/identity guards above are unchanged.
            if (-not (Test-BitmapHasVisiblePixels $bitmap)) {
                $captureBounds = Assert-SnapshotCaptureTarget $process $hwnd $ExpectedStartTimeTicks $bounds
                $graphics.Clear([System.Drawing.Color]::Black)
                $hdc = $graphics.GetHdc()
                try {
                    $captured = [OCUWin32]::PrintWindow([IntPtr]$hwnd, $hdc, 2)
                } finally {
                    $graphics.ReleaseHdc($hdc)
                }
            }
        }
        # A desktop rectangle is not an HWND-owned image. Never substitute it for a
        # background window when PrintWindow fails or returns blank pixels.
        if (-not $captured -or -not (Test-BitmapHasVisiblePixels $bitmap)) {
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
        if ($PSItem.Exception.Message -eq "Target changed; call get_app_state again.") {
            throw
        }
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
    try { return (Resolve-InteractiveWindowTarget $process).hwnd } catch { return [IntPtr]::Zero }
}

function Assert-SnapshotCaptureTarget($process, [IntPtr]$expectedHwnd, [int64]$expectedStartTimeTicks, $expectedBounds) {
    if ($null -eq $process -or $expectedHwnd -eq [IntPtr]::Zero -or $expectedStartTimeTicks -le 0) {
        Throw-TargetChanged
    }
    try {
        if ((Get-ProcessStartTimeTicks $process) -ne $expectedStartTimeTicks) { Throw-TargetChanged }
        $target = Resolve-InteractiveWindowTarget $process
        if ($target.hwnd -ne $expectedHwnd -or $null -eq $target.bounds) { Throw-TargetChanged }
        Assert-ValidFrame $target.bounds "Target changed; call get_app_state again." $true
        if ($null -ne $expectedBounds) {
            Assert-ValidFrame $expectedBounds "Target changed; call get_app_state again." $true
            if (-not (Test-FramesMatch $target.bounds $expectedBounds 1)) { Throw-TargetChanged }
        }
        return $target.bounds
    } catch {
        if ($PSItem.Exception.Message -eq "Target changed; call get_app_state again.") { throw }
        Throw-TargetChanged
    }
}

function Build-SnapshotForProcess($process, [string]$query, $TextLimit = $script:DefaultTextLimit, [int]$MaxTreeNodes = $script:AccessibilityTreeMaxNodeCount, [int]$MaxTreeDepth = $script:AccessibilityTreeMaxDepth, [bool]$IncludeImage = $false, [IntPtr]$ExpectedHwnd = [IntPtr]::Zero, [int64]$ExpectedStartTimeTicks = 0) {
    $target = Resolve-InteractiveWindowTarget $process
    $element = $target.element
    $targetHwnd = $target.hwnd
    $startTimeTicks = Get-ProcessStartTimeTicks $process
    if ($ExpectedHwnd -ne [IntPtr]::Zero -and $targetHwnd -ne $ExpectedHwnd) { Throw-TargetChanged }
    if ($ExpectedStartTimeTicks -gt 0 -and $startTimeTicks -ne $ExpectedStartTimeTicks) { Throw-TargetChanged }
    $bounds = $target.bounds
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
        screenshotPngBase64 = Capture-WindowPngBase64 $bounds $targetHwnd $IncludeImage $process $startTimeTicks
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

function Test-IntegerRuntimeIdValue($value) {
    if ($null -eq $value) {
        return $false
    }
    $isNumeric = $value -is [System.SByte] -or
        $value -is [System.Byte] -or
        $value -is [System.Int16] -or
        $value -is [System.UInt16] -or
        $value -is [System.Int32] -or
        $value -is [System.UInt32] -or
        $value -is [System.Int64] -or
        $value -is [System.UInt64] -or
        $value -is [System.Single] -or
        $value -is [System.Double] -or
        $value -is [System.Decimal]
    if (-not $isNumeric) {
        return $false
    }
    try {
        $number = [decimal]$value
        return $number -eq [decimal]::Truncate($number) -and
            $number -ge [decimal][int32]::MinValue -and
            $number -le [decimal][int32]::MaxValue
    } catch {
        return $false
    }
}

function Test-NonEmptyRuntimeId($runtimeId) {
    if ($null -eq $runtimeId) {
        return $false
    }
    $values = @($runtimeId)
    if ($values.Count -eq 0) {
        return $false
    }
    foreach ($value in $values) {
        if (-not (Test-IntegerRuntimeIdValue $value)) {
            return $false
        }
    }
    return $true
}

function Same-RuntimeId($left, $right) {
    if (-not (Test-NonEmptyRuntimeId $left) -or -not (Test-NonEmptyRuntimeId $right)) {
        return $false
    }
    $leftValues = @($left)
    $rightValues = @($right)
    if ($leftValues.Count -ne $rightValues.Count) {
        return $false
    }
    for ($i = 0; $i -lt $leftValues.Count; $i++) {
        if ([int64]$leftValues[$i] -ne [int64]$rightValues[$i]) {
            return $false
        }
    }
    return $true
}

function Get-AllElements($root, [int]$MaxElements = $script:MaxRuntimeElementSearchCount) {
    $items = New-Object System.Collections.Generic.List[object]
    if ($null -eq $root -or $MaxElements -le 0) {
        return @()
    }
    [void]$items.Add($root)
    if ($items.Count -ge $MaxElements) {
        return $items.ToArray()
    }
    try {
        $descendants = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $descendants.Count -and $items.Count -lt $MaxElements; $i++) {
            [void]$items.Add($descendants.Item($i))
        }
    } catch {
    }
    return $items.ToArray()
}

function Find-Element([IntPtr]$rootHwnd, $record) {
    if ($rootHwnd -eq [IntPtr]::Zero -or -not [OCUWin32]::IsWindow($rootHwnd) -or $null -eq $record -or -not (Test-NonEmptyRuntimeId $record.runtimeId)) {
        return $null
    }
    try {
        $root = [Windows.Automation.AutomationElement]::FromHandle($rootHwnd)
    } catch {
        return $null
    }
    if ($null -eq $root) {
        return $null
    }
    foreach ($element in (Get-AllElements $root)) {
        try {
            if (Same-RuntimeId @($element.GetRuntimeId()) @($record.runtimeId)) {
                return $element
            }
        } catch {
        }
    }
    return $null
}

function Resolve-SnapshotElement([IntPtr]$rootHwnd, $record) {
    if ($null -eq $record) {
        return $null
    }
    if (-not (Test-NonEmptyRuntimeId $record.runtimeId)) {
        Throw-TargetChanged
    }
    try {
        $element = Find-Element $rootHwnd $record
    } catch {
        Throw-TargetChanged
    }
    if ($null -eq $element) {
        Throw-TargetChanged
    }
    return $element
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
    throw "The requested secondary action is not supported by this element."
}

function Get-ScrollPercentTarget([double]$current, [double]$viewSize, [double]$pages, [int]$directionSign) {
    if (-not (Test-FiniteNumber $current) -or -not (Test-FiniteNumber $viewSize) -or -not (Test-FiniteNumber $pages)) {
        return $null
    }
    if ($current -lt 0 -or $current -gt 100 -or $viewSize -le 0 -or $viewSize -gt 100) {
        return $null
    }
    $target = $current + ($viewSize * $pages * $directionSign)
    if ($target -lt 0) {
        return 0.0
    }
    if ($target -gt 100) {
        return 100.0
    }
    return $target
}

function Invoke-Scroll($element, [string]$direction, [double]$pages) {
    $scroll = Get-CurrentPatternOrNull $element ([Windows.Automation.ScrollPattern]::Pattern)
    if ($null -eq $scroll) {
        return [pscustomobject]@{ handled = $false; attempted = $false }
    }

    $horizontal = [Windows.Automation.ScrollAmount]::NoAmount
    $vertical = [Windows.Automation.ScrollAmount]::NoAmount
    if ($direction -eq "up") { $vertical = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "down") { $vertical = [Windows.Automation.ScrollAmount]::LargeIncrement }
    elseif ($direction -eq "left") { $horizontal = [Windows.Automation.ScrollAmount]::LargeDecrement }
    elseif ($direction -eq "right") { $horizontal = [Windows.Automation.ScrollAmount]::LargeIncrement }

    $horizontalPercent = -1.0
    $verticalPercent = -1.0
    $horizontalViewSize = $null
    $verticalViewSize = $null
    try {
        $horizontalPercent = [double]$scroll.Current.HorizontalScrollPercent
        $verticalPercent = [double]$scroll.Current.VerticalScrollPercent
        $horizontalViewSize = [double]$scroll.Current.HorizontalViewSize
        $verticalViewSize = [double]$scroll.Current.VerticalViewSize
    } catch {
        return [pscustomobject]@{ handled = $false; attempted = $false }
    }

    $targetPercent = $null
    if ($direction -eq "up") {
        $targetPercent = Get-ScrollPercentTarget $verticalPercent $verticalViewSize $pages -1
    } elseif ($direction -eq "down") {
        $targetPercent = Get-ScrollPercentTarget $verticalPercent $verticalViewSize $pages 1
    } elseif ($direction -eq "left") {
        $targetPercent = Get-ScrollPercentTarget $horizontalPercent $horizontalViewSize $pages -1
    } elseif ($direction -eq "right") {
        $targetPercent = Get-ScrollPercentTarget $horizontalPercent $horizontalViewSize $pages 1
    }

    if ($null -ne $targetPercent) {
        try {
            if ($direction -eq "up" -or $direction -eq "down") {
                [void]$scroll.SetScrollPercent($horizontalPercent, $targetPercent)
            } else {
                [void]$scroll.SetScrollPercent($targetPercent, $verticalPercent)
            }
            return [pscustomobject]@{ handled = $true; attempted = $true }
        } catch {
            return [pscustomobject]@{ handled = $false; attempted = $true }
        }
    }

    if ($pages -eq 1) {
        try {
            [void]$scroll.Scroll($horizontal, $vertical)
            return [pscustomobject]@{ handled = $true; attempted = $true }
        } catch {
            return [pscustomobject]@{ handled = $false; attempted = $true }
        }
    }
    return [pscustomobject]@{ handled = $false; attempted = $false }
}

# type_text has no element record; the action-time focused element is its only implicit target.
# Keep this boundary separate from the snapshot element resolver used by set_value and other indexed actions.
$TypeTextTargetError = 'type_text requires a focused writable text control owned by the requested app/window; click/select the field first or use set_value with the complete generation-bound identifier in element_index.'
$TypeTextFallbackError = 'The focused text control has no usable native edit handle; UIA ValuePattern text fallback is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 or use set_value with the complete generation-bound identifier in element_index.'
$TypeTextDeliveryError = 'type_text could not write to the focused text control; click/select the field again or use set_value with the complete generation-bound identifier in element_index.'

# UIA proxy equality can hide provider replacement; compare only validated runtime IDs and fail closed when IDs are unavailable.
function Test-SameAutomationElement($left, $right) {
    if ($null -eq $left -or $null -eq $right) {
        return $false
    }
    try {
        $leftRuntimeId = @($left.GetRuntimeId())
        $rightRuntimeId = @($right.GetRuntimeId())
        return (Same-RuntimeId $leftRuntimeId $rightRuntimeId)
    } catch {
        return $false
    }
}

function Test-AutomationElementDescendantOf($root, $candidate) {
    if ($null -eq $root -or $null -eq $candidate) {
        return $false
    }
    if (Test-SameAutomationElement $root $candidate) {
        return $true
    }

    $walkers = @()
    try {
        $walkers += [Windows.Automation.TreeWalker]::ControlViewWalker
    } catch {
    }
    try {
        $walkers += [Windows.Automation.TreeWalker]::RawViewWalker
    } catch {
    }

    foreach ($walker in $walkers) {
        if ($null -eq $walker) {
            continue
        }
        $current = $candidate
        for ($depth = 0; $depth -lt 128; $depth++) {
            try {
                $parent = $walker.GetParent($current)
            } catch {
                break
            }
            if ($null -eq $parent) {
                break
            }
            if (Test-SameAutomationElement $root $parent) {
                return $true
            }
            $current = $parent
        }
    }
    return $false
}

function Test-TextEntryControlType($element) {
    $controlType = Get-ElementControlTypeName $element
    return $controlType -eq 'ControlType.Edit' -or $controlType -eq 'ControlType.Document'
}

function Test-FocusedTextElement($process, [IntPtr]$rootHwnd, $rootElement, $element) {
    if ($null -eq $element) {
        return $false
    }
    try {
        if ([int]$element.Current.ProcessId -ne [int]$process.Id) {
            return $false
        }
        if (-not $element.Current.IsEnabled) {
            return $false
        }
        if (-not (Test-TextEntryControlType $element)) {
            return $false
        }

        $nativeHwnd = Get-NativeWindowHandle $element
        if ($nativeHwnd -ne [IntPtr]::Zero) {
            if (-not (Test-HwndOwnedByProcess $nativeHwnd $process)) {
                return $false
            }
            if (-not (Test-HwndDescendantOf $rootHwnd $nativeHwnd)) {
                return $false
            }
        } elseif ($null -eq $rootElement -or -not (Test-AutomationElementDescendantOf $rootElement $element)) {
            return $false
        }

        $valuePattern = Get-CurrentPatternOrNull $element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Get-ValidatedFocusedTextTarget($process, [IntPtr]$rootHwnd) {
    $rootElement = $null
    try {
        if ($rootHwnd -ne [IntPtr]::Zero) {
            $rootElement = [Windows.Automation.AutomationElement]::FromHandle($rootHwnd)
        }
    } catch {
        $rootElement = $null
    }

    $focused = $null
    try {
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
    } catch {
        $focused = $null
    }
    if (-not (Test-FocusedTextElement $process $rootHwnd $rootElement $focused)) {
        throw $TypeTextTargetError
    }

    $rechecked = $null
    try {
        $rechecked = [Windows.Automation.AutomationElement]::FocusedElement
    } catch {
        $rechecked = $null
    }
    if ($null -eq $rechecked -or -not (Test-SameAutomationElement $focused $rechecked) -or -not (Test-FocusedTextElement $process $rootHwnd $rootElement $rechecked)) {
        throw $TypeTextTargetError
    }

    return [pscustomobject]@{
        element = $rechecked
        nativeWindowHandle = Get-NativeWindowHandle $rechecked
    }
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

function Assert-FocusedTextTarget($process, [IntPtr]$rootHwnd, $expectedElement, [IntPtr]$expectedHwnd) {
    $target = Get-ValidatedFocusedTextTarget $process $rootHwnd
    if ($null -ne $expectedElement -and -not (Test-SameAutomationElement $target.element $expectedElement)) {
        throw $TypeTextTargetError
    }
    if ($expectedHwnd -ne [IntPtr]::Zero -and $target.nativeWindowHandle -ne $expectedHwnd) {
        throw $TypeTextTargetError
    }
    return $target
}

function Invoke-FocusedValuePatternText($process, [IntPtr]$rootHwnd, [string]$text, $expectedElement) {
    $target = Assert-FocusedTextTarget $process $rootHwnd $expectedElement ([IntPtr]::Zero)
    if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK")) {
        throw $TypeTextFallbackError
    }

    try {
        [void](Assert-FocusedTextTarget $process $rootHwnd $target.element ([IntPtr]::Zero))
        $valuePattern = Get-CurrentPatternOrNull $target.element ([Windows.Automation.ValuePattern]::Pattern)
        if ($null -eq $valuePattern -or $valuePattern.Current.IsReadOnly) {
            throw $TypeTextTargetError
        }
        $current = ""
        try {
            $current = [string]$valuePattern.Current.Value
        } catch {
            throw $TypeTextDeliveryError
        }
        $valuePattern.SetValue($current + $text)
    } catch {
        if ($PSItem.Exception.Message -eq $TypeTextTargetError) {
            throw $TypeTextTargetError
        }
        throw $TypeTextDeliveryError
    }
    return $true
}

function Invoke-TypeText($process, [IntPtr]$rootHwnd, [string]$text) {
    $target = Get-ValidatedFocusedTextTarget $process $rootHwnd
    if ($target.nativeWindowHandle -ne [IntPtr]::Zero) {
        $nativeResult = Send-TextToEditHandle $process $target.nativeWindowHandle $text $target.element $rootHwnd
        if ($nativeResult.succeeded) {
            return $true
        }
        if ($nativeResult.attempted) {
        }
    }
    return Invoke-FocusedValuePatternText $process $rootHwnd $text $target.element
}

function Get-BoundedRuntimeError($exception) {
    $message = ""
    try {
        $message = [string]$exception.Exception.Message
    } catch {
        $message = ""
    }
    if ([string]::IsNullOrWhiteSpace($message) -or $message.Length -gt 512 -or $message.Contains("`r") -or $message.Contains("`n")) {
        return "Windows runtime operation failed."
    }

    $known = @(
        "No usable top-level interactive window is available for the requested app.",
        "Target changed; call get_app_state again.",
        "Click requires an element with a valid frame or explicit finite x/y coordinates.",
        "Scroll requires an element with a valid frame when ScrollPattern is unavailable.",
        "type_text requires a focused writable text control owned by the requested app/window; click/select the field first or use set_value with the complete generation-bound identifier in element_index.",
        "The focused text control has no usable native edit handle; UIA ValuePattern text fallback is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 or use set_value with the complete generation-bound identifier in element_index.",
        "type_text could not write to the focused text control; click/select the field again or use set_value with the complete generation-bound identifier in element_index.",
        "Interactive Windows input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 to enable it.",
        "Global pointer input is disabled by default; set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 to enable it.",
        "Interactive Windows keyboard input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 and focus the target before sending a key.",
        "SetFocus is disabled by default to avoid stealing user focus; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to enable it.",
        "The requested app no longer owns a valid top-level window.",
        "The requested app is not the topmost descendant of the snapshot window at the requested pointer coordinates; interactive input was not sent.",
        "Interactive drag requires at least one movement step.",
        "The requested app is not foreground; focus it with an authorized global click or set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOCUS_ACTIONS=1 to permit a bounded foreground attempt.",
        "Windows rejected the bounded foreground request for interactive keyboard input; first focus the target with an authorized global click or use a non-elevated target.",
        "Windows could not foreground the requested app for interactive keyboard input; first focus it with an authorized global click or use a non-elevated target.",
        "Windows could not convert the requested app-scoped coordinates.",
        "Windows did not report a usable virtual desktop for global pointer input.",
        "Global pointer coordinates are outside the virtual desktop.",
        "Windows could not queue the requested native button click message.",
        "Windows could not queue the requested mouse move message.",
        "Windows could not queue the requested mouse-down message.",
        "Windows could not queue the requested mouse-up message.",
        "Windows could not queue the requested background drag move message.",
        "Windows could not queue the requested background drag mouse-down message.",
        "Windows could not queue the requested background drag mouse-up message.",
        "Windows could not queue the requested app-scoped scroll message.",
        "Windows semantic scroll operation failed; refresh with get_app_state before retrying because the operation may have been applied.",
        "click_method 'app_post' requires a native HWND target for this WPF element; use click_method 'global' with the explicit interactive-input configuration.",
        "click_method 'app_post' cannot target WPF coordinate input without a native child HWND; use click_method 'global' with the explicit interactive-input configuration.",
        "Windows could not convert the requested app-post coordinates.",
        "click_method 'accessibility' requires element_index",
        "click_method 'accessibility' could not click the requested element",
        "click_method 'sky_click' is not supported on Windows",
        "Cannot set a value for an element that is not settable",
        "Windows runtime did not return an app snapshot.",
        "Windows runtime did not return a stable app snapshot.",
        "Windows runtime did not return screenshot image data.",
        "Unable to read operation input.",
        "Invalid operation JSON.",
        "Operation JSON must be an object.",
        "Operation JSON requires a non-empty tool.",
        "click_count must be an integer between 1 and 100.",
        "pages must be finite and in (0,100].",
        "Click coordinates x and y must be provided together.",
        "Invalid scroll direction."
    )
    if ($known -contains $message) {
        return $message
    }

    if ($message -like "Windows accepted * interactive input records*") {
        return "Windows interactive input was rejected or partially accepted; no retry was attempted."
    }
    if ($message -like "Unsupported mouse button:*") {
        return "Unsupported mouse button."
    }
    if ($message -like "Unsupported key:*") {
        return "Unsupported key."
    }
    if ($message -like "Unsupported modifier:*") {
        return "Unsupported keyboard modifier."
    }
    if ($message -like "appNotFound(*)") {
        return "The requested app was not found."
    }
    if ($message -like "No top-level UI Automation window is available*") {
        return "No top-level UI Automation window is available for the requested app."
    }
    if ($message -like "click_method 'accessibility' does not support mouse_button *") {
        return "Accessibility click does not support the requested mouse button."
    }
    if ($message -like "Invalid click_method *" -or $message -eq "Invalid click_method value.") {
        return "Invalid click method."
    }
    if ($message -like "unsupportedTool(*)") {
        return "Unsupported Windows runtime tool."
    }
    if ($message -like "* must be a finite coordinate." -or $message -like "* must be within the supported coordinate range.") {
        return "Invalid coordinate."
    }
    if ($message -like "Missing required argument: from_*") {
        return "Missing required drag coordinate."
    }
    return "Windows runtime operation failed."
}

# Get-Content defaults to the system ANSI code page (e.g. GBK on Chinese
# systems) for files without a BOM, which corrupts non-ASCII input such as
# Chinese text passed to set_value/type_text.
try {
    try {
        $operationJson = [System.IO.File]::ReadAllText($OperationPath, [System.Text.Encoding]::UTF8)
    } catch {
        throw "Unable to read operation input."
    }
    try {
        $operation = $operationJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Invalid operation JSON."
    }
    if ($null -eq $operation -or $operation -is [System.Array]) {
        throw "Operation JSON must be an object."
    }
    Assert-OperationNumericValues $operation

    if ($operation.tool -eq "list_apps") {
        $response = [pscustomobject]@{ ok = $true; text = (List-Apps) }
    } elseif ($operation.tool -eq "get_app_state") {
        $identity = Get-SnapshotIdentity $operation $false
        if ($null -ne $identity) {
            $target = Resolve-SnapshotActionTarget $operation
            $response = [pscustomobject]@{ ok = $true; snapshot = (Build-SnapshotForProcess $target.process $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) ([bool]$operation.include_image) ([IntPtr]$target.hwnd) ([int64]$identity.startTimeTicks)) }
        } else {
            $response = [pscustomobject]@{ ok = $true; snapshot = (Build-Snapshot $operation.app (Resolve-TextLimit $operation.text_limit) ([int]$operation.max_tree_nodes) ([int]$operation.max_tree_depth) ([bool]$operation.include_image)) }
        }
    } else {
        $target = Resolve-SnapshotActionTarget $operation
        $process = $target.process
        $hwnd = $target.hwnd
        $windowBounds = $operation.windowBounds
        $element = $null
        if ($null -ne $operation.element) {
            $element = Resolve-SnapshotElement $hwnd $operation.element
        }

        switch ($operation.tool) {
            "click" {
                $clickMethod = Get-OperationClickMethod $operation
                $mouseButton = Get-OperationMouseButton $operation
                $clickCount = Get-OperationClickCount $operation

                if ($clickMethod -eq "accessibility") {
                    if ($null -eq $element) { throw "click_method 'accessibility' requires element_index" }
                    if ($mouseButton -eq "right" -or $mouseButton -eq "middle") {
                        throw ("click_method 'accessibility' does not support mouse_button '" + $mouseButton + "'")
                    }
                    if (-not (Invoke-PreferredClick $element)) {
                        throw "click_method 'accessibility' could not click the requested element"
                    }
                } elseif ($clickMethod -eq "app_post") {
                    Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                    $point = Get-ValidatedClickPoint $operation.element $operation $windowBounds
                    $targetHwnd = Resolve-AppPostTargetHandle $process $hwnd $element $point.x $point.y
                    if ($mouseButton -eq "left" -and (Test-NativeButtonElement $element)) {
                        Send-NativeButtonClick $process $targetHwnd ($clickCount)
                    } else {
                        Send-MouseClick $process $targetHwnd $point.x $point.y $mouseButton ($clickCount)
                    }
                } elseif ($clickMethod -eq "global") {
                    Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                    $point = Get-ValidatedClickPoint $operation.element $operation $windowBounds
                    Send-InteractiveMouseClick $process $hwnd $point.x $point.y $mouseButton ($clickCount)
                } elseif ($clickMethod -eq "sky_click") {
                    throw "click_method 'sky_click' is not supported on Windows"
                } elseif ($clickMethod -eq "auto") {
                    $handled = $false
                    if ($null -ne $element -and $mouseButton -ne "right" -and $mouseButton -ne "middle") {
                        $handled = Invoke-PreferredClick $element
                    }
                    if (-not $handled) {
                        Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                        $point = Get-ValidatedClickPoint $operation.element $operation $windowBounds
                        Send-MouseClick $process $hwnd $point.x $point.y $mouseButton ($clickCount)
                    }
                } else {
                    throw "Invalid click_method '$clickMethod'"
                }
            }
            "perform_secondary_action" {
                if ($null -eq $element) { Throw-TargetChanged }
                Invoke-SecondaryAction $element $operation.action
            }
            "scroll" {
                $handled = $false
                $direction = Get-OperationDirection $operation
                $pages = Get-OperationPages $operation
                if ($null -ne $element) {
                    $semanticResult = Invoke-Scroll $element $direction $pages
                    $handled = $semanticResult.handled
                    if (-not $handled -and $semanticResult.attempted) {
                        throw "Windows semantic scroll operation failed; refresh with get_app_state before retrying because the operation may have been applied."
                    }
                }
                if (-not $handled) {
                    Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                    $point = Get-ValidatedScrollFallbackPoint $operation.element $windowBounds
                    Send-Scroll $process $hwnd $point.x $point.y $direction $pages
                }
            }
            "drag" {
                Assert-SnapshotCoordinateBounds $hwnd $windowBounds
                $fromX = ConvertTo-SafePixelCoordinate ([double]$windowBounds.x + [double]$operation.from_x)
                $fromY = ConvertTo-SafePixelCoordinate ([double]$windowBounds.y + [double]$operation.from_y)
                $toX = ConvertTo-SafePixelCoordinate ([double]$windowBounds.x + [double]$operation.to_x)
                $toY = ConvertTo-SafePixelCoordinate ([double]$windowBounds.y + [double]$operation.to_y)
                if ($null -eq $fromX -or $null -eq $fromY -or $null -eq $toX -or $null -eq $toY) {
                    Throw-TargetChanged
                }
                if (Test-InteractivePointerInputEnabled) {
                    Send-InteractiveDrag $process $hwnd $fromX $fromY $toX $toY
                } else {
                    Send-BackgroundDrag $process $hwnd $fromX $fromY $toX $toY
                }
            }
            "type_text" {
                [void](Invoke-TypeText $process $hwnd $operation.text)
            }
            "press_key" {
                if (-not (Test-EnvFlagEnabled "OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT")) {
                    throw "Interactive Windows keyboard input is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 and focus the target before sending a key."
                }
                Send-InteractiveKey $process $hwnd $operation.key
            }
            "set_value" {
                if ($null -eq $element) { Throw-TargetChanged }
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
        $response = [pscustomobject]@{ ok = $true; snapshot = (Build-SnapshotForProcess $process $operation.app $null $AccessibilityTreeMaxNodeCount $AccessibilityTreeMaxDepth $true $hwnd ([int64]$operation.expectedProcessStartTimeTicks)) }
    }
} catch {
    $message = Get-BoundedRuntimeError $PSItem
    $response = [pscustomobject]@{ ok = $false; error = $message }
}

try {
    $response | ConvertTo-Json -Depth 50 -Compress
} catch {
    [Console]::WriteLine('{"ok":false,"error":"Windows runtime operation failed."}')
}
