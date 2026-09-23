param(
    [switch]$KeepArtifacts,
    [string]$FixtureHostPath = 'pwsh.exe',
    [string]$RuntimeHostPath = 'powershell.exe',
    [string]$NativeFixtureHostPath = 'pwsh.exe',
    [switch]$IncludeChromium,
    [string]$ChromiumBrowserPath = '',
    [switch]$ChromiumRendererAccessibility
)

$ErrorActionPreference = 'Stop'
$fixtureRoot = $PSScriptRoot
$runtimePath = Join-Path (Split-Path -Parent $fixtureRoot) 'runtime.ps1'
$runRoot = Join-Path $env:TEMP ('ocu-windows-smoke-' + $PID)
$fixtures = New-Object System.Collections.Generic.List[object]
$operationNumber = 0
$runtimeTimeoutMilliseconds = 30000
$runtimeOutputLimit = 1048576
$focusedSuccessText = -join ([char[]]@(0x7126, 0x70B9, 0x6210, 0x529F, 0x2705))
$duplicateSuccessText = -join ([char[]]@(0x91CD, 0x590D, 0x6210, 0x529F, 0x2705))
$nativeSuccessText = -join ([char[]]@(0x539F, 0x751F, 0x6210, 0x529F, 0x2705))

function Resolve-HostExecutable([string]$candidate) {
    try {
        $command = Get-Command -Name $candidate -CommandType Application -ErrorAction Stop
        if ($null -ne $command.Source -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
        return [string]$command.Path
    } catch {
        throw 'Required PowerShell host executable was not found.'
    }
}

function ConvertTo-WindowsProcessArgument([string]$value) {
    if ($value -notmatch '[\s"]') {
        return $value
    }
    $escaped = $value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Set-ProcessArguments($startInfo, [string[]]$arguments) {
    $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
        return
    }
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-WindowsProcessArgument ([string]$_) }) -join ' ')
}

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) {
        throw $message
    }
}

function Test-TargetChangedResponse($response) {
    return ($null -ne $response -and -not $response.ok -and $response.error -eq 'Target changed; call get_app_state again.')
}

function Assert-TargetChangedResponse($response, [string]$message) {
    Assert-Condition (Test-TargetChangedResponse $response) $message
}

function Test-MissingClickFrameResponse($response) {
    return ($null -ne $response -and -not $response.ok -and $response.error -eq 'Click requires an element with a valid frame or explicit finite x/y coordinates.')
}

function Test-TypeTextTargetResponse($response) {
    return ($null -ne $response -and -not $response.ok -and $response.error -eq 'type_text requires a focused writable text control owned by the requested app/window; click/select the field first or use set_value with the complete generation-bound identifier in element_index. When the target exposes no such control (a Chromium/Electron content area has no actionable nodes), focus the field and use press_key, which needs OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT=1 and a target that already owns the foreground.')
}

function Test-TypeTextFallbackResponse($response) {
    return ($null -ne $response -and -not $response.ok -and $response.error -eq 'The focused text control has no usable native edit handle; UIA ValuePattern text fallback is disabled by default; set OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK=1 or use set_value with the complete generation-bound identifier in element_index.')
}

function Test-BoundedPngResponse($response) {
    if ($null -eq $response -or -not $response.ok) {
        return $false
    }
    $payload = [string]$response.snapshot.screenshotPngBase64
    if ([string]::IsNullOrWhiteSpace($payload)) {
        # Omission is the safe result when target ownership cannot be proven.
        return $true
    }
    try {
        $bytes = [Convert]::FromBase64String($payload)
        return ($bytes.Length -ge 8 -and $bytes[0] -eq 137 -and $bytes[1] -eq 80 -and $bytes[2] -eq 78 -and $bytes[3] -eq 71 -and $bytes[4] -eq 13 -and $bytes[5] -eq 10 -and $bytes[6] -eq 26 -and $bytes[7] -eq 10)
    } catch {
        return $false
    }
}

function Test-BoundedRuntimeErrorResponse($response) {
    return (
        $null -ne $response -and -not $response.ok -and
        -not [string]::IsNullOrWhiteSpace([string]$response.error) -and
        [string]$response.error -notmatch 'runtime\.ps1|ScriptStackTrace|line [0-9]+|operation-[0-9]+\.json'
    )
}


function Test-SameFixtureActionState($before, $after) {
    return (
        $before.auto -eq $after.auto -and
        $before.accessibility -eq $after.accessibility -and
        $before.appPost -eq $after.appPost -and
        $before.secondary -eq $after.secondary -and
        $before.typed -eq $after.typed -and
        $before.setValue -eq $after.setValue -and
        $before.eventCount -eq $after.eventCount -and
        $before.dragValue -eq $after.dragValue -and
        $before.scrollEvents -eq $after.scrollEvents -and
        $before.identityPrimaryValue -eq $after.identityPrimaryValue -and
        $before.identityDuplicateValue -eq $after.identityDuplicateValue
    )
}

function Read-State([string]$path) {
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            return ($json | ConvertFrom-Json -ErrorAction Stop)
        } catch {
            Start-Sleep -Milliseconds 25
        }
    }
    throw 'Fixture state could not be read consistently.'
}

function Start-Fixture([string]$scriptName, [string]$instance, [int]$left, [int]$top, [string]$hostPath, [bool]$allowOffscreenPlacement = $false, [string[]]$extraArguments = @()) {
    $readyPath = Join-Path $runRoot ($instance + '-ready.json')
    $statePath = Join-Path $runRoot ($instance + '-state.json')
    $scriptPath = Join-Path $fixtureRoot $scriptName
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-InstanceName', $instance, '-ReadyPath', $readyPath, '-StatePath', $statePath, '-Left', [string]$left, '-Top', [string]$top)
    if ($allowOffscreenPlacement) { $arguments += '-AllowOffscreenPlacement' }
    # Backward-compatible tail: fixtures with extra parameters (the Chromium
    # fixture's -BrowserPath / -RendererAccessibility) pass them verbatim here.
    if ($null -ne $extraArguments -and $extraArguments.Count -gt 0) { $arguments += $extraArguments }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Set-ProcessArguments $startInfo $arguments
    $process = [System.Diagnostics.Process]::Start($startInfo)
    Assert-Condition ($null -ne $process) ('Could not start fixture ' + $instance)
    $target = [pscustomobject]@{ Process = $process; Instance = $instance; ReadyPath = $readyPath; StatePath = $statePath }
    [void]$fixtures.Add($target)
    return $target
}

function Wait-FixtureReady($target, [int]$timeoutSeconds = 20) {
    $deadline = [datetime]::UtcNow.AddSeconds($timeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if ((Test-Path -LiteralPath $target.ReadyPath) -and (Test-Path -LiteralPath $target.StatePath)) {
            try {
                $state = Read-State $target.StatePath
                if ($state.ready -and $state.instance -eq $target.Instance -and $state.pid -gt 0 -and $state.hwnd -ne 0 -and -not [string]::IsNullOrWhiteSpace([string]$state.title)) {
                    try {
                        $process = Get-Process -Id ([int]$state.pid) -ErrorAction Stop
                        if ([int64]$process.MainWindowHandle -eq [int64]$state.hwnd) {
                            return $state
                        }
                    } catch {
                    }
                }
            } catch {
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw ('Fixture ' + $target.Instance + ' did not become ready: ' + $target.StatePath)
}

function Invoke-Runtime($operation) {
    $script:operationNumber += 1
    $operationPath = Join-Path $runRoot ('operation-' + $script:operationNumber + '.json')
    $operationJson = $operation | ConvertTo-Json -Depth 50 -Compress
    Set-Content -LiteralPath $operationPath -Value $operationJson -Encoding utf8

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:RuntimeHostPathResolved
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    Set-ProcessArguments $startInfo @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runtimePath, $operationPath)

    $process = $null
    try {
        try {
            $process = [System.Diagnostics.Process]::Start($startInfo)
        } catch {
            throw 'Could not start the Windows runtime process.'
        }
        Assert-Condition ($null -ne $process) 'Could not start the Windows runtime process.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($runtimeTimeoutMilliseconds)) {
            try { [void]$process.Kill() } catch { }
            try { [void]$process.WaitForExit(5000) } catch { }
            throw 'Windows runtime process timed out.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw 'Windows runtime process failed.'
        }
        if ($stdout.Length -gt $runtimeOutputLimit -or $stderr.Length -gt $runtimeOutputLimit) {
            throw 'Windows runtime output exceeded the safety limit.'
        }
        if ([string]::IsNullOrWhiteSpace($stdout)) {
            throw 'Windows runtime returned no response.'
        }
        try {
            $response = $stdout | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw 'Windows runtime returned invalid JSON.'
        }
        if ($null -eq $response -or $response -is [System.Array]) {
            throw 'Windows runtime returned an invalid response object.'
        }
        return $response
    } finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-Snapshot([string]$title, [bool]$includeImage = $false) {
    $response = Invoke-Runtime ([pscustomobject]@{
        tool = 'get_app_state'
        app = $title
        include_image = $includeImage
        text_limit = 250
        max_tree_nodes = 180
        max_tree_depth = 16
    })
    Assert-Condition $response.ok ('Snapshot failed for ' + $title + ': ' + $response.error)
    return $response.snapshot
}

function Invoke-TypeText($state, $snapshot, [string]$text) {
    return Invoke-Runtime ([pscustomobject]@{
        tool = 'type_text'
        app = $state.title
        text = $text
        expectedPid = [int]$snapshot.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshot.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshot.app.mainWindowHandle
    })
}
function Invoke-FocusedTypeText($state, $snapshot, [int64]$hwndValue, [string]$name, [string]$controlTypeName, [string]$valuePrefix, [string]$text) {
    $response = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        Set-FixtureFocus $hwndValue $name $controlTypeName $valuePrefix | Out-Null
        $response = Invoke-TypeText $state $snapshot $text
        if ($response.ok -or -not (Test-TypeTextTargetResponse $response)) {
            return $response
        }
    }
    return $response
}


function Wait-FixtureStateCondition($target, [scriptblock]$predicate, [string]$description) {
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $state = Read-State $target.StatePath
            if (& $predicate $state) {
                return $state
            }
        } catch {
        }
        Start-Sleep -Milliseconds 100
    }
    throw ('Fixture ' + $target.Instance + ' did not reach the expected state: ' + $description)
}

function Get-RuntimeIdKey($record) {
    if ($null -eq $record -or $null -eq $record.runtimeId) {
        return ''
    }
    $values = @($record.runtimeId)
    if ($values.Count -eq 0) {
        return ''
    }
    return ($values -join ',')
}

function Find-SamePresentationElements($snapshot, $reference) {
    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($record in $snapshot.elements) {
        if ($record.name -ne $reference.name -or $record.automationId -ne $reference.automationId -or $record.controlType -ne $reference.controlType) {
            continue
        }
        if (-not ($record.actions -contains 'SetValue')) {
            continue
        }
        [void]$matches.Add($record)
    }
    return @($matches.ToArray())
}

function Wait-IdentityReplacement($target, $originalRecord) {
    $originalRuntimeId = Get-RuntimeIdKey $originalRecord
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($originalRuntimeId)) 'The original identity target did not expose a runtime ID.'

    $deadline = [datetime]::UtcNow.AddSeconds(10)
    $lastObservation = 'replacement state was not observed'
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $state = Read-State $target.StatePath
            if ($state.identityGeneration -ne 1 -or $state.identityReplacementCount -ne 1) {
                $lastObservation = 'replacement state is not ready'
            } else {
                $snapshot = Get-Snapshot $state.title
                $records = @(Find-SamePresentationElements $snapshot $originalRecord)
                $runtimeIds = New-Object System.Collections.Generic.List[string]
                $allRuntimeIdsUsable = $true
                foreach ($record in $records) {
                    $runtimeId = Get-RuntimeIdKey $record
                    if ([string]::IsNullOrWhiteSpace($runtimeId)) {
                        $allRuntimeIdsUsable = $false
                        break
                    }
                    [void]$runtimeIds.Add($runtimeId)
                }
                if ($records.Count -eq 2 -and $allRuntimeIdsUsable -and $runtimeIds.Count -eq 2 -and $runtimeIds[0] -ne $runtimeIds[1] -and -not ($runtimeIds -contains $originalRuntimeId)) {
                    return [pscustomobject]@{
                        state = $state
                        snapshot = $snapshot
                        records = $records
                    }
                }
                $lastObservation = 'expected two replacement records with distinct runtime IDs that differ from the original'
            }
        } catch {
            $lastObservation = $PSItem.Exception.Message
        }
        Start-Sleep -Milliseconds 100
    }
    throw ('Identity replacement did not stabilize: ' + $lastObservation)
}

function Find-Element($snapshot, [string]$name, [string]$requiredAction, [bool]$requireNativeHandle) {
    foreach ($record in $snapshot.elements) {
        if ($record.name -ne $name) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($requiredAction) -and -not ($record.actions -contains $requiredAction)) {
            continue
        }
        if ($requireNativeHandle -and [int64]$record.nativeWindowHandle -eq 0) {
            continue
        }
        return $record
    }
    return $null
}

