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

function Test-TargetChangedResponse($response) {
    return ($null -ne $response -and -not $response.ok -and $response.error -eq 'Target changed; call get_app_state again.')
}

function Assert-TargetChangedResponse($response, [string]$message) {
    Assert-Condition (Test-TargetChangedResponse $response) $message
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

    $duplicateSnapshot = Get-Snapshot $stateA.title
    $replacementDuplicateElement = $null
    foreach ($record in (Find-SamePresentationElements $duplicateSnapshot $identityElementA)) {
        if ($record.value -eq $replacementDuplicateBeforeAddress) {
            $replacementDuplicateElement = $record
            break
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
    $identityPinned = (
        $crossResult.ok -and
        $afterCrossA.setValue -eq 'cross-query-A' -and
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
        $mismatchRejected,
        $staleBoundsRejected,
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
        identityPinned = $identityPinned
        mismatchRejected = $mismatchRejected
        staleBoundsRejected = $staleBoundsRejected
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
