# Renders the real progress bar from Android_SDK.ps1 with simulated transfers,
# so you can see exactly what an install looks like without downloading anything.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Progress.Demo.ps1
#   pwsh -NoProfile -File tests/Progress.Demo.ps1
#
# Optional: set $env:ANDROID_SDK_INSTALLER_DEMO_CONSOLE_WIDTH to preview another console width.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'Android_SDK.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw "Android_SDK.ps1 has parse errors: $(($parseErrors | ForEach-Object { $_.Message }) -join '; ')" }

$wanted = @('Get-ProgressLineWidth', 'Format-ByteSize', 'Format-DurationClock', 'Show-TransferProgress',
    'Close-InlineProgressLine', 'Reset-TransferProgress', 'Complete-TransferProgress', 'Get-SmoothedSpeed')
$definitions = $ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($wanted -contains $node.Name)
    }, $true)
foreach ($definition in $definitions) { Invoke-Expression $definition.Extent.Text }

# Preview a different console width without resizing the window.
if ($env:ANDROID_SDK_INSTALLER_DEMO_CONSOLE_WIDTH) {
    $script:StubConsoleWidth = [int]$env:ANDROID_SDK_INSTALLER_DEMO_CONSOLE_WIDTH
    function Get-ProgressLineWidth { return $script:StubConsoleWidth }
}

function Invoke-SimulatedTransfer {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][double]$TotalBytes,
        [Parameter(Mandatory = $true)][double]$BytesPerSecond,
        [int]$ItemCount = 0,
        [string]$ItemWord = 'files',
        [int]$Frames = 60,
        [int]$FrameMilliseconds = 60
    )
    $speed = [double]0
    $lastSampleAt = [double]0
    $lastSampleBytes = [double]0
    for ($frame = 1; $frame -le $Frames; $frame++) {
        # Compressed clock: the demo runs in a few seconds but reports realistic numbers.
        $elapsed = ($frame / $Frames) * ($TotalBytes / [Math]::Max(1, $BytesPerSecond))
        if ($TotalBytes -le 0) { $elapsed = ($frame / $Frames) * 20 }
        $received = if ($TotalBytes -gt 0) { [Math]::Min($TotalBytes, $TotalBytes * ($frame / $Frames)) } else { 41943040 * ($frame / $Frames) }
        $window = $elapsed - $lastSampleAt
        if ($window -gt 0) {
            $instant = ($received - $lastSampleBytes) / $window
            $speed = if ($speed -le 0) { $instant } else { (0.65 * $speed) + (0.35 * $instant) }
            $lastSampleAt = $elapsed
            $lastSampleBytes = $received
        }
        $remaining = if (($TotalBytes -gt 0) -and ($speed -gt 2048)) { ($TotalBytes - $received) / $speed } else { -1 }
        $counter = ''
        if ($ItemCount -gt 0) { $counter = ('{0,6}/{1,5} {2}' -f [int][Math]::Round($ItemCount * ($frame / $Frames)), $ItemCount, $ItemWord) }
        $arguments = @{
            Activity = $Activity; ReceivedBytes = $received; TotalBytes = $TotalBytes
            BytesPerSecond = $speed; ElapsedSeconds = $elapsed; RemainingSeconds = $remaining
        }
        if ($counter) { $arguments['Counter'] = $counter }
        if ($frame -eq $Frames) { $arguments['Completed'] = $true; $arguments['RemainingSeconds'] = 0 }
        Show-TransferProgress @arguments
        Start-Sleep -Milliseconds $FrameMilliseconds
    }
    $reportedSeconds = if ($TotalBytes -gt 0) { $TotalBytes / [Math]::Max(1, $BytesPerSecond) } else { 20 }
    $reportedBytes = if ($TotalBytes -gt 0) { $TotalBytes } else { 838860800 }
    Complete-TransferProgress -Activity $Activity -Summary ("{0} finished in {1}, average {2}/s" -f (Format-ByteSize $reportedBytes), (Format-DurationClock $reportedSeconds), (Format-ByteSize $BytesPerSecond))
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host '   Progress bar demo (no files are downloaded)' -ForegroundColor Cyan
Write-Host "   Console width in use: $(Get-ProgressLineWidth)" -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan

Write-Host ''
Write-Host '[*] Downloading Eclipse Temurin JDK 17 (x64) from Adoptium...' -ForegroundColor Yellow
Invoke-SimulatedTransfer -Activity 'Downloading Eclipse Temurin JDK 17' -TotalBytes 199229440 -BytesPerSecond 4300000

Write-Host ''
Write-Host '[*] Downloading Android command-line tools...' -ForegroundColor Yellow
Invoke-SimulatedTransfer -Activity 'Downloading Android command-line tools' -TotalBytes 152043520 -BytesPerSecond 11500000 -Frames 45

Write-Host ''
Write-Host '[*] Extracting Flutter SDK...' -ForegroundColor Yellow
Invoke-SimulatedTransfer -Activity 'Extracting Flutter SDK' -TotalBytes 1073741824 -BytesPerSecond 96000000 -ItemCount 42318 -Frames 50 -FrameMilliseconds 40

Write-Host ''
Write-Host '[*] Downloading NDK (server reports no size)...' -ForegroundColor Yellow
Invoke-SimulatedTransfer -Activity 'Downloading NDK' -TotalBytes 0 -BytesPerSecond 6400000 -Frames 40

Write-Host ''
Write-Host 'Demo finished. During a real install these bars show the live numbers for' -ForegroundColor Gray
Write-Host 'every download, extraction, and copy in the Java, Android SDK, and Flutter flows.' -ForegroundColor Gray
