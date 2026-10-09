# Runs on Windows PowerShell 5.1 and PowerShell 7+.
# Exercises the transfer-progress helpers of Android_SDK.ps1 without starting the menu,
# by pulling the function definitions out of the script with the PowerShell AST parser.
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'Android_SDK.ps1'
Write-Host "Testing $scriptPath on $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))" -ForegroundColor Cyan

$script:Checks = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Name)
    $script:Checks++
    if ([string]$Expected -ne [string]$Actual) {
        $script:Failures.Add("$Name -> expected [$Expected] but got [$Actual]")
        Write-Host "  FAIL $Name : expected [$Expected] got [$Actual]" -ForegroundColor Red
    } else { Write-Host "  ok   $Name = [$Actual]" -ForegroundColor DarkGray }
}

function Assert-True {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Name)
    $script:Checks++
    if (-not $Condition) {
        $script:Failures.Add($Name)
        Write-Host "  FAIL $Name" -ForegroundColor Red
    } else { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
}

# --- 1. The installer script must parse cleanly -----------------------------
Write-Host "`n[1] Parsing Android_SDK.ps1" -ForegroundColor Yellow
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
Assert-Equal 0 @($parseErrors).Count 'No PowerShell parse errors'
if (@($parseErrors).Count -gt 0) { $parseErrors | ForEach-Object { Write-Host "    line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red } }

# --- 2. Load only the progress helpers --------------------------------------
$wanted = @(
    'Test-InlineProgressSupported', 'Get-ProgressLineWidth', 'Format-ByteSize', 'Format-DurationClock',
    'Show-TransferProgress', 'Close-InlineProgressLine', 'Reset-TransferProgress', 'Complete-TransferProgress',
    'Get-SmoothedSpeed', 'Copy-SingleFile', 'Receive-FileWithProgress', 'Receive-FileSimple', 'Download-File',
    'Expand-ZipWithProgress', 'Expand-ArchiveWithProgress', 'Copy-TreeWithProgress', 'Copy-FileWithProgress',
    'Get-SdkLicenseAnswers', 'Get-SdkLicenseStatusFromText', 'Get-SdkLicenseFileHashes', 'Write-SdkLicenseFiles'
)
$definitions = $ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($wanted -contains $node.Name)
    }, $true)
$loaded = @($definitions | ForEach-Object { $_.Name })
foreach ($name in $wanted) {
    if ($loaded -notcontains $name) { throw "Function $name was not found in Android_SDK.ps1" }
}
foreach ($definition in $definitions) { Invoke-Expression $definition.Extent.Text }
Write-Host "`n[2] Loaded helpers: $($loaded -join ', ')" -ForegroundColor Yellow

# --- 3. Size and duration formatting ----------------------------------------
Write-Host "`n[3] Formatting helpers" -ForegroundColor Yellow
Assert-Equal 'unknown' (Format-ByteSize -1) 'Negative size reads unknown'
Assert-Equal '0 B' (Format-ByteSize 0) 'Zero bytes'
Assert-Equal '512 B' (Format-ByteSize 512) 'Bytes stay in B'
Assert-Equal '2 KB' (Format-ByteSize 2048) 'Kilobytes'
Assert-Equal '5.0 MB' (Format-ByteSize 5242880) 'Megabytes use one decimal'
Assert-Equal '3.00 GB' (Format-ByteSize 3221225472) 'Gigabytes use two decimals'
Assert-Equal '--:--' (Format-DurationClock -1) 'Unknown remaining time'
Assert-Equal '00:00' (Format-DurationClock 0) 'Zero seconds'
Assert-Equal '00:45' (Format-DurationClock 45) 'Seconds only'
Assert-Equal '02:05' (Format-DurationClock 125) 'Minutes and seconds'
Assert-Equal '1:02:05' (Format-DurationClock 3725) 'Hours, minutes and seconds'

# --- 4. The inline bar never exceeds the console width ----------------------
Write-Host "`n[4] Inline progress bar layout" -ForegroundColor Yellow
function Test-InlineProgressSupported { return $true }
function Get-ProgressLineWidth { return $script:StubConsoleWidth }

function Get-RenderedProgressLine {
    param([hashtable]$Arguments)
    $records = @(Show-TransferProgress @Arguments 6>&1)
    $text = -join ($records | ForEach-Object { $_.ToString() })
    return ($text -replace "`r", '')
}

