param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
$fixtureRoot = $PSScriptRoot
$runtimePath = Join-Path (Split-Path -Parent $fixtureRoot) 'runtime.ps1'
$runRoot = Join-Path $env:TEMP ('ocu-windows-smoke-' + $PID)
$fixtures = New-Object System.Collections.Generic.List[object]
$operationNumber = 0

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) {
        throw $message
    }
}

function Read-State([string]$path) {
    return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json)
}

function Start-Fixture([string]$scriptName, [string]$instance, [int]$left, [int]$top) {
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
    $startInfo.FileName = 'pwsh.exe'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
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
                if ($state.ready -and $state.pid -gt 0 -and $state.hwnd -ne 0) {
                    return $state
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
    $operation | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $operationPath -Encoding utf8
    $output = & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $runtimePath $operationPath
    if ($LASTEXITCODE -ne 0) {
        throw ('runtime process failed: ' + ($output -join "`n"))
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

function Get-Snapshot([string]$title) {
    $response = Invoke-Runtime ([pscustomobject]@{
        tool = 'get_app_state'
        app = $title
        include_image = $false
        text_limit = 250
        max_tree_nodes = 180
        max_tree_depth = 16
    })
    Assert-Condition $response.ok ('Snapshot failed for ' + $title + ': ' + $response.error)
    return $response.snapshot
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
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $targetA = Start-Fixture 'wpf-test-bench.ps1' 'A' 20 20
    $targetB = Start-Fixture 'wpf-test-bench.ps1' 'B' 1280 20
    $nativeTarget = Start-Fixture 'native-pointer-bench.ps1' 'N' 40 900
    $stateA = Wait-FixtureReady $targetA
    $stateB = Wait-FixtureReady $targetB
    $nativeState = Wait-FixtureReady $nativeTarget

    $snapshotA = Get-Snapshot $stateA.title
    $snapshotB = Get-Snapshot $stateB.title
    $nativeSnapshot = Get-Snapshot $nativeState.title
    Assert-Condition ($snapshotA.app.pid -ne $snapshotB.app.pid -and $snapshotA.app.mainWindowHandle -ne $snapshotB.app.mainWindowHandle) 'A and B did not receive distinct identities.'

    $setElementA = Find-Element $snapshotA 'Set value target' 'SetValue' $false
    Assert-Condition ($null -ne $setElementA) 'The settable A TextBox was not found.'
    $baselineB = Read-State $targetB.StatePath
    $crossQuery = [pscustomobject]@{
        tool = 'set_value'
        app = $stateB.title
        element = $setElementA
        value = 'cross-query-A'
        expectedPid = [int]$snapshotA.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    }
    $crossResult = Invoke-Runtime $crossQuery
    Assert-Condition $crossResult.ok ('Identity-pinned A action failed: ' + $crossResult.error)
    Start-Sleep -Milliseconds 200
    $afterCrossA = Read-State $targetA.StatePath
    $afterCrossB = Read-State $targetB.StatePath
    Assert-Condition ($afterCrossA.setValue -eq 'cross-query-A') 'A did not receive the identity-pinned set_value.'
    Assert-Condition ($afterCrossB.setValue -eq $baselineB.setValue) 'B changed during the identity-pinned A action.'

    $badIdentity = [pscustomobject]@{
        tool = 'set_value'
        app = $stateB.title
        element = $setElementA
        value = 'must-not-write'
        expectedPid = [int]$snapshotB.app.pid
        expectedProcessStartTimeTicks = [int64]$snapshotA.app.processStartTimeTicks
        expectedMainWindowHandle = [int64]$snapshotA.app.mainWindowHandle
    }
    $badResult = Invoke-Runtime $badIdentity
    Assert-Condition ((-not $badResult.ok) -and $badResult.error -like '*Target changed; call get_app_state again.*') 'Mismatched identity was not rejected.'
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
    Assert-Condition ((-not $staleResult.ok) -and $staleResult.error -like '*Target changed; call get_app_state again.*') 'Stale bounds were not rejected.'
    $snapshotA = Get-Snapshot $stateA.title

    $semanticScrollElement = Find-Element $snapshotA 'Scroll test container' 'Scroll' $false
    Assert-Condition ($null -ne $semanticScrollElement) 'The WPF ScrollViewer did not expose ScrollPattern.'
    $semanticScrollWithoutFrame = $semanticScrollElement | ConvertTo-Json -Depth 50 | ConvertFrom-Json
    $semanticScrollWithoutFrame.frame = $null
    $beforeSemanticScroll = Read-State $targetA.StatePath
    $semanticScrollResult = Invoke-Runtime ([pscustomobject]@{
        tool = 'scroll'; app = $stateA.title; element = $semanticScrollWithoutFrame; direction = 'down'; pages = 1
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
        tool = 'scroll'; app = $stateA.title; element = $scrollFallbackElement; direction = 'down'; pages = 1
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

    $outsideBefore = $nativeAfter
    $outsideAppPost = Invoke-Runtime ([pscustomobject]@{
        tool = 'click'; app = $nativeState.title; x = -100; y = -100; click_count = 1; mouse_button = 'left'; click_method = 'app_post'
        windowBounds = $nativeSnapshot.windowBounds; expectedPid = [int]$nativeSnapshot.app.pid
        expectedProcessStartTimeTicks = [int64]$nativeSnapshot.app.processStartTimeTicks; expectedMainWindowHandle = [int64]$nativeSnapshot.app.mainWindowHandle
    })
    Assert-Condition ((-not $outsideAppPost.ok) -and $outsideAppPost.error -like '*Target changed; call get_app_state again.*') 'Outside-window app_post was not rejected.'
    $outsideAfter = Read-State $nativeTarget.StatePath
    Assert-Condition ($outsideAfter.clicks -eq $outsideBefore.clicks -and $outsideAfter.buttonDown -eq $outsideBefore.buttonDown -and $outsideAfter.buttonUp -eq $outsideBefore.buttonUp) 'Outside-window app_post changed native counters.'

    $artifactReference = $null
    if ($KeepArtifacts) {
        $artifactReference = $runRoot
    }
    [pscustomobject]@{
        ok = $true
        identityPinned = $true
        mismatchRejected = $true
        staleBoundsRejected = $true
        semanticScrollWithoutFrame = $true
        validFrameScrollFallback = $true
        invalidScrollFramesRejected = $true
        unauthorizedGlobalAndKeyboardRejected = $true
        wpfAppPostCapabilityError = $true
        nativeOutsideAppPostRejected = $true
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
