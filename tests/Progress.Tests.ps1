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
    'Get-WebExceptionStatusCode', 'Get-CmdlineToolsDownloadUrl',
    'Expand-ZipWithProgress', 'Expand-ArchiveWithProgress', 'Copy-TreeWithProgress', 'Copy-FileWithProgress',
    'Get-SdkLicenseAnswers', 'Get-SdkLicenseStatusFromText', 'Get-SdkLicenseFileHashes', 'Write-SdkLicenseFiles',
    'Normalize-PathEntry', 'Get-ShortHash', 'Get-RawPathVariable', 'Get-VolumeFreeBytes', 'Assert-DiskSpace',
    'Get-FileSha256', 'Test-FileSha256', 'Test-InteractiveConsoleHost', 'Read-InstallerInput',
    'Get-SdkPackageMarkerPath', 'Test-SdkPackagePresent', 'Get-InstalledSdkPackagesOnDisk', 'Get-PartialSdkPackageFolders',
    'Test-SdkPackageInstalled', 'Get-SdkPackageNamesFromText', 'Get-LatestSdkPackage', 'Get-LatestVersionFolder',
    'Test-CmdlineToolsDirectory', 'Test-AndroidSdkRoot', 'Get-SdkPackageManagerHint',
    'Get-EmulatorAbi', 'Get-DefaultSystemImage', 'Test-SystemImagePackage', 'ConvertTo-AvdName',
    'Get-AvdRoot', 'Get-AvdNames', 'Get-SystemImageFolders', 'Get-SdkPackageManagerPaths',
    'ConvertFrom-FlutterReleaseCache', 'Test-InstallerFlag'
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
$liveDownloadWorked = $false
try {
    Download-File $downloadUrl $downloadTarget 'README.md'
    Assert-True ((Get-Item -LiteralPath $downloadTarget).Length -gt 1024) 'Downloaded file is not empty'
    $head = (Get-Content -LiteralPath $downloadTarget -TotalCount 1)
    Assert-True ($head -match 'Android SDK') 'Downloaded content looks like the README'
    $liveDownloadWorked = $true
} catch {
    Write-Host "  SKIP live download: $($_.Exception.Message)" -ForegroundColor Yellow
}

# A failed download must not leave a partial file behind.
$failedTarget = Join-Path $work 'missing.bin'
$failed = $false
$failedMessage = ''
try { Download-File 'https://raw.githubusercontent.com/Sajedur0/Android-SDK-Installer/main/does-not-exist-404.bin' $failedTarget 'missing file' }
catch { $failed = $true; $failedMessage = $_.Exception.Message }
Assert-True $failed 'A 404 download raises an error'
if ($liveDownloadWorked) {
    # The 404 arrives wrapped as 'Exception calling "GetResponse"...', so it only reads as HTTP 404
    # when the WebException is unwrapped. Without that the download is needlessly retried instead.
    Assert-True ($failedMessage -match 'HTTP 404') 'A 404 is reported as HTTP 404 at once, not retried as a transient failure'
}
Assert-True (-not (Test-Path -LiteralPath $failedTarget)) 'A failed download leaves no partial file'
Assert-True (-not (Test-Path -LiteralPath "$failedTarget.part")) 'A failed download leaves no resumable chunk either'
if (Test-Path -LiteralPath $downloadTarget) {
    Assert-True (-not (Test-Path -LiteralPath "$downloadTarget.part")) 'A finished download moves its partial file into place'
}

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

# --- 9. The optional Android Emulator stays out of Machine PATH --------------
# The installer never downloads the Emulator, so it must never claim <SDK>\emulator for PATH either.
$entriesBlock = [regex]::Match($scriptText, '(?s)\$entries = @\(.*?\r?\n    \)').Value
Assert-True ($entriesBlock.Length -gt 0) 'The Machine PATH entry list was found'
Assert-True ($entriesBlock -notmatch 'emulator') 'The Emulator folder is not an automatic PATH entry'
Assert-True ($scriptText -match 'Get-PathEntryScopes \$emulatorRoot') 'The environment check reports the Emulator PATH state'

