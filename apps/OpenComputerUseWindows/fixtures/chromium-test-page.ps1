param(
    [string]$InstanceName = 'Chrome',
    [string]$ReadyPath = '',
    [string]$StatePath = '',
    [int]$Left = 40,
    [int]$Top = 40,
    [int]$Width = 900,
    [int]$Height = 680,
    [int]$Port = 0,
    [string]$BrowserPath = '',
    [int]$ReadyTimeoutSeconds = 45,
    [switch]$RendererAccessibility,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

# A Chromium/Electron content area is rendered by the browser's own compositor and
# exposes no actionable UIA nodes, so this fixture proves the runtime's Chromium
# branches against real browser input routing instead of against a WPF mock. The
# page reports its own geometry (CSS px + devicePixelRatio + screen origin) so that
# coordinate assertions can be derived from measurements rather than from a
# hard-coded DPI factor.
$script:InstanceName = $InstanceName
$script:ReadyPath = $ReadyPath
$script:StatePath = $StatePath
$script:KeepArtifacts = [bool]$KeepArtifacts
$script:browserPath = ''
$script:profileDir = ''
$script:launchedPid = 0
$script:browserPid = 0
$script:hwnd = [int64]0
$script:windowTitle = ''
$script:bounds = $null
$script:clientOrigin = $null
$script:clientSize = $null
$script:ready = $false
$script:url = ''
$script:devicePixelRatio = $null
$script:geometry = $null
$script:geometrySeq = 0
$script:eventCount = 0
$script:clicks = 0
$script:documentClicks = 0
$script:mouseDowns = 0
$script:focusEvents = 0
$script:inputEvents = 0
$script:keyEvents = 0
$script:lastKey = ''
$script:textDraft = ''
$script:clickSamples = New-Object System.Collections.Generic.List[object]
$script:documentClickSamples = New-Object System.Collections.Generic.List[object]
$script:events = New-Object System.Collections.Generic.List[object]
$script:listener = $null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace OcuChromiumFixture
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int X; public int Y; }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int command);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

        public static int[] TryGetClientInfo(IntPtr hWnd)
        {
            RECT rect;
            if (!GetClientRect(hWnd, out rect)) { return null; }
            POINT origin = new POINT();
            origin.X = 0;
            origin.Y = 0;
            if (!ClientToScreen(hWnd, ref origin)) { return null; }
            return new int[] { origin.X, origin.Y, rect.Right - rect.Left, rect.Bottom - rect.Top };
        }

        public static int[] TryGetWindowRect(IntPtr hWnd)
        {
            RECT rect;
            if (!GetWindowRect(hWnd, out rect)) { return null; }
            return new int[] { rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top };
        }
    }
}
'@

