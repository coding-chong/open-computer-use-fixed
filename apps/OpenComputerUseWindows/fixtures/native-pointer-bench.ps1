param(
    [string]$InstanceName = "",
    [string]$ReadyPath = "",
    [string]$StatePath = "",
    [int]$Left = -1,
    [int]$Top = -1
)

$ErrorActionPreference = "Stop"
$script:InstanceName = $InstanceName
$script:ReadyPath = $ReadyPath
$script:StatePath = $StatePath
$script:DisplayTitle = "Open Computer Use Native Pointer Test"
if (-not [string]::IsNullOrWhiteSpace($InstanceName)) {
    $script:DisplayTitle = $script:DisplayTitle + " [" + $InstanceName + "]"
}

function Write-FixtureJson([string]$path, $value) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = $path + "." + $PID + ".tmp"
    $json = $value | ConvertTo-Json -Depth 20 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($temporary, $json, $utf8NoBom)
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Get-FixtureWindowHandle {
    try {
        return [int64](Get-Process -Id $PID -ErrorAction Stop).MainWindowHandle.ToInt64()
    } catch {
        return [int64]0
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:DisplayTitle
$form.ClientSize = New-Object System.Drawing.Size(760, 370)
if ($Left -ge 0 -and $Top -ge 0) {
    $form.StartPosition = 'Manual'
    $form.Location = New-Object System.Drawing.Point($Left, $Top)
} else {
    $form.StartPosition = 'CenterScreen'
}
$form.BackColor = [System.Drawing.Color]::White

function New-StatusLabel([string]$text, [int]$x, [int]$y, [int]$width) {
    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Location = New-Object System.Drawing.Point($x, $y)
    $label.Size = New-Object System.Drawing.Size($width, 28)
    $label.BorderStyle = 'FixedSingle'
    $label.TextAlign = 'MiddleLeft'
    $label.Padding = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
    $label.Text = $text
    return $label
}

$header = New-Object System.Windows.Forms.Label
$header.AutoSize = $true
$header.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(20, 18)
$header.Text = 'Native pointer and app-post test'
$form.Controls.Add($header)

$script:clickCount = 0
$script:buttonDown = 0
$script:buttonUp = 0
$script:dragDown = 0
$script:dragMove = 0
$script:dragUp = 0

function Get-FixtureState {
    $process = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $bounds = $null
    if ($null -ne $process) {
        $bounds = [pscustomobject]@{
            x = [double]$form.Left
            y = [double]$form.Top
            width = [double]$form.Width
            height = [double]$form.Height
        }
    }
    return [pscustomobject]@{
        ready = ($null -ne $process)
        instance = $script:InstanceName
        framework = "winforms"
        pid = [int]$PID
        hwnd = Get-FixtureWindowHandle
        title = $script:DisplayTitle
        windowBounds = $bounds
        clicks = [int]$script:clickCount
        buttonDown = [int]$script:buttonDown
        buttonUp = [int]$script:buttonUp
        typed = [string]$typeTextBox.Text
        dragValue = [int]$trackBar.Value
        dragDown = [int]$script:dragDown
        dragMove = [int]$script:dragMove
        dragUp = [int]$script:dragUp
    }
}

function Write-FixtureState {
    Write-FixtureJson $script:StatePath (Get-FixtureState)
}

$button = New-Object System.Windows.Forms.Button
$button.Location = New-Object System.Drawing.Point(20, 70)
$button.Size = New-Object System.Drawing.Size(280, 42)
$button.Text = 'App-post native button target'
$button.AccessibleName = 'App-post native button target'
$buttonStatus = New-StatusLabel 'clicks=0; down=0; up=0' 20 123 440
$buttonStatus.AccessibleName = 'App-post status'
$button.Add_MouseDown({
    $script:buttonDown += 1
    $buttonStatus.Text = 'clicks=' + $script:clickCount + '; down=' + $script:buttonDown + '; up=' + $script:buttonUp
    Write-FixtureState
})
$button.Add_MouseUp({
    $script:buttonUp += 1
    $buttonStatus.Text = 'clicks=' + $script:clickCount + '; down=' + $script:buttonDown + '; up=' + $script:buttonUp
    Write-FixtureState
})
$button.Add_Click({
    $script:clickCount += 1
    $buttonStatus.Text = 'clicks=' + $script:clickCount + '; down=' + $script:buttonDown + '; up=' + $script:buttonUp
    Write-FixtureState
})
$form.Controls.AddRange(@($button, $buttonStatus))

$typeTextBox = New-Object System.Windows.Forms.TextBox
$typeTextBox.Location = New-Object System.Drawing.Point(470, 70)
$typeTextBox.Size = New-Object System.Drawing.Size(260, 28)
$typeTextBox.AccessibleName = 'Native type_text target'
$typeStatus = New-StatusLabel 'typed=""' 470 105 260
$typeStatus.AccessibleName = 'Native type_text status'
$typeTextBox.Add_TextChanged({
    $typeStatus.Text = 'typed=' + [char]34 + $typeTextBox.Text + [char]34
    Write-FixtureState
})
$form.Controls.AddRange(@($typeTextBox, $typeStatus))

$sliderLabel = New-Object System.Windows.Forms.Label
$sliderLabel.AutoSize = $true
$sliderLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$sliderLabel.Location = New-Object System.Drawing.Point(20, 185)
$sliderLabel.Text = 'Native trackbar drag target'

$trackBar = New-Object System.Windows.Forms.TrackBar
$trackBar.Location = New-Object System.Drawing.Point(20, 215)
$trackBar.Size = New-Object System.Drawing.Size(620, 50)
$trackBar.Minimum = 0
$trackBar.Maximum = 100
$trackBar.Value = 10
$trackBar.TickFrequency = 10
$trackBar.AccessibleName = 'Native trackbar drag target'

$dragStatus = New-StatusLabel 'value=10; down=0; move=0; up=0' 20 276 620
$dragStatus.AccessibleName = 'Native drag status'
$trackBar.Add_MouseDown({
    $script:dragDown += 1
    $dragStatus.Text = 'value=' + $trackBar.Value + '; down=' + $script:dragDown + '; move=' + $script:dragMove + '; up=' + $script:dragUp
    Write-FixtureState
})
$trackBar.Add_MouseMove({
    $script:dragMove += 1
    $dragStatus.Text = 'value=' + $trackBar.Value + '; down=' + $script:dragDown + '; move=' + $script:dragMove + '; up=' + $script:dragUp
    Write-FixtureState
})
$trackBar.Add_MouseUp({
    $script:dragUp += 1
    $dragStatus.Text = 'value=' + $trackBar.Value + '; down=' + $script:dragDown + '; move=' + $script:dragMove + '; up=' + $script:dragUp
    Write-FixtureState
})
$trackBar.Add_Scroll({
    $dragStatus.Text = 'value=' + $trackBar.Value + '; down=' + $script:dragDown + '; move=' + $script:dragMove + '; up=' + $script:dragUp
    Write-FixtureState
})

$form.Controls.AddRange(@($sliderLabel, $trackBar, $dragStatus))

$footer = New-Object System.Windows.Forms.Label
$footer.AutoSize = $true
$footer.Location = New-Object System.Drawing.Point(20, 325)
$footer.Text = 'No user input is needed while this test is running.'
$form.Controls.Add($footer)

$form.Add_Shown({
    Write-FixtureState
    Write-FixtureJson $script:ReadyPath (Get-FixtureState)
})
Write-FixtureState
[System.Windows.Forms.Application]::Run($form)