function Set-FixtureFocus([int64]$hwndValue, [string]$name, [string]$controlTypeName, [string]$valuePrefix) {
    $root = [Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwndValue)
    $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::NameProperty), $name
    $matches = @($root.FindAll([Windows.Automation.TreeScope]::Descendants, $condition))
    foreach ($element in $matches) {
        if ([string]$element.Current.ControlType.ProgrammaticName -ne $controlTypeName) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($valuePrefix)) {
            try {
                $valuePattern = $element.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
                if (-not ([string]$valuePattern.Current.Value).StartsWith($valuePrefix, [System.StringComparison]::Ordinal)) {
                    continue
                }
            } catch {
                continue
            }
        }
        $deadline = [datetime]::UtcNow.AddSeconds(5)
        while ([datetime]::UtcNow -lt $deadline) {
            $focused = [Windows.Automation.AutomationElement]::FocusedElement
            if ($null -ne $focused -and [int]$focused.Current.ProcessId -eq [int]$root.Current.ProcessId -and [string]$focused.Current.Name -eq $name -and [string]$focused.Current.ControlType.ProgrammaticName -eq $controlTypeName) {
                return [pscustomobject]@{
                    name = [string]$focused.Current.Name
                    controlType = [string]$focused.Current.ControlType.ProgrammaticName
                    processId = [int]$focused.Current.ProcessId
                    nativeWindowHandle = [int64]$focused.Current.NativeWindowHandle
                }
            }
            $element.SetFocus()
            Start-Sleep -Milliseconds 180
        }
        throw ('Could not stabilize focus on ' + $name + ' (' + $controlTypeName + ')')
    }
    throw ('Could not focus ' + $name + ' (' + $controlTypeName + ')')
}

function Restore-ProcessEnvironment($saved, [string[]]$names) {
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) {
            Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ('Env:' + $name) -Value $saved[$name]
        }
    }
}

function Remove-StaleChromiumFixtureBrowsers {
    # A Chromium fixture browser is a separate process: killing the fixture host does not
    # kill it, so a leftover window whose title still carries a fixture instance tag can
    # answer the next run's title-based snapshot resolution and fail its identity guard.
    # Fixture-owned browsers are identifiable by the throwaway profile directory that the
    # fixture passes on the command line, so only those are ever touched.
    $removed = 0
    foreach ($browserName in @('chrome', 'msedge')) {
        foreach ($candidate in @(Get-Process -Name $browserName -ErrorAction SilentlyContinue)) {
            try {
                $commandLine = [string](Get-CimInstance Win32_Process -Filter ('ProcessId=' + $candidate.Id) -ErrorAction SilentlyContinue).CommandLine
                if ([string]::IsNullOrWhiteSpace($commandLine) -or $commandLine -notlike '*ocu-chromium-profile-*') {
                    continue
                }
                [void]$candidate.Kill()
                $removed += 1
            } catch {
            }
        }
    }
    return $removed
}

function Get-ChromiumBrowserCandidates([string]$explicitPath) {
    # An explicit override wins outright: a caller-supplied path is never silently
    # replaced by a discovered browser, so '-ChromiumBrowserPath <bad path>' skips
    # the section instead of silently testing a browser the caller did not name.
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
        [void]$candidates.Add($explicitPath)
        return @($candidates.ToArray())
    }
    $roots = @(
        [Environment]::GetEnvironmentVariable('ProgramFiles'),
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    )
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        [void]$candidates.Add((Join-Path $root 'Google\Chrome\Application\chrome.exe'))
    }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        [void]$candidates.Add((Join-Path $root 'Microsoft\Edge\Application\msedge.exe'))
    }
    return @($candidates.ToArray())
}

function Get-InteractiveCursorWitness {
    # Read-only GetCursorPos sample. It is recorded as evidence for a human
    # reader only: an operator using the machine moves the cursor during any
    # run, so the witness never participates in a pass/fail decision.
    if (-not ('OcuSmokeCursorWitness' -as [type])) {
        return 'unavailable'
    }
    $position = [OcuSmokeCursorWitness]::Position()
    if ($null -eq $position) {
        return 'unavailable'
    }
    return ([string]$position[0] + ',' + [string]$position[1])
}

