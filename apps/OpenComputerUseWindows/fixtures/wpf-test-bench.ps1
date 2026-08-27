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
$script:DisplayTitle = "Open Computer Use MCP WPF Test Bench"
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

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Open Computer Use MCP WPF Test Bench"
        Width="1120"
        Height="760"
        WindowStartupLocation="CenterScreen"
        ResizeMode="NoResize"
        Background="#F4F7FA"
        AutomationProperties.Name="Open Computer Use MCP WPF Test Bench">
  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="18" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="Auto" />
      <RowDefinition Height="*" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" FontSize="20" FontWeight="Bold" Text="Open Computer Use MCP WPF Test Bench" />
    <TextBlock Grid.Row="1" Margin="0,6,0,0" Text="Disposable controls for isolated end-to-end verification." />
    <StackPanel Grid.Row="3">
      <TextBlock FontWeight="Bold" Text="Click and secondary action" />
      <UniformGrid Columns="4" Margin="0,8,0,8">
        <Button x:Name="autoButton" Height="34" Margin="0,0,8,0" Content="Auto click target" AutomationProperties.Name="Auto click target" />
        <Button x:Name="accessibilityButton" Height="34" Margin="0,0,8,0" Content="Accessibility click target" AutomationProperties.Name="Accessibility click target" />
        <Button x:Name="appPostButton" Height="34" Margin="0,0,8,0" Content="App-post click target" AutomationProperties.Name="App-post click target" />
        <Button x:Name="secondaryButton" Height="34" Content="Secondary invoke target" AutomationProperties.Name="Secondary invoke target" />
      </UniformGrid>
      <Border BorderBrush="#8296A9" BorderThickness="1" Background="White" Padding="7,4">
        <TextBlock x:Name="clickStatus" Text="auto=0; accessibility=0; appPost=0; secondary=0" AutomationProperties.Name="Click status" />
      </Border>
    </StackPanel>
    <StackPanel Grid.Row="4" Margin="0,8,0,0" Orientation="Horizontal">
      <Button x:Name="replaceIdentityButton" Height="30" Width="220" Content="Replace identity target" AutomationProperties.Name="Replace identity target" />
      <StackPanel x:Name="identityTargetHost" Margin="8,0,0,0" Orientation="Horizontal" />
      <TextBlock x:Name="identityStatus" Margin="8,7,0,0" Text="identityGeneration=0" AutomationProperties.Name="Identity status" />
    </StackPanel>
    <Grid Grid.Row="5" Margin="0,20,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*" />
        <ColumnDefinition Width="32" />
        <ColumnDefinition Width="*" />
      </Grid.ColumnDefinitions>
      <StackPanel Grid.Column="0">
        <TextBlock FontWeight="Bold" Text="Type text target" />
        <TextBox x:Name="typeTextBox" Height="30" Margin="0,7,0,7" AutomationProperties.Name="Type text target" />
        <Border BorderBrush="#8296A9" BorderThickness="1" Background="White" Padding="7,4">
          <TextBlock x:Name="typeStatus" Text="typed=&quot;&quot;" AutomationProperties.Name="Typed text status" />
        </Border>
        <TextBlock Margin="0,24,0,0" FontWeight="Bold" Text="Set value target" />
        <TextBox x:Name="setValueTextBox" Height="30" Margin="0,7,0,7" AutomationProperties.Name="Set value target" />
        <Border BorderBrush="#8296A9" BorderThickness="1" Background="White" Padding="7,4">
          <TextBlock x:Name="setStatus" Text="setValue=&quot;&quot;" AutomationProperties.Name="Set value status" />
        </Border>
        <TextBlock Margin="0,24,0,0" FontWeight="Bold" Text="Press key target" />
        <TextBox x:Name="keyTextBox" Height="30" Margin="0,7,0,7" Text="keyboard-ready" AutomationProperties.Name="Press key target" />
        <Border BorderBrush="#8296A9" BorderThickness="1" Background="White" Padding="7,4">
          <TextBlock x:Name="keyStatus" Text="lastKey=&quot;&quot;; eventCount=0" AutomationProperties.Name="Key status" />
        </Border>
      </StackPanel>
      <StackPanel Grid.Column="2">
        <TextBlock FontWeight="Bold" Text="Drag slider target" />
        <Slider x:Name="slider" Minimum="0" Maximum="100" Value="10" Height="30" Margin="0,7,0,7" AutomationProperties.Name="Drag slider target" />
        <Border BorderBrush="#8296A9" BorderThickness="1" Background="White" Padding="7,4">
          <TextBlock x:Name="dragStatus" Text="dragValue=10" AutomationProperties.Name="Drag status" />
        </Border>
        <TextBlock Margin="0,24,0,0" FontWeight="Bold" Text="Scroll test container" />
        <ScrollViewer x:Name="scrollBox" Height="270" Margin="0,7,0,7" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" BorderBrush="#8296A9" BorderThickness="1" Background="White" AutomationProperties.Name="Scroll test container">
          <TextBlock x:Name="scrollText" Padding="8" TextWrapping="Wrap" />
        </ScrollViewer>
        <Border BorderBrush="#8296A9" BorderThickness="1" Background="White" Padding="7,4">
          <TextBlock x:Name="scrollStatus" Text="scrollEvents=0" AutomationProperties.Name="Scroll status" />
        </Border>
      </StackPanel>
    </Grid>
    <TextBlock Grid.Row="6" Margin="0,12,0,0" Foreground="#465565" Text="Ready for MCP verification." />
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$window.Title = $script:DisplayTitle
[System.Windows.Automation.AutomationProperties]::SetName($window, $script:DisplayTitle)
if ($Left -ge 0 -and $Top -ge 0) {
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
    $window.Left = $Left
    $window.Top = $Top
}