# --- 10. Installed, incomplete, or absent: package markers -------------------
Write-Host "`n[10] SDK package markers" -ForegroundColor Yellow
$fakeSdk = Join-Path $work 'fake-sdk'
foreach ($dir in @('ndk\30.0.16248370', 'ndk\27.0.12077973', 'cmake\3.22.1\bin', 'platform-tools', 'platforms\android-36')) {
    $null = New-Item -ItemType Directory -Path (Join-Path $fakeSdk $dir) -Force
}
Set-Content -LiteralPath (Join-Path $fakeSdk 'ndk\30.0.16248370\source.properties') -Value 'Pkg.Desc = Android NDK' -Encoding Ascii
foreach ($file in @('cmake\3.22.1\bin\cmake.exe', 'platform-tools\adb.exe', 'platforms\android-36\android.jar')) {
    Set-Content -LiteralPath (Join-Path $fakeSdk $file) -Value 'stub' -Encoding Ascii
}

Assert-Equal (Join-Path $fakeSdk 'ndk\30.0.16248370\source.properties') (Get-SdkPackageMarkerPath -SdkRoot $fakeSdk -Package 'ndk;30.0.16248370') 'The NDK marker is source.properties'
Assert-Equal (Join-Path $fakeSdk 'cmake\3.22.1\bin\cmake.exe') (Get-SdkPackageMarkerPath -SdkRoot $fakeSdk -Package 'cmake;3.22.1') 'The CMake marker is its own executable'
Assert-Equal (Join-Path $fakeSdk 'platforms\android-36\android.jar') (Get-SdkPackageMarkerPath -SdkRoot $fakeSdk -Package 'platforms;android-36') 'The platform marker is android.jar'
Assert-Equal '' (Get-SdkPackageMarkerPath -SdkRoot $fakeSdk -Package 'unknown;1.0') 'An unknown package has no marker'
Assert-True (Test-SdkPackagePresent -SdkRoot $fakeSdk -Package 'ndk;30.0.16248370') 'A complete NDK counts as installed'
Assert-True (-not (Test-SdkPackagePresent -SdkRoot $fakeSdk -Package 'ndk;27.0.12077973')) 'A folder without its marker is not installed'
Assert-Equal (Join-Path $fakeSdk 'ndk\30.0.16248370') (Get-LatestVersionFolder (Join-Path $fakeSdk 'ndk') 'source.properties') 'Only complete version folders are selected'
$partialFolders = @(Get-PartialSdkPackageFolders -SdkRoot $fakeSdk)
Assert-Equal 'ndk\27.0.12077973' ($partialFolders -join ',') 'The half-extracted NDK folder is reported'

$null = New-Item -ItemType Directory -Path (Join-Path $fakeSdk 'build-tools\36.0.0') -Force
Set-Content -LiteralPath (Join-Path $fakeSdk 'build-tools\36.0.0\aapt2.exe') -Value 'stub' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $fakeSdk 'build-tools\36.0.0\package.xml') -Value '<repository><ns2:localPackage path="build-tools;36.0.0" obsolete="false"><file-size>1</file-size></ns2:localPackage></repository>' -Encoding Ascii
$installed = @(Get-InstalledSdkPackagesOnDisk $fakeSdk)
Assert-True ($installed -contains 'build-tools;36.0.0') 'package.xml is read back as installed'
Assert-True ($installed -contains 'platform-tools') 'adb.exe marks platform-tools as installed'
Assert-True ($installed -contains 'ndk;30.0.16248370') 'A complete NDK is recognised without package.xml'
Assert-True (-not ($installed -contains 'ndk;27.0.12077973')) 'An incomplete NDK is never advertised as installed'
Assert-True (Test-SdkPackageInstalled -Installed $installed -Package 'PLATFORM-TOOLS') 'The membership check ignores case'
Assert-True (Test-AndroidSdkRoot $fakeSdk) 'A folder holding adb.exe counts as an Android SDK'
Assert-True (-not (Test-AndroidSdkRoot $work)) 'A random folder is not an Android SDK'