$script:InlineProgressActive = $false
$states = @(
    @{ Name = 'start'; ReceivedBytes = 0; TotalBytes = 199229440; BytesPerSecond = 0; ElapsedSeconds = 0; RemainingSeconds = -1 },
    @{ Name = 'partial MB'; ReceivedBytes = 81500000; TotalBytes = 199229440; BytesPerSecond = 4320000; ElapsedSeconds = 18.9; RemainingSeconds = 25.2 },
    @{ Name = 'GB scale'; ReceivedBytes = 3200000000; TotalBytes = 9800000000; BytesPerSecond = 105000000; ElapsedSeconds = 30.5; RemainingSeconds = 62.9 },
    @{ Name = 'slow KB/s'; ReceivedBytes = 950000; TotalBytes = 199229440; BytesPerSecond = 48000; ElapsedSeconds = 19.8; RemainingSeconds = 3900 },
    @{ Name = 'unknown size'; ReceivedBytes = 33500000; TotalBytes = 0; BytesPerSecond = 2100000; ElapsedSeconds = 16; RemainingSeconds = -1 },
    @{ Name = 'with counter'; ReceivedBytes = 120500000; TotalBytes = 375000000; BytesPerSecond = 85200000; ElapsedSeconds = 1.4; RemainingSeconds = 3; Counter = ('{0,6}/{1,5} files' -f 1204, 9830) },
    @{ Name = 'completed'; ReceivedBytes = 199229440; TotalBytes = 199229440; BytesPerSecond = 4100000; ElapsedSeconds = 46.3; RemainingSeconds = 0; Completed = $true }
)
foreach ($width in @(40, 60, 76, 80, 100, 112, 120, 160, 200)) {
    $script:StubConsoleWidth = $width
    foreach ($state in $states) {
        $arguments = @{ Activity = 'Downloading test file' }
        foreach ($key in $state.Keys) { if ($key -ne 'Name') { $arguments[$key] = $state[$key] } }
        $line = Get-RenderedProgressLine -Arguments $arguments
        Assert-True ($line.Length -le ($width - 1)) "width $width / $($state.Name): line fits ($($line.Length) <= $($width - 1))"
        Assert-True ($line -match '^ {4}\[') "width $width / $($state.Name): bar frame is drawn"
        Assert-True ($line -match '\] ') "width $width / $($state.Name): bar frame is closed"
        if ($state.ReceivedBytes -gt 0) {
            Assert-True ($line -match '#') "width $width / $($state.Name): bar shows progress"
        }
        if (($state.TotalBytes -gt 0) -and ($width -ge 76)) {
            Assert-True ($line -match 'MB|GB') "width $width / $($state.Name): shows a size"
        }
        if ($width -ge 112) {
            Assert-True ($line -match 'left|--:--') "width $width / $($state.Name): shows the time-left column"
        }
    }
}

# Percentage, size, speed, and remaining time are all present on a normal frame.
$script:StubConsoleWidth = 120
$line = Get-RenderedProgressLine -Arguments @{
    Activity = 'Downloading Eclipse Temurin JDK 17'; ReceivedBytes = 81500000; TotalBytes = 199229440
    BytesPerSecond = 4320000; ElapsedSeconds = 18.9; RemainingSeconds = 25.2
}
Write-Host "  sample: |$line|" -ForegroundColor Cyan
Assert-True ($line -match '40\.9%') 'Shows the percentage'
Assert-True ($line -match '77\.7 MB') 'Shows megabytes downloaded'
Assert-True ($line -match '190\.0 MB') 'Shows the total megabytes'
Assert-True ($line -match '4\.1 MB/s') 'Shows the download speed'
Assert-True ($line -match 'elapsed 00:18') 'Shows elapsed time'
Assert-True ($line -match 'left 00:25') 'Shows time remaining'

# A completed transfer ends on a full green bar at 100 percent.
$done = Get-RenderedProgressLine -Arguments @{
    Activity = 'Downloading Eclipse Temurin JDK 17'; ReceivedBytes = 199229440; TotalBytes = 199229440
    BytesPerSecond = 4100000; ElapsedSeconds = 46.3; RemainingSeconds = 0; Completed = $true
}
Assert-True ($done -match '100\.0%') 'Completed frame reaches 100 percent'
Assert-True ($done -notmatch '-') 'Completed bar has no empty segment'

# Close-InlineProgressLine emits exactly one newline and only once.
$script:InlineProgressActive = $true
$newlines = @(Close-InlineProgressLine 6>&1)
Assert-Equal 1 @($newlines).Count 'Inline bar line is closed with one newline'
Assert-Equal $false $script:InlineProgressActive 'Inline bar state is cleared'
Assert-Equal 0 @(Close-InlineProgressLine 6>&1).Count 'No extra newline when no bar is active'