$autoButton = $window.FindName('autoButton')
$accessibilityButton = $window.FindName('accessibilityButton')
$appPostButton = $window.FindName('appPostButton')
$secondaryButton = $window.FindName('secondaryButton')
$clickStatus = $window.FindName('clickStatus')
$typeTextBox = $window.FindName('typeTextBox')
$typeStatus = $window.FindName('typeStatus')
$setValueTextBox = $window.FindName('setValueTextBox')
$setStatus = $window.FindName('setStatus')
$keyTextBox = $window.FindName('keyTextBox')
$keyStatus = $window.FindName('keyStatus')
$slider = $window.FindName('slider')
$dragStatus = $window.FindName('dragStatus')
$scrollBox = $window.FindName('scrollBox')
$scrollText = $window.FindName('scrollText')
$scrollStatus = $window.FindName('scrollStatus')
$replaceIdentityButton = $window.FindName('replaceIdentityButton')
$identityTargetHost = $window.FindName('identityTargetHost')
$identityStatus = $window.FindName('identityStatus')

$script:autoCount = 0
$script:accessibilityCount = 0
$script:appPostCount = 0
$script:secondaryCount = 0
$script:keyEvents = 0
$script:scrollEvents = 0
$script:identityGeneration = 0
$script:identityReplacementCount = 0
$script:identityTarget = $null
$script:identityDuplicate = $null

function New-IdentityTarget([string]$initialValue) {
    $box = New-Object System.Windows.Controls.TextBox
    $box.Width = 220
    $box.Height = 30
    $box.Margin = New-Object System.Windows.Thickness(0,0,8,0)
    $box.Text = $initialValue
    [System.Windows.Automation.AutomationProperties]::SetName($box, 'Identity replacement target')
    [System.Windows.Automation.AutomationProperties]::SetAutomationId($box, 'identityTarget')
    $box.Add_TextChanged({ Write-FixtureState })
    return $box
}

function Install-IdentityTargets([bool]$includeDuplicate) {
    $identityTargetHost.Children.Clear()
    $primary = New-IdentityTarget ('identity-primary-' + $script:identityGeneration)
    [void]$identityTargetHost.Children.Add($primary)
    $script:identityTarget = $primary
    $script:identityDuplicate = $null
    if ($includeDuplicate) {
        $duplicate = New-IdentityTarget ('identity-duplicate-' + $script:identityGeneration)
        [void]$identityTargetHost.Children.Add($duplicate)
        $script:identityDuplicate = $duplicate
    }
}

function Update-IdentityStatus {
    $identityStatus.Text = 'identityGeneration=' + $script:identityGeneration + '; replacements=' + $script:identityReplacementCount
    [System.Windows.Automation.AutomationProperties]::SetName($identityStatus, $identityStatus.Text)
}