# --- 11. The package catalog is parsed the same way by both tools -----------
Write-Host "`n[11] SDK package catalog parsing" -ForegroundColor Yellow
$catalogLines = @(
    'Loading package information...',
    '  build-tools;36.0.0       | 36.0.0         | Android SDK Build-Tools 36        | build-tools/36.0.0',
    '  cmake;3.22.1             | 3.22.1         | CMake 3.22.1                      | cmake/3.22.1',
    '  cmake;4.1.2              | 4.1.2          | CMake 4.1.2                       | cmake/4.1.2',
    '  ndk;30.0.16248370        | 30.0.16248370  | NDK (Side by side) 30.0.16248370 | ndk/30.0.16248370',
    '  ndk/26.1.10909125        | 26.1.10909125  | NDK (Side by side)                | ndk/26.1.10909125',
    'Patch file                       | obsolete'
)
$parsed = @(Get-SdkPackageNamesFromText ($catalogLines -join "`n"))
Assert-True ($parsed -contains 'build-tools;36.0.0') 'Build Tools are parsed from the table'
Assert-True ($parsed -contains 'cmake;3.22.1') 'CMake versions are parsed'
Assert-True ($parsed -contains 'ndk;30.0.16248370') 'NDK versions are parsed'
Assert-True ($parsed -contains 'ndk;26.1.10909125') 'The Android CLI slash separator is normalised'
Assert-True (-not ($parsed -contains 'Patch file')) 'Unrelated rows are ignored'
Assert-Equal 'build-tools;36.0.0' (Get-LatestSdkPackage $parsed 'build-tools' '36') 'The requested Build Tools major is honoured'
Assert-Equal 'cmake;3.22.1' (Get-LatestSdkPackage $parsed 'cmake' '3') 'CMake 3.x wins when a major is requested'
Assert-Equal 'cmake;4.1.2' (Get-LatestSdkPackage $parsed 'cmake') 'Without a major the newest CMake is chosen'
Assert-Equal 'ndk;30.0.16248370' (Get-LatestSdkPackage $parsed 'ndk') 'The newest NDK is chosen'
Assert-Equal '' (Get-LatestSdkPackage $parsed 'patch') 'An absent package resolves to nothing'

# --- 12. Disk space, hashes, and prompts that cannot be answered ------------
Write-Host "`n[12] Disk space, hashes, and prompt safety" -ForegroundColor Yellow
Assert-True ((Get-VolumeFreeBytes $work) -gt 0) 'Free space of the test folder is measurable'
$diskOk = $true
try { Assert-DiskSpace -Path $work -RequiredBytes 1 -Label 'the test' } catch { $diskOk = $false }
Assert-True $diskOk 'A small disk-space requirement passes'
$diskThrew = $false
try { Assert-DiskSpace -Path $work -RequiredBytes 1PB -Label 'the test' } catch { $diskThrew = $true }
Assert-True $diskThrew 'An impossible disk-space requirement is refused before downloading'

$hashFile = Join-Path $work 'hash-me.txt'
Set-Content -LiteralPath $hashFile -Value 'android-sdk-installer' -Encoding Ascii
$hash = Get-FileSha256 $hashFile
Assert-True ($hash -match '^[0-9A-F]{64}$') 'SHA-256 is computed for a download'
Assert-True (Test-FileSha256 -Path $hashFile -Expected $hash.ToLowerInvariant()) 'A published hash is compared case-insensitively'
Assert-True (-not (Test-FileSha256 -Path $hashFile -Expected ('0' * 64))) 'A mismatching hash is rejected'
Assert-True (Test-FileSha256 -Path $hashFile) 'No published hash means nothing to verify'

