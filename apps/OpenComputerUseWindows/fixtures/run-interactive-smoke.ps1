param(
    [switch]$KeepArtifacts,
    [string]$FixtureHostPath = 'pwsh.exe',
    [string]$RuntimeHostPath = 'powershell.exe',
    [string]$NativeFixtureHostPath = 'pwsh.exe'
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
    return ($null -ne $response -and -not $response.ok -and $response.error -eq 'type_text requires a focused writable text control owned by the requested app/window; click/select the field first or use set_value with the complete generation-bound identifier in element_index.')
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

function Start-Fixture([string]$scriptName, [string]$instance, [int]$left, [int]$top, [string]$hostPath) {
    $readyPath = Join-Path $runRoot ($instance + '-ready.json')
    $statePath = Join-Path $runRoot ($instance + '-state.json')
    $scriptPath = Join-Path $fixtureRoot $scriptName
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $scriptPath,
        '-InstanceName', $instance,
        '-ReadyPath', $readyPath,
        '-StatePath', $statePath,
        '-Left', [string]$left,
        '-Top', [string]$top
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $hostPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Set-ProcessArguments $startInfo $arguments
    $process = [System.Diagnostics.Process]::Start($startInfo)
    Assert-Condition ($null -ne $process) ('Could not start fixture ' + $instance)
    $target = [pscustomobject]@{
        Process = $process
        Instance = $instance
        ReadyPath = $readyPath
        StatePath = $statePath
    }
    [void]$fixtures.Add($target)
    return $target
}

function Wait-FixtureReady($target) {
    $deadline = [datetime]::UtcNow.AddSeconds(20)
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
        $element.SetFocus()
        Start-Sleep -Milliseconds 180
        $focused = [Windows.Automation.AutomationElement]::FocusedElement
        Assert-Condition ($null -ne $focused) ('No focused element after selecting ' + $name)
        Assert-Condition ([string]$focused.Current.Name -eq $name) ('Unexpected focused element after selecting ' + $name)
        Assert-Condition ([string]$focused.Current.ControlType.ProgrammaticName -eq $controlTypeName) ('Unexpected focused control type after selecting ' + $name)
        return [pscustomobject]@{
            name = [string]$focused.Current.Name
            controlType = [string]$focused.Current.ControlType.ProgrammaticName
            processId = [int]$focused.Current.ProcessId
            nativeWindowHandle = [int64]$focused.Current.NativeWindowHandle
        }
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

try {
    $script:FixtureHostPathResolved = Resolve-HostExecutable $FixtureHostPath
    $script:RuntimeHostPathResolved = Resolve-HostExecutable $RuntimeHostPath
    $script:NativeFixtureHostPathResolved = Resolve-HostExecutable $NativeFixtureHostPath
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $targetA = Start-Fixture 'wpf-test-bench.ps1' 'A' 20 20 $script:FixtureHostPathResolved
    $targetB = Start-Fixture 'wpf-test-bench.ps1' 'B' 1280 20 $script:FixtureHostPathResolved
    $nativeTarget = Start-Fixture 'native-pointer-bench.ps1' 'N' 40 900 $script:NativeFixtureHostPathResolved
    $stateA = Wait-FixtureReady $targetA
    $stateB = Wait-FixtureReady $targetB
    $nativeState = Wait-FixtureReady $nativeTarget

    $snapshotA = Get-Snapshot $stateA.title
    $snapshotB = Get-Snapshot $stateB.title
    $nativeSnapshot = Get-Snapshot $nativeState.title
    Assert-Condition ($snapshotA.app.pid -ne $snapshotB.app.pid -and $snapshotA.app.mainWindowHandle -ne $snapshotB.app.mainWindowHandle) 'A and B did not receive distinct identities.'

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

    $baselineCrossA = Read-State $targetA.StatePath
    $baselineB = Read-State $targetB.StatePath
    $crossQuery = [pscustomobject]@{
        tool = 'set_value'
        app = $stateB.title
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
    $afterCrossB = Read-State $targetB.StatePath
    Assert-Condition ($afterCrossA.setValue -eq $baselineCrossA.setValue -and $afterCrossB.setValue -eq $baselineB.setValue) 'A cross-query pinned action changed a fixture.'

    $badIdentity = [pscustomobject]@{
        tool = 'set_value'
        app = $stateB.title
        element = $replacementPrimaryElement
        value = 'must-not-write'
        expectedPid = [int]$snapshotB.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    }
    $badResult = Invoke-Runtime $badIdentity
    Assert-Condition ((-not $badResult.ok) -and $badResult.error -eq 'Target changed; call get_app_state again.') 'Mismatched identity was not rejected.'
    $afterBadA = Read-State $targetA.StatePath
    $afterBadB = Read-State $targetB.StatePath
    Assert-Condition ($afterBadA.setValue -eq $afterCrossA.setValue -and $afterBadB.setValue -eq $afterCrossB.setValue) 'Mismatched identity mutated a fixture.'

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
        $focusedTypeTextResponse = Invoke-TypeText $stateA $snapshotA $focusedSuccessText
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
        $duplicateTypeTextResponse = Invoke-TypeText $stateA $snapshotA $duplicateSuccessText
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

        $focusTypeForDisabledFallback = Set-FixtureFocus $stateA.hwnd 'Type text target' 'ControlType.Edit' ''
        $savedFallbackForDisabledTest = [Environment]::GetEnvironmentVariable($typeTextEnvironmentName)
        try {
            [Environment]::SetEnvironmentVariable($typeTextEnvironmentName, $null)
            $beforeDisabledFallback = Read-State $targetA.StatePath
            $disabledFallbackTypeTextResponse = Invoke-TypeText $stateA $snapshotA 'must-not-use-disabled-fallback'
            Assert-Condition (Test-TypeTextFallbackResponse $disabledFallbackTypeTextResponse) 'Disabled UIA text fallback did not return its bounded capability error.'
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
            $nativeTypeTextResponse = Invoke-TypeText $nativeState $nativeSnapshot $nativeSuccessText
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
    Assert-Condition $allReportedChecksPassed 'One or more computed smoke result flags did not pass.'

    $artifactReference = $null
    if ($KeepArtifacts) {
        $artifactReference = $runRoot
    }
    [pscustomobject]@{
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
    } | ConvertTo-Json -Depth 10 -Compress
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
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $runRoot)) {
        Remove-Item -LiteralPath $runRoot -Recurse -Force
    }
}