function Get-FixtureState {
    $process = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $bounds = $null
    if ($null -ne $process) {
        $bounds = [pscustomobject]@{
            x = [double]$window.Left
            y = [double]$window.Top
            width = [double]$window.ActualWidth
            height = [double]$window.ActualHeight
        }
    }
    return [pscustomobject]@{
        ready = ($null -ne $process)
        instance = $script:InstanceName
        framework = "wpf"
        pid = [int]$PID
        hwnd = Get-FixtureWindowHandle
        title = $script:DisplayTitle
        windowBounds = $bounds
        auto = [int]$script:autoCount
        accessibility = [int]$script:accessibilityCount
        appPost = [int]$script:appPostCount
        secondary = [int]$script:secondaryCount
        typed = [string]$typeTextBox.Text
        setValue = [string]$setValueTextBox.Text
        lastKey = [string]$keyStatus.Text
        eventCount = [int]$script:keyEvents
        dragValue = [int]$slider.Value
        scrollEvents = [int]$script:scrollEvents
        identityGeneration = [int]$script:identityGeneration
        identityReplacementCount = [int]$script:identityReplacementCount
        identityPrimaryValue = if ($null -ne $script:identityTarget) { [string]$script:identityTarget.Text } else { '' }
        identityDuplicateValue = if ($null -ne $script:identityDuplicate) { [string]$script:identityDuplicate.Text } else { '' }
    }
}

function Write-FixtureState {
    Write-FixtureJson $script:StatePath (Get-FixtureState)
}

function Set-Status($element, [string]$text) {
    $element.Text = $text
    [System.Windows.Automation.AutomationProperties]::SetName($element, $text)
}

function Update-ClickStatus {
    Set-Status $clickStatus ('auto=' + $script:autoCount + '; accessibility=' + $script:accessibilityCount + '; appPost=' + $script:appPostCount + '; secondary=' + $script:secondaryCount)
}

$autoButton.Add_Click({
    $script:autoCount += 1
    Update-ClickStatus
    Write-FixtureState
})
$accessibilityButton.Add_Click({
    $script:accessibilityCount += 1
    Update-ClickStatus
    Write-FixtureState
})
$appPostButton.Add_Click({
    $script:appPostCount += 1
    Update-ClickStatus
    Write-FixtureState
})
$secondaryButton.Add_Click({
    $script:secondaryCount += 1
    Update-ClickStatus
    Write-FixtureState
})
$typeTextBox.Add_TextChanged({ Set-Status $typeStatus ('typed=' + [char]34 + $typeTextBox.Text + [char]34); Write-FixtureState })
$setValueTextBox.Add_TextChanged({ Set-Status $setStatus ('setValue=' + [char]34 + $setValueTextBox.Text + [char]34); Write-FixtureState })
$keyTextBox.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    $script:keyEvents += 1
    Set-Status $keyStatus ('lastKey=' + [char]34 + $eventArgs.Key.ToString() + [char]34 + '; eventCount=' + $script:keyEvents)
    Write-FixtureState
})
$slider.Add_ValueChanged({
    Set-Status $dragStatus ('dragValue=' + [int]$slider.Value)
    Write-FixtureState
})
$scrollBox.Add_ScrollChanged({
    param($sender, $eventArgs)
    if ($eventArgs.VerticalChange -ne 0) {
        $script:scrollEvents += 1
        Set-Status $scrollStatus ('scrollEvents=' + $script:scrollEvents)
        Write-FixtureState
    }
})
$replaceIdentityButton.Add_Click({
    $script:identityGeneration += 1
    $script:identityReplacementCount += 1
    Install-IdentityTargets $true
    Update-IdentityStatus
    Write-FixtureState
})

$rows = New-Object System.Collections.Generic.List[string]
foreach ($row in 1..80) {
    [void]$rows.Add('Scroll row ' + $row)
}
$scrollText.Text = [string]::Join([Environment]::NewLine, $rows)
Set-Status $clickStatus 'auto=0; accessibility=0; appPost=0; secondary=0'
Set-Status $typeStatus 'typed=""'
Set-Status $setStatus 'setValue=""'
Set-Status $keyStatus 'lastKey=""; eventCount=0'
Set-Status $dragStatus 'dragValue=10'
Set-Status $scrollStatus 'scrollEvents=0'
Install-IdentityTargets $false
Update-IdentityStatus

$window.Add_ContentRendered({
    Write-FixtureState
    Write-FixtureJson $script:ReadyPath (Get-FixtureState)
})
Write-FixtureState
[void]$window.ShowDialog()