# A prompt that nobody can answer has to fall back to its default, never hang the run.
$env:ANDROID_SDK_INSTALLER_ASSUME_NONINTERACTIVE = '1'
try {
    Assert-True (-not (Test-InteractiveConsoleHost)) 'A non-interactive session is detected'
    Assert-Equal 'Y' (Read-InstallerInput -Prompt 'unanswered prompt' -Default 'Y' -Choices 'Y|N') 'An unanswered prompt uses its default'
    Assert-Equal 'the Android SDK command-line tools --licenses' (Get-SdkPackageManagerHint -SdkManager (Join-Path $work 'no-such\sdkmanager.bat') -AndroidCli '' -SdkRoot 'C:\Android' -Arguments '--licenses') 'A missing package manager is named generically'
    $fakeManager = Join-Path $fakeSdk 'cmdline-tools\bin\sdkmanager.bat'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $fakeManager) -Force
    Set-Content -LiteralPath $fakeManager -Value '@echo off' -Encoding Ascii
    $hint = Get-SdkPackageManagerHint -SdkManager $fakeManager -AndroidCli '' -SdkRoot $fakeSdk -Arguments 'install "ndk;30.0.16248370"'
    Assert-True ($hint.Contains($fakeManager)) 'An existing sdkmanager is named in the repair hint'
    Assert-True ($hint -match '--sdk_root=') 'The repair hint repeats the SDK root'
} finally {
    Remove-Item -LiteralPath 'Env:\ANDROID_SDK_INSTALLER_ASSUME_NONINTERACTIVE' -ErrorAction SilentlyContinue
}