# --- 5. Extraction with progress --------------------------------------------
Write-Host "`n[5] Expand-ZipWithProgress" -ForegroundColor Yellow
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch { }
$work = Join-Path ([IO.Path]::GetTempPath()) ('ProgressTests-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $work 'payload'
$zipPath = Join-Path $work 'payload.zip'
$extracted = Join-Path $work 'extracted'
New-Item -ItemType Directory -Path (Join-Path $payload 'nested\deeper') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $payload 'root.txt') -Value 'root file' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $payload 'nested\one.bin') -Value ('A' * 5000) -Encoding UTF8
Set-Content -LiteralPath (Join-Path $payload 'nested\deeper\two.bin') -Value ('B' * 9000) -Encoding UTF8
[IO.Compression.ZipFile]::CreateFromDirectory($payload, $zipPath)

$script:StubConsoleWidth = 120
Expand-ZipWithProgress -LiteralPath $zipPath -DestinationPath $extracted -Activity 'Extracting test archive'
$expected = @(Get-ChildItem -LiteralPath $payload -Recurse -File | ForEach-Object { $_.FullName.Substring($payload.Length).TrimStart('\') } | Sort-Object)
$actual = @(Get-ChildItem -LiteralPath $extracted -Recurse -File | ForEach-Object { $_.FullName.Substring($extracted.Length).TrimStart('\') } | Sort-Object)
Assert-Equal ($expected -join '|') ($actual -join '|') 'Every archive entry is extracted'
foreach ($relative in $expected) {
    $left = (Get-FileHash -LiteralPath (Join-Path $payload $relative) -Algorithm SHA256).Hash
    $right = (Get-FileHash -LiteralPath (Join-Path $extracted $relative) -Algorithm SHA256).Hash
    Assert-Equal $left $right "Content of $relative survives extraction"
}

# An entry that tries to escape the destination folder must be skipped.
$slipZip = Join-Path $work 'slip.zip'
$slipOut = Join-Path $work 'slip-out'
New-Item -ItemType Directory -Path $slipOut -Force | Out-Null
$slipArchive = [IO.Compression.ZipFile]::Open($slipZip, [IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $slipArchive.CreateEntry('../escaped.txt')
    $writer = New-Object IO.StreamWriter($entry.Open())
    try { $writer.Write('should never be written outside the destination') } finally { $writer.Dispose() }
    $safeEntry = $slipArchive.CreateEntry('inside.txt')
    $safeWriter = New-Object IO.StreamWriter($safeEntry.Open())
    try { $safeWriter.Write('safe') } finally { $safeWriter.Dispose() }
} finally { $slipArchive.Dispose() }
$warnings = @(Expand-ZipWithProgress -LiteralPath $slipZip -DestinationPath $slipOut -Activity 'Extracting slip archive' 3>&1)
Assert-True (-not (Test-Path -LiteralPath (Join-Path $work 'escaped.txt'))) 'Zip-slip entry is not written outside the destination'
Assert-True (Test-Path -LiteralPath (Join-Path $slipOut 'inside.txt')) 'Safe entry next to the zip-slip entry is still extracted'
Assert-True (@($warnings).Count -gt 0) 'Unsafe entry is reported as a warning'

# --- 6. Copy helpers ---------------------------------------------------------
Write-Host "`n[6] Copy-TreeWithProgress and Copy-FileWithProgress" -ForegroundColor Yellow
$treeTarget = Join-Path $work 'tree-copy'
New-Item -ItemType Directory -Path $treeTarget -Force | Out-Null
Copy-TreeWithProgress -Source $payload -Destination $treeTarget -Label 'test tree'
$copied = @(Get-ChildItem -LiteralPath $treeTarget -Recurse -File | ForEach-Object { $_.FullName.Substring($treeTarget.Length).TrimStart('\') } | Sort-Object)
Assert-Equal ($expected -join '|') ($copied -join '|') 'Folder copy keeps every file'
foreach ($relative in $expected) {
    $left = (Get-FileHash -LiteralPath (Join-Path $payload $relative) -Algorithm SHA256).Hash
    $right = (Get-FileHash -LiteralPath (Join-Path $treeTarget $relative) -Algorithm SHA256).Hash
    Assert-Equal $left $right "Content of $relative survives the folder copy"
}

# Attributes and empty folders must survive the folder copy too.
$attributed = Join-Path $work 'attributed'
New-Item -ItemType Directory -Path (Join-Path $attributed 'sub\empty-dir') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $attributed 'plain.txt') -Value 'plain content' -Encoding UTF8
$flagged = Join-Path $attributed 'sub\flagged.txt'
Set-Content -LiteralPath $flagged -Value 'flagged content' -Encoding UTF8
Set-ItemProperty -LiteralPath $flagged -Name Attributes -Value ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::ReadOnly)
$attributedTarget = Join-Path $work 'attributed-copy'
New-Item -ItemType Directory -Path $attributedTarget -Force | Out-Null
Copy-TreeWithProgress -Source $attributed -Destination $attributedTarget -Label 'attributed tree'
Assert-True (Test-Path -LiteralPath (Join-Path $attributedTarget 'plain.txt')) 'Folder copy keeps top-level files'
Assert-True (Test-Path -LiteralPath (Join-Path $attributedTarget 'sub\empty-dir') -PathType Container) 'Folder copy keeps empty folders'
$flaggedCopy = Join-Path $attributedTarget 'sub\flagged.txt'
Assert-True (Test-Path -LiteralPath $flaggedCopy) 'Folder copy keeps hidden files'
Assert-Equal (Get-FileHash -LiteralPath $flagged -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $flaggedCopy -Algorithm SHA256).Hash 'Hidden file content survives the copy'
$copyAttributes = (Get-Item -LiteralPath $flaggedCopy -Force).Attributes
Assert-True (($copyAttributes -band [IO.FileAttributes]::Hidden) -eq [IO.FileAttributes]::Hidden) 'Hidden attribute is preserved'
Assert-True (($copyAttributes -band [IO.FileAttributes]::ReadOnly) -eq [IO.FileAttributes]::ReadOnly) 'ReadOnly attribute is preserved'
Set-ItemProperty -LiteralPath $flaggedCopy -Name Attributes -Value ([IO.FileAttributes]::Normal)
Set-ItemProperty -LiteralPath $flagged -Name Attributes -Value ([IO.FileAttributes]::Normal)

$fileTarget = Join-Path $work 'single-copy.bin'
Copy-FileWithProgress -Source (Join-Path $payload 'nested\deeper\two.bin') -Destination $fileTarget -Label 'two.bin'
Assert-True (Test-Path -LiteralPath $fileTarget) 'Single file copy creates the destination'
Assert-Equal (Get-FileHash -LiteralPath (Join-Path $payload 'nested\deeper\two.bin') -Algorithm SHA256).Hash (Get-FileHash -LiteralPath $fileTarget -Algorithm SHA256).Hash 'Single file copy keeps the content'

# --- 7. Download-File against a real HTTPS endpoint --------------------------
Write-Host "`n[7] Download-File with a live progress bar" -ForegroundColor Yellow
$downloadTarget = Join-Path $work 'downloaded.bin'
$downloadUrl = 'https://raw.githubusercontent.com/Sajedur0/Android-SDK-Installer/main/README.md'
try {
    Download-File $downloadUrl $downloadTarget 'README.md'
    Assert-True ((Get-Item -LiteralPath $downloadTarget).Length -gt 1024) 'Downloaded file is not empty'
    $head = (Get-Content -LiteralPath $downloadTarget -TotalCount 1)
    Assert-True ($head -match 'Android SDK') 'Downloaded content looks like the README'
} catch {
    Write-Host "  SKIP live download: $($_.Exception.Message)" -ForegroundColor Yellow
}

# A failed download must not leave a partial file behind.
$failedTarget = Join-Path $work 'missing.bin'
$failed = $false
try { Download-File 'https://raw.githubusercontent.com/Sajedur0/Android-SDK-Installer/main/does-not-exist-404.bin' $failedTarget 'missing file' }
catch { $failed = $true }
Assert-True $failed 'A 404 download raises an error'
Assert-True (-not (Test-Path -LiteralPath $failedTarget)) 'A failed download leaves no partial file'

# --- 8. Android SDK license helpers -------------------------------------------
Write-Host "`n[8] Android SDK license helpers" -ForegroundColor Yellow

# The answer sheet feeds one answer per prompt, so a captured or piped run never stalls.
Assert-Equal 40 @(Get-SdkLicenseAnswers 'y').Count 'Answer sheet covers plenty of prompts'
Assert-Equal 'y' (@(Get-SdkLicenseAnswers 'y')[0]) 'Answer sheet can accept licenses'
Assert-Equal 3 @(Get-SdkLicenseAnswers 'n' 3).Count 'Answer sheet honors the requested count'
Assert-Equal 'n' (@(Get-SdkLicenseAnswers 'n' 3)[2]) 'Answer sheet can decline licenses'

# sdkmanager reports acceptance in text, which is more reliable than its exit code.
Assert-Equal 'Accepted' (Get-SdkLicenseStatusFromText 'All SDK package licenses accepted.') 'Success text is recognized'
Assert-Equal 'NotAccepted' (Get-SdkLicenseStatusFromText '8 of 8 SDK package licenses not accepted.') 'Unaccepted licenses are recognized'
Assert-Equal 'Accepted' (Get-SdkLicenseStatusFromText '0 of 8 SDK package licenses not accepted.') 'Nothing pending counts as accepted'
Assert-Equal 'NotAccepted' (Get-SdkLicenseStatusFromText "Loading local repository...`n2 of 8 SDK package licenses not accepted.") 'The summary is found after other output'
$colored = 'Computing updates... ' + [string][char]27 + '[32mAll SDK package licenses accepted.' + [string][char]27 + '[0m'
Assert-Equal 'Accepted' (Get-SdkLicenseStatusFromText $colored) 'ANSI colors do not hide the result'
Assert-Equal 'Unknown' (Get-SdkLicenseStatusFromText 'Computing updates...') 'Unrelated output stays unknown'
Assert-Equal 'Unknown' (Get-SdkLicenseStatusFromText '') 'Empty output stays unknown'
Assert-Equal 'Unknown' (Get-SdkLicenseStatusFromText $null) 'Missing output stays unknown'

$hashes = Get-SdkLicenseFileHashes
Assert-True ($hashes.Keys -contains 'android-sdk-license') 'The main SDK license is covered'
Assert-True ($hashes.Keys -contains 'android-sdk-preview-license') 'The preview license is covered'
foreach ($name in $hashes.Keys) {
    Assert-True (@($hashes[$name]).Count -ge 1) "License $name has at least one hash"
    foreach ($hash in $hashes[$name]) { Assert-True ($hash -match '^[0-9a-f]{40}$') "License $name hash is SHA-1 hex" }
}

# The fallback writes real files under <SDK root>\licenses and keeps hashes already on disk.
$sdkRoot = Join-Path $work 'sdk-root'
Write-SdkLicenseFiles -SdkRoot $sdkRoot
$licenseFile = Join-Path $sdkRoot 'licenses\android-sdk-license'
Assert-True (Test-Path -LiteralPath $licenseFile) 'The SDK license file is written'
Assert-True (@(Get-Content -LiteralPath $licenseFile) -contains $hashes['android-sdk-license'][0]) 'Published hashes are written'
$kept = 'ffffffffffffffffffffffffffffffffffffffff'
Set-Content -LiteralPath $licenseFile -Value $kept -Encoding Ascii
Write-SdkLicenseFiles -SdkRoot $sdkRoot
$licenseLines = @(Get-Content -LiteralPath $licenseFile)
Assert-True ($licenseLines -contains $kept) 'A hash already on disk is kept'
Assert-True ($licenseLines -contains $hashes['android-sdk-license'][0]) 'Published hashes are added next to it'
Assert-True (Test-Path -LiteralPath (Join-Path $sdkRoot 'licenses\google-gdk-license')) 'Every published license file is written'

# Regression guard: license prompts must reach the console instead of a PowerShell pipeline,
# otherwise sdkmanager hides "Accept? (y/N)" and every license defaults to "no".
$scriptText = Get-Content -LiteralPath $scriptPath -Raw
Assert-True ($scriptText -notmatch 'Invoke-ExternalToHost[^\r\n]*--licenses') 'License prompts are not piped through PowerShell'
Assert-True ($scriptText -match 'function Invoke-ExternalInteractive') 'A console-attached runner is defined'
Assert-True ($scriptText -match 'Invoke-ExternalInteractive -Path \$SdkManager -ArgumentList \$licenseArgs') 'Licenses run with the console attached'
Assert-True ($scriptText -match '\$licenseArgs = @\("--sdk_root=') 'The license arguments point at --licenses'
Assert-True ($scriptText -notmatch '\|\s*Out-Host') 'Native output is no longer sent through Out-Host'

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

# --- Summary -----------------------------------------------------------------
Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "FAILED: $($script:Failures.Count) of $script:Checks checks" -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
Write-Host "PASSED: all $script:Checks checks" -ForegroundColor Green
exit 0