function Resolve-FixtureBrowser([string]$explicit) {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        [void]$candidates.Add($explicit)
    }
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        [void]$candidates.Add((Join-Path $programFiles 'Google\Chrome\Application\chrome.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        [void]$candidates.Add((Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe'))
        [void]$candidates.Add((Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        [void]$candidates.Add((Join-Path $programFiles 'Microsoft\Edge\Application\msedge.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'No Chromium-family browser found; pass -BrowserPath <chrome.exe|msedge.exe>.'
}

function Get-FreeLoopbackPort {
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    $probe.Stop()
    return $port
}

function Write-FixtureJson([string]$path, $value) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = $path + '.' + $PID + '.tmp'
    $json = $value | ConvertTo-Json -Depth 24 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporary, $json, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Get-FixtureBounds {
    if ($script:hwnd -eq 0) {
        return $null
    }
    $rect = [OcuChromiumFixture.Native]::TryGetWindowRect([IntPtr]$script:hwnd)
    if ($null -eq $rect) {
        return $null
    }
    return [pscustomobject]@{ x = [double]$rect[0]; y = [double]$rect[1]; width = [double]$rect[2]; height = [double]$rect[3] }
}

function Get-FixtureClientInfo {
    if ($script:hwnd -eq 0) {
        return $null
    }
    $values = [OcuChromiumFixture.Native]::TryGetClientInfo([IntPtr]$script:hwnd)
    if ($null -eq $values) {
        return $null
    }
    return [pscustomobject]@{ x = [int]$values[0]; y = [int]$values[1]; width = [int]$values[2]; height = [int]$values[3] }
}

function Get-FixtureState {
    return [pscustomobject]@{
        instance = $script:InstanceName
        ready = $script:ready
        title = $script:windowTitle
        pid = $script:browserPid
        hwnd = $script:hwnd
        bounds = $script:bounds
        clientOrigin = $script:clientOrigin
        clientSize = $script:clientSize
        url = $script:url
        devicePixelRatio = $script:devicePixelRatio
        geometry = $script:geometry
        geometrySeq = $script:geometrySeq
        events = @($script:events.ToArray())
        eventCount = $script:eventCount
        clicks = $script:clicks
        clickSamples = @($script:clickSamples.ToArray())
        documentClicks = $script:documentClicks
        documentClickSamples = @($script:documentClickSamples.ToArray())
        mouseDowns = $script:mouseDowns
        focusEvents = $script:focusEvents
        inputEvents = $script:inputEvents
        keyEvents = $script:keyEvents
        lastKey = $script:lastKey
        textDraft = $script:textDraft
        fixturePid = $PID
        launchedPid = $script:launchedPid
        browserPath = $script:browserPath
        profileDir = $script:profileDir
    }
}

function Write-FixtureState {
    Write-FixtureJson $script:StatePath (Get-FixtureState)
}

function Update-FixtureWindowInfo {
    if ($script:browserPid -le 0) {
        return
    }
    try {
        $process = Get-Process -Id $script:browserPid -ErrorAction Stop
    } catch {
        return
    }
    $title = [string]$process.MainWindowTitle
    # Chrome applies the document title asynchronously; only a title carrying the
    # instance tag is authoritative, so a placeholder title is never published as
    # the app selector the runner resolves against.
    if (-not [string]::IsNullOrWhiteSpace($title) -and $title.Contains('[' + $script:InstanceName + ']')) {
        $script:windowTitle = $title
    }
    $bounds = Get-FixtureBounds
    if ($null -eq $bounds) {
        return
    }
    $clientInfo = Get-FixtureClientInfo
    $boundsChanged = ($null -eq $script:bounds) -or $script:bounds.x -ne $bounds.x -or $script:bounds.y -ne $bounds.y -or $script:bounds.width -ne $bounds.width -or $script:bounds.height -ne $bounds.height
    $clientChanged = ($null -eq $clientInfo) -or ($null -eq $script:clientOrigin) -or $script:clientOrigin.x -ne $clientInfo.x -or $script:clientOrigin.y -ne $clientInfo.y -or $script:clientSize.width -ne $clientInfo.width -or $script:clientSize.height -ne $clientInfo.height
    if (-not $boundsChanged -and -not $clientChanged) {
        return
    }
    $script:bounds = $bounds
    if ($null -ne $clientInfo) {
        $script:clientOrigin = [pscustomobject]@{ x = $clientInfo.x; y = $clientInfo.y }
        $script:clientSize = [pscustomobject]@{ width = $clientInfo.width; height = $clientInfo.height }
    }
    Write-FixtureState
}

function Add-FixtureEvent([string]$body) {
    $event = $null
    try {
        $event = $body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return
    }
    if ($null -eq $event -or $event -is [System.Array]) {
        return
    }
    $script:eventCount += 1
    if ($script:events.Count -ge 200) {
        $script:events.RemoveAt(0)
    }
    [void]$script:events.Add($event)
    switch ([string]$event.type) {
        'geometry' {
            $script:geometry = $event.geometry
            $script:devicePixelRatio = $event.geometry.devicePixelRatio
            $script:geometrySeq += 1
        }
        'click' {
            $script:clicks = [int]$event.counters.clicks
            if ($script:clickSamples.Count -ge 20) {
                $script:clickSamples.RemoveAt(0)
            }
            [void]$script:clickSamples.Add($event)
        }
        'documentclick' {
            $script:documentClicks += 1
            if ($script:documentClickSamples.Count -ge 20) {
                $script:documentClickSamples.RemoveAt(0)
            }
            [void]$script:documentClickSamples.Add($event)
        }
        'mousedown' {
            $script:mouseDowns += 1
        }
        'focus' {
            $script:focusEvents = [int]$event.counters.focusEvents
        }
        'input' {
            $script:inputEvents = [int]$event.counters.inputEvents
            $script:textDraft = [string]$event.value
        }
        'keydown' {
            $script:keyEvents = [int]$event.counters.keyEvents
            $script:lastKey = [string]$event.key
        }
    }
    Write-FixtureState
}

function Write-HttpResponse($context, [int]$status, [string]$contentType, [byte[]]$body) {
    $response = $context.Response
    $response.StatusCode = $status
    if ($null -eq $body) {
        $response.ContentLength64 = 0
    } else {
        $response.ContentType = $contentType
        $response.ContentLength64 = $body.Length
        $response.OutputStream.Write($body, 0, $body.Length)
    }
    $response.Close()
}

function Handle-FixtureRequest($context) {
    try {
        $request = $context.Request
        $path = $request.Url.AbsolutePath
        if ($request.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
            Write-HttpResponse $context 200 'text/html; charset=utf-8' $script:htmlBody
            return
        }
        if ($request.HttpMethod -eq 'POST' -and $path -eq '/event') {
            $reader = New-Object System.IO.StreamReader($request.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            Add-FixtureEvent $body
            Write-HttpResponse $context 200 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
            return
        }
        if ($request.HttpMethod -eq 'GET' -and $path -eq '/state') {
            $json = (Get-FixtureState | ConvertTo-Json -Depth 24 -Compress)
            Write-HttpResponse $context 200 'application/json; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes($json))
            return
        }
        Write-HttpResponse $context 404 'text/plain; charset=utf-8' ([System.Text.Encoding]::UTF8.GetBytes('not found'))
    } catch {
        try { $context.Response.Abort() } catch { }
    }
}

function Get-HtmlTemplate {
    return @'
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Open Computer Use Chromium Fixture [__INSTANCE__]</title>
<style>
  html, body { margin: 0; padding: 0; font-family: "Segoe UI", Arial, sans-serif; background: #f6f7f9; }
  #banner { padding: 8px 12px; background: #1f3f6b; color: #fff; font-size: 14px; }
  #click-target { position: fixed; left: 55%; top: 45%; width: 200px; height: 80px; background: #cfe3ff; border: 2px solid #2a5b9e; color: #10305c; font-size: 14px; text-align: center; line-height: 24px; cursor: default; }
  #text-input { position: fixed; left: 8%; top: 78%; width: 180px; height: 28px; font-size: 14px; }
  #status { position: fixed; left: 12px; top: 44px; font-size: 12px; color: #333; white-space: pre; }
</style>
</head>
<body>
<div id="banner">Open Computer Use Chromium Fixture [__INSTANCE__]</div>
<div id="click-target">click target<br><span id="click-count">clicks=0</span></div>
<input id="text-input" type="text" autocomplete="off" spellcheck="false" placeholder="text input">
<div id="status">waiting for events</div>
<script>
(function () {
  var counters = { clicks: 0, mouseDowns: 0, focusEvents: 0, inputEvents: 0, keyEvents: 0 };
  var lastSignature = '';
  var status = document.getElementById('status');
  var clickTarget = document.getElementById('click-target');
  var clickCount = document.getElementById('click-count');
  var textInput = document.getElementById('text-input');

  function post(payload) {
    try {
      payload.dpr = window.devicePixelRatio;
      payload.clientWidth = window.innerWidth;
      payload.clientHeight = window.innerHeight;
      payload.sequence = (payload.sequence || 0);
      fetch('/event', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
        keepalive: true
      }).catch(function () { });
    } catch (e) { }
  }

  function rectOf(element) {
    var rect = element.getBoundingClientRect();
    return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
  }

  function getGeometry() {
    return {
      devicePixelRatio: window.devicePixelRatio,
      screenX: window.screenX,
      screenY: window.screenY,
      screenLeft: window.screenLeft,
      screenTop: window.screenTop,
      outerWidth: window.outerWidth,
      outerHeight: window.outerHeight,
      innerWidth: window.innerWidth,
      innerHeight: window.innerHeight,
      screenWidth: window.screen.width,
      screenHeight: window.screen.height,
      availWidth: window.screen.availWidth,
      availHeight: window.screen.availHeight,
      clickTarget: rectOf(clickTarget),
      textInput: rectOf(textInput)
    };
  }

  function geometrySignature(geometry) {
    return [geometry.screenX, geometry.screenY, geometry.outerWidth, geometry.outerHeight,
      geometry.innerWidth, geometry.innerHeight, geometry.devicePixelRatio,
      geometry.clickTarget.x, geometry.clickTarget.y, geometry.clickTarget.width, geometry.clickTarget.height,
      geometry.textInput.x, geometry.textInput.y].join(',');
  }

  function reportGeometry(reason) {
    var geometry = getGeometry();
    lastSignature = geometrySignature(geometry);
    post({ type: 'geometry', reason: reason, geometry: geometry });
  }

  function reportGeometryIfChanged(reason) {
    var geometry = getGeometry();
    var signature = geometrySignature(geometry);
    if (signature === lastSignature) { return; }
    lastSignature = signature;
    post({ type: 'geometry', reason: reason, geometry: geometry });
  }

  clickTarget.addEventListener('click', function (event) {
    counters.clicks += 1;
    clickCount.textContent = 'clicks=' + counters.clicks;
    status.textContent = 'click clientX=' + event.clientX + ' clientY=' + event.clientY + ' dpr=' + window.devicePixelRatio;
    post({
      type: 'click', target: '#click-target', clientX: event.clientX, clientY: event.clientY,
      screenX: event.screenX, screenY: event.screenY, offsetX: event.offsetX, offsetY: event.offsetY,
      button: event.button, detail: event.detail, counters: { clicks: counters.clicks }
    });
  });

  clickTarget.addEventListener('mousedown', function (event) {
    counters.mouseDowns += 1;
    post({
      type: 'mousedown', target: '#click-target', clientX: event.clientX, clientY: event.clientY,
      screenX: event.screenX, screenY: event.screenY, counters: { mouseDowns: counters.mouseDowns }
    });
  });

  document.addEventListener('click', function (event) {
    post({
      type: 'documentclick', targetId: (event.target && event.target.id) || '',
      clientX: event.clientX, clientY: event.clientY, screenX: event.screenX, screenY: event.screenY,
      detail: event.detail
    });
  }, true);

  textInput.addEventListener('focus', function () {
    counters.focusEvents += 1;
    status.textContent = 'focus #text-input dpr=' + window.devicePixelRatio;
    post({ type: 'focus', target: '#text-input', counters: { focusEvents: counters.focusEvents } });
  });

  textInput.addEventListener('input', function () {
    counters.inputEvents += 1;
    post({ type: 'input', target: '#text-input', value: textInput.value, counters: { inputEvents: counters.inputEvents } });
  });

  document.addEventListener('keydown', function (event) {
    counters.keyEvents += 1;
    post({ type: 'keydown', key: event.key, counters: { keyEvents: counters.keyEvents } });
  });

  window.addEventListener('resize', function () { reportGeometryIfChanged('resize'); });
  window.addEventListener('load', function () { reportGeometry('load'); });
  setInterval(function () { reportGeometryIfChanged('heartbeat'); }, 400);
  reportGeometry('bootstrap');
})();
</script>
</body>
</html>
'@
}

function Find-FixtureBrowserWindow([datetime]$launchedAt) {
    $browserName = [System.IO.Path]::GetFileNameWithoutExtension($script:browserPath)
    $candidates = @(Get-Process -Name $browserName -ErrorAction SilentlyContinue)
    foreach ($candidate in $candidates) {
        try {
            if ([int64]$candidate.MainWindowHandle -eq 0) {
                continue
            }
            # Plain substring match: a wildcard pattern would treat the brackets as a
            # character class, so instance names would stop being unique. The cast is
            # kept off the method call because [string]$x.Contains(...) would stringify
            # the boolean and make -not always false.
            $candidateTitle = [string]$candidate.MainWindowTitle
            if (-not $candidateTitle.Contains('[' + $script:InstanceName + ']')) {
                continue
            }
            if ($candidate.StartTime -lt $launchedAt.AddSeconds(-5)) {
                continue
            }
        } catch {
            continue
        }
        $script:browserPid = [int]$candidate.Id
        $script:hwnd = [int64]$candidate.MainWindowHandle.ToInt64()
        $script:windowTitle = [string]$candidate.MainWindowTitle
        Set-FixtureWindowPlacement
        $script:bounds = Get-FixtureBounds
        $clientInfo = Get-FixtureClientInfo
        if ($null -ne $clientInfo) {
            $script:clientOrigin = [pscustomobject]@{ x = $clientInfo.x; y = $clientInfo.y }
            $script:clientSize = [pscustomobject]@{ width = $clientInfo.width; height = $clientInfo.height }
        }
        $script:ready = $true
        $state = Get-FixtureState
        Write-FixtureJson $script:StatePath $state
        Write-FixtureJson $script:ReadyPath $state
        return $true
    }
    return $false
}

function Set-FixtureWindowPlacement {
    # The browser may create its first window minimized or offscreen when the
    # fixture host was itself started without a visible window. Placement is
    # applied here in physical pixels so the runner can compute click points
    # against a rect it already knows; SW_SHOWNOACTIVATE / SWP_NOACTIVATE keep
    # this fixture from stealing the operator's foreground and it never calls
    # SetForegroundWindow.
    if ($script:hwnd -eq 0) {
        return
    }
    $target = [IntPtr]$script:hwnd
    if ([OcuChromiumFixture.Native]::IsIconic($target)) {
        [void][OcuChromiumFixture.Native]::ShowWindow($target, 4)
        Start-Sleep -Milliseconds 120
    }
    [void][OcuChromiumFixture.Native]::SetWindowPos($target, [IntPtr]::Zero, $Left, $Top, $Width, $Height, 0x0010 -bor 0x0004)
    Start-Sleep -Milliseconds 150
}

function Stop-FixtureBrowserProcess([int]$processId) {
    if ($processId -le 0) {
        return
    }
    $process = $null
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
    } catch {
        return
    }
    try {
        # Only ever stop a browser we resolved from the requested browser path.
        if (-not [string]::Equals([string]$process.Path, $script:browserPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    } catch {
        return
    }
    try {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    } catch {
    }
}

$listener = $null
try {
    $script:browserPath = Resolve-FixtureBrowser $BrowserPath
    $port = $Port
    if ($port -le 0) {
        $port = Get-FreeLoopbackPort
    }
    $server = [System.Net.HttpListener]::new()
    $server.Prefixes.Add('http://127.0.0.1:' + $port + '/')
    $server.Start()
    $listener = $server
    $script:url = 'http://127.0.0.1:' + $port + '/'
    $html = (Get-HtmlTemplate) -replace '__INSTANCE__', ($script:InstanceName -replace '[&<>]', '')
    $script:htmlBody = (New-Object System.Text.UTF8Encoding($false)).GetBytes($html)

    $script:profileDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ocu-chromium-profile-' + $PID)
    New-Item -ItemType Directory -Path $script:profileDir -Force | Out-Null
    $launchedAt = [datetime]::Now
    $browserArguments = @(
        ('--app=' + $script:url),
        ('--user-data-dir=' + $script:profileDir),
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-sync',
        ('--window-position=' + $Left + ',' + $Top),
        ('--window-size=' + $Width + ',' + $Height)
    )
    if ($RendererAccessibility) {
        # Diagnostic only: Chromium normally keeps renderer accessibility off, so
        # the rendered page contributes no nodes to the UIA tree. Forcing it on
        # makes the page's own controls appear, which is how the fixture's
        # "content area is opaque to element-targeted actions" claim is falsified.
        $browserArguments += '--force-renderer-accessibility'
    }
    $browser = Start-Process -FilePath $script:browserPath -ArgumentList $browserArguments -PassThru
    if ($null -eq $browser) {
        throw 'The Chromium-family browser could not be started.'
    }
    $script:launchedPid = [int]$browser.Id

    $deadline = [datetime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    $pending = $null
    while ([datetime]::UtcNow -lt $deadline -and -not $script:ready) {
        if ($null -eq $pending) {
            $pending = $listener.GetContextAsync()
        }
        if ($pending.Wait(100)) {
            $context = $pending.Result
            $pending = $null
            Handle-FixtureRequest $context
        }
        [void](Find-FixtureBrowserWindow $launchedAt)
    }
    if (-not $script:ready) {
        throw ('The Chromium fixture window did not become ready within ' + $ReadyTimeoutSeconds + ' seconds.')
    }

    while ($true) {
        if ($null -eq $pending) {
            $pending = $listener.GetContextAsync()
        }
        if ($pending.Wait(100)) {
            $context = $pending.Result
            $pending = $null
            Handle-FixtureRequest $context
        }
        Update-FixtureWindowInfo
        try {
            if ($browser.HasExited) {
                break
            }
        } catch {
            break
        }
    }
} finally {
    try {
        if ($null -ne $listener) {
            $listener.Stop()
            $listener.Close()
        }
    } catch {
    }
    Stop-FixtureBrowserProcess $script:browserPid
    Stop-FixtureBrowserProcess $script:launchedPid
    if (-not $script:KeepArtifacts) {
        $profile = $script:profileDir
        if (-not [string]::IsNullOrWhiteSpace($profile)) {
            for ($attempt = 0; $attempt -lt 5; $attempt++) {
                try {
                    Remove-Item -LiteralPath $profile -Recurse -Force -ErrorAction Stop
                    break
                } catch {
                    Start-Sleep -Milliseconds 200
                }
            }
        }
    }
}