# --- 13. The raw PATH is preserved, and the expanding API is not used -------
Write-Host "`n[13] PATH handling" -ForegroundColor Yellow
Assert-Equal 'C:\Android\platform-tools' (Normalize-PathEntry 'C:\Android\platform-tools\') 'A trailing separator is removed'
Assert-Equal '' (Normalize-PathEntry '   ') 'A blank entry normalizes to empty'
$rawPath = Get-RawPathVariable -Scope 'Machine'
Assert-True ($null -ne $rawPath) 'The raw Machine PATH can be read'
Assert-True (@($rawPath.PSObject.Properties.Name) -contains 'Expandable') 'The raw value reports its registry kind'
$registryCatalog = Get-ShortHash 'C:\Android'
Assert-True ($registryCatalog -match '^[0-9a-f]{12}$') 'Cache file names are derived from the SDK root'
$emptyCatalogName = Get-ShortHash ''
Assert-Equal 'default' $emptyCatalogName 'An unknown SDK root still gets a usable cache name'

# --- 14. Regression guards for the fixes themselves --------------------------
Write-Host "`n[14] Regression guards" -ForegroundColor Yellow
$acceptFunction = [regex]::Match($scriptText, '(?s)function Accept-SdkLicenses.*?\r?\n}\r?\n').Value
$acceptPlain = $acceptFunction -replace '\s+', ' '
Assert-True ($acceptPlain -match "Mode -ne 'Auto'") 'Declined licenses are never written by hand in review mode'
Assert-True ($scriptText -match '-SkipInstalled') 'Already installed packages are skipped before a retry'
Assert-True ($scriptText -notmatch 'Retrying the same packages') 'A failed Android CLI does not re-download every package'
Assert-True ($scriptText -match 'PARTIAL') 'A core-only install is reported as partial, not verified'
Assert-True ($scriptText -match 'Get-PartialSdkPackageFolders') 'Incomplete package folders are named, not advertised'
Assert-True ($scriptText -match 'AddRange') 'Interrupted downloads resume instead of starting over'
Assert-True ($scriptText -match 'Test-FileSha256') 'Downloads are hash-verified when a hash is published'
Assert-True ($scriptText -match 'Assert-DiskSpace') 'Free space is checked before a multi-gigabyte download'
Assert-True ($scriptText -match 'JdkMaxMajor') 'A JDK newer than Gradle supports is kept out of JAVA_HOME'
Assert-True ($scriptText -notmatch "\[Environment\]::SetEnvironmentVariable\('Path',\s*\`$newValue") 'PATH is written through the raw registry helper'
Assert-True ($scriptText -match 'exit 1') 'A handled failure leaves a non-zero exit code'
Assert-Equal 2 ([regex]::Matches($scriptText, 'Read-Host')).Count 'Only the guarded helpers read the console'
$flutterSection = [regex]::Match($scriptText, '(?s)function Install-Flutter.*?FLUTTER INSTALLATION VERIFIED').Value
Assert-True ($flutterSection -match 'if \(\$licensesRecorded -or \$acceptForUser\)') 'Flutter only answers license prompts when they are already recorded'

# --- 15. Emulator and virtual device helpers --------------------------------
Write-Host "`n[15] Emulator and AVD helpers" -ForegroundColor Yellow

# The system image ABI follows the host CPU.
Assert-Equal 'x86_64' (Get-EmulatorAbi -Architecture 'AMD64') 'Intel/AMD hosts use x86_64 images'
Assert-Equal 'arm64-v8a' (Get-EmulatorAbi -Architecture 'ARM64') 'Windows on ARM uses arm64-v8a images'
Assert-Equal 'x86_64' (Get-EmulatorAbi -Architecture '') 'An unknown architecture falls back to x86_64'
Assert-Equal 'system-images;android-36;google_apis;x86_64' (Get-DefaultSystemImage -Api 36 -Abi 'x86_64') 'The default system image matches the API level and ABI'
Assert-Equal 'system-images;android-34;google_apis;arm64-v8a' (Get-DefaultSystemImage -Api 34 -Abi 'arm64-v8a') 'The default system image follows the API level'

# Package ids are validated before a multi-gigabyte download starts.
Assert-True (Test-SystemImagePackage 'system-images;android-36;google_apis;x86_64') 'A valid system image id is accepted'
Assert-True (Test-SystemImagePackage 'system-images;android-36;google_apis_playstore;arm64-v8a') 'A Play Store image id is accepted'
Assert-True (-not (Test-SystemImagePackage 'emulator')) 'A plain package is not a system image'
Assert-True (-not (Test-SystemImagePackage 'system-images;android-36;google_apis')) 'An incomplete system image id is rejected'
Assert-True (-not (Test-SystemImagePackage '')) 'An empty package id is rejected'

# AVD names are used as file names, so unsafe characters are replaced.
Assert-Equal 'Pixel_Api36' (ConvertTo-AvdName -Name '' -Api 36) 'An empty name gets an API-specific default'
Assert-Equal 'My_Phone' (ConvertTo-AvdName -Name 'My Phone!' -Api 36) 'Spaces and punctuation become underscores'
Assert-Equal 'Pixel_Api34' (ConvertTo-AvdName -Name '   ' -Api 34) 'A blank name falls back to the default'
Assert-Equal 'api36' (ConvertTo-AvdName -Name '__api36__' -Api 36) 'Repeated and edge underscores are trimmed'

# AVDs are read from the signed-in user's profile.
$profilePath = Join-Path $work 'profile'
$avdRoot = Join-Path (Join-Path $profilePath '.android') 'avd'
Assert-Equal $avdRoot (Get-AvdRoot -ProfilePath $profilePath) 'The AVD root follows the user profile'
$null = New-Item -ItemType Directory -Path (Join-Path $avdRoot 'Pixel_Api36.avd') -Force
Set-Content -LiteralPath (Join-Path $avdRoot 'Pixel_Api36.ini') -Value 'path=Pixel_Api36.avd' -Encoding Ascii
Assert-Equal 'Pixel_Api36' (@(Get-AvdNames -AvdRoot $avdRoot) -join ',') 'AVD ini files are listed'
Assert-Equal 0 @(Get-AvdNames -AvdRoot (Join-Path $work 'no-such-avd-root')).Count 'A missing AVD folder lists nothing'

# A system image needs its system.img before it counts as installed.
$emulatorSdk = Join-Path $work 'emulator-sdk'
$imageFolder = Join-Path $emulatorSdk 'system-images\android-36\google_apis\x86_64'
$null = New-Item -ItemType Directory -Path $imageFolder -Force
Set-Content -LiteralPath (Join-Path $imageFolder 'system.img') -Value 'stub image' -Encoding Ascii
Assert-Equal (Join-Path $emulatorSdk 'system-images\android-36\google_apis\x86_64\system.img') (Get-SdkPackageMarkerPath -SdkRoot $emulatorSdk -Package 'system-images;android-36;google_apis;x86_64') 'The system image marker is system.img'
Assert-True (Test-SdkPackagePresent -SdkRoot $emulatorSdk -Package 'system-images;android-36;google_apis;x86_64') 'A complete system image counts as installed'
Assert-True (-not (Test-SdkPackagePresent -SdkRoot $emulatorSdk -Package 'system-images;android-36;google_apis_playstore;x86_64')) 'Another image is not reported as installed'
Assert-Equal 'system-images;android-36;google_apis;x86_64' (@(Get-SystemImageFolders -SdkRoot $emulatorSdk) -join ',') 'Installed system images are listed'
$null = New-Item -ItemType Directory -Path (Join-Path $emulatorSdk 'emulator') -Force
Set-Content -LiteralPath (Join-Path $emulatorSdk 'emulator\emulator.exe') -Value 'stub' -Encoding Ascii
$emulatorPackages = @(Get-InstalledSdkPackagesOnDisk $emulatorSdk)
Assert-True ($emulatorPackages -contains 'emulator') 'emulator.exe marks the Emulator as installed'
Assert-True ($emulatorPackages -contains 'system-images;android-36;google_apis;x86_64') 'An installed system image is reported on disk'

# The package managers are discovered once and described the same way everywhere.
$managerPaths = Get-SdkPackageManagerPaths -SdkRoot $emulatorSdk
Assert-Equal '' $managerPaths.SdkManager 'A missing sdkmanager is reported as empty'
Assert-Equal (Join-Path $emulatorSdk 'emulator\emulator.exe') $managerPaths.Emulator 'The Emulator executable is discovered'
$null = New-Item -ItemType Directory -Path (Join-Path $emulatorSdk 'cmdline-tools\latest\bin') -Force
Set-Content -LiteralPath (Join-Path $emulatorSdk 'cmdline-tools\latest\bin\sdkmanager.bat') -Value '@echo off' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $emulatorSdk 'cmdline-tools\latest\bin\avdmanager.bat') -Value '@echo off' -Encoding Ascii
$managerPaths = Get-SdkPackageManagerPaths -SdkRoot $emulatorSdk
Assert-Equal (Join-Path $emulatorSdk 'cmdline-tools\latest\bin\sdkmanager.bat') $managerPaths.SdkManager 'sdkmanager is discovered'
Assert-Equal (Join-Path $emulatorSdk 'cmdline-tools\latest\bin\avdmanager.bat') $managerPaths.AvdManager 'avdmanager is discovered'