function Write-ChromiumNotice([string]$message) {
    # Operator-facing progress and skip lines go to the process's stderr handle as
    # UTF-8 without a BOM: stdout carries the result JSON and must stay
    # machine-parseable, and the notices must stay readable in a captured log.
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($message + [Environment]::NewLine)
    $stream = [Console]::OpenStandardError()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function Wait-ChromiumPointSample($target, [int]$clicksBefore, [int]$documentClicksBefore, [string]$description) {
    # Returns the page-reported point produced by one click, taken from whichever
    # list the page filled. A click on #click-target also triggers the document
    # listener, so both counters can rise for one click; the click sample is
    # preferred because it carries the target id, and a short settle window covers
    # the case where the document-level sample lands first.
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    $settleDeadline = $null
    while ([datetime]::UtcNow -lt $deadline) {
        $state = Read-State $target.StatePath
        if (([int]$state.clicks -gt $clicksBefore) -and (@($state.clickSamples).Count -gt 0)) {
            $sample = @($state.clickSamples)[-1]
            return [pscustomobject]@{ kind = 'click'; x = [double]$sample.clientX; y = [double]$sample.clientY; target = [string]$sample.target; state = $state }
        }
        if (([int]$state.documentClicks -gt $documentClicksBefore) -and (@($state.documentClickSamples).Count -gt 0)) {
            if ($null -eq $settleDeadline) { $settleDeadline = [datetime]::UtcNow.AddMilliseconds(400) }
            if ([datetime]::UtcNow -ge $settleDeadline) {
                $sample = @($state.documentClickSamples)[-1]
                return [pscustomobject]@{ kind = 'documentclick'; x = [double]$sample.clientX; y = [double]$sample.clientY; target = [string]$sample.targetId; state = $state }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw ('Fixture ' + $target.Instance + ' never reported a page point for: ' + $description)
}

function Get-ChromiumTargetGeometry($state) {
    # The runtime reads explicit x/y as window-relative screen offsets and adds
    # windowBounds itself (Get-ScreenPoint), so every point handed to a click is
    # converted back to a window-relative offset here. The page reports its own
    # CSS geometry plus devicePixelRatio, so the physical point is derived from
    # measurements instead of a hard-coded DPI factor.
    $rect = $state.geometry.clickTarget
    return [pscustomobject]@{
        devicePixelRatio = [double]$state.devicePixelRatio
        centerCssX = ([double]$rect.x + ([double]$rect.width / 2.0))
        centerCssY = ([double]$rect.y + ([double]$rect.height / 2.0))
    }
}

try {
    $script:FixtureHostPathResolved = Resolve-HostExecutable $FixtureHostPath
    $script:RuntimeHostPathResolved = Resolve-HostExecutable $RuntimeHostPath
    $script:NativeFixtureHostPathResolved = Resolve-HostExecutable $NativeFixtureHostPath
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $targetA = Start-Fixture 'wpf-test-bench.ps1' 'A' 20 20 $script:FixtureHostPathResolved
    $proxyTarget = Start-Fixture 'wpf-test-bench.ps1' 'Proxy' -14222 -14222 $script:FixtureHostPathResolved $true
    $proxyState = Wait-FixtureReady $proxyTarget
    $proxyResponse = Invoke-Runtime ([pscustomobject]@{ tool = 'get_app_state'; app = $proxyState.title; include_image = $true; text_limit = 250; max_tree_nodes = 180; max_tree_depth = 16 })
    $offscreenProxyRejected = (-not $proxyResponse.ok -and $proxyResponse.error -eq 'No usable top-level interactive window is available for the requested app.')
    $stateA = Wait-FixtureReady $targetA
    $snapshotA = Get-Snapshot $stateA.title
    Assert-Condition ($null -ne $snapshotA.app -and $snapshotA.app.pid -eq $stateA.pid -and $snapshotA.app.mainWindowHandle -eq $stateA.hwnd) 'A snapshot did not retain its fixture identity.'


    $screenshotResponse = Invoke-Runtime ([pscustomobject]@{
        tool = 'get_app_state'; app = $stateA.title; include_image = $true; text_limit = 250; max_tree_nodes = 180; max_tree_depth = 16
    })
    $screenshotCaptureBounded = Test-BoundedPngResponse $screenshotResponse
    Assert-Condition $screenshotCaptureBounded 'Screenshot response was neither a valid PNG nor a safely omitted image.'

    $identityBaselineForValidation = Read-State $targetA.StatePath
    $identityValidationPassed = $true
    $identityCases = @(
        [pscustomobject]@{ tool = 'get_app_state'; app = $stateA.title; expectedPid = [int]$snapshotA.app.pid },
        [pscustomobject]@{ tool = 'get_app_state'; app = $stateA.title; expectedPid = 'not-a-pid'; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle },
        [pscustomobject]@{ tool = 'get_app_state'; app = $stateA.title; expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = $null; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle },
        [pscustomobject]@{ tool = 'get_app_state'; app = $stateA.title; expectedPid = 1.5; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle }
    )
    foreach ($identityCase in $identityCases) {
        $identityResponse = Invoke-Runtime $identityCase
        if (-not (Test-TargetChangedResponse $identityResponse)) {
            $identityValidationPassed = $false
            break
        }
    }
    $identityAfterValidation = Read-State $targetA.StatePath
    $identityValidationPassed = $identityValidationPassed -and (Test-SameFixtureActionState $identityBaselineForValidation $identityAfterValidation)
    Assert-Condition $identityValidationPassed 'Malformed or partial pinned get_app_state identity was not rejected fail-closed.'

    $numericBaseline = Read-State $targetA.StatePath
    $numericOperations = @(
        [pscustomobject]@{ tool = 'click'; app = $stateA.title; click_count = 1.5 },
        [pscustomobject]@{ tool = 'click'; app = $stateA.title; click_count = $null },
        [pscustomobject]@{ tool = 'click'; app = $stateA.title; x = 1; y = $null },
        [pscustomobject]@{ tool = 'scroll'; app = $stateA.title; pages = 0.5 },
        [pscustomobject]@{ tool = 'scroll'; app = $stateA.title; pages = $null },
        [pscustomobject]@{ tool = 'scroll'; app = $stateA.title; pages = 'not-a-number' },
        [pscustomobject]@{ tool = 'click'; app = $stateA.title; click_count = 0 },
        [pscustomobject]@{ tool = 'click'; app = $stateA.title; x = 2000000000; y = 2000000000 },
        [pscustomobject]@{ tool = 'scroll'; app = $stateA.title; pages = 0 },
        [pscustomobject]@{ tool = 'scroll'; app = $stateA.title; pages = 101 }
    )
    $numericValidationPassed = $true
    foreach ($numericOperation in $numericOperations) {
        $numericResponse = Invoke-Runtime $numericOperation
        if (-not (Test-BoundedRuntimeErrorResponse $numericResponse)) {
            $numericValidationPassed = $false
            break
        }
    }
    $numericAfter = Read-State $targetA.StatePath
    $numericValidationPassed = $numericValidationPassed -and (Test-SameFixtureActionState $numericBaseline $numericAfter)
    Assert-Condition $numericValidationPassed 'Invalid numeric operations were not rejected before fixture delivery or leaked diagnostics.'

    $identityElementA = Find-Element $snapshotA 'Identity replacement target' 'SetValue' $false
    Assert-Condition ($null -ne $identityElementA) 'The identity replacement target was not found.'
    $replaceIdentityElementA = Find-Element $snapshotA 'Replace identity target' 'Invoke' $false
    Assert-Condition ($null -ne $replaceIdentityElementA) 'The identity replacement trigger was not found.'
    $identityBaseline = Read-State $targetA.StatePath

    $emptyRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $emptyRuntimeIdElement.runtimeId = @()
    $emptyRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $emptyRuntimeIdElement; value = 'must-not-write-empty-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $emptyRuntimeIdResult 'An empty runtime ID was not rejected.'
    $afterEmptyRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterEmptyRuntimeId.setValue -eq $identityBaseline.setValue -and $afterEmptyRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterEmptyRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'An empty runtime ID changed fixture state.'

    $missingRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    [void]$missingRuntimeIdElement.PSObject.Properties.Remove('runtimeId')
    $missingRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $missingRuntimeIdElement; value = 'must-not-write-missing-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $missingRuntimeIdResult 'A missing runtime ID was not rejected.'
    $afterMissingRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterMissingRuntimeId.setValue -eq $identityBaseline.setValue -and $afterMissingRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterMissingRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'A missing runtime ID changed fixture state.'

    $nullMemberRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $nullMemberRuntimeIdElement.runtimeId = @($null)
    $nullMemberRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $nullMemberRuntimeIdElement; value = 'must-not-write-null-member-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $nullMemberRuntimeIdResult 'A null runtime ID member was not rejected.'
    $afterNullMemberRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterNullMemberRuntimeId.setValue -eq $identityBaseline.setValue -and $afterNullMemberRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterNullMemberRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'A null runtime ID member changed fixture state.'

    $blankRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $blankRuntimeIdElement.runtimeId = @(' ')
    $blankRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $blankRuntimeIdElement; value = 'must-not-write-blank-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $blankRuntimeIdResult 'A blank runtime ID was not rejected.'
    $afterBlankRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterBlankRuntimeId.setValue -eq $identityBaseline.setValue -and $afterBlankRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterBlankRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'A blank runtime ID changed fixture state.'

    $fractionalRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $fractionalRuntimeIdElement.runtimeId = @(1.2)
    $fractionalRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $fractionalRuntimeIdElement; value = 'must-not-write-fractional-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $fractionalRuntimeIdResult 'A fractional runtime ID was not rejected.'
    $afterFractionalRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterFractionalRuntimeId.setValue -eq $identityBaseline.setValue -and $afterFractionalRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterFractionalRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'A fractional runtime ID changed fixture state.'

    $outOfRangeRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $outOfRangeRuntimeIdElement.runtimeId = @(2147483648)
    $outOfRangeRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $outOfRangeRuntimeIdElement; value = 'must-not-write-out-of-range-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $outOfRangeRuntimeIdResult 'An out-of-range runtime ID was not rejected.'
    $afterOutOfRangeRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterOutOfRangeRuntimeId.setValue -eq $identityBaseline.setValue -and $afterOutOfRangeRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterOutOfRangeRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'An out-of-range runtime ID changed fixture state.'

    $negativeOutOfRangeRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $negativeOutOfRangeRuntimeIdElement.runtimeId = @(-2147483649)
    $negativeOutOfRangeRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $negativeOutOfRangeRuntimeIdElement; value = 'must-not-write-negative-out-of-range-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $negativeOutOfRangeRuntimeIdResult 'A negative out-of-range runtime ID was not rejected.'
    $afterNegativeOutOfRangeRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterNegativeOutOfRangeRuntimeId.setValue -eq $identityBaseline.setValue -and $afterNegativeOutOfRangeRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterNegativeOutOfRangeRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'A negative out-of-range runtime ID changed fixture state.'

    $malformedRuntimeIdElement = $identityElementA | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $malformedRuntimeIdElement.runtimeId = @('not-an-int')
    $malformedRuntimeIdResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $malformedRuntimeIdElement; value = 'must-not-write-malformed-id'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $malformedRuntimeIdResult 'A malformed runtime ID was not rejected.'
    $afterMalformedRuntimeId = Read-State $targetA.StatePath
    Assert-Condition ($afterMalformedRuntimeId.setValue -eq $identityBaseline.setValue -and $afterMalformedRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and $afterMalformedRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue) 'A malformed runtime ID changed fixture state.'

    $replaceIdentityResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'perform_secondary_action'; app = $stateA.title; element = $replaceIdentityElementA; action = 'Invoke'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $replaceIdentityResult.ok ('Identity target replacement failed: ' + $replaceIdentityResult.error)
    $replacement = Wait-IdentityReplacement $targetA $identityElementA
    $identityAfterReplacement = $replacement.state
    $replacementPrimaryBeforeAddress = $identityAfterReplacement.identityPrimaryValue
    $replacementDuplicateBeforeAddress = $identityAfterReplacement.identityDuplicateValue
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($replacementPrimaryBeforeAddress) -and -not [string]::IsNullOrWhiteSpace($replacementDuplicateBeforeAddress)) 'The replacement fixture did not expose both duplicate target values.'

    $replacementPrimaryElement = $null
    $replacementDuplicateElement = $null
    foreach ($record in $replacement.records) {
        if ($record.value -eq $replacementPrimaryBeforeAddress) {
            $replacementPrimaryElement = $record
        }
        if ($record.value -eq $replacementDuplicateBeforeAddress) {
            $replacementDuplicateElement = $record
        }
    }
    Assert-Condition ($null -ne $replacementPrimaryElement -and $null -ne $replacementDuplicateElement) 'The replacement snapshot did not distinguish the two duplicate targets by value.'

    $addressedPrimaryValue = 'identity-primary-addressed'
    $addressedPrimaryResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $replacementPrimaryElement; value = $addressedPrimaryValue
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $addressedPrimaryResult.ok ('The first duplicate target could not be addressed: ' + $addressedPrimaryResult.error)
    $afterAddressedPrimary = Wait-FixtureStateCondition $targetA {
        param($state)
        return $state.identityPrimaryValue -eq $addressedPrimaryValue -and $state.identityDuplicateValue -eq $replacementDuplicateBeforeAddress
    } 'first duplicate target update'

    $duplicateSnapshot = $null
    $replacementDuplicateElement = $null
    $duplicateLookupDeadline = [datetime]::UtcNow.AddSeconds(5)
    while ([datetime]::UtcNow -lt $duplicateLookupDeadline -and $null -eq $replacementDuplicateElement) {
        $duplicateSnapshot = Get-Snapshot $stateA.title
        foreach ($record in (Find-SamePresentationElements $duplicateSnapshot $identityElementA)) {
            if ($record.value -eq $replacementDuplicateBeforeAddress) {
                $replacementDuplicateElement = $record
                break
            }
        }
        if ($null -eq $replacementDuplicateElement) {
            Start-Sleep -Milliseconds 100
        }
    }
    Assert-Condition ($null -ne $replacementDuplicateElement) 'The second duplicate target was not independently addressable after the first update.'

    $addressedDuplicateValue = 'identity-duplicate-addressed'
    $addressedDuplicateResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $replacementDuplicateElement; value = $addressedDuplicateValue
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $addressedDuplicateResult.ok ('The second duplicate target could not be addressed: ' + $addressedDuplicateResult.error)
    $afterAddressedDuplicate = Wait-FixtureStateCondition $targetA {
        param($state)
        return $state.identityPrimaryValue -eq $addressedPrimaryValue -and $state.identityDuplicateValue -eq $addressedDuplicateValue
    } 'second duplicate target update'

    $staleClickAccessibilityResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $identityElementA; click_count = 1; mouse_button = 'left'; click_method = 'accessibility'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleClickAccessibilityResult 'A stale accessibility click was not rejected.'

    $staleClickAppPostResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $identityElementA; click_count = 1; mouse_button = 'left'; click_method = 'app_post'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleClickAppPostResult 'A stale app-post click was not rejected.'

    $staleClickGlobalResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $identityElementA; click_count = 1; mouse_button = 'left'; click_method = 'global'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleClickGlobalResult 'A stale global click was not rejected before authorization or input delivery.'

    $staleClickAutoResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $identityElementA; click_count = 1; mouse_button = 'left'; click_method = 'auto'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleClickAutoResult 'A stale auto click was not rejected.'

    $staleSecondaryResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'perform_secondary_action'; app = $stateA.title; element = $identityElementA; action = 'Invoke'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleSecondaryResult 'A stale secondary action was not rejected.'

    $staleScrollResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'scroll'; app = $stateA.title; element = $identityElementA; direction = 'down'; pages = 1
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleScrollResult 'A stale scroll was not rejected before semantic or coordinate delivery.'

    $staleElementResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'set_value'; app = $stateA.title; element = $identityElementA; value = 'must-not-write-replacement'
        expectedPid = [int]$snapshotA.app.pid; expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-TargetChangedResponse $staleElementResult 'A replaced same-metadata element was not rejected.'
    Start-Sleep -Milliseconds 300
    $afterStaleElement = Read-State $targetA.StatePath
    Assert-Condition ($afterStaleElement.identityPrimaryValue -eq $addressedPrimaryValue -and $afterStaleElement.identityDuplicateValue -eq $addressedDuplicateValue -and $afterStaleElement.identityReplacementCount -eq 1) 'A stale element action changed a replacement or duplicate target.'

    $alternateTitle = 'Open Computer Use MCP WPF Test Bench [B]'
    $baselineCrossA = Read-State $targetA.StatePath
    $crossQuery = [pscustomobject]@{
        tool = 'set_value'
        app = $alternateTitle
        element = $replacementPrimaryElement
        value = 'must-not-cross-query'
        expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    }
    $crossResult = Invoke-Runtime $crossQuery
    Assert-TargetChangedResponse $crossResult 'A pinned identity was accepted under a different app selector.'
    Start-Sleep -Milliseconds 200
    $afterCrossA = Read-State $targetA.StatePath
    Assert-Condition ($afterCrossA.setValue -eq $baselineCrossA.setValue) 'A cross-query pinned action changed the fixture.'

    $badIdentity = [pscustomobject]@{
        tool = 'set_value'
        app = $stateA.title
        element = $replacementPrimaryElement
        value = 'must-not-write'
        expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = ([int64]$snapshotA.app.processStartTimeTicks + 1)
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    }
    $badResult = Invoke-Runtime $badIdentity
    Assert-Condition ((-not $badResult.ok) -and $badResult.error -eq 'Target changed; call get_app_state again.') 'Mismatched identity was not rejected.'
    $afterBadA = Read-State $targetA.StatePath
    Assert-Condition ($afterBadA.setValue -eq $afterCrossA.setValue) 'Mismatched identity mutated the fixture.'

    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class OcuSmokeWindow { [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; } [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint flags); [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect); public static int[] Position(IntPtr hWnd) { RECT rect; if (!GetWindowRect(hWnd, out rect)) { return null; } return new int[] { rect.Left, rect.Top }; } }'
    $oldBounds = $snapshotA.windowBounds
    $moved = [OcuSmokeWindow]::SetWindowPos([IntPtr]$snapshotA.app.mainWindowHandle, [IntPtr]::Zero, ([int]$oldBounds.x + 25), [int]$oldBounds.y, 0, 0, 0x0001 -bor 0x0004 -bor 0x0040)
    Assert-Condition $moved 'SetWindowPos failed for A.'
    $moveDeadline = [datetime]::UtcNow.AddSeconds(5)
    $didMove = $false
    while ([datetime]::UtcNow -lt $moveDeadline) {
        $position = [OcuSmokeWindow]::Position([IntPtr]$snapshotA.app.mainWindowHandle)
        if ($null -ne $position -and ($position[0] -ne [int]$oldBounds.x -or $position[1] -ne [int]$oldBounds.y)) {
            $didMove = $true
            break
        }
        Start-Sleep -Milliseconds 50
    }
    Assert-Condition $didMove 'A did not move before stale-bounds assertion.'
    $staleDrag = [pscustomobject]@{
        tool = 'drag'
        app = $stateA.title
        from_x = 100
        from_y = 250
        to_x = 400
        to_y = 250
        windowBounds = $oldBounds
        expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    }
    $staleResult = Invoke-Runtime $staleDrag
    Assert-Condition ((-not $staleResult.ok) -and $staleResult.error -eq 'Target changed; call get_app_state again.') 'Stale bounds were not rejected.'
    $snapshotA = Get-Snapshot $stateA.title

    # Focus changes here are fixture setup only; type_text itself must never call SetFocus.
    $typeTextEnvironmentName = 'OPEN_COMPUTER_USE_WINDOWS_ALLOW_UIA_TEXT_FALLBACK'
    $savedTypeTextEnvironment = [Environment]::GetEnvironmentVariable($typeTextEnvironmentName)
    $focusedTypeTextResponse = $null
    $nonEditableTypeTextResponse = $null
    $duplicateTypeTextResponse = $null
    $outsideWindowTypeTextResponse = $null
    $disabledFallbackTypeTextResponse = $null
    $nativeTypeTextResponse = $null
    $focusedTypeTextAccepted = $false
    $nonEditableTypeTextRejected = $false
    $duplicateFocusedTypeTextIsolated = $false
    $outsideWindowTypeTextRejected = $false
    $disabledUIATextFallbackRejected = $false
    $nativeFocusedTypeTextAccepted = $false
    try {
        $typeTextElement = Find-Element $snapshotA 'Type text target' 'SetValue' $false
        Assert-Condition ($null -ne $typeTextElement) 'The WPF type_text target was not found.'
        [Environment]::SetEnvironmentVariable($typeTextEnvironmentName, '1')

        $beforeFocusedTypeText = Read-State $targetA.StatePath
        $focusedType = Set-FixtureFocus $stateA.hwnd 'Type text target' 'ControlType.Edit' ''
        Assert-Condition ($focusedType.processId -eq $snapshotA.app.pid) 'The WPF type_text target focus escaped the requested process.'
        $focusedTypeTextResponse = Invoke-FocusedTypeText $stateA $snapshotA $stateA.hwnd 'Type text target' 'ControlType.Edit' '' $focusedSuccessText
        Assert-Condition $focusedTypeTextResponse.ok ('Focused WPF type_text failed: ' + $focusedTypeTextResponse.error)
        $afterFocusedTypeText = Wait-FixtureStateCondition $targetA {
            param($state)
            return $state.typed -eq ($beforeFocusedTypeText.typed + $focusedSuccessText)
        } 'focused WPF type_text'
        $focusedTypeTextAccepted = (
            $focusedTypeTextResponse.ok -and
            $afterFocusedTypeText.typed -eq ($beforeFocusedTypeText.typed + $focusedSuccessText) -and
            $afterFocusedTypeText.identityPrimaryValue -eq $beforeFocusedTypeText.identityPrimaryValue -and
            $afterFocusedTypeText.identityDuplicateValue -eq $beforeFocusedTypeText.identityDuplicateValue
        )
        Assert-Condition $focusedTypeTextAccepted 'Focused WPF type_text did not change only the intended field.'

        $replaceIdentityForTypeText = Find-Element $snapshotA 'Replace identity target' 'Invoke' $false
        Assert-Condition ($null -ne $replaceIdentityForTypeText) 'The type_text non-editable focus target was not found.'
        $replaceIdentityForTypeText | Out-Null
        $focusButtonForTypeText = Set-FixtureFocus $stateA.hwnd 'Replace identity target' 'ControlType.Button' ''
        $beforeNonEditableTypeText = Read-State $targetA.StatePath
        $nonEditableTypeTextResponse = Invoke-TypeText $stateA $snapshotA 'must-not-write-from-button'
        Assert-Condition (Test-TypeTextTargetResponse $nonEditableTypeTextResponse) 'Non-editable focus did not return the bounded type_text target error.'
        $afterNonEditableTypeText = Read-State $targetA.StatePath
        $nonEditableTypeTextRejected = (
            (Test-TypeTextTargetResponse $nonEditableTypeTextResponse) -and
            $afterNonEditableTypeText.typed -eq $beforeNonEditableTypeText.typed -and
            $afterNonEditableTypeText.identityPrimaryValue -eq $beforeNonEditableTypeText.identityPrimaryValue -and
            $afterNonEditableTypeText.identityDuplicateValue -eq $beforeNonEditableTypeText.identityDuplicateValue -and
            $nonEditableTypeTextResponse.error -notmatch 'runtime\.ps1|ScriptStackTrace|line [0-9]+'
        )
        Assert-Condition $nonEditableTypeTextRejected 'Non-editable type_text focus changed fixture state or leaked diagnostics.'

        $duplicateTypeTextRecord = $null
        foreach ($record in $snapshotA.elements) {
            if ($record.name -eq 'Identity replacement target' -and $record.controlType -eq 'ControlType.Edit' -and $record.actions -contains 'SetValue' -and $record.value -like 'identity-duplicate-*') {
                $duplicateTypeTextRecord = $record
                break
            }
        }
        Assert-Condition ($null -ne $duplicateTypeTextRecord) 'The duplicate focused type_text target was not found.'
        $focusDuplicateForTypeText = Set-FixtureFocus $stateA.hwnd 'Identity replacement target' 'ControlType.Edit' 'identity-duplicate-'
        $beforeDuplicateTypeText = Read-State $targetA.StatePath
        $duplicateTypeTextResponse = Invoke-FocusedTypeText $stateA $snapshotA $stateA.hwnd 'Identity replacement target' 'ControlType.Edit' 'identity-duplicate-' $duplicateSuccessText
        Assert-Condition $duplicateTypeTextResponse.ok ('Focused duplicate WPF type_text failed: ' + $duplicateTypeTextResponse.error)
        $afterDuplicateTypeText = Wait-FixtureStateCondition $targetA {
            param($state)
            return $state.identityDuplicateValue -eq ($beforeDuplicateTypeText.identityDuplicateValue + $duplicateSuccessText)
        } 'focused duplicate WPF type_text'
        $duplicateFocusedTypeTextIsolated = (
            $duplicateTypeTextResponse.ok -and
            $afterDuplicateTypeText.identityPrimaryValue -eq $beforeDuplicateTypeText.identityPrimaryValue -and
            $afterDuplicateTypeText.identityDuplicateValue -eq ($beforeDuplicateTypeText.identityDuplicateValue + $duplicateSuccessText) -and
            $afterDuplicateTypeText.typed -eq $beforeDuplicateTypeText.typed
        )
        Assert-Condition $duplicateFocusedTypeTextIsolated 'Focused duplicate type_text did not stay on the focused control.'


        $focusTypeForDisabledFallback = Set-FixtureFocus $stateA.hwnd 'Type text target' 'ControlType.Edit' ''
        $savedFallbackForDisabledTest = [Environment]::GetEnvironmentVariable($typeTextEnvironmentName)
        try {
            [Environment]::SetEnvironmentVariable($typeTextEnvironmentName, $null)
            $beforeDisabledFallback = Read-State $targetA.StatePath
            $disabledFallbackTypeTextResponse = Invoke-FocusedTypeText $stateA $snapshotA $stateA.hwnd 'Type text target' 'ControlType.Edit' '' 'must-not-use-disabled-fallback'
            Assert-Condition (Test-TypeTextFallbackResponse $disabledFallbackTypeTextResponse) ('Disabled UIA text fallback did not return its bounded capability error: ' + $disabledFallbackTypeTextResponse.error)
            $afterDisabledFallback = Read-State $targetA.StatePath
            $disabledUIATextFallbackRejected = (
                (Test-TypeTextFallbackResponse $disabledFallbackTypeTextResponse) -and
                $afterDisabledFallback.typed -eq $beforeDisabledFallback.typed -and
                $disabledFallbackTypeTextResponse.error -notmatch 'runtime\.ps1|ScriptStackTrace|line [0-9]+'
            )
            Assert-Condition $disabledUIATextFallbackRejected 'Disabled UIA text fallback changed state or leaked diagnostics.'
        } finally {
            if ($null -eq $savedFallbackForDisabledTest) {
                Remove-Item -LiteralPath ('Env:' + $typeTextEnvironmentName) -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path ('Env:' + $typeTextEnvironmentName) -Value $savedFallbackForDisabledTest
            }
        }
        # The separate B fixture is needed only for this cross-window focus case.
        $targetB = Start-Fixture 'wpf-test-bench.ps1' 'B' 0 760 $script:FixtureHostPathResolved
        $stateB = Wait-FixtureReady $targetB
        $snapshotB = Get-Snapshot $stateB.title
        Assert-Condition ($snapshotA.app.pid -ne $snapshotB.app.pid -and $snapshotA.app.mainWindowHandle -ne $snapshotB.app.mainWindowHandle) 'A and B did not receive distinct identities.'
        [void][OcuSmokeWindow]::SetWindowPos([IntPtr]$stateB.hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0001 -bor 0x0004 -bor 0x0040)
        Start-Sleep -Milliseconds 180
        $snapshotBForTypeText = Get-Snapshot $stateB.title
        $focusOutsideTypeText = Set-FixtureFocus $stateB.hwnd 'Type text target' 'ControlType.Edit' ''
        $beforeOutsideTypeTextA = Read-State $targetA.StatePath
        $beforeOutsideTypeTextB = Read-State $targetB.StatePath
        $outsideWindowTypeTextResponse = Invoke-TypeText $stateA $snapshotA 'must-not-cross-window'
        Assert-Condition (Test-TypeTextTargetResponse $outsideWindowTypeTextResponse) 'Outside-window focus did not return the bounded type_text target error.'
        $afterOutsideTypeTextA = Read-State $targetA.StatePath
        $afterOutsideTypeTextB = Read-State $targetB.StatePath
        $outsideWindowTypeTextRejected = (
            (Test-TypeTextTargetResponse $outsideWindowTypeTextResponse) -and
            $afterOutsideTypeTextA.typed -eq $beforeOutsideTypeTextA.typed -and
            $afterOutsideTypeTextA.identityPrimaryValue -eq $beforeOutsideTypeTextA.identityPrimaryValue -and
            $afterOutsideTypeTextA.identityDuplicateValue -eq $beforeOutsideTypeTextA.identityDuplicateValue -and
            $afterOutsideTypeTextB.typed -eq $beforeOutsideTypeTextB.typed
        )
        Assert-Condition $outsideWindowTypeTextRejected 'Outside-window type_text changed a fixture state.'
        # B exists only to prove that A refuses an out-of-window focus. Remove it
        # before resuming A's focus-sensitive tests on a one-window desktop.
        [void][OcuSmokeWindow]::SetWindowPos([IntPtr]$stateB.hwnd, [IntPtr]::Zero, -14222, -14222, 0, 0, 0x0001 -bor 0x0004 -bor 0x0040)
        Start-Sleep -Milliseconds 180
        [void][OcuSmokeWindow]::SetWindowPos([IntPtr]$stateA.hwnd, [IntPtr]::Zero, [int]$snapshotA.windowBounds.x, [int]$snapshotA.windowBounds.y, 0, 0, 0x0001 -bor 0x0004 -bor 0x0040)
        Start-Sleep -Milliseconds 180

        # Run all WPF identity/focus paths before a native fixture owns another
        # foreground window on small single-desktop hosts.
        $nativeTarget = Start-Fixture 'native-pointer-bench.ps1' 'N' 1120 0 $script:NativeFixtureHostPathResolved
        $nativeState = Wait-FixtureReady $nativeTarget
        $nativeSnapshot = Get-Snapshot $nativeState.title
        $nativeTypeElement = Find-Element $nativeSnapshot 'Native type_text target' 'SetValue' $true
        Assert-Condition ($null -ne $nativeTypeElement) 'The native type_text target was not found with a child HWND.'
        $nativeSeedValue = 'native-seed-'
        $nativeSeedResult = Invoke-Runtime ([pscustomobject]@{
            tool = 'set_value'; app = $nativeState.title; element = $nativeTypeElement; value = $nativeSeedValue
            expectedPid = [int]$nativeSnapshot.app.pid; expectedProcessStartTimeTicks = [int64]$nativeSnapshot.app.processStartTimeTicks
            expectedMainWindowHandle = [int64]$nativeSnapshot.app.mainWindowHandle
        })
        Assert-Condition $nativeSeedResult.ok ('Native type_text seed failed: ' + $nativeSeedResult.error)
        $nativeSnapshot = $nativeSeedResult.snapshot
        $nativeTypeElement = Find-Element $nativeSnapshot 'Native type_text target' 'SetValue' $true
        Assert-Condition ($null -ne $nativeTypeElement) 'The native type_text target disappeared after seeding.'
        $focusNativeTypeText = Set-FixtureFocus $nativeState.hwnd 'Native type_text target' 'ControlType.Edit' ''
        $savedFallbackForNativeTest = [Environment]::GetEnvironmentVariable($typeTextEnvironmentName)
        try {
            [Environment]::SetEnvironmentVariable($typeTextEnvironmentName, $null)
            $beforeNativeTypeText = Read-State $nativeTarget.StatePath
            Assert-Condition ($beforeNativeTypeText.typed -eq $nativeSeedValue) 'Native type_text seed did not stabilize before typing.'
            $nativeTypeTextResponse = Invoke-FocusedTypeText $nativeState $nativeSnapshot $nativeState.hwnd 'Native type_text target' 'ControlType.Edit' '' $nativeSuccessText
            Assert-Condition $nativeTypeTextResponse.ok ('Native child-HWND type_text failed: ' + $nativeTypeTextResponse.error)
            $afterNativeTypeText = Wait-FixtureStateCondition $nativeTarget {
                param($state)
                return $state.typed -eq ($beforeNativeTypeText.typed + $nativeSuccessText)
            } 'native child-HWND type_text append'
            $nativeFocusedTypeTextAccepted = (
                $nativeTypeTextResponse.ok -and
                $afterNativeTypeText.typed -eq ($beforeNativeTypeText.typed + $nativeSuccessText)
            )
            Assert-Condition $nativeFocusedTypeTextAccepted 'Native child-HWND type_text did not append to its intended field.'
        } finally {
            if ($null -eq $savedFallbackForNativeTest) {
                Remove-Item -LiteralPath ('Env:' + $typeTextEnvironmentName) -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path ('Env:' + $typeTextEnvironmentName) -Value $savedFallbackForNativeTest
            }
        }
    } finally {
        if ($null -eq $savedTypeTextEnvironment) {
            Remove-Item -LiteralPath ('Env:' + $typeTextEnvironmentName) -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path ('Env:' + $typeTextEnvironmentName) -Value $savedTypeTextEnvironment
        }
    }

    $autoCompatibilityElement = Find-Element $snapshotA 'Auto click target' 'Invoke' $false
    Assert-Condition ($null -ne $autoCompatibilityElement -and $null -ne $autoCompatibilityElement.frame) 'The valid-frame auto click element was not found.'
    $beforeAutoCompatibility = Read-State $targetA.StatePath
    $autoCompatibilityResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $autoCompatibilityElement; click_count = 1; mouse_button = 'left'; click_method = 'auto'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $autoCompatibilityResult.ok ('Valid-frame auto click failed: ' + $autoCompatibilityResult.error)
    $afterAutoCompatibility = Wait-FixtureStateCondition $targetA {
        param($state)
        return $state.auto -eq ($beforeAutoCompatibility.auto + 1)
    } 'valid-frame auto click'

    $semanticClickElement = Find-Element $snapshotA 'Accessibility click target' 'Invoke' $false
    Assert-Condition ($null -ne $semanticClickElement) 'The semantic no-frame click element was not found.'
    $semanticClickWithoutFrameElement = $semanticClickElement | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $semanticClickWithoutFrameElement.frame = $null
    $beforeSemanticClick = $afterAutoCompatibility
    $semanticClickWithoutFrameResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $semanticClickWithoutFrameElement; click_count = 1; mouse_button = 'left'; click_method = 'accessibility'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $semanticClickWithoutFrameResult.ok ('Semantic accessibility click without a frame failed: ' + $semanticClickWithoutFrameResult.error)
    $afterSemanticClick = Wait-FixtureStateCondition $targetA {
        param($state)
        return $state.accessibility -eq ($beforeSemanticClick.accessibility + 1)
    } 'semantic accessibility click without frame'

    $clickFallbackElement = Find-Element $snapshotA 'Set value target' 'SetValue' $false
    Assert-Condition ($null -ne $clickFallbackElement -and $null -ne $clickFallbackElement.frame) 'The click fallback test element was not found with a frame.'
    Assert-Condition (-not ($clickFallbackElement.actions -contains 'Invoke')) 'The click fallback test element unexpectedly exposes InvokePattern.'
    $missingClickElement = $clickFallbackElement | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $missingClickElement.frame = $null
    $missingClickBaseline = Read-State $targetA.StatePath
    $missingClickResults = @{}
    $clickEnvironmentNames = @('OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT', 'OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS')
    $savedClickEnvironment = @{}
    foreach ($name in $clickEnvironmentNames) {
        $savedClickEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        Set-Item -Path ('Env:' + $name) -Value '1'
    }
    try {
        foreach ($method in @('auto', 'app_post', 'global')) {
            $missingClickResults[$method] = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $stateA.title; element = $missingClickElement; click_count = 1; mouse_button = 'left'; click_method = $method
                windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
                expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
            })
            Assert-Condition (Test-MissingClickFrameResponse $missingClickResults[$method]) ('Missing-frame ' + $method + ' click did not fail with the bounded frame error.')
            Start-Sleep -Milliseconds 150
            $afterMissingClick = Read-State $targetA.StatePath
            Assert-Condition (Test-SameFixtureActionState $missingClickBaseline $afterMissingClick) ('Missing-frame ' + $method + ' click changed fixture state.')
        }
    } finally {
        Restore-ProcessEnvironment $savedClickEnvironment $clickEnvironmentNames
    }

    $semanticScrollElement = Find-Element $snapshotA 'Scroll test container' 'Scroll' $false
    Assert-Condition ($null -ne $semanticScrollElement) 'The WPF ScrollViewer did not expose ScrollPattern.'
    $semanticScrollWithoutFrame = $semanticScrollElement | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $semanticScrollWithoutFrame.frame = $null
    $beforeSemanticScroll = Read-State $targetA.StatePath
    $semanticScrollResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'scroll'; app = $stateA.title; element = $semanticScrollWithoutFrame; direction = 'down'; pages = 0.5
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $semanticScrollResult.ok ('Semantic scroll without a frame failed: ' + $semanticScrollResult.error)
    Start-Sleep -Milliseconds 200
    $afterSemanticScroll = Read-State $targetA.StatePath
    Assert-Condition ($afterSemanticScroll.scrollEvents -gt $beforeSemanticScroll.scrollEvents) 'Semantic scroll without a frame did not change the ScrollViewer.'

    $scrollFallbackElement = Find-Element $snapshotA 'Auto click target' 'Invoke' $false
    Assert-Condition ($null -ne $scrollFallbackElement -and $null -ne $scrollFallbackElement.frame) 'The fallback scroll target was not found with a frame.'
    Assert-Condition (-not ($scrollFallbackElement.actions -contains 'Scroll')) 'The fallback scroll target unexpectedly exposes ScrollPattern.'
    $validFallbackResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'scroll'; app = $stateA.title; element = $scrollFallbackElement; direction = 'down'; pages = 0.5
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition $validFallbackResult.ok ('Valid-frame scroll fallback failed: ' + $validFallbackResult.error)

    $beforeInvalidScrollFrame = Read-State $targetA.StatePath
    $missingFrameElement = $scrollFallbackElement | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $missingFrameElement.frame = $null
    $missingFrameResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'scroll'; app = $stateA.title; element = $missingFrameElement; direction = 'down'; pages = 1
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition ((-not $missingFrameResult.ok) -and $missingFrameResult.error -like 'Scroll requires an element with a valid frame when ScrollPattern is unavailable.*') 'Missing scroll frame was not rejected with the bounded error.'

    $zeroWidthFrameElement = $scrollFallbackElement | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $zeroWidthFrameElement.frame.width = 0
    $zeroWidthFrameResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'scroll'; app = $stateA.title; element = $zeroWidthFrameElement; direction = 'down'; pages = 1
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition ((-not $zeroWidthFrameResult.ok) -and $zeroWidthFrameResult.error -like 'Scroll requires an element with a valid frame when ScrollPattern is unavailable.*') 'Non-positive scroll frame was not rejected with the bounded error.'
    Start-Sleep -Milliseconds 200
    $afterInvalidScrollFrame = Read-State $targetA.StatePath
    Assert-Condition ($afterInvalidScrollFrame.scrollEvents -eq $beforeInvalidScrollFrame.scrollEvents) 'Invalid scroll frame changed the ScrollViewer.'

    $savedNames = @{}
    $negativeNames = @('OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT', 'OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS')
    foreach ($name in $negativeNames) {
        $savedNames[$name] = [Environment]::GetEnvironmentVariable($name)
        Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue
    }
    try {
        $autoElementA = Find-Element $snapshotA 'Auto click target' 'Invoke' $false
        $globalDenied = Invoke-Runtime ([pscustomobject]@{
            tool = 'click'; app = $stateA.title; element = $autoElementA; click_count = 1; mouse_button = 'left'; click_method = 'global'
            windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
            expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
        })
        Assert-Condition ((-not $globalDenied.ok) -and $globalDenied.error -like '*Interactive Windows input is disabled by default*') 'Unauthorized global click was not rejected.'
        $beforeKey = Read-State $targetA.StatePath
        $keyDenied = Invoke-Runtime ([pscustomobject]@{
            tool = 'press_key'; app = $stateA.title; key = 'End'; expectedPid = [int]$snapshotA.app.pid
            expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
        })
        $afterKey = Read-State $targetA.StatePath
        Assert-Condition ((-not $keyDenied.ok) -and $keyDenied.error -like '*Interactive Windows keyboard input is disabled by default*') 'Unauthorized key input was not rejected.'
        Assert-Condition ($beforeKey.eventCount -eq $afterKey.eventCount) 'Unauthorized key input changed the fixture.'
    } finally {
        Restore-ProcessEnvironment $savedNames $negativeNames
    }

    $wpfAppPostElement = Find-Element $snapshotA 'App-post click target' 'Invoke' $false
    $wpfAppPost = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $stateA.title; element = $wpfAppPostElement; click_count = 1; mouse_button = 'left'; click_method = 'app_post'
        windowBounds = $snapshotA.windowBounds; expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    })
    Assert-Condition ((-not $wpfAppPost.ok) -and $wpfAppPost.error -like '*native HWND*') 'WPF app_post did not return its capability error.'

    $nativeButton = Find-Element $nativeSnapshot 'App-post native button target' '' $true
    Assert-Condition ($null -ne $nativeButton) 'The native button HWND was not found.'
    $nativeAction = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $nativeState.title; element = $nativeButton; click_count = 1; mouse_button = 'left'; click_method = 'app_post'
        windowBounds = $nativeSnapshot.windowBounds; expectedPid = [int]$nativeSnapshot.app.pid
        expectedProcessStartTimeTicks = [int64]$nativeSnapshot.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$nativeSnapshot.app.mainWindowHandle
    })
    Assert-Condition $nativeAction.ok ('Native app_post failed: ' + $nativeAction.error)
    Start-Sleep -Milliseconds 200
    $nativeAfter = Read-State $nativeTarget.StatePath
    Assert-Condition ($nativeAfter.clicks -eq 1 -and $nativeAfter.buttonDown -eq 0 -and $nativeAfter.buttonUp -eq 0) 'Native BM_CLICK counters were unexpected.'

    $explicitCoordinateButton = $nativeButton | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $explicitCoordinateX = [double]$nativeButton.frame.x + ([double]$nativeButton.frame.width / 2)
    $explicitCoordinateY = [double]$nativeButton.frame.y + ([double]$nativeButton.frame.height / 2)
    $explicitCoordinateButton.frame = $null
    $explicitCoordinateResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $nativeState.title; element = $explicitCoordinateButton; x = $explicitCoordinateX; y = $explicitCoordinateY
        click_count = 1; mouse_button = 'left'; click_method = 'app_post'; windowBounds = $nativeSnapshot.windowBounds
        expectedPid = [int]$nativeSnapshot.app.pid; expectedProcessStartTimeTicks = [int64]$nativeSnapshot.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$nativeSnapshot.app.mainWindowHandle
    })
    Assert-Condition $explicitCoordinateResult.ok ('Explicit coordinates without an element frame failed: ' + $explicitCoordinateResult.error)
    $nativeAfterExplicitCoordinate = Wait-FixtureStateCondition $nativeTarget {
        param($state)
        return $state.clicks -eq 2 -and $state.buttonDown -eq 0 -and $state.buttonUp -eq 0
    } 'explicit-coordinate native BM_CLICK'

    $outsideBefore = $nativeAfterExplicitCoordinate
    $outsideAppPost = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $nativeState.title; x = -100; y = -100; click_count = 1; mouse_button = 'left'; click_method = 'app_post'
        windowBounds = $nativeSnapshot.windowBounds; expectedPid = [int]$nativeSnapshot.app.pid
        expectedProcessStartTimeTicks = [int64]$nativeSnapshot.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$nativeSnapshot.app.mainWindowHandle
    })
    Assert-Condition ((-not $outsideAppPost.ok) -and $outsideAppPost.error -eq 'Target changed; call get_app_state again.') 'Outside-window app_post was not rejected.'
    $outsideAfter = Read-State $nativeTarget.StatePath
    Assert-Condition ($outsideAfter.clicks -eq $outsideBefore.clicks -and $outsideAfter.buttonDown -eq $outsideBefore.buttonDown -and $outsideAfter.buttonUp -eq $outsideBefore.buttonUp) 'Outside-window app_post changed native counters.'

    # -------------------------------------------------------------------------
    # Chromium/Electron core-surface section (opt-in: -IncludeChromium).
    #
    # A Chromium/Electron content area renders its own UI, so the runtime's
    # Chromium branches can only be exercised against a real browser rather than
    # against a WPF or WinForms mock. Test discipline (D1-D5,
    # research/incident-physical-pointer-hijack.md): this section injects NO
    # physical pointer or keyboard input on the default path and refuses to start
    # when the interactive-input authorizations are already present. Physical
    # pointer/keyboard injection is a supported product capability and is NOT
    # weakened here: the physical occlusion branch stays implemented and runs
    # only when the operator opts in with OCU_FIXTURE_ALLOW_PHYSICAL_POINTER=1
    # while away from the machine.
    #
    # Operator-facing notices go to stderr: stdout carries the result JSON and
    # must stay machine-parseable.
    # -------------------------------------------------------------------------
    $chromiumContentAreaOpaque = $false
    $chromiumTypeTextNewMessage = $false
    $chromiumSetValueRejected = $false
    $chromiumAppPostLanded = $false
    $chromiumGlobalOcclusionFailClosed = $false
    $chromiumGlobalPhysicalFailClosed = $null
    $chromiumCoordinateLanding = $false
    $chromiumCoordinateScale = $null
    $chromiumCoordinateAnchor = ''
    $chromiumDevicePixelRatio = $null
    $chromiumHost = ''
    $chromiumPointerWitness = ''
    $chromiumPointerWitnessNote = 'read-only GetCursorPos sample; it is evidence for a human reader, not a pass criterion, because an operator using the machine moves the cursor during any run'
    $chromiumSkipped = $false
    $chromiumSkippedReason = ''

    if ($IncludeChromium) {
        # D2 entry self-check: the default path must carry neither interactive-input
        # authorization. This constrains this section's entry only; the earlier
        # missing-frame block authorizes and restores its own two switches around an
        # injection path that its frame pre-check already rejects.
        foreach ($chromiumAuthorizationName in @('OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT', 'OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS')) {
            if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($chromiumAuthorizationName))) {
                throw ('The Chromium section refuses to start while ' + $chromiumAuthorizationName + ' is set; unset it so the default path proves that no physical input is injected.')
            }
        }
        Write-ChromiumNotice '[chromium] entry self-check passed: neither interactive-input authorization is present'

        if (-not ('OcuSmokeCursorWitness' -as [type])) {
            Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class OcuSmokeCursorWitness { [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; } [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point); public static int[] Position() { POINT point; if (!GetCursorPos(out point)) { return null; } return new int[] { point.X, point.Y }; } } public static class OcuSmokePointOwner { [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; } [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point); [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int processId); public static int OwnerPid(int x, int y) { POINT point; point.X = x; point.Y = y; IntPtr hWnd = WindowFromPoint(point); if (hWnd == IntPtr.Zero) { return 0; } int processId; GetWindowThreadProcessId(hWnd, out processId); return processId; } }'
        }
        $chromiumWitnessBefore = Get-InteractiveCursorWitness

        $chromiumBrowserResolved = ''
        foreach ($chromiumCandidate in (Get-ChromiumBrowserCandidates $ChromiumBrowserPath)) {
            if (Test-Path -LiteralPath $chromiumCandidate -PathType Leaf) {
                $chromiumBrowserResolved = (Resolve-Path -LiteralPath $chromiumCandidate).Path
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($chromiumBrowserResolved)) {
            # No browser: skip, never fail. The runtime is untested here, so every
            # Chromium result key stays false/empty instead of claiming a pass.
            $chromiumSkipped = $true
            if (-not [string]::IsNullOrWhiteSpace($ChromiumBrowserPath)) {
                $chromiumHost = $ChromiumBrowserPath
                $chromiumSkippedReason = 'the requested -ChromiumBrowserPath does not exist: ' + $ChromiumBrowserPath
            } else {
                $chromiumHost = 'none'
                $chromiumSkippedReason = 'no Chromium-family browser found under Program Files or Program Files (x86); pass -ChromiumBrowserPath <chrome.exe|msedge.exe>'
            }
            Write-ChromiumNotice ('[chromium] SKIPPED: ' + $chromiumSkippedReason)
        } else {
            $chromiumHost = $chromiumBrowserResolved
            Write-ChromiumNotice ('[chromium] host: ' + $chromiumHost)

            $chromiumFixtureArguments = @('-BrowserPath', $chromiumBrowserResolved)
            if ($ChromiumRendererAccessibility) { $chromiumFixtureArguments += '-RendererAccessibility' }
            # Placed below the WPF A fixture (20,20) and beside the native fixture
            # (1120,0) so the three windows stay visually separable; nothing here
            # depends on z-order. The instance tag is per-run and leftovers are swept
            # first: a fixed tag would let a stale browser window from an earlier run be
            # mistaken for this one by the title-based snapshot resolution above.
            [void](Remove-StaleChromiumFixtureBrowsers)
            $chromiumTarget = Start-Fixture 'chromium-test-page.ps1' ('Chromium-' + $PID) 40 760 $script:FixtureHostPathResolved $false $chromiumFixtureArguments
            $chromiumState = Wait-FixtureReady $chromiumTarget 60
            $chromiumState = Wait-FixtureStateCondition $chromiumTarget {
                param($state)
                return ($null -ne $state.geometry) -and ($null -ne $state.geometry.clickTarget) -and ($null -ne $state.devicePixelRatio)
            } 'Chromium page geometry'
            $chromiumSnapshot = Get-Snapshot $chromiumState.title
            Assert-Condition ($null -ne $chromiumSnapshot.app -and $chromiumSnapshot.app.pid -eq $chromiumState.pid -and $chromiumSnapshot.app.mainWindowHandle -eq $chromiumState.hwnd) 'The Chromium snapshot did not retain its fixture identity.'
            # The fixture's own state bounds and the runtime's windowBounds can legitimately
            # disagree (measured: fixture 40,760 x 900x680 against runtime 90,1710 x
            # 2025x1530), so their relationship is recorded as a measurement instead of
            # asserted. What must hold is that the runtime reported a usable rectangle,
            # because every point in this section is expressed relative to it.
            Assert-Condition ([double]$chromiumSnapshot.windowBounds.width -gt 0 -and [double]$chromiumSnapshot.windowBounds.height -gt 0) 'The Chromium snapshot reported no usable window bounds.'
            $chromiumSpaceShared = ([math]::Abs([double]$chromiumSnapshot.windowBounds.x - [double]$chromiumState.bounds.x) -le 1 -and [math]::Abs([double]$chromiumSnapshot.windowBounds.y - [double]$chromiumState.bounds.y) -le 1 -and [math]::Abs([double]$chromiumSnapshot.windowBounds.width - [double]$chromiumState.bounds.width) -le 1 -and [math]::Abs([double]$chromiumSnapshot.windowBounds.height - [double]$chromiumState.bounds.height) -le 1)
            Write-ChromiumNotice ('[chromium] fixtureBounds=' + $chromiumState.bounds.x + ',' + $chromiumState.bounds.y + ' ' + $chromiumState.bounds.width + 'x' + $chromiumState.bounds.height + ' runtimeWindowBounds=' + $chromiumSnapshot.windowBounds.x + ',' + $chromiumSnapshot.windowBounds.y + ' ' + $chromiumSnapshot.windowBounds.width + 'x' + $chromiumSnapshot.windowBounds.height + ' sharedSpace=' + $chromiumSpaceShared)
            $chromiumDevicePixelRatio = [double]$chromiumState.devicePixelRatio
            Write-ChromiumNotice ('[chromium] elementCount=' + @($chromiumSnapshot.elements).Count + ' devicePixelRatio=' + $chromiumDevicePixelRatio + ' clientOrigin=' + $chromiumState.clientOrigin.x + ',' + $chromiumState.clientOrigin.y + ' bounds=' + $chromiumState.bounds.x + ',' + $chromiumState.bounds.y)

            # Assertion 1 (chromiumContentAreaOpaque): a Chromium content area contributes
            # NO node that an element-targeted action could reach. Criterion, where any
            # single clause below is enough to fail:
            #   1. an element whose name carries one of the page's own control texts
            #      ('click target' / 'text input'); and
            #   2. a content-control type (Edit / Document) that carries a frame. The
            #      omnibox Edit the browser itself exposes has no frame, while the page's
            #      own <input> arrives framed once the renderer tree is published.
            # '-ChromiumRendererAccessibility' forces that renderer tree on, which is the
            # falsification switch: the same criterion must then turn false.
            $chromiumOpaqueViolations = New-Object System.Collections.Generic.List[string]
            foreach ($chromiumElement in @($chromiumSnapshot.elements)) {
                $chromiumElementName = [string]$chromiumElement.name
                $chromiumElementControlType = [string]$chromiumElement.controlType
                if ($chromiumElementName -match '(?i)click target|text input') {
                    [void]$chromiumOpaqueViolations.Add('page-control-text:' + $chromiumElementControlType + ':' + $chromiumElementName)
                }
                $chromiumElementHasFrame = ($null -ne $chromiumElement.frame -and [double]$chromiumElement.frame.width -gt 0 -and [double]$chromiumElement.frame.height -gt 0)
                if ($chromiumElementHasFrame -and ($chromiumElementControlType -eq 'ControlType.Edit' -or $chromiumElementControlType -eq 'ControlType.Document')) {
                    [void]$chromiumOpaqueViolations.Add('framed-content-control:' + $chromiumElementControlType)
                }
            }
            $chromiumContentAreaOpaque = ($chromiumOpaqueViolations.Count -eq 0)
            # A control-type census is emitted so a criterion that is too weak is
            # diagnosable from the log alone, including on the falsification run
            # (-ChromiumRendererAccessibility), where the renderer tree appears.
            $chromiumControlTypeCensus = @($chromiumSnapshot.elements | Group-Object controlType | Sort-Object Name | ForEach-Object { $_.Name + ':' + $_.Count }) -join ','
            Write-ChromiumNotice ('[chromium] contentAreaOpaque=' + $chromiumContentAreaOpaque + ' violations=' + $chromiumOpaqueViolations.Count + ' controlTypes=' + $chromiumControlTypeCensus)
            Assert-Condition $chromiumContentAreaOpaque ('The Chromium content area contributed addressable nodes: ' + ($chromiumOpaqueViolations -join '; '))

            # Assertion 2 (chromiumTypeTextNewMessage): no writable text control owned by
            # the browser process is focused, so type_text must return the exact bounded
            # message. Test-TypeTextTargetResponse holds the one literal this repository
            # compares against, so matching through it is byte-for-byte.
            $chromiumTypeTextResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'type_text'; app = $chromiumState.title; text = 'must-not-type'
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            $chromiumTypeTextNewMessage = Test-TypeTextTargetResponse $chromiumTypeTextResponse
            Write-ChromiumNotice ('[chromium] type_text errorBytes=' + [System.Text.Encoding]::UTF8.GetByteCount([string]$chromiumTypeTextResponse.error) + ' exactMatch=' + $chromiumTypeTextNewMessage)
            Assert-Condition $chromiumTypeTextNewMessage ('type_text on the Chromium content area did not return the bounded message: ' + $chromiumTypeTextResponse.error)

            # Assertion 3 (chromiumSetValueRejected): set_value must refuse a real
            # non-settable window element with no side effect on the page, and a bare
            # legacy element index must still be rejected as an expired target.
            $chromiumSetValueWindowElement = @($chromiumSnapshot.elements)[0]
            Assert-Condition ($null -ne $chromiumSetValueWindowElement -and -not ($chromiumSetValueWindowElement.actions -contains 'SetValue')) 'The first Chromium element was not a non-settable window element.'
            $chromiumSetValueBaseline = Read-State $chromiumTarget.StatePath
            $chromiumNotSettableResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'set_value'; app = $chromiumState.title; element = $chromiumSetValueWindowElement; value = 'must-not-write'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            $chromiumLegacyIndexResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'set_value'; app = $chromiumState.title; element_index = 0; value = 'must-not-write'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Start-Sleep -Milliseconds 500
            $chromiumSetValueAfter = Read-State $chromiumTarget.StatePath
            $chromiumSetValueRejected = (
                (-not $chromiumNotSettableResponse.ok) -and
                $chromiumNotSettableResponse.error -eq 'Cannot set a value for an element that is not settable' -and
                (Test-TargetChangedResponse $chromiumLegacyIndexResponse) -and
                [int]$chromiumSetValueAfter.inputEvents -eq [int]$chromiumSetValueBaseline.inputEvents
            )
            Write-ChromiumNotice ('[chromium] setValue element="' + $chromiumNotSettableResponse.error + '" legacyIndex="' + $chromiumLegacyIndexResponse.error + '" inputEvents=' + $chromiumSetValueBaseline.inputEvents + '->' + $chromiumSetValueAfter.inputEvents)
            Assert-Condition $chromiumSetValueRejected 'set_value against the Chromium content area was not rejected without side effects.'

            # --- Coordinate space (measured, not assumed) -------------------------
            # The fixture process and the runtime need not report the same coordinate
            # space, and which space the runtime reports can differ between runs
            # (measured: one run where the fixture state said bounds 40,760 x 900x680
            # while the runtime snapshot said 90,1710 x 2025x1530). Mixing the two
            # spaces pushed the effective click point off the physical screen and the
            # runtime rejected it as "Target changed". Every point below is therefore
            # built ONLY from $chromiumSnapshot.windowBounds, because that is the value
            # the runtime itself adds to explicit x/y (Get-ScreenPoint) before it
            # delivers input. The fixture state contributes only page-reported
            # quantities (CSS rectangles, devicePixelRatio, counters), never an origin.
            $chromiumGeometry = Get-ChromiumTargetGeometry $chromiumState
            $chromiumCentreRelX = [double]$chromiumSnapshot.windowBounds.width / 3.0
            $chromiumCentreRelY = [double]$chromiumSnapshot.windowBounds.height / 3.0

            # Calibration probe A: send the window centre, which is inside the content
            # area, and read back where the page says the click landed. The answer is
            # usable whether the click hit the target (a click sample) or only the page
            # (a document-click sample): both report clientX/clientY. The anchor is the
            # page's client-space origin in runtime units relative to windowBounds:
            # anchor = rel - reported x dpr.
            $chromiumProbeBaseline = Read-State $chromiumTarget.StatePath
            $chromiumProbeResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $chromiumState.title; x = $chromiumCentreRelX; y = $chromiumCentreRelY
                click_count = 1; mouse_button = 'left'; click_method = 'app_post'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Assert-Condition $chromiumProbeResponse.ok ('Chromium coordinate calibration probe failed: ' + $chromiumProbeResponse.error)
            $chromiumProbeSample = Wait-ChromiumPointSample $chromiumTarget ([int]$chromiumProbeBaseline.clicks) ([int]$chromiumProbeBaseline.documentClicks) 'Chromium coordinate calibration probe'
            $chromiumAnchorX = $chromiumCentreRelX - ($chromiumProbeSample.x * $chromiumGeometry.devicePixelRatio)
            $chromiumAnchorY = $chromiumCentreRelY - ($chromiumProbeSample.y * $chromiumGeometry.devicePixelRatio)
            $chromiumCoordinateAnchor = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2},{1:F2}', $chromiumAnchorX, $chromiumAnchorY) + ' runtime-units-relative-to-snapshot.windowBounds'

            # Calibration probe B turns the assumed devicePixelRatio into a measurement:
            # the same origin plus a known runtime-unit offset must move the page's
            # reported point by that offset divided by the scale. A scale near
            # devicePixelRatio means one runtime unit is one physical pixel; a scale near
            # 1 would mean the runtime is already reporting CSS-scaled units, which this
            # assertion makes visible instead of silently mis-landing.
            $chromiumScaleOffset = 120.0
            $chromiumScaleBaseline = Read-State $chromiumTarget.StatePath
            $chromiumScaleResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $chromiumState.title; x = ($chromiumCentreRelX + $chromiumScaleOffset); y = ($chromiumCentreRelY + $chromiumScaleOffset)
                click_count = 1; mouse_button = 'left'; click_method = 'app_post'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Assert-Condition $chromiumScaleResponse.ok ('Chromium coordinate scale probe failed: ' + $chromiumScaleResponse.error)
            $chromiumScaleSample = Wait-ChromiumPointSample $chromiumTarget ([int]$chromiumScaleBaseline.clicks) ([int]$chromiumScaleBaseline.documentClicks) 'Chromium coordinate scale probe'
            $chromiumScaleX = $chromiumScaleOffset / ($chromiumScaleSample.x - $chromiumProbeSample.x)
            $chromiumScaleY = $chromiumScaleOffset / ($chromiumScaleSample.y - $chromiumProbeSample.y)
            $chromiumCoordinateScale = ($chromiumScaleX + $chromiumScaleY) / 2.0
            $chromiumCoordinateScaleMatched = ([math]::Abs($chromiumCoordinateScale - $chromiumGeometry.devicePixelRatio) -le 0.1)
            Write-ChromiumNotice ('[chromium] probe=' + $chromiumProbeSample.kind + ':' + $chromiumProbeSample.x + ',' + $chromiumProbeSample.y + ' scaled=' + $chromiumScaleSample.kind + ':' + $chromiumScaleSample.x + ',' + $chromiumScaleSample.y + ' anchor=' + $chromiumCoordinateAnchor + ' scale=' + [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F4}', $chromiumCoordinateScale) + ' dpr=' + $chromiumGeometry.devicePixelRatio)
            Assert-Condition $chromiumCoordinateScaleMatched ('The measured coordinate scale did not match the page devicePixelRatio: scale=' + $chromiumCoordinateScale + ' dpr=' + $chromiumGeometry.devicePixelRatio)

            # Landing point: the page's target centre mapped back through the anchor.
            $chromiumTargetRelX = $chromiumAnchorX + ($chromiumGeometry.centerCssX * $chromiumGeometry.devicePixelRatio)
            $chromiumTargetRelY = $chromiumAnchorY + ($chromiumGeometry.centerCssY * $chromiumGeometry.devicePixelRatio)

            # Assertion 4 (chromiumAppPostLanded): with explicit coordinates,
            # click_method 'app_post' must land on the page target through the
            # window-message path (no pointer motion), and 'auto' must reproduce it.
            # The WPF-only app_post capability error must NOT be expected here: Chromium
            # is a native HWND target, so a landed click is the observable result.
            $chromiumAppPostBaseline = Read-State $chromiumTarget.StatePath
            $chromiumAppPostResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $chromiumState.title; x = $chromiumTargetRelX; y = $chromiumTargetRelY
                click_count = 1; mouse_button = 'left'; click_method = 'app_post'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Assert-Condition $chromiumAppPostResponse.ok ('Chromium app_post click failed: ' + $chromiumAppPostResponse.error)
            $chromiumAppPostSample = Wait-ChromiumPointSample $chromiumTarget ([int]$chromiumAppPostBaseline.clicks) ([int]$chromiumAppPostBaseline.documentClicks) 'Chromium app_post landing'
            $chromiumAppPostLanded = (
                $chromiumAppPostResponse.ok -and
                [int]$chromiumAppPostSample.state.clicks -eq ([int]$chromiumAppPostBaseline.clicks + 1) -and
                $chromiumAppPostSample.kind -eq 'click' -and
                $chromiumAppPostSample.target -eq '#click-target'
            )
            Write-ChromiumNotice ('[chromium] appPost clicks=' + $chromiumAppPostBaseline.clicks + '->' + $chromiumAppPostSample.state.clicks + ' kind=' + $chromiumAppPostSample.kind + ' target=' + $chromiumAppPostSample.target + ' reported=' + $chromiumAppPostSample.x + ',' + $chromiumAppPostSample.y)
            Assert-Condition $chromiumAppPostLanded ('Chromium app_post did not land on the page target: kind=' + $chromiumAppPostSample.kind + ' target=' + $chromiumAppPostSample.target + ' reported=' + $chromiumAppPostSample.x + ',' + $chromiumAppPostSample.y)

            $chromiumAutoBaseline = $chromiumAppPostSample.state
            $chromiumAutoResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $chromiumState.title; x = $chromiumTargetRelX; y = $chromiumTargetRelY
                click_count = 1; mouse_button = 'left'; click_method = 'auto'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Assert-Condition $chromiumAutoResponse.ok ('Chromium auto click failed: ' + $chromiumAutoResponse.error)
            $chromiumAutoSample = Wait-ChromiumPointSample $chromiumTarget ([int]$chromiumAutoBaseline.clicks) ([int]$chromiumAutoBaseline.documentClicks) 'Chromium auto landing'
            # Both non-physical methods must land; the single key reports the pair.
            $chromiumAppPostLanded = (
                $chromiumAppPostLanded -and
                $chromiumAutoResponse.ok -and
                [int]$chromiumAutoSample.state.clicks -eq ([int]$chromiumAutoBaseline.clicks + 1) -and
                $chromiumAutoSample.kind -eq 'click' -and
                $chromiumAutoSample.target -eq '#click-target'
            )
            Write-ChromiumNotice ('[chromium] auto clicks=' + $chromiumAutoBaseline.clicks + '->' + $chromiumAutoSample.state.clicks + ' kind=' + $chromiumAutoSample.kind + ' target=' + $chromiumAutoSample.target + ' reported=' + $chromiumAutoSample.x + ',' + $chromiumAutoSample.y)
            Assert-Condition $chromiumAppPostLanded ('Chromium auto did not land on the page target: kind=' + $chromiumAutoSample.kind + ' target=' + $chromiumAutoSample.target + ' reported=' + $chromiumAutoSample.x + ',' + $chromiumAutoSample.y)

            # Assertion 6 (chromiumCoordinateLanding): the anchored point must land on
            # the target, and the page's reported point must match the target centre the
            # page reports for that click, within a tightened tolerance. The reported
            # client point is an integer, so the aim is compared against the rectangle
            # the page reports at that moment, not against the one probed earlier.
            $chromiumLandingBaseline = $chromiumAutoSample.state
            $chromiumLandingResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $chromiumState.title; x = $chromiumTargetRelX; y = $chromiumTargetRelY
                click_count = 1; mouse_button = 'left'; click_method = 'app_post'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Assert-Condition $chromiumLandingResponse.ok ('Chromium calibrated coordinate click failed: ' + $chromiumLandingResponse.error)
            $chromiumLandingSample = Wait-ChromiumPointSample $chromiumTarget ([int]$chromiumLandingBaseline.clicks) ([int]$chromiumLandingBaseline.documentClicks) 'Chromium calibrated coordinate landing'
            $chromiumLandingRect = $chromiumLandingSample.state.geometry.clickTarget
            $chromiumLandingCentreCssX = [double]$chromiumLandingRect.x + ([double]$chromiumLandingRect.width / 2.0)
            $chromiumLandingCentreCssY = [double]$chromiumLandingRect.y + ([double]$chromiumLandingRect.height / 2.0)
            # Four CSS pixels: the reported point is an integer, the sent point is rounded
            # to whole runtime units, and the anchor comes from one integer sample, so a
            # couple of CSS pixels of residual error are expected. A wrong scale or a
            # wrong anchor misses by far more than this.
            $chromiumCoordinateTolerance = 4.0
            $chromiumCoordinateLanding = (
                $chromiumLandingResponse.ok -and
                $chromiumLandingSample.kind -eq 'click' -and
                $chromiumLandingSample.target -eq '#click-target' -and
                [math]::Abs($chromiumLandingSample.x - $chromiumLandingCentreCssX) -le $chromiumCoordinateTolerance -and
                [math]::Abs($chromiumLandingSample.y - $chromiumLandingCentreCssY) -le $chromiumCoordinateTolerance
            )
            Write-ChromiumNotice ('[chromium] calibrated rel=' + [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2},{1:F2}', $chromiumTargetRelX, $chromiumTargetRelY) + ' reported=' + $chromiumLandingSample.x + ',' + $chromiumLandingSample.y + ' centre=' + [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F2},{1:F2}', $chromiumLandingCentreCssX, $chromiumLandingCentreCssY) + ' inCentre=' + $chromiumCoordinateLanding)
            Assert-Condition $chromiumCoordinateLanding ('The calibrated Chromium click did not land on the reported target centre: kind=' + $chromiumLandingSample.kind + ' reported=' + $chromiumLandingSample.x + ',' + $chromiumLandingSample.y + ' centre=' + $chromiumLandingCentreCssX + ',' + $chromiumLandingCentreCssY)

            # Assertion 5a (chromiumGlobalOcclusionFailClosed): unauthorized global
            # pointer input must be refused before any injection, and the page must
            # not observe a click. No occlusion window is built here: with the
            # authorization absent the refusal happens before any occlusion
            # evaluation, so occlusion cannot change the outcome. Occlusion semantics
            # belong to the opt-in physical branch in 5b.
            $chromiumClicksBeforeGlobal = [int](Read-State $chromiumTarget.StatePath).clicks
            $chromiumUnauthorizedGlobalResponse = Invoke-Runtime ([pscustomobject]@{
                tool = 'click'; app = $chromiumState.title; x = $chromiumTargetRelX; y = $chromiumTargetRelY
                click_count = 1; mouse_button = 'left'; click_method = 'global'
                windowBounds = $chromiumSnapshot.windowBounds
                expectedPid = [int]$chromiumSnapshot.app.pid
                expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
            })
            Start-Sleep -Milliseconds 400
            $chromiumAfterGlobal = Read-State $chromiumTarget.StatePath
            $chromiumGlobalOcclusionFailClosed = (
                (-not $chromiumUnauthorizedGlobalResponse.ok) -and
                [string]$chromiumUnauthorizedGlobalResponse.error -like '*Interactive Windows input is disabled by default*' -and
                [int]$chromiumAfterGlobal.clicks -eq $chromiumClicksBeforeGlobal
            )
            Write-ChromiumNotice ('[chromium] global error="' + $chromiumUnauthorizedGlobalResponse.error + '" clicks=' + $chromiumClicksBeforeGlobal + '->' + $chromiumAfterGlobal.clicks)
            Assert-Condition $chromiumGlobalOcclusionFailClosed 'Unauthorized global click on the Chromium target was not refused without side effects.'

            # Assertion 5b (chromiumGlobalPhysicalFailClosed): physical pointer branch.
            # IMPLEMENTED, NOT RUN BY DEFAULT. Only the operator may enable it, and only
            # while away from the machine: this branch really moves the system pointer
            # and can take foreground focus, because that is what the product's
            # physical-input path does. It covers the target point with an unrelated
            # window and proves the physical path fails closed on occlusion without
            # moving the pointer.
            if ([Environment]::GetEnvironmentVariable('OCU_FIXTURE_ALLOW_PHYSICAL_POINTER') -eq '1') {
                # The point to cover is expressed in the runtime's space, like every
                # other point in this section, and the cover is placed from the same
                # value. The read-only owner check below then decides whether the cover
                # really owns that point: if the fixture host and the runtime disagree
                # about the coordinate space, the cover lands elsewhere, the check fails
                # and the branch refuses to inject rather than clicking into whatever is
                # actually there.
                $chromiumPhysicalPointX = [double]$chromiumSnapshot.windowBounds.x + $chromiumTargetRelX
                $chromiumPhysicalPointY = [double]$chromiumSnapshot.windowBounds.y + $chromiumTargetRelY
                $chromiumCoverLeft = [int][math]::Round($chromiumPhysicalPointX - 120)
                $chromiumCoverTop = [int][math]::Round($chromiumPhysicalPointY - 120)
                $chromiumCoverTarget = Start-Fixture 'wpf-test-bench.ps1' 'ChromiumCover' $chromiumCoverLeft $chromiumCoverTop $script:FixtureHostPathResolved
                $chromiumCoverState = Wait-FixtureReady $chromiumCoverTarget
                # Cover the exact target point and raise the cover above the browser.
                # SWP_NOZORDER must be absent here or HWND_TOPMOST would be ignored and
                # the "occluded" click would land on the browser instead of failing
                # closed. SWP_NOACTIVATE keeps the cover from taking foreground.
                [void][OcuSmokeWindow]::SetWindowPos([IntPtr]$chromiumCoverState.hwnd, [IntPtr](-1), $chromiumCoverLeft, $chromiumCoverTop, 900, 680, 0x0001 -bor 0x0002 -bor 0x0010 -bor 0x0040)
                Start-Sleep -Milliseconds 300
                # Read-only proof that the cover owns the point. Without it the branch
                # could inject a real click into whatever window happens to be there,
                # which is exactly the accident this opt-in exists to prevent.
                $chromiumCoverOwner = [OcuSmokePointOwner]::OwnerPid([int][math]::Round($chromiumPhysicalPointX), [int][math]::Round($chromiumPhysicalPointY))
                Assert-Condition ($chromiumCoverOwner -eq [int]$chromiumCoverState.pid) ('The cover window does not own the target point (owner pid ' + $chromiumCoverOwner + '), so the physical branch refuses to inject.')
                $chromiumPhysicalPointerBefore = Get-InteractiveCursorWitness
                $chromiumPhysicalClicksBefore = [int](Read-State $chromiumTarget.StatePath).clicks
                $chromiumPhysicalEnvironmentNames = @('OPEN_COMPUTER_USE_WINDOWS_ALLOW_FOREGROUND_INPUT', 'OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS')
                $chromiumSavedPhysicalEnvironment = @{}
                foreach ($chromiumEnvironmentName in $chromiumPhysicalEnvironmentNames) {
                    $chromiumSavedPhysicalEnvironment[$chromiumEnvironmentName] = [Environment]::GetEnvironmentVariable($chromiumEnvironmentName)
                    Set-Item -Path ('Env:' + $chromiumEnvironmentName) -Value '1'
                }
                try {
                    $chromiumPhysicalResponse = Invoke-Runtime ([pscustomobject]@{
                        tool = 'click'; app = $chromiumState.title; x = $chromiumTargetRelX; y = $chromiumTargetRelY
                        click_count = 1; mouse_button = 'left'; click_method = 'global'
                        windowBounds = $chromiumSnapshot.windowBounds
                        expectedPid = [int]$chromiumSnapshot.app.pid
                        expectedProcessStartTimeTicks = [int64]$chromiumSnapshot.app.processStartTimeTicks
                        expectedMainWindowHandle = [int64]$chromiumSnapshot.app.mainWindowHandle
                    })
                    Start-Sleep -Milliseconds 400
                    $chromiumPhysicalAfter = Read-State $chromiumTarget.StatePath
                    $chromiumPhysicalPointerAfter = Get-InteractiveCursorWitness
                    $chromiumGlobalPhysicalFailClosed = (
                        (-not $chromiumPhysicalResponse.ok) -and
                        [string]$chromiumPhysicalResponse.error -like '*is not the topmost descendant of the snapshot window at the requested pointer coordinates*' -and
                        [int]$chromiumPhysicalAfter.clicks -eq $chromiumPhysicalClicksBefore -and
                        $chromiumPhysicalPointerAfter -eq $chromiumPhysicalPointerBefore
                    )
                    Write-ChromiumNotice ('[chromium] physical global error="' + $chromiumPhysicalResponse.error + '" clicks=' + $chromiumPhysicalClicksBefore + '->' + $chromiumPhysicalAfter.clicks + ' pointer=' + $chromiumPhysicalPointerBefore + '->' + $chromiumPhysicalPointerAfter)
                    Assert-Condition $chromiumGlobalPhysicalFailClosed 'The occluded physical click did not fail closed without moving the pointer.'
                } finally {
                    Restore-ProcessEnvironment $chromiumSavedPhysicalEnvironment $chromiumPhysicalEnvironmentNames
                    if ($null -ne $chromiumCoverTarget.Process -and -not $chromiumCoverTarget.Process.HasExited) {
                        try {
                            [void]$chromiumCoverTarget.Process.Kill()
                            [void]$chromiumCoverTarget.Process.WaitForExit(5000)
                        } catch {
                        }
                    }
                }
            } else {
                Write-ChromiumNotice '[chromium] 5b SKIPPED: 此段会真实移动你的鼠标（物理遮挡 fail-closed 用例）。请在离开电脑时设置 OCU_FIXTURE_ALLOW_PHYSICAL_POINTER=1 再运行。'
                $chromiumGlobalPhysicalFailClosed = $null
            }
        }

        $chromiumPointerWitness = $chromiumWitnessBefore + '->' + (Get-InteractiveCursorWitness)
        Write-ChromiumNotice ('[chromium] cursor witness (read-only, not a pass criterion): ' + $chromiumPointerWitness)
    }

    $originalIdentityRuntimeId = Get-RuntimeIdKey $identityElementA
    $replacementRuntimeIdA = Get-RuntimeIdKey $replacement.records[0]
    $replacementRuntimeIdB = Get-RuntimeIdKey $replacement.records[1]
    $replacementRuntimeIdsDistinct = (
        $replacement.records.Count -eq 2 -and
        -not [string]::IsNullOrWhiteSpace($replacementRuntimeIdA) -and
        -not [string]::IsNullOrWhiteSpace($replacementRuntimeIdB) -and
        $replacementRuntimeIdA -ne $replacementRuntimeIdB -and
        $replacementRuntimeIdA -ne $originalIdentityRuntimeId -and
        $replacementRuntimeIdB -ne $originalIdentityRuntimeId
    )
    $duplicateMetadataAddressedIndependently = (
        $addressedPrimaryResult.ok -and
        $addressedDuplicateResult.ok -and
        $afterAddressedDuplicate.identityPrimaryValue -eq $addressedPrimaryValue -and
        $afterAddressedDuplicate.identityDuplicateValue -eq $addressedDuplicateValue
    )
    $allStaleElementTargetedActionsRejected = (
        (Test-TargetChangedResponse $staleClickAccessibilityResult) -and
        (Test-TargetChangedResponse $staleClickAppPostResult) -and
        (Test-TargetChangedResponse $staleClickGlobalResult) -and
        (Test-TargetChangedResponse $staleClickAutoResult) -and
        (Test-TargetChangedResponse $staleSecondaryResult) -and
        (Test-TargetChangedResponse $staleScrollResult) -and
        (Test-TargetChangedResponse $staleElementResult)
    )
    $missingFrameClickRejected = (
        (Test-MissingClickFrameResponse $missingClickResults['auto']) -and
        (Test-MissingClickFrameResponse $missingClickResults['app_post']) -and
        (Test-MissingClickFrameResponse $missingClickResults['global'])
    )
    $validFrameAutoClick = (
        $autoCompatibilityResult.ok -and
        $afterAutoCompatibility.auto -eq ($beforeAutoCompatibility.auto + 1)
    )
    $semanticClickWithoutFrame = (
        $semanticClickWithoutFrameResult.ok -and
        $afterSemanticClick.accessibility -eq ($beforeSemanticClick.accessibility + 1)
    )
    $explicitCoordinateClickAccepted = (
        $explicitCoordinateResult.ok -and
        $nativeAfterExplicitCoordinate.clicks -eq 2 -and
        $nativeAfterExplicitCoordinate.buttonDown -eq 0 -and
        $nativeAfterExplicitCoordinate.buttonUp -eq 0
    )
    $identityPinned = (
        $addressedPrimaryResult.ok -and
        $addressedDuplicateResult.ok -and
        $afterAddressedDuplicate.identityPrimaryValue -eq $addressedPrimaryValue -and
        $afterAddressedDuplicate.identityDuplicateValue -eq $addressedDuplicateValue
    )
    $crossQueryRejected = (
        (Test-TargetChangedResponse $crossResult) -and
        $afterCrossA.setValue -eq $baselineCrossA.setValue -and
        $afterCrossB.setValue -eq $baselineB.setValue
    )
    $mismatchRejected = (
        (Test-TargetChangedResponse $badResult) -and
        $afterBadA.setValue -eq $afterCrossA.setValue -and
        $afterBadB.setValue -eq $afterCrossB.setValue
    )
    $staleBoundsRejected = Test-TargetChangedResponse $staleResult
    $emptyRuntimeIdRejected = (
        (Test-TargetChangedResponse $emptyRuntimeIdResult) -and
        $afterEmptyRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterEmptyRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterEmptyRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue
    )
    $missingRuntimeIdRejected = (
        (Test-TargetChangedResponse $missingRuntimeIdResult) -and
        $afterMissingRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterMissingRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterMissingRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue
    )
    $malformedRuntimeIdRejected = (
        (Test-TargetChangedResponse $nullMemberRuntimeIdResult) -and
        (Test-TargetChangedResponse $blankRuntimeIdResult) -and
        (Test-TargetChangedResponse $fractionalRuntimeIdResult) -and
        (Test-TargetChangedResponse $outOfRangeRuntimeIdResult) -and
        (Test-TargetChangedResponse $negativeOutOfRangeRuntimeIdResult) -and
        (Test-TargetChangedResponse $malformedRuntimeIdResult) -and
        $afterNullMemberRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterNullMemberRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterNullMemberRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue -and
        $afterBlankRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterBlankRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterBlankRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue -and
        $afterFractionalRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterFractionalRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterFractionalRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue -and
        $afterOutOfRangeRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterOutOfRangeRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterOutOfRangeRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue -and
        $afterNegativeOutOfRangeRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterNegativeOutOfRangeRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterNegativeOutOfRangeRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue -and
        $afterMalformedRuntimeId.setValue -eq $identityBaseline.setValue -and
        $afterMalformedRuntimeId.identityPrimaryValue -eq $identityBaseline.identityPrimaryValue -and
        $afterMalformedRuntimeId.identityDuplicateValue -eq $identityBaseline.identityDuplicateValue
    )
    $semanticScrollWithoutFrame = (
        $semanticScrollResult.ok -and
        $afterSemanticScroll.scrollEvents -gt $beforeSemanticScroll.scrollEvents
    )
    $validFrameScrollFallback = $validFallbackResult.ok
    $invalidScrollFramesRejected = (
        (-not $missingFrameResult.ok) -and
        $missingFrameResult.error -like 'Scroll requires an element with a valid frame when ScrollPattern is unavailable.*' -and
        (-not $zeroWidthFrameResult.ok) -and
        $zeroWidthFrameResult.error -like 'Scroll requires an element with a valid frame when ScrollPattern is unavailable.*' -and
        $afterInvalidScrollFrame.scrollEvents -eq $beforeInvalidScrollFrame.scrollEvents
    )
    $unauthorizedGlobalAndKeyboardRejected = (
        (-not $globalDenied.ok) -and
        $globalDenied.error -like '*Interactive Windows input is disabled by default*' -and
        (-not $keyDenied.ok) -and
        $keyDenied.error -like '*Interactive Windows keyboard input is disabled by default*' -and
        $beforeKey.eventCount -eq $afterKey.eventCount
    )
    $wpfAppPostCapabilityError = (
        (-not $wpfAppPost.ok) -and
        $wpfAppPost.error -like '*native HWND*'
    )
    $nativeOutsideAppPostRejected = (
        (Test-TargetChangedResponse $outsideAppPost) -and
        $outsideAfter.clicks -eq $outsideBefore.clicks -and
        $outsideAfter.buttonDown -eq $outsideBefore.buttonDown -and
        $outsideAfter.buttonUp -eq $outsideBefore.buttonUp
    )
    $nativeBmClickVerified = (
        $nativeAction.ok -and
        $nativeAfter.clicks -eq 1 -and
        $nativeAfter.buttonDown -eq 0 -and
        $nativeAfter.buttonUp -eq 0
    )
    $allReportedChecksPassed = @(
        $identityPinned,
        $crossQueryRejected,
        $screenshotCaptureBounded,
        $offscreenProxyRejected,
        $identityValidationPassed,
        $numericValidationPassed,
        $mismatchRejected,
        $staleBoundsRejected,
        $focusedTypeTextAccepted,
        $nonEditableTypeTextRejected,
        $duplicateFocusedTypeTextIsolated,
        $outsideWindowTypeTextRejected,
        $disabledUIATextFallbackRejected,
        $nativeFocusedTypeTextAccepted,
        $missingFrameClickRejected,
        $validFrameAutoClick,
        $semanticClickWithoutFrame,
        $explicitCoordinateClickAccepted,
        $emptyRuntimeIdRejected,
        $missingRuntimeIdRejected,
        $malformedRuntimeIdRejected,
        $replacementRuntimeIdsDistinct,
        $duplicateMetadataAddressedIndependently,
        $allStaleElementTargetedActionsRejected,
        $semanticScrollWithoutFrame,
        $validFrameScrollFallback,
        $invalidScrollFramesRejected,
        $unauthorizedGlobalAndKeyboardRejected,
        $wpfAppPostCapabilityError,
        $nativeOutsideAppPostRejected,
        $nativeBmClickVerified
    ) -notcontains $false
    if ($IncludeChromium -and -not $chromiumSkipped) {
        # Only the non-skipped Chromium section can contribute a pass/fail; a skipped
        # section (no browser) leaves the six flags false without failing the run.
        $chromiumReportedChecks = @(
            $chromiumContentAreaOpaque,
            $chromiumTypeTextNewMessage,
            $chromiumSetValueRejected,
            $chromiumAppPostLanded,
            $chromiumGlobalOcclusionFailClosed,
            $chromiumCoordinateLanding,
            $chromiumCoordinateScaleMatched
        )
        # The opt-in physical branch participates only when the operator ran it.
        if ($null -ne $chromiumGlobalPhysicalFailClosed) {
            $chromiumReportedChecks += $chromiumGlobalPhysicalFailClosed
        }
        $allReportedChecksPassed = $allReportedChecksPassed -and (($chromiumReportedChecks -notcontains $false) -and ($chromiumReportedChecks -notcontains $null))
    }
    Assert-Condition $allReportedChecksPassed 'One or more computed smoke result flags did not pass.'

    $artifactReference = $null
    if ($KeepArtifacts) {
        $artifactReference = $runRoot
    }
    $result = [pscustomobject]@{
        ok = $allReportedChecksPassed
        runnerPowerShell = [string]$PSVersionTable.PSVersion
        fixtureHost = [System.IO.Path]::GetFileName($script:FixtureHostPathResolved)
        runtimeHost = [System.IO.Path]::GetFileName($script:RuntimeHostPathResolved)
        nativeFixtureHost = [System.IO.Path]::GetFileName($script:NativeFixtureHostPathResolved)
        identityPinned = $identityPinned
        crossQueryRejected = $crossQueryRejected
        screenshotCaptureBounded = $screenshotCaptureBounded
        identityValidationPassed = $identityValidationPassed
        numericValidationPassed = $numericValidationPassed
        mismatchRejected = $mismatchRejected
        staleBoundsRejected = $staleBoundsRejected
        focusedTypeTextAccepted = $focusedTypeTextAccepted
        nonEditableTypeTextRejected = $nonEditableTypeTextRejected
        duplicateFocusedTypeTextIsolated = $duplicateFocusedTypeTextIsolated
        outsideWindowTypeTextRejected = $outsideWindowTypeTextRejected
        disabledUIATextFallbackRejected = $disabledUIATextFallbackRejected
        nativeFocusedTypeTextAccepted = $nativeFocusedTypeTextAccepted
        missingFrameClickRejected = $missingFrameClickRejected
        validFrameAutoClick = $validFrameAutoClick
        semanticClickWithoutFrame = $semanticClickWithoutFrame
        explicitCoordinateClickAccepted = $explicitCoordinateClickAccepted
        emptyRuntimeIdRejected = $emptyRuntimeIdRejected
        missingRuntimeIdRejected = $missingRuntimeIdRejected
        malformedRuntimeIdRejected = $malformedRuntimeIdRejected
        replacementRuntimeIdsDistinct = $replacementRuntimeIdsDistinct
        duplicateMetadataAddressedIndependently = $duplicateMetadataAddressedIndependently
        allStaleElementTargetedActionsRejected = $allStaleElementTargetedActionsRejected
        semanticScrollWithoutFrame = $semanticScrollWithoutFrame
        validFrameScrollFallback = $validFrameScrollFallback
        invalidScrollFramesRejected = $invalidScrollFramesRejected
        unauthorizedGlobalAndKeyboardRejected = $unauthorizedGlobalAndKeyboardRejected
        wpfAppPostCapabilityError = $wpfAppPostCapabilityError
        nativeOutsideAppPostRejected = $nativeOutsideAppPostRejected
        nativeBmClick = ('clicks=' + $nativeAfter.clicks + '; down=' + $nativeAfter.buttonDown + '; up=' + $nativeAfter.buttonUp)
        artifacts = $artifactReference
    }
    if ($IncludeChromium) {
        # R6: appended only on request, so the default key set stays byte-identical
        # to the baseline (research/baseline-runner-keys.json).
        [void]($result | Add-Member -NotePropertyName chromiumContentAreaOpaque -NotePropertyValue $chromiumContentAreaOpaque -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumTypeTextNewMessage -NotePropertyValue $chromiumTypeTextNewMessage -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumSetValueRejected -NotePropertyValue $chromiumSetValueRejected -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumAppPostLanded -NotePropertyValue $chromiumAppPostLanded -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumGlobalOcclusionFailClosed -NotePropertyValue $chromiumGlobalOcclusionFailClosed -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumGlobalPhysicalFailClosed -NotePropertyValue $chromiumGlobalPhysicalFailClosed -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumCoordinateLanding -NotePropertyValue $chromiumCoordinateLanding -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumCoordinateScale -NotePropertyValue $chromiumCoordinateScale -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumCoordinateAnchor -NotePropertyValue $chromiumCoordinateAnchor -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumDevicePixelRatio -NotePropertyValue $chromiumDevicePixelRatio -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumHost -NotePropertyValue $chromiumHost -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumPointerWitness -NotePropertyValue $chromiumPointerWitness -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumPointerWitnessNote -NotePropertyValue $chromiumPointerWitnessNote -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumSkipped -NotePropertyValue $chromiumSkipped -PassThru)
        [void]($result | Add-Member -NotePropertyName chromiumSkippedReason -NotePropertyValue $chromiumSkippedReason -PassThru)
    }
    $result | ConvertTo-Json -Depth 10 -Compress
    } finally {
    foreach ($target in $fixtures) {
        if ($null -ne $target.Process -and -not $target.Process.HasExited) {
            try {
                [void]$target.Process.Kill()
                [void]$target.Process.WaitForExit(5000)
            } catch {
            }
        }
    }
    # The Chromium fixture's browser outlives a hard-killed fixture host, so the run
    # cleans its own fixture browsers here instead of relying on the fixture's finally.
    [void](Remove-StaleChromiumFixtureBrowsers)
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $runRoot)) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
}