# --- 16. The new menu entries and console flags are wired in ------------------
Write-Host "`n[16] Menu and unattended wiring" -ForegroundColor Yellow
Assert-True ($scriptText -match "4\. Android Emulator") 'The menu offers the Emulator option'
Assert-True ($scriptText -match 'Install everything') 'The menu offers the full setup'
Assert-True ($scriptText -match 'ANDROID_SDK_INSTALLER_FLUTTER_ROOT') 'The Flutter root can be overridden'
Assert-True ($scriptText -match 'ANDROID_SDK_INSTALLER_AVD_NAME') 'The AVD name can be overridden'
Assert-True ($scriptText -match 'ANDROID_SDK_INSTALLER_SYSTEM_IMAGE') 'The system image can be overridden'
Assert-True ($scriptText -match 'ANDROID_SDK_INSTALLER_EMULATOR_PATH') 'The Emulator PATH entry is opt-in'
Assert-True ($scriptText -match 'ANDROID_SDK_INSTALLER_NO_AVD') 'AVD creation can be skipped'
Assert-True ($scriptText -match "WindowsPowerShell\\v1\.0\\powershell\.exe") 'Elevation uses the Windows PowerShell 5.1 host'
Assert-True ($scriptText -match 'ANDROID_SDK_INSTALLER_FLUTTER_DOWNLOAD') 'The automatic Flutter download can be enabled unattended'
Assert-True ($scriptText -match '--- Git for Windows ---') 'The environment check covers Git'

# --- 17. The automatic Flutter release lookup --------------------------------
Write-Host "`n[17] Flutter release cache" -ForegroundColor Yellow
$flutterSha = 'c2c875da25a1a1448d18ee4e8f398b2f6fce888b4775d8f9130538e16d826cb4'
$flutterUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.7-stable.zip'
$release = ConvertFrom-FlutterReleaseCache "3.47.7|$flutterUrl|$flutterSha"
Assert-Equal '3.47.7' $release.Version 'The cached Flutter version is read back'
Assert-Equal 'Url' $release.Kind 'The automatic release is treated as a download'
Assert-Equal $flutterUrl $release.Path 'The cached Flutter archive URL is read back'
Assert-Equal $flutterSha $release.Sha256 'The published SHA-256 is read back'
Assert-True ($release.Name -match '3\.47\.7') 'The release label carries the version'
Assert-True ($null -eq (ConvertFrom-FlutterReleaseCache '')) 'An empty cache entry is ignored'
Assert-True ($null -eq (ConvertFrom-FlutterReleaseCache 'not a release')) 'A malformed cache entry is ignored'
Assert-True ($null -eq (ConvertFrom-FlutterReleaseCache "3.47.7|ftp://example.com/flutter.zip|$flutterSha")) 'A non-HTTP archive URL is rejected'
$releaseWithoutSha = ConvertFrom-FlutterReleaseCache "3.47.7|$flutterUrl|"
Assert-Equal '' $releaseWithoutSha.Sha256 'A missing hash leaves verification off, not broken'
Assert-Equal $flutterUrl $releaseWithoutSha.Path 'The URL without a hash still parses'

# --- 18. Environment switches ------------------------------------------------
Write-Host "`n[18] Environment switches" -ForegroundColor Yellow
foreach ($value in @('1', 'Y', 'yes', 'TRUE', 'on')) {
    Assert-True (Test-InstallerFlag $value) "Switch value [$value] is on"
}
foreach ($value in @('', '0', 'N', 'no', 'false', 'off', 'maybe')) {
    Assert-True (-not (Test-InstallerFlag $value)) "Switch value [$value] is off"
}

# --- 19. The command-line tools download address -------------------------------
Write-Host "`n[19] Command-line tools download URL" -ForegroundColor Yellow
# Google publishes commandlinetools-win-<build>_latest.zip. Building the address with an underscore
# before the build instead made Step 2 download a file that never existed, so every install 404'd.
Assert-Equal 'https://dl.google.com/android/repository/commandlinetools-win-15859902_latest.zip' (Get-CmdlineToolsDownloadUrl -Build '15859902') 'The download URL uses a hyphen before the build and an underscore before latest'
Assert-True ((Get-CmdlineToolsDownloadUrl -Build '15859902') -notmatch 'commandlinetools-win_') 'The download URL never puts an underscore before the build'
Assert-True ($scriptText -notmatch 'commandlinetools-win_') 'No underscore-before-build address survives anywhere in the installer'
Assert-True ($scriptText -match 'Get-CmdlineToolsDownloadUrl -Build \$build') 'The version lookup builds its address through the tested helper'
# The built address must be a name the download-page scrape itself recognizes, with the build intact.
$scrapeHits = @([regex]::Matches((Get-CmdlineToolsDownloadUrl -Build '15859902'), 'commandlinetools-win-(\d+)_latest\.zip'))
Assert-Equal 1 $scrapeHits.Count 'The built URL matches the pattern scraped from the Android developer page'
if ($scrapeHits.Count -gt 0) {
    Assert-Equal '15859902' $scrapeHits[0].Groups[1].Value 'The scraped pattern recovers the build from the built URL'
}
# Only a real (possibly wrapped) WebException carries a status; anything else must not be mistaken for one.
Assert-Equal 0 (Get-WebExceptionStatusCode -Exception $null) 'A missing exception carries no HTTP status'
Assert-Equal 0 (Get-WebExceptionStatusCode -Exception ([System.Exception]::new('boom'))) 'A non-web exception carries no HTTP status'
Assert-Equal 0 (Get-WebExceptionStatusCode -Exception ([System.Exception]::new('outer', [Net.WebException]::new('inner')))) 'A wrapped WebException without a response carries no HTTP status'

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
