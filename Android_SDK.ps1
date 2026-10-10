#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OriginalUserSid,
    # Where the SDK goes. Left empty, an ANDROID_HOME that already points at a usable SDK wins.
    [string]$SdkRoot = '',
    # Android API level (and the Build Tools major) to install. 0 keeps the built-in default.
    [int]$ApiLevel = 0
)

$ErrorActionPreference = 'Stop'
$script:SdkRootOverride = $SdkRoot
$script:DefaultSdkRoot = 'C:\Android'
$script:SdkRoot = 'C:\Android'
# Resolved once, on first use, because an existing SDK elsewhere must not be silently repointed.
$script:SdkRootResolved = $false
$script:FlutterRoot = 'C:\flutter'
$script:OriginalUserSid = $OriginalUserSid
# True while an inline (single-line, redrawn) progress bar owns the current console line.
$script:InlineProgressActive = $false
$script:EnvBroadcastTypeLoaded = $false
# Set once the user has agreed to accept every Android SDK license; auto-answering a late prompt is
# only allowed afterwards, never as a default.
$script:AcceptAllLicensesGranted = $false
# Every caught failure is counted so the menu can leave a non-zero exit code behind for Run.bat/CI.
$script:FailureCount = 0

# Gradle and the Android Gradle Plugin support JDK 17 up to 21. Newer JDKs are reported but not used.
$script:JdkMinMajor = 17
$script:JdkMaxMajor = 21
$script:ApiLevelDefault = 36
$script:ApiLevel = $script:ApiLevelDefault
if ($ApiLevel -gt 0) { $script:ApiLevel = $ApiLevel }
elseif ($env:ANDROID_SDK_INSTALLER_API_LEVEL -match '^\d+$') { $script:ApiLevel = [int]$env:ANDROID_SDK_INSTALLER_API_LEVEL }
# CMake 4 removed compatibility with the `cmake_minimum_required(VERSION 3.4.1)` declarations that
# most Android and Flutter plugin CMakeLists still carry, so a 3.x build is the safe default.
$script:CMakePreferredMajor = 3
if ($env:ANDROID_SDK_INSTALLER_CMAKE_MAJOR -match '^\d+$') { $script:CMakePreferredMajor = [int]$env:ANDROID_SDK_INSTALLER_CMAKE_MAJOR }
if ($env:ANDROID_SDK_INSTALLER_ROOT) { $script:DefaultSdkRoot = $env:ANDROID_SDK_INSTALLER_ROOT }
if ($script:SdkRootOverride) { $script:DefaultSdkRoot = $script:SdkRootOverride }
$script:SdkRoot = $script:DefaultSdkRoot

# Remember the signed-in user's SID before UAC so C:\ installs remain usable by that user.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ([string]::IsNullOrWhiteSpace($script:OriginalUserSid)) { $script:OriginalUserSid = $currentIdentity.User.Value }
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Requesting Administrator privileges...' -ForegroundColor Yellow
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    # Everything the caller passed must survive the elevation hop, or a scripted -SdkRoot/-ApiLevel
    # would silently fall back to the defaults in the elevated child.
    $elevationArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -OriginalUserSid `"$script:OriginalUserSid`""
    if ($script:SdkRootOverride) { $elevationArgs += " -SdkRoot `"$($script:SdkRootOverride.Replace('"', ''))`"" }
    if ($ApiLevel -gt 0) { $elevationArgs += " -ApiLevel $ApiLevel" }
    try {
        $elevated = Start-Process -FilePath $powerShellExe -ArgumentList $elevationArgs -Verb RunAs -Wait -PassThru
        exit $elevated.ExitCode
    } catch {
        Write-Host "Administrator elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        # The helper functions are defined below this point, so this one wait is guarded by hand.
        try { [void](Read-Host 'Press Enter to exit') } catch { Start-Sleep -Seconds 5 }
        exit 1
    }
}

function Wait-ForEnter {
    param([string]$Message = 'Press Enter to continue...')
    if (-not (Test-InteractiveConsoleHost)) { return }
    [void](Read-InstallerInput -Prompt $Message)
}

function Invoke-ExternalToHost {
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$ArgumentList = @())
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        # Merged native stderr arrives as ErrorRecord objects. Out-Host renders those as
        # NativeCommandError blocks, so a plain tool warning looks like a script failure.
        # Print the text of each line instead and keep only the exit code.
        & $Path @ArgumentList 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host $_.Exception.Message -ForegroundColor DarkYellow }
            elseif ($null -ne $_) { Write-Host $_.ToString() }
        }
        $code = $LASTEXITCODE
        return $code
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Invoke-ExternalInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$ArgumentList = @(),
        [AllowEmptyCollection()][string[]]$Answers = @()
    )
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        # Nothing is redirected here: the tool keeps the console, so prompts render as they are
        # written, progress bars redraw in place, and keystrokes reach the tool. Piping the output
        # through PowerShell hides prompts that do not end in a newline, which silently turns every
        # "Accept? (y/N)" answer into the default "no".
        if ($Answers.Count -gt 0) { $Answers | & $Path @ArgumentList } else { & $Path @ArgumentList }
        $code = $LASTEXITCODE
        return $code
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Invoke-ExternalCapture {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$ArgumentList = @(),
        [AllowEmptyCollection()][string[]]$Answers = @()
    )
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        # -Answers keeps a captured run from blocking on a prompt it can never display.
        if ($Answers.Count -gt 0) { $output = @($Answers | & $Path @ArgumentList 2>&1) }
        else { $output = @(& $Path @ArgumentList 2>&1) }
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Output = $output; ExitCode = $code }
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Normalize-PathEntry {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().TrimEnd('\')
}

function Get-InstallerStateRoot {
    param([string]$Subfolder = '')
    $root = $env:ProgramData
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:LOCALAPPDATA }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $env:TEMP }
    $state = Join-Path $root 'Android-SDK-Installer'
    if (-not [string]::IsNullOrWhiteSpace($Subfolder)) { $state = Join-Path $state $Subfolder }
    if (-not (Test-Path -LiteralPath $state -PathType Container)) {
        try { New-Item -ItemType Directory -Path $state -Force -ErrorAction Stop | Out-Null } catch { }
    }
    return $state
}

function Read-InstallerCache {
    # Returns cached text while the entry is younger than $MaxAgeHours, otherwise $null.
    param([Parameter(Mandatory = $true)][string]$Name, [double]$MaxAgeHours = 6)
    if ($env:ANDROID_SDK_INSTALLER_NO_CACHE) { return $null }
    $path = Join-Path (Get-InstallerStateRoot 'cache') $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        if (((Get-Date) - (Get-Item -LiteralPath $path).LastWriteTime).TotalHours -gt $MaxAgeHours) { return $null }
        return [string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
    } catch { return $null }
}

function Write-InstallerCache {
    param([Parameter(Mandatory = $true)][string]$Name, [AllowEmptyString()][string]$Content)
    if ($env:ANDROID_SDK_INSTALLER_NO_CACHE -or [string]::IsNullOrWhiteSpace($Content)) { return }
    try { Set-Content -LiteralPath (Join-Path (Get-InstallerStateRoot 'cache') $Name) -Value $Content -Encoding UTF8 -Force -ErrorAction Stop } catch { }
}

function Test-InteractiveConsoleHost {
    # True only when a real console can both show a prompt and take keystrokes. A piped or ISE host
    # answers nothing, so every prompt needs a documented default instead of an endless re-ask.
    if ($env:ANDROID_SDK_INSTALLER_ASSUME_INTERACTIVE) { return $true }
    if ($env:ANDROID_SDK_INSTALLER_ASSUME_NONINTERACTIVE) { return $false }
    if ($Host.Name -like '*ISE*') { return $false }
    try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false } } catch { return $false }
    try {
        $ui = $Host.UI.RawUI
        if ($null -eq $ui) { return $false }
        $null = $ui.WindowSize
    } catch { return $false }
    return $true
}

function Read-InstallerInput {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Default = '',
        [string]$Choices = ''
    )
    if (-not (Test-InteractiveConsoleHost)) { return $Default }
    $attempts = 0
    while ($attempts -lt 10) {
        $attempts++
        try { $answer = [string](Read-Host $Prompt) } catch { return $Default }
        $answer = $answer.Trim()
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        if ([string]::IsNullOrWhiteSpace($Choices)) { return $answer }
        foreach ($choice in ($Choices -split '\|')) { if ($answer -ieq $choice) { return $choice } }
        Write-Host "Unrecognised answer [$answer]. Enter one of: $(($Choices -split '\|') -join ', ')" -ForegroundColor Yellow
    }
    return $Default
}

function Clear-StaleInstallerWorkDirs {
    # A Ctrl+C, a closed window, or a reboot leaves multi-gigabyte staging folders in TEMP forever.
    $removed = 0
    foreach ($pattern in @('AndroidSdkInstaller-*', 'FlutterInstaller-*', 'TemurinJdk-*', 'GitInstaller-*')) {
        foreach ($dir in (Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter $pattern -ErrorAction SilentlyContinue)) {
            try { if (((Get-Date) - $dir.LastWriteTime).TotalHours -lt 12) { continue } } catch { continue }
            try { Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { }
        }
    }
    if ($removed -gt 0) { Write-Host "[*] Removed $removed staging folder(s) left behind by an earlier run." -ForegroundColor Gray }
}

function Get-RawPathVariable {
    # [Environment]::GetEnvironmentVariable() expands REG_EXPAND_SZ values, so writing the result
    # straight back would hard-code %SystemRoot%-style entries. The registry keeps them verbatim.
    param([ValidateSet('User', 'Machine')][string]$Scope = 'Machine')
    $result = $null
    try {
        if ($Scope -eq 'Machine') {
            $hive = [Microsoft.Win32.Registry]::LocalMachine
            $subKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        } else {
            $hive = [Microsoft.Win32.Registry]::CurrentUser
            $subKey = 'Environment'
        }
        $key = $hive.OpenSubKey($subKey, $false)
        if ($null -ne $key) {
            try {
                $raw = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $kind = [Microsoft.Win32.RegistryValueKind]::Unknown
                try { $kind = $key.GetValueKind('Path') } catch { }
                $result = [pscustomobject]@{ Value = [string]$raw; Expandable = ($kind -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            } finally { $key.Close() }
        }
    } catch { $result = $null }
    if ($null -eq $result) {
        $result = [pscustomobject]@{ Value = [string][Environment]::GetEnvironmentVariable('Path', $Scope); Expandable = $true }
    }
    return $result
}

function Set-RawPathVariable {
    param(
        [ValidateSet('User', 'Machine')][string]$Scope = 'Machine',
        [AllowEmptyString()][string]$Value = '',
        [bool]$Expandable = $true
    )
    try {
        if ($Scope -eq 'Machine') {
            $hive = [Microsoft.Win32.Registry]::LocalMachine
            $subKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        } else {
            $hive = [Microsoft.Win32.Registry]::CurrentUser
            $subKey = 'Environment'
        }
        $key = $hive.OpenSubKey($subKey, $true)
        if ($null -eq $key) { throw 'the Environment registry key could not be opened for writing' }
        try {
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            if ($Expandable) { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $key.SetValue('Path', $Value, $kind)
        } finally { $key.Close() }
        return $true
    } catch {
        try { [Environment]::SetEnvironmentVariable('Path', $Value, $Scope); return $true } catch { return $false }
    }
}

function Get-VolumeFreeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $probe = $Path
        if (-not [IO.Path]::IsPathRooted($probe)) { $probe = [IO.Path]::GetFullPath($probe) }
        while ($probe -and ($probe -ne [IO.Path]::GetPathRoot($probe)) -and -not (Test-Path -LiteralPath $probe)) { $probe = Split-Path -Parent $probe }
        $root = [IO.Path]::GetPathRoot($probe)
        if ([string]::IsNullOrWhiteSpace($root)) { return [double]-1 }
        return [double](New-Object IO.DriveInfo($root.TrimEnd('\'))).AvailableFreeSpace
    } catch { return [double]-1 }
}

function Assert-DiskSpace {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][double]$RequiredBytes,
        [string]$Label = 'this step'
    )
    $free = Get-VolumeFreeBytes $Path
    $drive = 'the target volume'
    try { $drive = Split-Path -Qualifier $Path } catch { }
    if ($free -lt 0) {
        Write-Host "[*] Free space for $Path could not be measured; continuing without a disk-space check." -ForegroundColor Gray
        return
    }
    if ($free -lt $RequiredBytes) {
        throw "Not enough free space on $drive for ${Label}: $(Format-ByteSize $free) free, about $(Format-ByteSize $RequiredBytes) needed. Free up space, or pass -SdkRoot with a folder on a larger volume."
    }
    if ($free -lt ($RequiredBytes * 1.5)) {
        Write-Host "[!] Only $(Format-ByteSize $free) free on $drive for ${Label} (about $(Format-ByteSize $RequiredBytes) needed)." -ForegroundColor Yellow
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() } catch { return '' }
}

function Test-FileSha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Expected = ''
    )
    if ([string]::IsNullOrWhiteSpace($Expected)) { return $true }
    $wanted = $Expected.Trim().Replace('sha256:', '').Replace('sha256/', '').ToUpperInvariant()
    $actual = Get-FileSha256 $Path
    if ([string]::IsNullOrWhiteSpace($actual)) {
        Write-Warning "The SHA-256 of $([IO.Path]::GetFileName($Path)) could not be computed, so the download was not verified."
        return $true
    }
    return ($actual -eq $wanted)
}

function Test-AndroidSdkRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $Path 'platform-tools\adb.exe') -PathType Leaf) { return $true }
    return (Test-CmdlineToolsDirectory (Join-Path $Path 'cmdline-tools\latest'))
}

function Resolve-AndroidSdkRoot {
    param([switch]$Quiet)
    if ($script:SdkRootResolved) { return $script:SdkRoot }
    $target = Normalize-PathEntry $script:DefaultSdkRoot
    if ([string]::IsNullOrWhiteSpace($target)) { $target = 'C:\Android' }
    $existing = [string][Environment]::GetEnvironmentVariable('ANDROID_HOME', 'Machine')
    if ([string]::IsNullOrWhiteSpace($existing)) { $existing = [string][Environment]::GetEnvironmentVariable('ANDROID_HOME', 'User') }
    $existing = Normalize-PathEntry $existing
    # Android Studio keeps its SDK under the user profile. Repointing that machine at C:\Android and
    # downloading a second multi-gigabyte SDK has to be a decision, never a side effect of option 1.
    if ($existing -and ($existing -ine $target) -and (Test-AndroidSdkRoot $existing)) {
        if ($script:SdkRootOverride -or $env:ANDROID_SDK_INSTALLER_ROOT -or $Quiet -or -not (Test-InteractiveConsoleHost)) {
            Write-Host "[*] Reusing the Android SDK already configured at $existing (pass -SdkRoot to force another location)." -ForegroundColor Yellow
            $target = $existing
        } else {
            Write-Host "[*] ANDROID_HOME already points at a usable Android SDK: $existing" -ForegroundColor Yellow
            Write-Host "    $target is only needed when you want a second, IDE-free SDK at a fixed path." -ForegroundColor Gray
            $answer = Read-InstallerInput -Prompt "Keep using $existing? (Y = keep it, N = install to $target)" -Default 'Y' -Choices 'Y|N'
            if ($answer -ieq 'Y') { $target = $existing }
        }
    }
    $script:SdkRoot = $target
    $script:SdkRootResolved = $true
    return $script:SdkRoot
}

function Get-SdkPackageManagerHint {
    param(
        [AllowEmptyString()][string]$SdkManager = '',
        [AllowEmptyString()][string]$AndroidCli = '',
        [string]$SdkRoot = '',
        [string]$Arguments = ''
    )
    # Only name a tool that exists, or a repair instruction points at a path nobody can run.
    if ($SdkManager -and (Test-Path -LiteralPath $SdkManager -PathType Leaf)) { return ("`"$SdkManager`" --sdk_root=$SdkRoot $Arguments").Trim() }
    if ($AndroidCli -and (Test-Path -LiteralPath $AndroidCli -PathType Leaf)) { return ("`"$AndroidCli`" --sdk=$SdkRoot sdk $Arguments").Trim() }
    return "the Android SDK command-line tools $Arguments".Trim()
}

function Get-InstalledSdkPackagesOnDisk {
    param([Parameter(Mandatory = $true)][string]$SdkRoot)
    # Reads what is really in the SDK folder: cheaper than a repository round-trip, and it also
    # recognises packages another tool (Android Studio) installed.
    $found = @()
    if (-not (Test-Path -LiteralPath $SdkRoot -PathType Container)) { return @() }
    $xmlFiles = @()
    foreach ($name in @('platform-tools', 'emulator', 'cmdline-tools', 'extras')) {
        $dir = Join-Path $SdkRoot $name
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $ownXml = Join-Path $dir 'package.xml'
        if (Test-Path -LiteralPath $ownXml -PathType Leaf) { $xmlFiles += $ownXml }
        foreach ($child in (Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
            $childXml = Join-Path $child.FullName 'package.xml'
            if (Test-Path -LiteralPath $childXml -PathType Leaf) { $xmlFiles += $childXml }
        }
    }
    foreach ($name in @('platforms', 'build-tools', 'ndk', 'cmake', 'patch', 'sources')) {
        $parent = Join-Path $SdkRoot $name
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        foreach ($child in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
            $childXml = Join-Path $child.FullName 'package.xml'
            if (Test-Path -LiteralPath $childXml -PathType Leaf) { $xmlFiles += $childXml }
        }
    }
    foreach ($xml in $xmlFiles) {
        try { $text = [string](Get-Content -LiteralPath $xml -Raw -ErrorAction Stop) } catch { continue }
        foreach ($match in [regex]::Matches($text, '(?:localPackage|remotePackage)[^>]*?path="(?<id>[^"]+)"')) {
            $id = $match.Groups['id'].Value
            if ($id) { $found += $id }
        }
    }
    # Marker files catch hand-extracted tools and folders that never got a package.xml. A folder that
    # is present but incomplete stays unlisted, so a half-extracted NDK is never advertised as usable.
    $markers = @(
        [pscustomobject]@{ group = 'platforms'; marker = 'android.jar'; prefix = 'platforms;android-'; strip = '^android-' },
        [pscustomobject]@{ group = 'build-tools'; marker = 'aapt2.exe'; prefix = 'build-tools;'; strip = '' },
        [pscustomobject]@{ group = 'ndk'; marker = 'source.properties'; prefix = 'ndk;'; strip = '' },
        [pscustomobject]@{ group = 'cmake'; marker = 'bin\cmake.exe'; prefix = 'cmake;'; strip = '' }
    )
    foreach ($entry in $markers) {
        $parent = Join-Path $SdkRoot $entry.group
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        foreach ($child in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path -LiteralPath (Join-Path $child.FullName $entry.marker) -PathType Leaf)) { continue }
            $suffix = $child.Name
            if ($entry.strip) { $suffix = $child.Name -replace $entry.strip, '' }
            $found += ($entry.prefix + $suffix)
        }
    }
    if (Test-Path -LiteralPath (Join-Path $SdkRoot 'platform-tools\adb.exe') -PathType Leaf) { $found += 'platform-tools' }
    return @($found | Sort-Object -Unique)
}

function Test-SdkPackageInstalled {
    param([AllowEmptyCollection()][string[]]$Installed = @(), [string]$Package = '')
    if ([string]::IsNullOrWhiteSpace($Package)) { return $false }
    foreach ($entry in $Installed) { if ($entry -ieq $Package) { return $true } }
    return $false
}

function Get-PartialSdkPackageFolders {
    param([Parameter(Mandatory = $true)][string]$SdkRoot)
    # A version folder without its marker file is a half-finished download. Tooling picks such a
    # folder up by name and then fails in confusing ways, so the installer names it instead of
    # pretending it is not there.
    $partial = @()
    $checks = @(
        [pscustomobject]@{ group = 'platforms'; marker = 'android.jar' },
        [pscustomobject]@{ group = 'build-tools'; marker = 'aapt2.exe' },
        [pscustomobject]@{ group = 'ndk'; marker = 'source.properties' },
        [pscustomobject]@{ group = 'cmake'; marker = 'bin\cmake.exe' }
    )
    foreach ($entry in $checks) {
        $parent = Join-Path $SdkRoot $entry.group
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        foreach ($child in (Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Name -like '*.backup-*') { continue }
            if ($child.Name -like '*.installer*') { continue }
            if (Test-Path -LiteralPath (Join-Path $child.FullName $entry.marker) -PathType Leaf) { continue }
            $partial += (Join-Path $entry.group $child.Name)
        }
    }
    return @($partial)
}

function Test-DirectoryModifiableBySid {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sid
    )
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $wanted = [int][Security.AccessControl.FileSystemRights]::Modify
        foreach ($ace in $acl.Access) {
            if ($ace.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $identity = $null
            try { $identity = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $identity = $null }
            if ($identity -ne $Sid) { continue }
            if ((([int]$ace.FileSystemRights) -band $wanted) -eq $wanted) { return $true }
        }
    } catch { }
    return $false
}

function Add-PathEntry {
    param([Parameter(Mandatory = $true)][string]$Entry, [ValidateSet('User', 'Machine')][string]$Scope = 'Machine')
    $wanted = Normalize-PathEntry $Entry
    if (-not $wanted) { return }
    $raw = Get-RawPathVariable -Scope $Scope
    $current = [string]$raw.Value
    $items = @()
    if (-not [string]::IsNullOrWhiteSpace($current)) { $items = @($current -split ';' | Where-Object { $_.Trim() }) }
    $exists = $false
    foreach ($item in $items) {
        # Compare the raw and the expanded form, so a %VAR% entry that resolves to the same folder
        # is recognised instead of duplicated.
        if ((Normalize-PathEntry $item) -ieq $wanted) { $exists = $true; break }
        if ((Normalize-PathEntry ([Environment]::ExpandEnvironmentVariables($item.Trim()))) -ieq $wanted) { $exists = $true; break }
    }
    if (-not $exists) {
        $items += $Entry
        $newValue = $items -join ';'
        if ($newValue.Length -gt 30000) { throw "The $Scope PATH is too long ($($newValue.Length) characters). Remove obsolete entries and retry." }
        if (-not (Set-RawPathVariable -Scope $Scope -Value $newValue -Expandable ([bool]$raw.Expandable))) {
            throw "The $Scope PATH could not be written. Check that this session may still change system environment variables."
        }
    }
    $processItems = @()
    if ($env:Path) { $processItems = @($env:Path -split ';' | Where-Object { $_.Trim() }) }
    $processHasEntry = $false
    foreach ($item in $processItems) { if ((Normalize-PathEntry $item) -ieq $wanted) { $processHasEntry = $true; break } }
    if (-not $processHasEntry) { $processItems += $Entry; $env:Path = $processItems -join ';' }
}

function Refresh-ProcessPath {
    $all = @()
    foreach ($scope in @('Machine', 'User')) {
        $value = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ($value) { $all += @($value -split ';' | Where-Object { $_.Trim() }) }
    }
    if ($env:Path) { $all += @($env:Path -split ';' | Where-Object { $_.Trim() }) }
    $unique = @()
    foreach ($item in $all) {
        $found = $false
        foreach ($saved in $unique) { if ((Normalize-PathEntry $saved) -ieq (Normalize-PathEntry $item)) { $found = $true; break } }
        if (-not $found) { $unique += $item }
    }
    $env:Path = $unique -join ';'
}

function Broadcast-EnvironmentChange {
    try {
        if (-not $script:EnvBroadcastTypeLoaded) {
            Add-Type -Namespace Native -Name SdkEnvironmentBroadcast -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, System.UInt32 Msg, System.UIntPtr wParam, string lParam, System.UInt32 fuFlags, System.UInt32 uTimeout, out System.UIntPtr lpdwResult);
'@ -ErrorAction Stop | Out-Null
            $script:EnvBroadcastTypeLoaded = $true
        }
        $result = [UIntPtr]::Zero
        [void][Native.SdkEnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$result)
    } catch {
        # The environment is persisted even if the notification cannot be sent.
    }
}

function Set-AndroidEnvironment {
    # The root may be an existing ANDROID_HOME, so resolve before persisting anything.
    $null = Resolve-AndroidSdkRoot -Quiet
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $script:SdkRoot, 'Machine')
    [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $script:SdkRoot, 'Machine')
    $env:ANDROID_HOME = $script:SdkRoot
    $env:ANDROID_SDK_ROOT = $script:SdkRoot

    $ndk = Get-LatestVersionFolder (Join-Path $script:SdkRoot 'ndk') 'source.properties'
    if ($ndk) {
        [Environment]::SetEnvironmentVariable('ANDROID_NDK_HOME', $ndk, 'Machine')
        $env:ANDROID_NDK_HOME = $ndk
    } else {
        # A stale value pointing at a removed or half-extracted NDK breaks native builds confusingly.
        [Environment]::SetEnvironmentVariable('ANDROID_NDK_HOME', $null, 'Machine')
        $env:ANDROID_NDK_HOME = $null
    }

    $javaHome = $env:JAVA_HOME
    if ([string]::IsNullOrWhiteSpace($javaHome)) { $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine') }
    if ($javaHome -and (Test-Path -LiteralPath (Join-Path $javaHome 'bin') -PathType Container)) {
        Add-PathEntry (Join-Path $javaHome 'bin') 'Machine'
    }

    # The Emulator is opt-in only: the installer never downloads it, so an <SDK>\emulator folder
    # left behind by Android Studio must not be claimed by Machine PATH. Android Studio, Gradle,
    # and `flutter emulators` reach the Emulator through ANDROID_HOME, not through PATH, so nothing
    # breaks without this entry. For the `emulator -avd <name>` command line workflow, add it by hand.
    $entries = @(
        (Join-Path $script:SdkRoot 'cmdline-tools\latest\bin'),
        (Join-Path $script:SdkRoot 'platform-tools')
    )
    $buildTools = Get-LatestVersionFolder (Join-Path $script:SdkRoot 'build-tools') 'aapt2.exe'
    if ($buildTools) { $entries += $buildTools }
    $cmake = Get-LatestVersionFolder (Join-Path $script:SdkRoot 'cmake') 'bin\cmake.exe'
    if ($cmake) { $entries += (Join-Path $cmake 'bin') }
    foreach ($entry in $entries) {
        if (Test-Path -LiteralPath $entry -PathType Container) { Add-PathEntry $entry 'Machine' }
    }
}

function Grant-OriginalUserModifyAccess {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Force)
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or -not $script:OriginalUserSid) { return }
    # Re-running the installer used to walk the whole tree again, which on an installed NDK means
    # a million files for an access entry that is already there.
    if (-not $Force -and (Test-DirectoryModifiableBySid -Path $Path -Sid $script:OriginalUserSid)) { return }
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls)) { Write-Warning "icacls.exe was not found; the signed-in user may not be able to update $Path later."; return }
    $ace = "*$($script:OriginalUserSid):(OI)(CI)M"
    # Inheritance carries the grant into existing and future children. A full /T pass is only needed
    # after someone replaced child ACLs explicitly, so it stays behind an opt-in switch.
    $icaclsArgs = @($Path, '/grant', $ace, '/C', '/Q')
    if ($env:ANDROID_SDK_INSTALLER_RECURSIVE_ACL -or $Force) { $icaclsArgs = @($Path, '/grant', $ace, '/T', '/C', '/Q') }
    $code = Invoke-ExternalToHost -Path $icacls -ArgumentList $icaclsArgs
    if ($code -ne 0) { Write-Warning "Could not grant modify access to the signed-in user for $Path (icacls exit code $code)." }
}

function Get-OriginalUserProfilePath {
    if ([string]::IsNullOrWhiteSpace($script:OriginalUserSid)) { return $null }
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($script:OriginalUserSid)"
    try {
        $path = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).ProfileImagePath
        if (-not [string]::IsNullOrWhiteSpace($path)) { return [Environment]::ExpandEnvironmentVariables($path) }
    } catch { }
    return $null
}

function Get-NativeWindowsArch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    if ($arch -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Test-UsableExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        # App execution aliases under WindowsApps are 0-byte stubs and fail when elevated.
        return ($item.Length -gt 0)
    } catch { return $false }
}

function Get-WingetPath {
    $cmd = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and (Test-UsableExecutable $cmd.Source)) { return $cmd.Source }

    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe') }
    $profile = Get-OriginalUserProfilePath
    if ($profile) { $candidates += (Join-Path $profile 'AppData\Local\Microsoft\WindowsApps\winget.exe') }
    foreach ($path in $candidates) {
        if (Test-UsableExecutable $path) { return $path }
    }

    try {
        $packages = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue)
        if ($packages.Count -eq 0) {
            $packages = @(Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction SilentlyContinue)
        }
        foreach ($pkg in $packages) {
            if ([string]::IsNullOrWhiteSpace($pkg.InstallLocation)) { continue }
            $exe = Join-Path $pkg.InstallLocation 'winget.exe'
            if (Test-UsableExecutable $exe) { return $exe }
        }
    } catch { }

    $windowsApps = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $windowsApps -PathType Container) {
        foreach ($folder in (Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $exe = Join-Path $folder.FullName 'winget.exe'
            if (Test-UsableExecutable $exe) { return $exe }
        }
    }
    return $null
}

function Install-WingetPackage {
    param([Parameter(Mandatory = $true)][string]$PackageId, [Parameter(Mandatory = $true)][string]$DisplayName)
    $winget = Get-WingetPath
    if (-not $winget) { throw "winget was not found. Install $DisplayName manually, then run this installer again." }
    Write-Host "[*] Starting winget installation for $DisplayName. Review and approve the package terms if prompted." -ForegroundColor Yellow
    # winget draws its own progress bar and may ask for source agreements, so keep the console attached.
    # Package agreements must also be accepted on the command line: an elevated or detached session
    # cannot answer that prompt, and winget then exits with an agreement error.
    $common = @('install', '--id', $PackageId, '--exact', '--accept-source-agreements', '--accept-package-agreements')
    if (-not (Test-InteractiveConsoleHost)) { $common += '--disable-interactivity' }
    $code = Invoke-ExternalInteractive -Path $winget -ArgumentList ($common + @('--scope', 'machine'))
    if ($code -ne 0) {
        # Some packages only ship a user scope, so retry without the flag before falling back.
        Write-Host "[*] winget rejected the machine scope for $DisplayName; retrying without it..." -ForegroundColor Yellow
        $code = Invoke-ExternalInteractive -Path $winget -ArgumentList $common
    }
    if ($code -ne 0) { throw "winget could not install $DisplayName (exit code $code)." }
    Refresh-ProcessPath
}

function Find-ExtractedJdkHome {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    $roots = @($Root)
    foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) { $roots += $dir.FullName }
    foreach ($candidateHome in $roots) {
        $java = Join-Path $candidateHome 'bin\java.exe'
        $javac = Join-Path $candidateHome 'bin\javac.exe'
        if ((Test-Path -LiteralPath $java -PathType Leaf) -and (Test-Path -LiteralPath $javac -PathType Leaf)) { return $candidateHome }
    }
    return $null
}

function Get-TemurinJdkDownloadInfo {
    # The assets API publishes the SHA-256 next to the link; the plain binary redirect does not, so
    # it is only used when that lookup fails.
    param([string]$AdoptiumArch)
    $feature = $script:JdkMinMajor
    $result = [pscustomobject]@{ Url = ''; Sha256 = '' }
    try {
        $api = "https://api.adoptium.net/v3/assets/latest/$feature/hotspot?architecture=$AdoptiumArch&image_type=jdk&os=windows&vendor=eclipse"
        $releases = @(Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Android-SDK-Installer' } -ErrorAction Stop)
        foreach ($entry in $releases) {
            $binary = $entry.binary
            if (-not $binary -or -not $binary.link) { continue }
            if ($binary.package -and $binary.package.checksum) { $result.Sha256 = [string]$binary.package.checksum }
            $result.Url = [string]$binary.link
            return $result
        }
        Write-Warning 'The Adoptium release API returned no Windows JDK asset; using the redirect endpoint without a published checksum.'
    } catch {
        Write-Warning "The Adoptium release API was not reachable ($($_.Exception.Message)); using the redirect endpoint without a published checksum."
    }
    $result.Url = "https://api.adoptium.net/v3/binary/latest/$feature/ga/windows/$AdoptiumArch/jdk/hotspot/normal/eclipse?project=jdk"
    return $result
}

function Install-TemurinJdkFromAdoptium {
    $arch = Get-NativeWindowsArch
    $adoptiumArch = if ($arch -eq 'arm64') { 'aarch64' } else { 'x64' }
    $download = Get-TemurinJdkDownloadInfo -AdoptiumArch $adoptiumArch
    $url = $download.Url
    $work = Join-Path $env:TEMP ('TemurinJdk-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $work "temurin-jdk-$($script:JdkMinMajor).zip"
    $extract = Join-Path $work 'extract'
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Assert-DiskSpace -Path $env:TEMP -RequiredBytes 2GB -Label 'the Eclipse Temurin JDK download and extraction'
        Assert-DiskSpace -Path $env:ProgramFiles -RequiredBytes 1GB -Label 'the Eclipse Temurin JDK installation'
        Write-Host "[*] Downloading Eclipse Temurin JDK $($script:JdkMinMajor) ($adoptiumArch) from Adoptium..." -ForegroundColor Yellow
        Download-File $url $zip "Eclipse Temurin JDK $($script:JdkMinMajor)" $download.Sha256
        if ((Get-Item -LiteralPath $zip).Length -lt 1048576) { throw 'The Temurin JDK download is too small to be a valid archive.' }
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        Write-Host '[*] Extracting Eclipse Temurin JDK 17...' -ForegroundColor Yellow
        Expand-ArchiveWithProgress -LiteralPath $zip -DestinationPath $extract -Label 'Eclipse Temurin JDK 17'
        $jdkFolder = Find-ExtractedJdkHome $extract
        if (-not $jdkFolder) { throw 'The Temurin archive did not contain a JDK with java.exe and javac.exe.' }

        $vendorRoot = Join-Path $env:ProgramFiles 'Eclipse Adoptium'
        New-Item -ItemType Directory -Path $vendorRoot -Force | Out-Null
        $destName = Split-Path -Leaf $jdkFolder
        if ([string]::IsNullOrWhiteSpace($destName) -or ($destName -ieq 'extract')) { $destName = 'jdk-17-hotspot' }
        $dest = Join-Path $vendorRoot $destName
        if (Test-Path -LiteralPath $dest) { $dest = Join-Path $vendorRoot ($destName + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
        Write-Host "[*] Installing JDK to $dest" -ForegroundColor Yellow
        Move-Item -LiteralPath $jdkFolder -Destination $dest
        if (-not (Test-Path -LiteralPath (Join-Path $dest 'bin\javac.exe') -PathType Leaf)) { throw "JDK files were not found after extracting to $dest." }
        Refresh-ProcessPath
    } finally {
        if (Test-Path -LiteralPath $work -PathType Container) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-GitInstallerAsset {
    param([string]$Arch)
    # The unauthenticated GitHub release API is limited to 60 requests per hour per IP, which shared
    # NAT connections hit easily, so a pinned release stays available as a fallback.
    $pinned = [pscustomobject]@{
        x64   = [pscustomobject]@{ Name = 'Git-2.56.0.2-64-bit.exe'; Url = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-64-bit.exe' }
        arm64 = [pscustomobject]@{ Name = 'Git-2.56.0.2-arm64.exe'; Url = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-arm64.exe' }
    }
    $fallback = $pinned.x64
    if ($Arch -eq 'arm64') { $fallback = $pinned.arm64 }
    $result = [pscustomobject]@{ Name = [string]$fallback.Name; Url = [string]$fallback.Url; Sha256 = ''; Source = 'pinned release' }
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'Android-SDK-Installer' } -ErrorAction Stop
        foreach ($item in @($release.assets)) {
            $name = [string]$item.name
            $wanted = $false
            if ($Arch -eq 'arm64') { $wanted = ($name -match '(?i)^Git-.+-arm64\.exe$') }
            else { $wanted = (($name -match '(?i)^Git-.+-64-bit\.exe$') -and ($name -notmatch '(?i)(busybox|mingit|portable|tar)')) }
            if (-not $wanted) { continue }
            $result.Name = $name
            $result.Url = [string]$item.browser_download_url
            if ($item.digest) { $result.Sha256 = ([string]$item.digest).Replace('sha256:', '') }
            $result.Source = 'GitHub release API'
            return $result
        }
        Write-Warning 'The latest Git for Windows release has no matching installer asset; using the pinned release.'
    } catch {
        Write-Warning "The GitHub release API was not reachable ($($_.Exception.Message)); using the pinned Git installer."
    }
    return $result
}

function Install-GitFromGitHub {
    $arch = Get-NativeWindowsArch
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host "[*] Looking up a Git for Windows installer ($arch)..." -ForegroundColor Yellow
    $asset = Get-GitInstallerAsset -Arch $arch
    Write-Host "    Source: $($asset.Source) - $($asset.Name)" -ForegroundColor Gray

    $work = Join-Path $env:TEMP ('GitInstaller-' + [guid]::NewGuid().ToString('N'))
    $setup = Join-Path $work $asset.Name
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Assert-DiskSpace -Path $env:TEMP -RequiredBytes 500MB -Label 'the Git for Windows installer download'
        Write-Host "[*] Downloading $($asset.Name)..." -ForegroundColor Yellow
        Download-File $asset.Url $setup $asset.Name $asset.Sha256
        if ((Get-Item -LiteralPath $setup).Length -lt 1048576) { throw 'The Git installer download is too small to be valid.' }
        Write-Host '[*] Installing Git for Windows...' -ForegroundColor Yellow
        $setupArgs = '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /COMPONENTS=gitlfs,assoc,assoc_sh /o:PathOption=Cmd'
        $process = Start-Process -FilePath $setup -ArgumentList $setupArgs -Wait -PassThru
        if ($null -eq $process -or ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010)) {
            $code = if ($null -eq $process) { 'unknown' } else { $process.ExitCode }
            throw "Git installer failed (exit code $code)."
        }
        Refresh-ProcessPath
    } finally {
        if (Test-Path -LiteralPath $work -PathType Container) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-JdkInfo {
    $candidates = @()
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME 'bin\java.exe'
        if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
    $adoptium = Join-Path $env:ProgramFiles 'Eclipse Adoptium'
    if (Test-Path -LiteralPath $adoptium -PathType Container) {
        foreach ($folder in (Get-ChildItem -LiteralPath $adoptium -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            $candidate = Join-Path $folder.FullName 'bin\java.exe'
            if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
        }
    }
    $javac = Get-Command 'javac.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($javac) {
        $javacHome = Split-Path -Parent (Split-Path -Parent $javac.Source)
        $candidate = Join-Path $javacHome 'bin\java.exe'
        if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
    $java = Get-Command 'java.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($java) { $candidates += $java.Source }

    $seen = @()
    $found = @()
    foreach ($javaPath in $candidates) {
        $key = $javaPath.ToLowerInvariant()
        if ($seen -contains $key -or -not (Test-Path -LiteralPath $javaPath -PathType Leaf)) { continue }
        $seen += $key
        $bin = Split-Path -Parent $javaPath
        $javaHomeDir = Split-Path -Parent $bin
        if (-not (Test-Path -LiteralPath (Join-Path $bin 'javac.exe') -PathType Leaf)) { continue }
        $versionResult = Invoke-ExternalCapture -Path $javaPath -ArgumentList @('-version')
        $versionText = ($versionResult.Output | Out-String)
        $major = 0
        if ($versionText -match 'version\s+"(?<major>\d+)') { $major = [int]$Matches['major'] }
        elseif ($versionText -match '(?:openjdk|java)\s+(?<major>\d+)') { $major = [int]$Matches['major'] }
        if ($major -le 0) { continue }
        $found += [pscustomobject]@{ JavaHome = $javaHomeDir; Major = $major }
    }
    # Gradle and the Android Gradle Plugin support a bounded JDK range. A JDK that merely satisfies
    # "17 or newer" still fails an Android build with "Unsupported class file major version", so a
    # too-new JDK is reported separately instead of being wired into JAVA_HOME.
    $suitable = @($found | Where-Object { ($_.Major -ge $script:JdkMinMajor) -and ($_.Major -le $script:JdkMaxMajor) })
    if ($suitable.Count -gt 0) {
        $best = @($suitable | Sort-Object Major | Select-Object -First 1)
        return [pscustomobject]@{ Ready = $true; JavaHome = $best.JavaHome; Major = $best.Major; NewerMajor = 0; NewerJavaHome = '' }
    }
    $newer = @($found | Where-Object { $_.Major -gt $script:JdkMaxMajor } | Sort-Object Major | Select-Object -First 1)
    if ($newer.Count -gt 0) {
        return [pscustomobject]@{ Ready = $false; JavaHome = ''; Major = 0; NewerMajor = $newer[0].Major; NewerJavaHome = $newer[0].JavaHome }
    }
    return [pscustomobject]@{ Ready = $false; JavaHome = ''; Major = 0; NewerMajor = 0; NewerJavaHome = '' }
}

function Ensure-Jdk {
    param([switch]$AutoInstall)
    $jdk = Get-JdkInfo
    if (-not $jdk.Ready) {
        if ($jdk.NewerMajor -gt 0) {
            Write-Host "[!] JDK $($jdk.NewerMajor) was found at $($jdk.NewerJavaHome), but Gradle and the Android Gradle Plugin support JDK $($script:JdkMinMajor) to $($script:JdkMaxMajor)." -ForegroundColor Yellow
            Write-Host "    Eclipse Temurin JDK $($script:JdkMinMajor) is installed beside it and becomes JAVA_HOME; the newer JDK itself is left untouched." -ForegroundColor Gray
        }
        if ($AutoInstall) {
            Write-Host "A JDK $($script:JdkMinMajor)-$($script:JdkMaxMajor) is required, and none was found, so Eclipse Temurin JDK $($script:JdkMinMajor) will be installed automatically." -ForegroundColor Yellow
        } else {
            Write-Host "A JDK $($script:JdkMinMajor) to $($script:JdkMaxMajor) is required for Android builds." -ForegroundColor Yellow
            $answer = Read-InstallerInput -Prompt "Install Eclipse Temurin JDK $($script:JdkMinMajor) now? (Y/N)" -Default 'N' -Choices 'Y|N'
            if ($answer -notmatch '(?i)^y(es)?$') { throw "Install a JDK $($script:JdkMinMajor)-$($script:JdkMaxMajor) and run this installer again, or run it from an interactive console." }
        }
        $installed = $false
        if (Get-WingetPath) {
            try {
                Install-WingetPackage 'EclipseAdoptium.Temurin.17.JDK' 'Eclipse Temurin JDK 17'
                $installed = $true
            } catch {
                Write-Warning $_.Exception.Message
                Write-Host '[*] Falling back to a direct Adoptium download...' -ForegroundColor Yellow
            }
        } else {
            Write-Host '[*] winget was not found. Downloading Eclipse Temurin JDK 17 from Adoptium...' -ForegroundColor Yellow
        }
        if (-not $installed) { Install-TemurinJdkFromAdoptium }
        Refresh-ProcessPath
        $jdk = Get-JdkInfo
        if (-not $jdk.Ready) { throw 'JDK installation finished, but java.exe and javac.exe for JDK 17+ were not found. Reopen the terminal and retry.' }
    }
    [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdk.JavaHome, 'Machine')
    $env:JAVA_HOME = $jdk.JavaHome
    Add-PathEntry (Join-Path $jdk.JavaHome 'bin') 'Machine'
    Write-Host "[+] JDK $($jdk.Major) ready: $($jdk.JavaHome)" -ForegroundColor Green
}

function Get-GitPath {
    $cmd = Get-Command 'git.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $paths = @((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'), (Join-Path $env:ProgramFiles 'Git\bin\git.exe'))
    if (${env:ProgramFiles(x86)}) { $paths += (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe') }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    return $null
}

function Ensure-GitForWindows {
    $git = Get-GitPath
    if (-not $git) {
        Write-Host 'Git for Windows is required by Flutter.' -ForegroundColor Yellow
        $answer = Read-InstallerInput -Prompt 'Install Git for Windows now? (Y/N)' -Default 'N' -Choices 'Y|N'
        if ($answer -notmatch '(?i)^y(es)?$') { throw 'Install Git for Windows and run the Flutter installer again, or answer Y when the installer runs in a console.' }
        $installed = $false
        if (Get-WingetPath) {
            try {
                Install-WingetPackage 'Git.Git' 'Git for Windows'
                $installed = $true
            } catch {
                Write-Warning $_.Exception.Message
                Write-Host '[*] Falling back to a direct Git for Windows download...' -ForegroundColor Yellow
            }
        } else {
            Write-Host '[*] winget was not found. Downloading Git for Windows from GitHub...' -ForegroundColor Yellow
        }
        if (-not $installed) { Install-GitFromGitHub }
        Refresh-ProcessPath
        $git = Get-GitPath
        if (-not $git) { throw 'Git installation finished, but git.exe was not found. Reopen the terminal and retry.' }
    }
    Add-PathEntry (Split-Path -Parent $git) 'Machine'
    $code = Invoke-ExternalToHost -Path $git -ArgumentList @('--version')
    if ($code -ne 0) { throw "Git did not start successfully (exit code $code)." }
    return $git
}

function Add-GitSafeDirectory {
    param([string]$GitPath, [string]$Directory)
    $safePath = $Directory.Replace('\', '/')
    $configuredResult = Invoke-ExternalCapture -Path $GitPath -ArgumentList @('config', '--system', '--get-all', 'safe.directory')
    $found = $false
    foreach ($value in $configuredResult.Output) { if ($value.ToString().Trim() -ieq $safePath) { $found = $true; break } }
    if (-not $found) {
        $code = Invoke-ExternalToHost -Path $GitPath -ArgumentList @('config', '--system', '--add', 'safe.directory', $safePath)
        if ($code -ne 0) { Write-Warning "Git could not trust $safePath system-wide; Flutter may report a Git ownership warning." }
    }
}

function Test-CmdlineToolsDirectory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $bin = Join-Path $Path 'bin'
    return ((Test-Path -LiteralPath (Join-Path $bin 'sdkmanager.bat') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $bin 'android.exe') -PathType Leaf))
}

function Get-CmdlineToolsFolders {
    param([string]$Root)
    $found = @()
    if (Test-CmdlineToolsDirectory $Root) { $found += (Get-Item -LiteralPath $Root).FullName }
    foreach ($name in @('cmdline-tools', 'commandlinetools', 'tools')) {
        $container = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $container -PathType Container)) { continue }
        if (Test-CmdlineToolsDirectory $container) { $found += (Get-Item -LiteralPath $container).FullName }
        foreach ($child in (Get-ChildItem -LiteralPath $container -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Name -match '^latest\.backup-') { continue }
            if (Test-CmdlineToolsDirectory $child.FullName) { $found += $child.FullName }
        }
    }
    $unique = @()
    foreach ($item in $found) { if (-not ($unique | Where-Object { $_ -ieq $item })) { $unique += $item } }
    return @($unique)
}

function Get-FlutterFolders {
    param([string]$Root)
    $found = @()
    if (Test-Path -LiteralPath (Join-Path $Root 'bin\flutter.bat') -PathType Leaf) { $found += (Get-Item -LiteralPath $Root).FullName }
    $nested = Join-Path $Root 'flutter'
    if (Test-Path -LiteralPath (Join-Path $nested 'bin\flutter.bat') -PathType Leaf) { $found += (Get-Item -LiteralPath $nested).FullName }
    foreach ($child in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        if (Test-Path -LiteralPath (Join-Path $child.FullName 'bin\flutter.bat') -PathType Leaf) { $found += $child.FullName }
    }
    $unique = @()
    foreach ($item in $found) { if (-not ($unique | Where-Object { $_ -ieq $item })) { $unique += $item } }
    return @($unique)
}

function Select-SourceCandidate {
    param([object[]]$Candidates, [string]$Title)
    if ($Candidates.Count -eq 0) { return $null }
    if ($Candidates.Count -eq 1) { return $Candidates[0] }
    Write-Host $Title -ForegroundColor Yellow
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        $label = $Candidates[$i].Name
        if ($Candidates[$i].Size -gt 0) { $label += " ($([math]::Round($Candidates[$i].Size / 1048576.0, 1)) MB)" }
        Write-Host "  $($i + 1). $label"
    }
    while ($true) {
        $answer = Read-InstallerInput -Prompt "Enter a number (1-$($Candidates.Count), Enter for 1, 0 to cancel)"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Candidates[0] }
        if ($answer -eq '0') { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Candidates.Count) { return $Candidates[$number - 1] }
        Write-Host 'Invalid selection.' -ForegroundColor Red
    }
}

function Read-FlutterSource {
    # An unattended run cannot answer "paste a path", so the source can come from the environment.
    $override = [string]$env:ANDROID_SDK_INSTALLER_FLUTTER_SOURCE
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $value = $override.Trim().Trim([char]'"').Trim()
        Write-Host "[*] Flutter source from ANDROID_SDK_INSTALLER_FLUTTER_SOURCE: $value" -ForegroundColor Yellow
        if ($value -match '^https?://') { return [pscustomobject]@{ Kind = 'Url'; Path = $value; Name = $value; Size = 0 } }
        if ((Test-Path -LiteralPath $value -PathType Leaf) -and ([IO.Path]::GetExtension($value) -ieq '.zip')) {
            $zipItem = Get-Item -LiteralPath $value
            return [pscustomobject]@{ Kind = 'Zip'; Path = $zipItem.FullName; Name = $zipItem.Name; Size = $zipItem.Length }
        }
        if (Test-Path -LiteralPath $value -PathType Container) {
            $folders = @(Get-FlutterFolders $value)
            if ($folders.Count -eq 0) { throw "ANDROID_SDK_INSTALLER_FLUTTER_SOURCE points at a folder that holds no Flutter SDK: $value" }
            return [pscustomobject]@{ Kind = 'Folder'; Path = $folders[0]; Name = "Extracted Flutter: $($folders[0])"; Size = 0 }
        }
        throw "ANDROID_SDK_INSTALLER_FLUTTER_SOURCE is neither a URL, a ZIP file, nor a folder: $value"
    }
    if (-not (Test-InteractiveConsoleHost)) {
        throw 'Flutter has to be told where its SDK comes from, and no console is attached. Run the installer from Run.bat, or set ANDROID_SDK_INSTALLER_FLUTTER_SOURCE to a ZIP path, a folder, or a URL.'
    }
    while ($true) {
        Write-Host 'Paste a folder containing flutter*.zip, an extracted Flutter folder, a ZIP path, or a direct URL.' -ForegroundColor Yellow
        Write-Host "Example: $env:USERPROFILE\Downloads" -ForegroundColor Gray
        $value = (Read-InstallerInput -Prompt 'Folder / ZIP / URL').Trim().Trim([char]'"').Trim([char]"'").Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { Write-Host 'Input cannot be empty.' -ForegroundColor Red; continue }
        if ($value -match '^https?://') { return [pscustomobject]@{ Kind = 'Url'; Path = $value; Name = $value; Size = 0 } }
        if (Test-Path -LiteralPath $value -PathType Leaf) {
            if ([IO.Path]::GetExtension($value) -ine '.zip') { Write-Host 'Select a .zip file or a folder.' -ForegroundColor Red; continue }
            $zip = Get-Item -LiteralPath $value
            return [pscustomobject]@{ Kind = 'Zip'; Path = $zip.FullName; Name = $zip.Name; Size = $zip.Length }
        }
        if (Test-Path -LiteralPath $value -PathType Container) {
            $sources = @()
            foreach ($zip in (Get-ChildItem -LiteralPath $value -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^flutter.*\.zip$' } | Sort-Object LastWriteTime -Descending)) {
                $sources += [pscustomobject]@{ Kind = 'Zip'; Path = $zip.FullName; Name = $zip.Name; Size = $zip.Length }
            }
            foreach ($folder in (Get-FlutterFolders $value)) {
                if (-not ($sources | Where-Object { $_.Path -ieq $folder })) { $sources += [pscustomobject]@{ Kind = 'Folder'; Path = $folder; Name = "Extracted Flutter: $folder"; Size = 0 } }
            }
            if ($sources.Count -eq 0) { Write-Host 'No Flutter ZIP or extracted Flutter SDK was found.' -ForegroundColor Red; continue }
            $selected = Select-SourceCandidate $sources 'Matching Flutter sources:'
            if ($null -ne $selected) { return $selected }
            continue
        }
        Write-Host 'Path not found. Try again.' -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Transfer progress: one live bar for every download and extraction, showing
# percentage, MB moved, MB/second, elapsed time, and time remaining.
# Set ANDROID_SDK_INSTALLER_NO_PROGRESS=1 to keep the old silent behaviour.
# ---------------------------------------------------------------------------

function Test-InlineProgressSupported {
    if ($env:ANDROID_SDK_INSTALLER_NO_PROGRESS) { return $false }
    if ($Host.Name -like '*ISE*') { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    try {
        $ui = $Host.UI.RawUI
        if ($null -eq $ui) { return $false }
        $null = $ui.WindowSize
        return $true
    } catch { return $false }
}

function Get-ProgressLineWidth {
    $width = 0
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch { $width = 0 }
    if ($width -le 0) { try { $width = [Console]::WindowWidth } catch { $width = 0 } }
    if ($width -le 0) { $width = 120 }
    if ($width -gt 240) { $width = 240 }
    return $width
}

function Format-ByteSize {
    param([double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ([double]::IsNaN($Bytes) -or [double]::IsInfinity($Bytes) -or ($Bytes -lt 0)) { return 'unknown' }
    if ($Bytes -ge 1073741824) { return ($Bytes / 1073741824).ToString('0.00', $inv) + ' GB' }
    if ($Bytes -ge 1048576) { return ($Bytes / 1048576).ToString('0.0', $inv) + ' MB' }
    if ($Bytes -ge 1024) { return ($Bytes / 1024).ToString('0', $inv) + ' KB' }
    return ([Math]::Round($Bytes)).ToString('0', $inv) + ' B'
}

function Format-DurationClock {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { return '--:--' }
    $span = [TimeSpan]::FromSeconds($Seconds)
    if ($span.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds) }
    return ('{0:00}:{1:00}' -f [int][Math]::Floor($span.TotalMinutes), $span.Seconds)
}

function Show-TransferProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][double]$ReceivedBytes,
        [double]$TotalBytes = 0,
        [double]$BytesPerSecond = 0,
        [double]$ElapsedSeconds = 0,
        [double]$RemainingSeconds = -1,
        [string]$Counter = '',
        [switch]$Completed
    )
    if ($env:ANDROID_SDK_INSTALLER_NO_PROGRESS) { return }
    if ($TotalBytes -lt 0) { $TotalBytes = 0 }
    if ($ReceivedBytes -lt 0) { $ReceivedBytes = 0 }
    if ($BytesPerSecond -lt 0) { $BytesPerSecond = 0 }
    if ($ElapsedSeconds -lt 0) { $ElapsedSeconds = 0 }
    $known = $TotalBytes -gt 0
    $fraction = if ($known) { [Math]::Min(1, $ReceivedBytes / $TotalBytes) } else { -1 }
    if ($Completed) { $fraction = 1 }

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $percentText = if ($fraction -ge 0) { ($fraction * 100).ToString('0.0', $inv) + '%' } else { '?' }
    $receivedText = Format-ByteSize $ReceivedBytes
    $totalText = if ($known) { Format-ByteSize $TotalBytes } else { 'unknown' }
    $speedText = (Format-ByteSize $BytesPerSecond) + '/s'
    $elapsedText = Format-DurationClock $ElapsedSeconds
    $leftText = Format-DurationClock $RemainingSeconds

    # Fixed-width fields keep the text the same length on every frame, so the bar
    # does not jitter while it is redrawn in place.
    $width = Get-ProgressLineWidth
    if ($width -lt 76) {
        $detail = ('{0,5} {1,9}/{2,9} {3,9} {4,7}' -f $percentText, $receivedText, $totalText, $speedText, $leftText)
    } elseif ($width -lt 112) {
        $detail = ('{0,5}  {1,9} / {2,-10} {3,10}  {4,7} left' -f $percentText, $receivedText, $totalText, $speedText, $leftText)
    } elseif ($Counter) {
        # The file/item counter is more useful than the elapsed clock on busy steps.
        $detail = ('{0,6}  {1,10} / {2,-10}  {3,10}  left {4}' -f $percentText, $receivedText, $totalText, $speedText, $leftText)
    } else {
        $detail = ('{0,6}  {1,10} / {2,-10}  {3,10}  elapsed {4}  left {5}' -f $percentText, $receivedText, $totalText, $speedText, $elapsedText, $leftText)
    }
    if ($Counter) {
        $withCounter = "$detail  ($Counter)"
        if ((($width - 1) - 7 - $withCounter.Length) -ge 8) { $detail = $withCounter }
    }
    $barWidth = ($width - 1) - 7 - $detail.Length
    if ($barWidth -lt 8) { $barWidth = 8 }
    if ($barWidth -gt 42) { $barWidth = 42 }
    $compact = $width -lt 112

    if (-not (Test-InlineProgressSupported)) {
        # Hosts without a real console line (ISE, redirected logs, remoting) get the
        # native PowerShell progress bar with the same numbers in its status text.
        $status = ($detail -replace '\s{2,}', ' ').Trim()
        if ($Counter -and $compact) { $status += " ($Counter)" }
        $percent = if ($fraction -ge 0) { [Math]::Min(100, [int][Math]::Floor($fraction * 100)) } else { -1 }
        try { Write-Progress -Activity $Activity -Status $status -PercentComplete $percent } catch { }
        if ($Completed) { try { Write-Progress -Activity $Activity -Completed } catch { } }
        return
    }

    # 7 = '    [' + '] ' frame around the bar; the line is padded so the redraw never wraps.
    $budget = ($width - 1) - 7 - $barWidth
    if ($budget -lt 8) { $budget = 8 }
    if ($detail.Length -gt $budget) { $detail = $detail.Substring(0, $budget) }
    $detail = $detail.PadRight($budget)

    $barColor = if ($Completed) { 'Green' } else { 'Cyan' }
    Write-Host "`r    [" -NoNewline -ForegroundColor DarkGray
    if ($fraction -ge 0) {
        $filled = [int][Math]::Round($fraction * $barWidth)
        if ($filled -lt 0) { $filled = 0 }
        if ($filled -gt $barWidth) { $filled = $barWidth }
        # Keep at least one block visible as soon as the transfer has started.
        if (($filled -eq 0) -and ($ReceivedBytes -gt 0) -and (-not $Completed)) { $filled = 1 }
        Write-Host ('#' * $filled) -NoNewline -ForegroundColor $barColor
        Write-Host ('-' * ($barWidth - $filled)) -NoNewline -ForegroundColor DarkGray
    } else {
        # Size unknown: slide a marker so the bar still shows movement and speed.
        $marker = [Math]::Min(3, $barWidth)
        $span = [Math]::Max(1, $barWidth - $marker)
        $position = ([int][Math]::Floor($ElapsedSeconds * 4)) % $span
        Write-Host ('-' * $position) -NoNewline -ForegroundColor DarkGray
        Write-Host ('#' * $marker) -NoNewline -ForegroundColor Yellow
        Write-Host ('-' * [Math]::Max(0, $barWidth - $position - $marker)) -NoNewline -ForegroundColor DarkGray
    }
    Write-Host ('] ' + $detail) -NoNewline -ForegroundColor Gray
    Write-Host "`r" -NoNewline
    $script:InlineProgressActive = $true
}

function Close-InlineProgressLine {
    if ($script:InlineProgressActive) {
        $script:InlineProgressActive = $false
        Write-Host ''
    }
}

function Reset-TransferProgress {
    param([Parameter(Mandatory = $true)][string]$Activity)
    Close-InlineProgressLine
    try { Write-Progress -Activity $Activity -Completed } catch { }
}

function Complete-TransferProgress {
    param([Parameter(Mandatory = $true)][string]$Activity, [string]$Summary)
    Close-InlineProgressLine
    try { Write-Progress -Activity $Activity -Completed } catch { }
    if (-not [string]::IsNullOrWhiteSpace($Summary)) { Write-Host "    [+] $Summary" -ForegroundColor Green }
}

function Get-SmoothedSpeed {
    param([double]$CurrentSmoothedSpeed, [double]$InstantSpeed)
    if ($InstantSpeed -le 0) { return $CurrentSmoothedSpeed }
    if ($CurrentSmoothedSpeed -le 0) { return $InstantSpeed }
    return (0.65 * $CurrentSmoothedSpeed) + (0.35 * $InstantSpeed)
}

function Get-PartialDownloadPath {
    param([Parameter(Mandatory = $true)][string]$Destination)
    # Partial transfers live next to the target so a retry can resume instead of starting over.
    return "$Destination.part"
}

function Receive-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Activity,
        [switch]$Resume
    )
    $destinationDir = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationDir) -and -not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }

    $part = Get-PartialDownloadPath $Destination
    $existing = [double]0
    if ($Resume -and (Test-Path -LiteralPath $part -PathType Leaf)) {
        try { $existing = [double](Get-Item -LiteralPath $part).Length } catch { $existing = [double]0 }
    }
    if ($existing -le 0) {
        if (Test-Path -LiteralPath $part -PathType Leaf) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        $existing = [double]0
    }

    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $request.UserAgent = 'Android-SDK-Installer'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 300000
    if ($existing -gt 0) {
        try { $request.AddRange([long]$existing) } catch { $existing = [double]0 }
    }

    $totalBytes = [double]0
    $receivedBytes = $existing
    $elapsedSeconds = [double]0
    $averageSpeed = [double]0
    $finalUri = $Url
    $response = $request.GetResponse()
    try {
        $status = [Net.HttpStatusCode]::OK
        try { $status = $response.StatusCode } catch { }
        $resumed = ($existing -gt 0) -and ($status -eq [Net.HttpStatusCode]::PartialContent)
        if (-not $resumed) { $existing = [double]0 }
        $contentBytes = [double]$response.ContentLength
        if ($contentBytes -lt 0) { $contentBytes = 0 }
        $totalBytes = $contentBytes + $existing
        try { if ($null -ne $response.ResponseUri) { $finalUri = [string]$response.ResponseUri } } catch { }
        $source = $response.GetResponseStream()
        try {
            if ($resumed) { $output = [IO.File]::Open($part, [IO.FileMode]::Append, [IO.FileAccess]::Write) }
            else { $output = [IO.File]::Create($part) }
            try {
                $buffer = New-Object 'byte[]' 524288
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $received = $existing
                $speed = [double]0
                $lastRender = [double]-1
                $lastSampleAt = [double]0
                $lastSampleBytes = $existing
                Show-TransferProgress -Activity $Activity -ReceivedBytes $received -TotalBytes $totalBytes -BytesPerSecond 0 -ElapsedSeconds 0 -RemainingSeconds -1
                while ($true) {
                    $read = $source.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) { break }
                    $output.Write($buffer, 0, $read)
                    $received += [double]$read
                    $elapsed = $clock.Elapsed.TotalSeconds
                    if (($elapsed - $lastSampleAt) -ge 0.5) {
                        $window = $elapsed - $lastSampleAt
                        if ($window -gt 0) { $speed = Get-SmoothedSpeed -CurrentSmoothedSpeed $speed -InstantSpeed (($received - $lastSampleBytes) / $window) }
                        $lastSampleAt = $elapsed
                        $lastSampleBytes = $received
                    }
                    $finished = ($totalBytes -gt 0) -and ($received -ge $totalBytes)
                    if ((($elapsed - $lastRender) -ge 0.12) -or $finished) {
                        $lastRender = $elapsed
                        $remaining = if (($totalBytes -gt 0) -and ($speed -gt 2048)) { ($totalBytes - $received) / $speed } else { -1 }
                        Show-TransferProgress -Activity $Activity -ReceivedBytes $received -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $elapsed -RemainingSeconds $remaining -Completed:$finished
                    }
                }
                $output.Flush($true)
                $clock.Stop()
                $seconds = $clock.Elapsed.TotalSeconds
                Show-TransferProgress -Activity $Activity -ReceivedBytes $received -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $seconds -RemainingSeconds 0 -Completed
                $receivedBytes = $received
                $elapsedSeconds = $seconds
                if (($seconds -gt 0) -and ($received -gt $existing)) { $averageSpeed = ($received - $existing) / $seconds }
            } finally { $output.Dispose() }
        } finally { $source.Dispose() }
    } finally { $response.Close() }

    # Completeness is checked once every stream is closed, so the rename can never race a writer.
    $written = [double]0
    try { if (Test-Path -LiteralPath $part -PathType Leaf) { $written = [double](Get-Item -LiteralPath $part).Length } } catch { $written = [double]0 }
    if ($written -le 0) { throw 'The download produced no data.' }
    if (($totalBytes -gt 0) -and ($written -lt $totalBytes)) {
        throw "The transfer ended after $(Format-ByteSize $written) of $(Format-ByteSize $totalBytes); the next attempt resumes from the partial file."
    }
    Move-Item -LiteralPath $part -Destination $Destination -Force
    return [pscustomobject]@{ Bytes = $written; Seconds = $elapsedSeconds; AverageSpeed = $averageSpeed; Source = $finalUri }
}

function Receive-FileSimple {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $client = New-Object Net.WebClient
    try {
        $client.Headers.Add('User-Agent', 'Android-SDK-Installer')
        $client.DownloadFile($Url, $Destination)
    } finally { $client.Dispose() }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw "The download did not create an output file: $Url" }
    return [pscustomobject]@{ Bytes = [double](Get-Item -LiteralPath $Destination).Length; Seconds = 0; AverageSpeed = 0; Source = $Url }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Url,
        [Parameter(Mandatory = $true, Position = 1)][string]$Destination,
        [Parameter(Position = 2)][string]$Label,
        # Published SHA-256 values are verified when the source offers one; the computed hash is
        # always printed so a suspect download can still be compared by hand.
        [string]$ExpectedSha256 = '',
        [int]$Attempts = 3
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = ''
        try { $Label = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath) } catch { $Label = '' }
        if ([string]::IsNullOrWhiteSpace($Label)) { $Label = [IO.Path]::GetFileName($Destination) }
    }
    $activity = "Downloading $Label"
    $part = Get-PartialDownloadPath $Destination
    $totalAttempts = [Math]::Max(1, $Attempts)
    $result = $null
    $lastFailure = ''
    for ($attempt = 1; $attempt -le $totalAttempts; $attempt++) {
        try {
            $result = Receive-FileWithProgress -Url $Url -Destination $Destination -Activity $activity -Resume:($attempt -gt 1)
            break
        } catch {
            $lastFailure = $_.Exception.Message
            Reset-TransferProgress -Activity $activity
            $serverStatus = 0
            if ($_.Exception -is [Net.WebException]) { try { $serverStatus = [int]$_.Exception.Response.StatusCode } catch { $serverStatus = 0 } }
            if (($serverStatus -ge 400) -and ($serverStatus -lt 500) -and ($serverStatus -ne 408) -and ($serverStatus -ne 429)) {
                # A missing or forbidden resource will not improve on a retry.
                if (Test-Path -LiteralPath $part -PathType Leaf) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
                throw "The server rejected the download of ${Label}: HTTP $serverStatus. $lastFailure"
            }
            $partialBytes = [double]0
            if (Test-Path -LiteralPath $part -PathType Leaf) { try { $partialBytes = [double](Get-Item -LiteralPath $part).Length } catch { $partialBytes = [double]0 } }
            if ($attempt -lt $totalAttempts) {
                $wait = 5 * $attempt
                if ($partialBytes -gt 0) {
                    Write-Host "[!] Attempt $attempt of $totalAttempts for $Label stopped after $(Format-ByteSize $partialBytes) ($lastFailure). Resuming in $wait second(s)..." -ForegroundColor Yellow
                } else {
                    Write-Host "[!] Attempt $attempt of $totalAttempts for $Label failed ($lastFailure). Retrying in $wait second(s)..." -ForegroundColor Yellow
                }
                Start-Sleep -Seconds $wait
                continue
            }
            if ($partialBytes -gt 0) { throw "The download of $Label stopped after $(Format-ByteSize $partialBytes). $lastFailure" }
            Write-Host "[!] The live progress bar could not start for $Label ($lastFailure). Retrying with a plain download..." -ForegroundColor Yellow
            try { $result = Receive-FileSimple -Url $Url -Destination $Destination }
            catch { throw "The download failed for ${Label}: $($_.Exception.Message)" }
        }
    }
    if ($null -eq $result) { throw "The download of $Label did not complete after $totalAttempts attempt(s). $lastFailure" }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'The download did not create an output file.' }
    if (-not (Test-FileSha256 -Path $Destination -Expected $ExpectedSha256)) {
        $actual = Get-FileSha256 $Destination
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "The SHA-256 of $Label did not match the published value (expected $($ExpectedSha256.ToUpperInvariant()), got $actual). The download was deleted; run the installer again."
    }
    if ($result.Seconds -gt 0) {
        $summary = ('{0} ({1}) downloaded in {2}, average {3}/s' -f $Label, (Format-ByteSize $result.Bytes), (Format-DurationClock $result.Seconds), (Format-ByteSize $result.AverageSpeed))
    } else {
        $summary = ('{0} ({1}) downloaded.' -f $Label, (Format-ByteSize $result.Bytes))
    }
    Complete-TransferProgress -Activity $activity -Summary $summary
    $sha = Get-FileSha256 $Destination
    if ($sha) {
        if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) { Write-Host "    SHA-256 (not verified against a published value): $sha" -ForegroundColor DarkGray }
        else { Write-Host "    SHA-256 verified: $sha" -ForegroundColor DarkGray }
    }
}

function Expand-ZipWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$Activity
    )
    try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue } catch { }
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch { }
    if (-not (Test-Path -LiteralPath $LiteralPath -PathType Leaf)) { throw "The archive was not found: $LiteralPath" }
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) { New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null }
    $destinationRoot = (Resolve-Path -LiteralPath $DestinationPath).ProviderPath.TrimEnd('\') + '\'

    $archive = [IO.Compression.ZipFile]::OpenRead($LiteralPath)
    try {
        $entries = @($archive.Entries)
        $totalEntries = $entries.Count
        if ($totalEntries -eq 0) { return }
        $totalBytes = [double]($entries | Measure-Object -Property Length -Sum).Sum
        $createdDirectories = @{}
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $doneBytes = [double]0
        $doneEntries = 0
        $speed = [double]0
        $lastRender = [double]-1
        $lastSampleAt = [double]0
        $lastSampleBytes = [double]0
        Show-TransferProgress -Activity $Activity -ReceivedBytes 0 -TotalBytes $totalBytes -BytesPerSecond 0 -ElapsedSeconds 0 -RemainingSeconds -1 -Counter ('{0,6}/{1,5} files' -f 0, $totalEntries)
        foreach ($entry in $entries) {
            $relative = $entry.FullName.Replace('\', '/').TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $destinationRoot ($relative -replace '/', '\')))
            if (-not $target.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning "Skipped an unsafe archive entry: $($entry.FullName)"
                continue
            }
            if ($relative.EndsWith('/')) {
                [void][IO.Directory]::CreateDirectory($target)
            } else {
                $targetDirectory = Split-Path -Parent $target
                if (-not $createdDirectories.ContainsKey($targetDirectory)) {
                    [void][IO.Directory]::CreateDirectory($targetDirectory)
                    $createdDirectories[$targetDirectory] = $true
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                $doneBytes += [double]$entry.Length
            }
            $doneEntries++
            $elapsed = $clock.Elapsed.TotalSeconds
            if (($elapsed - $lastSampleAt) -ge 0.5) {
                $window = $elapsed - $lastSampleAt
                if ($window -gt 0) { $speed = Get-SmoothedSpeed -CurrentSmoothedSpeed $speed -InstantSpeed (($doneBytes - $lastSampleBytes) / $window) }
                $lastSampleAt = $elapsed
                $lastSampleBytes = $doneBytes
            }
            $finished = $doneEntries -ge $totalEntries
            if ((($elapsed - $lastRender) -ge 0.12) -or $finished) {
                $lastRender = $elapsed
                $remaining = if (($totalBytes -gt 0) -and ($speed -gt 2048)) { ($totalBytes - $doneBytes) / $speed } else { -1 }
                Show-TransferProgress -Activity $Activity -ReceivedBytes $doneBytes -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $elapsed -RemainingSeconds $remaining -Counter ('{0,6}/{1,5} files' -f $doneEntries, $totalEntries) -Completed:$finished
            }
        }
        $clock.Stop()
        $seconds = $clock.Elapsed.TotalSeconds
        Show-TransferProgress -Activity $Activity -ReceivedBytes $doneBytes -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $seconds -RemainingSeconds 0 -Counter ('{0,6}/{1,5} files' -f $doneEntries, $totalEntries) -Completed
        Complete-TransferProgress -Activity $Activity -Summary ("{0} extracted: {1} in {2}" -f $doneEntries, (Format-ByteSize $doneBytes), (Format-DurationClock $seconds))
    } finally { $archive.Dispose() }
}

function Expand-ArchiveWithProgress {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$LiteralPath,
        [Parameter(Mandatory = $true, Position = 1)][string]$DestinationPath,
        [Parameter(Position = 2)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = [IO.Path]::GetFileName($LiteralPath) }
    $activity = "Extracting $Label"
    try {
        Expand-ZipWithProgress -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Activity $activity
    } catch {
        Reset-TransferProgress -Activity $activity
        Write-Warning "Progress-based extraction failed ($($_.Exception.Message)); falling back to Expand-Archive."
        if (Test-Path -LiteralPath $DestinationPath -PathType Container) { Remove-Item -LiteralPath $DestinationPath -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath -Force
        Write-Host '    [+] Extraction finished.' -ForegroundColor Green
    }
}

function Copy-SingleFile {
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$Target
    )
    [IO.File]::Copy($File.FullName, $Target, $true)
    $attributes = $File.Attributes
    if ((($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -and ($attributes -ne [IO.FileAttributes]::Normal)) {
        try { [IO.File]::SetAttributes($Target, $attributes) } catch { }
    }
}

function Copy-TreeWithProgress {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Source,
        [Parameter(Mandatory = $true, Position = 1)][string]$Destination,
        [Parameter(Position = 2)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = 'files' }
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "The source folder was not found: $Source" }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $sourceRoot = (Resolve-Path -LiteralPath $Source).ProviderPath.TrimEnd('\')
    $destinationRoot = (Resolve-Path -LiteralPath $Destination).ProviderPath.TrimEnd('\')

    # One enumeration feeds the folder structure, the byte total, and the per-file copy loop.
    $entries = @(Get-ChildItem -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue)
    $directories = @($entries | Where-Object { $_.PSIsContainer })
    $files = @($entries | Where-Object { -not $_.PSIsContainer })
    foreach ($directory in $directories) {
        [void][IO.Directory]::CreateDirectory($destinationRoot + $directory.FullName.Substring($sourceRoot.Length))
    }
    if ($files.Count -eq 0) { return }
    $totalBytes = [double]($files | Measure-Object -Property Length -Sum).Sum

    $activity = "Copying $Label"
    if ($env:ANDROID_SDK_INSTALLER_NO_PROGRESS) {
        foreach ($file in $files) { Copy-SingleFile -File $file -Target ($destinationRoot + $file.FullName.Substring($sourceRoot.Length)) }
        return
    }

    $clock = [Diagnostics.Stopwatch]::StartNew()
    $doneBytes = [double]0
    $speed = [double]0
    $lastRender = [double]-1
    $lastSampleAt = [double]0
    $lastSampleBytes = [double]0
    $index = 0
    Show-TransferProgress -Activity $activity -ReceivedBytes 0 -TotalBytes $totalBytes -BytesPerSecond 0 -ElapsedSeconds 0 -RemainingSeconds -1 -Counter ('{0,6}/{1,5} files' -f 0, $files.Count)
    foreach ($file in $files) {
        Copy-SingleFile -File $file -Target ($destinationRoot + $file.FullName.Substring($sourceRoot.Length))
        $doneBytes += [double]$file.Length
        $index++
        $elapsed = $clock.Elapsed.TotalSeconds
        if (($elapsed - $lastSampleAt) -ge 0.5) {
            $window = $elapsed - $lastSampleAt
            if ($window -gt 0) { $speed = Get-SmoothedSpeed -CurrentSmoothedSpeed $speed -InstantSpeed (($doneBytes - $lastSampleBytes) / $window) }
            $lastSampleAt = $elapsed
            $lastSampleBytes = $doneBytes
        }
        $finished = $index -ge $files.Count
        if ((($elapsed - $lastRender) -ge 0.12) -or $finished) {
            $lastRender = $elapsed
            $remaining = if (($totalBytes -gt 0) -and ($speed -gt 2048)) { ($totalBytes - $doneBytes) / $speed } else { -1 }
            Show-TransferProgress -Activity $activity -ReceivedBytes $doneBytes -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $elapsed -RemainingSeconds $remaining -Counter ('{0,6}/{1,5} files' -f $index, $files.Count) -Completed:$finished
        }
    }
    $clock.Stop()
    Complete-TransferProgress -Activity $activity -Summary ("{0} copied: {1} in {2}" -f $files.Count, (Format-ByteSize $doneBytes), (Format-DurationClock $clock.Elapsed.TotalSeconds))
}

function Copy-FileWithProgress {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Source,
        [Parameter(Mandatory = $true, Position = 1)][string]$Destination,
        [Parameter(Position = 2)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "The source file was not found: $Source" }
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = [IO.Path]::GetFileName($Source) }
    if ($env:ANDROID_SDK_INSTALLER_NO_PROGRESS) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return
    }
    $activity = "Copying $Label"
    $totalBytes = [double](Get-Item -LiteralPath $Source).Length
    $destinationDir = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationDir) -and -not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }
    $sourceStream = [IO.File]::OpenRead($Source)
    try {
        $output = [IO.File]::Create($Destination)
        try {
            $buffer = New-Object 'byte[]' 1048576
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $doneBytes = [double]0
            $speed = [double]0
            $lastRender = [double]-1
            $lastSampleAt = [double]0
            $lastSampleBytes = [double]0
            Show-TransferProgress -Activity $activity -ReceivedBytes 0 -TotalBytes $totalBytes -BytesPerSecond 0 -ElapsedSeconds 0 -RemainingSeconds -1
            while ($true) {
                $read = $sourceStream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0) { break }
                $output.Write($buffer, 0, $read)
                $doneBytes += [double]$read
                $elapsed = $clock.Elapsed.TotalSeconds
                if (($elapsed - $lastSampleAt) -ge 0.5) {
                    $window = $elapsed - $lastSampleAt
                    if ($window -gt 0) { $speed = Get-SmoothedSpeed -CurrentSmoothedSpeed $speed -InstantSpeed (($doneBytes - $lastSampleBytes) / $window) }
                    $lastSampleAt = $elapsed
                    $lastSampleBytes = $doneBytes
                }
                $finished = ($totalBytes -gt 0) -and ($doneBytes -ge $totalBytes)
                if ((($elapsed - $lastRender) -ge 0.12) -or $finished) {
                    $lastRender = $elapsed
                    $remaining = if (($totalBytes -gt 0) -and ($speed -gt 2048)) { ($totalBytes - $doneBytes) / $speed } else { -1 }
                    Show-TransferProgress -Activity $activity -ReceivedBytes $doneBytes -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $elapsed -RemainingSeconds $remaining -Completed:$finished
                }
            }
            $output.Flush($true)
            $clock.Stop()
            Show-TransferProgress -Activity $activity -ReceivedBytes $doneBytes -TotalBytes $totalBytes -BytesPerSecond $speed -ElapsedSeconds $clock.Elapsed.TotalSeconds -RemainingSeconds 0 -Completed
            Complete-TransferProgress -Activity $activity -Summary ("{0} copied in {1}" -f (Format-ByteSize $doneBytes), (Format-DurationClock $clock.Elapsed.TotalSeconds))
        } finally { $output.Dispose() }
    } finally { $sourceStream.Dispose() }
}

function Find-ExtractedAndroidTools {
    param([string]$Root)
    $folders = @(Get-CmdlineToolsFolders $Root)
    if ($folders.Count -gt 0) { return $folders[0] }
    return $null
}

function Get-SdkLicenseAnswers {
    param([ValidateSet('y', 'n')][string]$Answer = 'y', [int]$Count = 40)
    # One answer per license prompt, with spares for retries and per-package confirmations.
    $answers = @()
    for ($i = 0; $i -lt $Count; $i++) { $answers += $Answer }
    return $answers
}

function Get-SdkLicenseStatusFromText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'Unknown' }
    $ansi = [string][char]27 + '\[[0-9;]*m'
    $clean = ($Text -replace $ansi, '') -replace '\s+', ' '
    if ($clean -match '(?i)all sdk package licenses (?:have been )?accepted') { return 'Accepted' }
    $summary = [regex]::Match($clean, '(?i)(?<count>\d+) of (?<total>\d+) SDK package licenses not accepted')
    if ($summary.Success) {
        if ([int]$summary.Groups['count'].Value -eq 0) { return 'Accepted' }
        return 'NotAccepted'
    }
    if ($clean -match '(?i)SDK package licenses? (?:have )?not (?:been )?accepted') { return 'NotAccepted' }
    return 'Unknown'
}

function Test-SdkLicensesAccepted {
    param([AllowEmptyString()][string]$SdkManager, [Parameter(Mandatory = $true)][string]$SdkRoot)
    if ([string]::IsNullOrWhiteSpace($SdkManager) -or -not (Test-Path -LiteralPath $SdkManager -PathType Leaf)) { return $false }
    # "n" answers keep a verification run from accepting anything on the user's behalf and stop it
    # from waiting forever on a prompt whose text is captured instead of displayed.
    $check = Invoke-ExternalCapture -Path $SdkManager -ArgumentList @("--sdk_root=$SdkRoot", '--licenses') -Answers (Get-SdkLicenseAnswers 'n')
    $text = (@($check.Output | ForEach-Object { $_.ToString() }) -join "`n")
    $status = Get-SdkLicenseStatusFromText $text
    if ($status -eq 'Unknown') { return ($check.ExitCode -eq 0) }
    return ($status -eq 'Accepted')
}

function Get-SdkLicenseFileHashes {
    # License hashes published by Google. sdkmanager writes these files itself when it accepts a
    # license, so they are only used when the tool cannot record an acceptance.
    return [ordered]@{
        'android-sdk-license'         = @('8933bad161af4178b1185d1a37fbf41ea5269c55', '24333f8a63b6825ea9c5514f83c2829b004d1fee', 'd56f5187479451eabf01fb78af6dfcb131a6481e')
        'android-sdk-preview-license' = @('84831b9409646a918e30573bab4c9c91346d8abd')
        'android-googletv-license'    = @('601085b94cd77f0b54ff86406957099ebe79c4d6')
        'android-sdk-arm-dbt-license' = @('859f317696f67ef3d7f320ef9dff4ae5c47d97a4')
        'google-gdk-license'          = @('33b6a2b64607f11b759f320ef9dff4ae5c47d97a')
    }
}

function Write-SdkLicenseFiles {
    param([Parameter(Mandatory = $true)][string]$SdkRoot)
    $licensesRoot = Join-Path $SdkRoot 'licenses'
    New-Item -ItemType Directory -Path $licensesRoot -Force | Out-Null
    $published = Get-SdkLicenseFileHashes
    $written = @()
    foreach ($name in $published.Keys) {
        $path = Join-Path $licensesRoot $name
        $hashes = @()
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            # Keep hashes sdkmanager already recorded and add the published ones.
            $hashes = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        foreach ($hash in $published[$name]) { if ($hashes -notcontains $hash) { $hashes += $hash } }
        Set-Content -LiteralPath $path -Value ($hashes -join [Environment]::NewLine) -Encoding Ascii -Force
        $written += $name
    }
    Write-Host "[+] SDK license files written to $licensesRoot ($($written -join ', '))" -ForegroundColor Green
}

function Accept-SdkLicenses {
    param(
        [AllowEmptyString()][string]$SdkManager,
        [AllowEmptyString()][string]$AndroidCli,
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        [ValidateSet('Auto', 'Review')][string]$Mode = 'Auto'
    )
    if ([string]::IsNullOrWhiteSpace($SdkManager)) {
        if ($AndroidCli) { Write-Warning 'sdkmanager.bat is absent; the Android CLI will manage licenses during package installation.' }
        else { Write-Warning 'No SDK license manager was found, so license acceptance cannot be verified.' }
        return $true
    }

    $licenseArgs = @("--sdk_root=$SdkRoot", '--licenses')
    $licensesRoot = Join-Path $SdkRoot 'licenses'
    $recorded = @(Get-ChildItem -LiteralPath $licensesRoot -File -ErrorAction SilentlyContinue)

    # A verification run contacts the package repository, so only spend one up front when license
    # files already exist. A fresh SDK goes straight to acceptance.
    if ($recorded.Count -gt 0) {
        Write-Host "[*] Checking the licenses already recorded under $licensesRoot..." -ForegroundColor Yellow
        if (Test-SdkLicensesAccepted -SdkManager $SdkManager -SdkRoot $SdkRoot) {
            Write-Host '[+] All Android SDK licenses are already accepted.' -ForegroundColor Green
            return $true
        }
    }

    if ($Mode -eq 'Review') {
        if (-not (Test-InteractiveConsoleHost)) {
            # The review path has to be answerable: without a real console the prompts are invisible
            # and every licence would silently default to "no" - or the tool would simply wait forever.
            throw 'Reviewing the Android SDK license prompts needs a real console. Start the installer from Run.bat, or choose Y at the "accept every license" prompt.'
        }
        Write-Host '[*] Review the Android SDK licenses and enter Y at each prompt to accept it.' -ForegroundColor Yellow
        [void](Invoke-ExternalInteractive -Path $SdkManager -ArgumentList $licenseArgs)
    } else {
        Write-Host '[*] Accepting the Android SDK licenses (this refreshes the package catalog and can take a minute)...' -ForegroundColor Yellow
        [void](Invoke-ExternalInteractive -Path $SdkManager -ArgumentList $licenseArgs -Answers (Get-SdkLicenseAnswers 'y'))
    }
    Write-Host '[*] Verifying that every license was recorded...' -ForegroundColor Yellow
    if (Test-SdkLicensesAccepted -SdkManager $SdkManager -SdkRoot $SdkRoot) {
        Write-Host '[+] All Android SDK licenses accepted.' -ForegroundColor Green
        return $true
    }

    if ($Mode -ne 'Auto') {
        # In review mode a declined prompt is a decision. Writing the published hash files here would
        # accept exactly the licenses the user refused, so the choice is respected and reported.
        Write-Warning 'Some Android SDK licenses were declined. Re-run this step and accept them, or install those packages manually.'
        return $false
    }

    Write-Warning 'sdkmanager did not record the accepted licenses. Writing the SDK license files directly...'
    Write-SdkLicenseFiles -SdkRoot $SdkRoot
    Write-Host '[*] Verifying the written license files...' -ForegroundColor Yellow
    if (Test-SdkLicensesAccepted -SdkManager $SdkManager -SdkRoot $SdkRoot) {
        Write-Host '[+] All Android SDK licenses accepted.' -ForegroundColor Green
        return $true
    }

    if (Test-InteractiveConsoleHost) {
        Write-Host '[*] Automatic acceptance did not stick. Review the prompts and enter Y at each one.' -ForegroundColor Yellow
        [void](Invoke-ExternalInteractive -Path $SdkManager -ArgumentList $licenseArgs)
        Write-Host '[*] Verifying that every license was recorded...' -ForegroundColor Yellow
        if (Test-SdkLicensesAccepted -SdkManager $SdkManager -SdkRoot $SdkRoot) {
            Write-Host '[+] All Android SDK licenses accepted.' -ForegroundColor Green
            return $true
        }
    }
    return $false
}

function Get-ShortHash {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'default' }
    try {
        $md5 = [Security.Cryptography.MD5]::Create()
        $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        return ((@($bytes) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    } catch { return 'default' }
}

function Get-SdkPackageNamesFromText {
    param([AllowEmptyString()][string]$Text)
    # `--list` output is the only place sdkmanager exposes the optional NDK/CMake versions, and the
    # newer Android CLI writes the same table with '/' instead of ';' as the version separator.
    $packages = @()
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $ansi = [string][char]27 + '\[[0-9;]*m'
    foreach ($line in ($Text -split "`r?`n")) {
        $clean = $line -replace $ansi, ''
        if ($clean -match '^\s*(?<package>(?:build-tools|cmake|ndk)[;/]\d+(?:\.\d+)+)\s*\|') { $packages += ($Matches['package'] -replace '/', ';') }
    }
    return @($packages | Sort-Object -Unique)
}

function Clear-SdkCatalogCache {
    param([string]$SdkRoot)
    if ($env:ANDROID_SDK_INSTALLER_NO_CACHE) { return }
    $path = Join-Path (Get-InstallerStateRoot 'cache') ('sdk-catalog-' + (Get-ShortHash $SdkRoot) + '.txt')
    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-AvailableSdkPackages {
    param(
        [AllowEmptyString()][string]$SdkManager = '',
        [AllowEmptyString()][string]$AndroidCli = '',
        [string]$SdkRoot = ''
    )
    $cacheName = 'sdk-catalog-' + (Get-ShortHash $SdkRoot) + '.txt'
    $cached = Read-InstallerCache -Name $cacheName -MaxAgeHours 6
    if ($cached) {
        $fromCache = @(Get-SdkPackageNamesFromText $cached)
        if ($fromCache.Count -gt 0) {
            Write-Host "    SDK package catalog reused from the installer cache ($($fromCache.Count) candidate(s))" -ForegroundColor DarkGray
            return $fromCache
        }
    }
    $output = @()
    $managerUsable = [bool]($SdkManager -and (Test-Path -LiteralPath $SdkManager -PathType Leaf))
    $cliUsable = [bool]($AndroidCli -and (Test-Path -LiteralPath $AndroidCli -PathType Leaf))
    if ($managerUsable) {
        $catalogResult = Invoke-ExternalCapture -Path $SdkManager -ArgumentList @("--sdk_root=$SdkRoot", '--list')
        $output = @($catalogResult.Output | ForEach-Object { $_.ToString() })
        if ($catalogResult.ExitCode -ne 0) {
            Write-Warning "Could not read the SDK package catalog (sdkmanager exit code $($catalogResult.ExitCode)). Optional NDK/CMake packages may be skipped."
            return @()
        }
    } elseif ($cliUsable) {
        $catalogResult = Invoke-ExternalCapture -Path $AndroidCli -ArgumentList @("--sdk=$SdkRoot", 'sdk', 'list')
        $output = @($catalogResult.Output | ForEach-Object { $_.ToString() })
        if ($catalogResult.ExitCode -ne 0) {
            Write-Warning "Could not read the SDK package catalog (Android CLI exit code $($catalogResult.ExitCode)). Optional NDK/CMake packages may be skipped."
            return @()
        }
    } else {
        return @()
    }
    $text = $output -join "`n"
    $packages = @(Get-SdkPackageNamesFromText $text)
    # Caching a failed or empty listing would hide every optional package for the next six hours.
    if ($packages.Count -gt 0) { Write-InstallerCache -Name $cacheName -Content $text }
    return $packages
}

function Get-LatestSdkPackage {
    param([AllowEmptyCollection()][string[]]$Packages, [string]$Name, [string]$Major = '')
    $results = @()
    foreach ($package in $Packages) {
        if ($package -notmatch "^$([regex]::Escape($Name));(?<v>\d+(?:\.\d+)+)$") { continue }
        $versionText = $Matches['v']
        if ($Major -and $versionText -notmatch "^$([regex]::Escape($Major))\.") { continue }
        $version = [version]'0.0'
        if ([version]::TryParse($versionText, [ref]$version)) { $results += [pscustomobject]@{ Path = $package; Version = $version } }
    }
    if ($results.Count -eq 0) { return $null }
    return ($results | Sort-Object Version -Descending | Select-Object -First 1).Path
}

function Get-SdkPackageMarkerPath {
    param([string]$SdkRoot, [string]$Package)
    # The file that proves a package is usable. Markers, not folder names, are what keep a
    # half-extracted NDK from being treated as installed.
    if ($Package -imatch '^(?<name>build-tools|cmake|ndk);(?<version>.+)$') {
        $name = $Matches['name']
        $version = $Matches['version']
        if ($name -ieq 'ndk') { return (Join-Path $SdkRoot "ndk\$version\source.properties") }
        if ($name -ieq 'cmake') { return (Join-Path $SdkRoot "cmake\$version\bin\cmake.exe") }
        return (Join-Path $SdkRoot "build-tools\$version\aapt2.exe")
    }
    if ($Package -ieq 'platform-tools') { return (Join-Path $SdkRoot 'platform-tools\adb.exe') }
    if ($Package -imatch '^platforms;android-(?<api>.+)$') { return (Join-Path $SdkRoot "platforms\android-$($Matches['api'])\android.jar") }
    if ($Package -imatch '^cmdline-tools;latest$') { return (Join-Path $SdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat') }
    if ($Package -imatch '^emulator$') { return (Join-Path $SdkRoot 'emulator\emulator.exe') }
    return ''
}

function Test-SdkPackagePresent {
    param([string]$SdkRoot, [string]$Package)
    $marker = Get-SdkPackageMarkerPath -SdkRoot $SdkRoot -Package $Package
    if ([string]::IsNullOrWhiteSpace($marker)) { return $false }
    return (Test-Path -LiteralPath $marker -PathType Leaf)
}

function Install-SdkPackages {
    param(
        [AllowEmptyString()][string]$SdkManager,
        [AllowEmptyString()][string]$AndroidCli,
        [string]$SdkRoot,
        [string[]]$Packages,
        # Already-installed packages are skipped, so a fallback never re-downloads a 2 GB NDK.
        [switch]$SkipInstalled
    )
    # Installs run with the console attached so the tool's own progress and any late license prompt
    # stay visible and answerable.
    $wanted = @($Packages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($SkipInstalled) {
        $pending = @()
        foreach ($package in $wanted) {
            if (Test-SdkPackagePresent -SdkRoot $SdkRoot -Package $package) {
                Write-Host "    Already installed, nothing to download: $package" -ForegroundColor DarkGray
                continue
            }
            $pending += $package
        }
        $wanted = @($pending)
    }
    if ($wanted.Count -eq 0) { return 0 }
    $cliUsable = [bool]($AndroidCli -and (Test-Path -LiteralPath $AndroidCli -PathType Leaf))
    $managerUsable = [bool]($SdkManager -and (Test-Path -LiteralPath $SdkManager -PathType Leaf))
    # Without a console an unattended prompt would hang forever. Piping answers is only allowed when
    # the user already accepted every license, so nothing new is agreed on their behalf.
    $answers = @()
    if ((-not (Test-InteractiveConsoleHost)) -and $script:AcceptAllLicensesGranted) { $answers = @(Get-SdkLicenseAnswers 'y' 8) }
    $lastCode = 1
    if ($cliUsable) {
        $cliPackages = @($wanted | ForEach-Object { $_ -replace ';', '/' })
        Write-Host "[*] Installing with Android CLI: $($cliPackages -join ', ')" -ForegroundColor Yellow
        $cliArgs = @("--sdk=$SdkRoot", 'sdk', 'install') + $cliPackages
        $lastCode = Invoke-ExternalInteractive -Path $AndroidCli -ArgumentList $cliArgs -Answers $answers
        if ($lastCode -eq 0) { return 0 }
        # The CLI reports errors that do not invalidate the transfer (deprecation notices, a package
        # it just wrote), so only what is genuinely missing is retried - and only with sdkmanager.
        $remaining = @($wanted | Where-Object { -not (Test-SdkPackagePresent -SdkRoot $SdkRoot -Package $_) })
        if ($remaining.Count -eq 0) {
            Write-Host "    The Android CLI returned $lastCode, but every requested package is present in $SdkRoot." -ForegroundColor Gray
            return 0
        }
        if (-not $managerUsable) { return $lastCode }
        Write-Host "[!] The Android CLI returned $lastCode. Retrying the missing packages with sdkmanager: $($remaining -join ', ')" -ForegroundColor Yellow
        $wanted = $remaining
    }
    if (-not $managerUsable) { return $lastCode }
    Write-Host "[*] Installing with sdkmanager: $($wanted -join ', ')" -ForegroundColor Yellow
    $managerArgs = @("--sdk_root=$SdkRoot") + $wanted
    return (Invoke-ExternalInteractive -Path $SdkManager -ArgumentList $managerArgs -Answers $answers)
}

function Get-LatestVersionFolder {
    param(
        [string]$Parent,
        # A version folder only counts when this file is inside it, so a half-extracted package is
        # never advertised as usable (the reason a failed NDK download used to poison ANDROID_NDK_HOME).
        [string]$RequiredFile = ''
    )
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { return $null }
    $best = $null
    $bestVersion = $null
    foreach ($dir in (Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue)) {
        $version = [version]'0.0'
        if (-not [version]::TryParse($dir.Name, [ref]$version)) { continue }
        if ($RequiredFile -and -not (Test-Path -LiteralPath (Join-Path $dir.FullName $RequiredFile) -PathType Leaf)) { continue }
        if ($null -eq $bestVersion -or $version -gt $bestVersion) { $best = $dir.FullName; $bestVersion = $version }
    }
    return $best
}

function Get-CmdlineToolsBuildMarkerPath {
    param([string]$SdkRoot)
    return (Join-Path $SdkRoot 'cmdline-tools\latest\.installer-build')
}

function Get-InstalledCmdlineToolsBuild {
    param([string]$SdkRoot)
    $path = Get-CmdlineToolsBuildMarkerPath $SdkRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try { return ([string](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)).Trim() } catch { return '' }
}

function Set-InstalledCmdlineToolsBuild {
    param([string]$SdkRoot, [string]$Build)
    # The zip name carries the build number but no installed file does, so the installer records it.
    try { Set-Content -LiteralPath (Get-CmdlineToolsBuildMarkerPath $SdkRoot) -Value $Build -Encoding Ascii -Force -ErrorAction Stop } catch { }
}

function Get-BackupRoot {
    return (Get-InstallerStateRoot 'backups')
}

function Get-BackupFolders {
    param([string]$Prefix = '')
    $root = Get-BackupRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $filter = '*backup*'
    if ($Prefix) { $filter = "$Prefix.*" }
    return @(Get-ChildItem -LiteralPath $root -Directory -Filter $filter -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
}

function Remove-OldBackups {
    param([string]$Prefix = '', [int]$Keep = 3)
    # Backups used to pile up inside the SDK root, where tools also scan for packages. They now live
    # beside the installer state, and only the newest few are kept.
    $folders = @(Get-BackupFolders -Prefix $Prefix)
    if ($folders.Count -le $Keep) { return }
    foreach ($old in @($folders | Select-Object -Skip $Keep)) {
        try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop; Write-Host "    Removed an old backup: $($old.Name)" -ForegroundColor Gray } catch { }
    }
}

function Move-LegacyCmdlineToolsBackups {
    param([string]$ToolsRoot)
    # Older installer runs left "latest.backup-<timestamp>" folders inside C:\Android\cmdline-tools.
    if (-not (Test-Path -LiteralPath $ToolsRoot -PathType Container)) { return 0 }
    $moved = 0
    $root = Get-BackupRoot
    foreach ($folder in (Get-ChildItem -LiteralPath $ToolsRoot -Directory -Filter 'latest.backup-*' -ErrorAction SilentlyContinue)) {
        $stamp = $folder.Name -replace '^latest\.backup-', ''
        $target = Join-Path $root ('cmdline-tools-latest.' + $stamp)
        try { Move-Item -LiteralPath $folder.FullName -Destination $target -ErrorAction Stop; $moved++ } catch { }
    }
    if ($moved -gt 0) { Write-Host "    Moved $moved old command-line tools backup(s) out of $ToolsRoot into $(Get-BackupRoot)" -ForegroundColor Gray }
    return $moved
}

function Get-LatestCmdlineToolsInfo {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Last known build, used only if the Android developer page cannot be read.
    $fallbackBuild = '15859902'
    $build = ''
    $source = 'Android developer download page'
    if ($env:ANDROID_SDK_INSTALLER_CMDLINE_TOOLS_BUILD -match '^\d+$') {
        $build = $env:ANDROID_SDK_INSTALLER_CMDLINE_TOOLS_BUILD
        $source = 'ANDROID_SDK_INSTALLER_CMDLINE_TOOLS_BUILD'
    } else {
        $cachedText = Read-InstallerCache -Name 'cmdline-tools-build.txt' -MaxAgeHours 168
        $cached = ''
        if ($cachedText) { $cached = ([string]$cachedText).Trim() }
        if ($cached -match '^\d+$') { $build = $cached; $source = 'installer cache' }
    }
    if ([string]::IsNullOrWhiteSpace($build)) {
        Write-Host '[*] Looking up the latest Google command-line tools version...' -ForegroundColor Yellow
        try {
            $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://developer.android.com/studio' -Headers @{ 'User-Agent' = 'Android-SDK-Installer' }
            $hits = @([regex]::Matches([string]$page.Content, 'commandlinetools-win-(\d+)_latest\.zip'))
            $numbers = @($hits | ForEach-Object { [long]$_.Groups[1].Value } | Sort-Object -Descending)
            if ($numbers.Count -gt 0) { $build = [string]$numbers[0] }
            Write-InstallerCache -Name 'cmdline-tools-build.txt' -Content $build
        } catch {
            Write-Warning "Could not read the Android developer download page: $($_.Exception.Message)"
        }
    } else {
        Write-Host "    Latest command-line tools build reused from the $source." -ForegroundColor DarkGray
    }
    if ([string]::IsNullOrWhiteSpace($build)) {
        Write-Warning "Using the fallback command-line tools build $fallbackBuild."
        $build = $fallbackBuild
    }
    Write-Host "[*] Latest command-line tools build: $build" -ForegroundColor Yellow
    return [pscustomobject]@{ Build = $build; Url = "https://dl.google.com/android/repository/commandlinetools-win_$($build)_latest.zip" }
}

function Install-AndroidSdk {
    Write-Host ''
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '        Java SDK + Android SDK Installation               ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan

    # An ANDROID_HOME that already points at a working SDK must be respected, not replaced.
    $null = Resolve-AndroidSdkRoot
    Write-Host ''
    Write-Host "[*] Android SDK root: $script:SdkRoot   (Android API $script:ApiLevel)" -ForegroundColor Cyan

    Write-Host ''
    Write-Host "[Step 1/4] Java SDK: Eclipse Temurin JDK $script:JdkMinMajor" -ForegroundColor Cyan
    # Automatically install Temurin JDK 17 when no JDK inside the supported range is present.
    Ensure-Jdk -AutoInstall

    Write-Host ''
    Write-Host '[Step 2/4] Android command-line tools (latest Google release)' -ForegroundColor Cyan
    $tools = Get-LatestCmdlineToolsInfo
    $toolsRoot = Join-Path $script:SdkRoot 'cmdline-tools'
    $latest = Join-Path $toolsRoot 'latest'
    $work = ''
    $backup = ''
    $toolsSkipped = $false
    try {
        $installedBuild = Get-InstalledCmdlineToolsBuild $script:SdkRoot
        if ($installedBuild -and ($installedBuild -eq $tools.Build) -and (Test-CmdlineToolsDirectory $latest)) {
            # Nothing about the previous run needs repeating: same build, usable tools folder.
            $toolsSkipped = $true
            Write-Host "[+] Command-line tools build $installedBuild is already installed; the download, staging, and backup are skipped." -ForegroundColor Green
        } else {
            $work = Join-Path $env:TEMP ('AndroidSdkInstaller-' + [guid]::NewGuid().ToString('N'))
            $zip = Join-Path $work 'commandlinetools.zip'
            $extract = Join-Path $work 'extract'
            $stage = Join-Path $work 'latest-staged'
            New-Item -ItemType Directory -Path $work -Force | Out-Null
            Assert-DiskSpace -Path $env:TEMP -RequiredBytes 1GB -Label 'the command-line tools download and extraction'
            Assert-DiskSpace -Path $script:SdkRoot -RequiredBytes 500MB -Label 'the command-line tools installation'
            if ((Split-Path -Qualifier $env:TEMP) -ine (Split-Path -Qualifier $script:SdkRoot)) {
                Write-Host "[!] TEMP is on $(Split-Path -Qualifier $env:TEMP) and the SDK on $(Split-Path -Qualifier $script:SdkRoot): the download needs room on both." -ForegroundColor Yellow
            }
            Write-Host '[*] Downloading Android command-line tools...' -ForegroundColor Yellow
            Download-File $tools.Url $zip 'Android command-line tools'
            if ((Get-Item -LiteralPath $zip).Length -lt 1048576) { throw 'The command-line tools download is too small to be a valid archive.' }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Write-Host '[*] Extracting Android command-line tools...' -ForegroundColor Yellow
            Expand-ArchiveWithProgress -LiteralPath $zip -DestinationPath $extract -Label 'Android command-line tools'
            $toolsSource = Find-ExtractedAndroidTools $extract
            if (-not $toolsSource) { throw 'The downloaded ZIP does not contain a cmdline-tools folder with sdkmanager.bat or android.exe.' }

            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Write-Host '[*] Staging the extracted command-line tools...' -ForegroundColor Yellow
            Copy-TreeWithProgress -Source $toolsSource -Destination $stage -Label 'Android command-line tools'
            if (-not (Test-CmdlineToolsDirectory $stage)) { throw 'The downloaded folder does not contain usable Android command-line tools.' }

            New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
            $null = Move-LegacyCmdlineToolsBackups $toolsRoot
            if (Test-Path -LiteralPath $latest -PathType Container) {
                # Backups belong outside the SDK root, or the package managers keep scanning them.
                $backup = Join-Path (Get-BackupRoot) ('cmdline-tools-latest.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
                Write-Host "[*] Preserving old command-line tools at $backup" -ForegroundColor Yellow
                Move-Item -LiteralPath $latest -Destination $backup
            }
            try { Move-Item -LiteralPath $stage -Destination $latest }
            catch {
                if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $latest)) { Move-Item -LiteralPath $backup -Destination $latest -ErrorAction SilentlyContinue }
                throw
            }
            Set-InstalledCmdlineToolsBuild -SdkRoot $script:SdkRoot -Build $tools.Build
            Remove-OldBackups -Prefix 'cmdline-tools-latest' -Keep 3
        }

        New-Item -ItemType Directory -Path $script:SdkRoot -Force | Out-Null
        Grant-OriginalUserModifyAccess $script:SdkRoot
        Set-AndroidEnvironment

        Write-Host ''
        Write-Host '[Step 3/4] Android SDK packages' -ForegroundColor Cyan
        $alreadyThere = @(Get-InstalledSdkPackagesOnDisk $script:SdkRoot)
        if ($alreadyThere.Count -gt 0) {
            Write-Host "    Recorded in this SDK already: $($alreadyThere -join ', ')" -ForegroundColor DarkGray
        }
        $bin = Join-Path $latest 'bin'
        $sdkManager = Join-Path $bin 'sdkmanager.bat'
        $androidCli = Join-Path $bin 'android.exe'
        if (-not (Test-Path -LiteralPath $sdkManager -PathType Leaf)) { $sdkManager = '' }
        if (-not (Test-Path -LiteralPath $androidCli -PathType Leaf)) { $androidCli = '' }
        if (-not $sdkManager -and -not $androidCli) { throw 'No usable SDK package manager was found after extraction.' }
        $licenseHint = Get-SdkPackageManagerHint -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot -Arguments '--licenses'
        $installHint = Get-SdkPackageManagerHint -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot

        Write-Host ''
        Write-Host '[*] Android SDK packages can only be downloaded after their licenses are accepted.' -ForegroundColor Yellow
        $licenseChoice = ''
        if (Test-InteractiveConsoleHost) {
            $licenseChoice = Read-InstallerInput -Prompt 'Accept every Android SDK license now? (Y = accept all, N = answer each prompt yourself)' -Default 'Y' -Choices 'Y|N'
        } elseif ($env:ANDROID_SDK_INSTALLER_ACCEPT_LICENSES -imatch '^(y|yes|true|1)$') {
            $licenseChoice = 'Y'
            Write-Host '[*] ANDROID_SDK_INSTALLER_ACCEPT_LICENSES is set, so every license prompt is answered Y for this unattended run.' -ForegroundColor Yellow
        } else {
            throw 'No console is attached, so the license prompts cannot be answered. Start the installer from Run.bat, or set ANDROID_SDK_INSTALLER_ACCEPT_LICENSES=Y for an unattended run.'
        }
        $licenseMode = 'Auto'
        if ($licenseChoice -imatch '^N') { $licenseMode = 'Review' }
        # Installs may only auto-answer a late prompt when the user already agreed to accept all.
        $script:AcceptAllLicensesGranted = ($licenseMode -eq 'Auto')
        $licensesAccepted = Accept-SdkLicenses -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot -Mode $licenseMode
        if (-not $licensesAccepted) {
            throw "The Android SDK licenses were not accepted, so no package can be installed. Run $licenseHint, enter Y at each prompt, then choose option 1 again."
        }

        $available = @(Get-AvailableSdkPackages -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot)
        $buildTools = Get-LatestSdkPackage $available 'build-tools' "$script:ApiLevel"
        if (-not $buildTools) { $buildTools = Get-LatestSdkPackage $available 'build-tools' }
        # A guessed version must never sink an otherwise good install: when it is the only reason the
        # core install failed, the core packages are retried without it and the file check reports it.
        $buildToolsGuessed = $false
        $buildToolsFromGuess = $false
        if (-not $buildTools) {
            $buildTools = "build-tools;$script:ApiLevel.0.0"
            $buildToolsGuessed = $true
            $buildToolsFromGuess = $true
            Write-Host "[!] The package catalog was not readable, so $buildTools is tried directly." -ForegroundColor Yellow
        }
        $corePackages = @('platform-tools', "platforms;android-$script:ApiLevel", $buildTools)
        $coreCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $corePackages -SkipInstalled
        if (($coreCode -ne 0) -and $sdkManager -and -not (Test-SdkLicensesAccepted -SdkManager $sdkManager -SdkRoot $script:SdkRoot)) {
            # A declined license surfaces as a failed install, so offer the prompts once more.
            Write-Host '[!] Some licenses are still unaccepted. Enter Y at each prompt, then the install runs again.' -ForegroundColor Yellow
            if (Accept-SdkLicenses -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot -Mode 'Review') {
                $coreCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $corePackages -SkipInstalled
            }
        }
        if (($coreCode -ne 0) -and $buildToolsGuessed) {
            Write-Host "[!] $buildTools could not be resolved from the catalog, so the core packages are installed without it." -ForegroundColor Yellow
            $corePackages = @('platform-tools', "platforms;android-$script:ApiLevel")
            $coreCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $corePackages -SkipInstalled
            $buildToolsGuessed = $false
        }
        if ($coreCode -ne 0) { throw "Core SDK installation failed (exit code $coreCode). Check network access and the license prompts: $licenseHint" }
        # platform-tools did not exist during the Step 2 call above, so its PATH entry was skipped.
        # Persist PATH now that the core packages are installed, so a later verification failure
        # cannot leave platform-tools (adb) missing from Machine PATH. Step 4 repeats this (idempotent).
        Set-AndroidEnvironment
        # The catalog was read before these packages landed, so drop the cache and let the optional
        # packages be resolved against the repository state that now includes them.
        Clear-SdkCatalogCache $script:SdkRoot

        $native = @()
        # CMake 4 removed the pre-3.5 compatibility mode that most Android NDK projects still declare,
        # so the AGP-era 3.x release is preferred even when a newer one is in the catalog.
        $cmake = Get-LatestSdkPackage $available 'cmake' "$script:CMakePreferredMajor"
        if (-not $cmake) { $cmake = Get-LatestSdkPackage $available 'cmake' }
        if ($cmake) { $native += $cmake }
        $ndk = Get-LatestSdkPackage $available 'ndk'
        if ($ndk) { $native += $ndk }
        $nativeWanted = @($native)
        $nativeCode = 0
        if ($native.Count -gt 0) {
            Assert-DiskSpace -Path $script:SdkRoot -RequiredBytes 4GB -Label 'the NDK and CMake installation'
            $nativeCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $native -SkipInstalled
        } else {
            Write-Host '[!] The package catalog offered no NDK/CMake versions; projects with native code may need them later.' -ForegroundColor Yellow
        }

        Write-Host ''
        Write-Host '[Step 4/4] Setting environment variables and PATH entries' -ForegroundColor Cyan
        Set-AndroidEnvironment
        Broadcast-EnvironmentChange

        # Every claim below is checked on disk: reporting success for files that were never written is
        # the failure mode that left this installer saying "VERIFIED" after a failed NDK download.
        $coreWanted = @('platform-tools', "platforms;android-$script:ApiLevel", $buildTools)
        $coreMissing = @($coreWanted | Where-Object { -not (Test-SdkPackagePresent -SdkRoot $script:SdkRoot -Package $_) })
        if ($buildToolsFromGuess) {
            # A Build Tools version guessed without a readable catalog must not sink an otherwise good
            # install, so it is reported with the optional packages instead of failing the whole run.
            $guessedMissing = @($coreMissing | Where-Object { $_ -ieq $buildTools })
            if ($guessedMissing.Count -gt 0) {
                $coreMissing = @($coreMissing | Where-Object { $_ -ine $buildTools })
                $nativeWanted = @($nativeWanted) + $guessedMissing
                Write-Host "[!] $buildTools is not available either, so Build Tools were left for you to pick." -ForegroundColor Yellow
            }
        }
        if ($coreMissing.Count -gt 0) {
            $quoted = '"' + ($coreMissing -join '" "') + '"'
            throw "SDK verification failed. Missing or incomplete: $($coreMissing -join ', '). Repair with: $installHint install $quoted"
        }
        $nativeOk = @($nativeWanted | Where-Object { Test-SdkPackagePresent -SdkRoot $script:SdkRoot -Package $_ })
        $nativeMissing = @($nativeWanted | Where-Object { -not (Test-SdkPackagePresent -SdkRoot $script:SdkRoot -Package $_) })
        $partialFolders = @(Get-PartialSdkPackageFolders -SdkRoot $script:SdkRoot)

        Write-Host ''
        Write-Host '=========================================================' -ForegroundColor Cyan
        if ($nativeMissing.Count -eq 0) {
            Write-Host 'JAVA + ANDROID SDK INSTALLATION VERIFIED' -ForegroundColor Green
        } else {
            Write-Host 'ANDROID SDK INSTALLATION PARTIAL - CORE OK, NATIVE PACKAGES MISSING' -ForegroundColor Yellow
        }
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host "JAVA_HOME: $([Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'))"
        Write-Host "SDK root: $script:SdkRoot"
        Write-Host "Command-line tools build: $($tools.Build)$(if ($toolsSkipped) { ' (reused, not re-downloaded)' })"
        if ($buildToolsFromGuess) {
            Write-Host "Verified: Temurin JDK $script:JdkMinMajor, platform-tools, and Android API $script:ApiLevel (Build Tools were not resolved from the catalog)."
        } else {
            Write-Host "Verified: Temurin JDK $script:JdkMinMajor, platform-tools, Android API $script:ApiLevel, and $buildTools."
        }
        if ($nativeOk.Count -gt 0) { Write-Host "Verified NDK/CMake: $($nativeOk -join ', ')" -ForegroundColor Green }
        if ($nativeMissing.Count -gt 0) {
            $quoted = '"' + ($nativeMissing -join '" "') + '"'
            Write-Host "Not installed (exit code $nativeCode): $($nativeMissing -join ', ')" -ForegroundColor Yellow
            Write-Host "    Retry with: $installHint install $quoted" -ForegroundColor Yellow
            Write-Host '    A project without native code builds fine without these two packages.' -ForegroundColor Gray
        }
        if ($nativeWanted.Count -eq 0) { Write-Host 'NDK/CMake: not offered by the package catalog, so nothing was attempted.' -ForegroundColor Gray }
        if ($partialFolders.Count -gt 0) {
            Write-Host "Incomplete package folders were ignored, not advertised: $($partialFolders -join ', ')" -ForegroundColor Yellow
            Write-Host '    Delete those folders before a retry, or the package manager may call them installed.' -ForegroundColor Gray
        }
        if ($backup) { Write-Host "Previous command-line tools backup: $backup" -ForegroundColor Gray }
        Write-Host 'JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, and Machine PATH have been configured.' -ForegroundColor Green
        Write-Host 'Open a new terminal before building.' -ForegroundColor Yellow
    } finally {
        if ($work -and (Test-Path -LiteralPath $work -PathType Container)) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Flutter {
    Write-Host ''
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '            Flutter Installation (C:\flutter)            ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Ensure-Jdk
    $git = Ensure-GitForWindows
    $source = Read-FlutterSource
    if ($null -eq $source) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }

    $work = Join-Path $env:TEMP ('FlutterInstaller-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $work 'flutter.zip'
    $extract = Join-Path $work 'extract'
    $stage = Join-Path $work 'flutter-staged'
    $backup = ''
    Assert-DiskSpace -Path $script:FlutterRoot -RequiredBytes 3GB -Label 'the Flutter SDK installation'
    if ($source.Kind -ne 'Folder') { Assert-DiskSpace -Path $env:TEMP -RequiredBytes 2GB -Label 'the Flutter download and extraction' }
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        if ($source.Kind -eq 'Url') {
            Write-Host '[*] Downloading Flutter to a temporary folder...' -ForegroundColor Yellow
            Download-File $source.Path $zip 'Flutter SDK'
        } elseif ($source.Kind -eq 'Zip') {
            Write-Host '[*] Copying the ZIP to a temporary folder. The source file will not be deleted.' -ForegroundColor Yellow
            Copy-FileWithProgress -Source $source.Path -Destination $zip -Label $source.Name
        } else { $flutterSource = $source.Path }

        if ($source.Kind -ne 'Folder') {
            if ((Get-Item -LiteralPath $zip).Length -lt 1048576) { throw 'The selected file is too small to be a Flutter SDK ZIP.' }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Write-Host '[*] Extracting Flutter. The progress bar shows the size, speed, and time left...' -ForegroundColor Yellow
            Expand-ArchiveWithProgress -LiteralPath $zip -DestinationPath $extract -Label 'Flutter SDK'
            $folders = @(Get-FlutterFolders $extract)
            if ($folders.Count -eq 0) { throw 'The ZIP does not contain a Flutter SDK with bin\flutter.bat.' }
            $flutterSource = $folders[0]
        }
        if (-not (Test-Path -LiteralPath (Join-Path $flutterSource 'bin\flutter.bat') -PathType Leaf)) { throw 'The selected folder does not contain bin\flutter.bat.' }

        if ($source.Kind -eq 'Folder') {
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Write-Host '[*] Staging the selected Flutter folder...' -ForegroundColor Yellow
            Copy-TreeWithProgress -Source $flutterSource -Destination $stage -Label 'Flutter SDK'
        } else { Move-Item -LiteralPath $flutterSource -Destination $stage }
        if (-not (Test-Path -LiteralPath (Join-Path $stage 'bin\flutter.bat') -PathType Leaf)) { throw 'Flutter staging verification failed.' }

        if (Test-Path -LiteralPath $script:FlutterRoot -PathType Container) {
            $backup = "$($script:FlutterRoot).backup-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')"
            Write-Host "[*] Preserving the previous Flutter SDK at $backup" -ForegroundColor Yellow
            Move-Item -LiteralPath $script:FlutterRoot -Destination $backup
        }
        try { Move-Item -LiteralPath $stage -Destination $script:FlutterRoot }
        catch {
            if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $script:FlutterRoot)) { Move-Item -LiteralPath $backup -Destination $script:FlutterRoot -ErrorAction SilentlyContinue }
            throw
        }

        Grant-OriginalUserModifyAccess $script:FlutterRoot
        Add-GitSafeDirectory $git $script:FlutterRoot
        [Environment]::SetEnvironmentVariable('FLUTTER_ROOT', $script:FlutterRoot, 'Machine')
        $env:FLUTTER_ROOT = $script:FlutterRoot
        $flutterBin = Join-Path $script:FlutterRoot 'bin'
        Add-PathEntry $flutterBin 'Machine'
        $flutterBat = Join-Path $flutterBin 'flutter.bat'
        $null = Resolve-AndroidSdkRoot -Quiet
        $sdkPlatform = Join-Path $script:SdkRoot "platforms\android-$script:ApiLevel\android.jar"

        if (Test-Path -LiteralPath $sdkPlatform -PathType Leaf) {
            Set-AndroidEnvironment
            Write-Host '[*] Connecting Flutter to C:\Android...' -ForegroundColor Yellow
            $configCode = Invoke-ExternalInteractive -Path $flutterBat -ArgumentList @('config', '--android-sdk', $script:SdkRoot)
            if ($configCode -ne 0) { Write-Warning "Flutter could not save the SDK path (exit code $configCode); ANDROID_HOME is still set." }
            # Flutter re-asks "Accept? (y/N)" for every license. Answering on the user's behalf is only
            # allowed when the licenses are already recorded (option 1 asked first) or the unattended
            # opt-in is set - otherwise the prompts are shown, or the step is skipped with a warning.
            $licensesRecorded = Test-Path -LiteralPath (Join-Path $script:SdkRoot 'licenses\android-sdk-license') -PathType Leaf
            $acceptForUser = ($env:ANDROID_SDK_INSTALLER_ACCEPT_LICENSES -imatch '^(y|yes|true|1)$')
            $flutterAnswers = @()
            if ($licensesRecorded -or $acceptForUser) { $flutterAnswers = @(Get-SdkLicenseAnswers 'y') }
            if ((-not $licensesRecorded) -and (-not $acceptForUser) -and (-not (Test-InteractiveConsoleHost))) {
                Write-Warning "Android SDK licenses are not recorded under $script:SdkRoot and no console is attached, so Flutter was not asked to accept them. Run option 1 first, or set ANDROID_SDK_INSTALLER_ACCEPT_LICENSES=Y."
            } else {
                Write-Host '[*] Confirming the Android SDK licenses through Flutter...' -ForegroundColor Yellow
                $licenseCode = Invoke-ExternalInteractive -Path $flutterBat -ArgumentList @('doctor', '--android-licenses') -Answers $flutterAnswers
                if ($licenseCode -ne 0) { Write-Warning "Flutter's license check returned $licenseCode. Review its output and the SDK license files." }
            }
        } else {
            Write-Warning "Android Platform $script:ApiLevel was not found in $script:SdkRoot. Run Android SDK Installation first to build Android apps with Flutter."
        }

        Add-PathEntry $flutterBin 'Machine'
        Broadcast-EnvironmentChange
        Write-Host '[*] Verifying Flutter installation...' -ForegroundColor Yellow
        $versionCode = Invoke-ExternalInteractive -Path $flutterBat -ArgumentList @('--version')
        if ($versionCode -ne 0) { throw "flutter --version failed (exit code $versionCode). Files remain in C:\flutter for troubleshooting." }
        if (Test-Path -LiteralPath $sdkPlatform -PathType Leaf) {
            Write-Host '[*] Running flutter doctor -v...' -ForegroundColor Yellow
            $doctorCode = Invoke-ExternalInteractive -Path $flutterBat -ArgumentList @('doctor', '-v')
            if ($doctorCode -ne 0) { Write-Warning "flutter doctor reported unresolved checks (exit code $doctorCode); Flutter itself passed the version check." }
        }
        Write-Host ''
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host 'FLUTTER INSTALLATION VERIFIED' -ForegroundColor Green
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host "Flutter root: $script:FlutterRoot"
        Write-Host 'FLUTTER_ROOT and Machine PATH have been configured.' -ForegroundColor Green
        if ($backup) { Write-Host "Previous Flutter backup: $backup" -ForegroundColor Gray }
        Write-Host 'Open a new terminal before using Flutter.' -ForegroundColor Yellow
    } finally {
        if (Test-Path -LiteralPath $work -PathType Container) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-CheckEnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [pscustomobject]@{
        Process = [Environment]::GetEnvironmentVariable($Name, 'Process')
        Machine = [Environment]::GetEnvironmentVariable($Name, 'Machine')
        User = [Environment]::GetEnvironmentVariable($Name, 'User')
    }
}

function Write-EnvironmentCheckResult {
    param([ValidateSet('OK', 'WARN', 'MISSING')][string]$Status, [string]$Message)
    $color = if ($Status -eq 'OK') { 'Green' } elseif ($Status -eq 'WARN') { 'Yellow' } else { 'Red' }
    Write-Host "[$Status] $Message" -ForegroundColor $color
}

function Get-PathEntryScopes {
    param([string]$Entry)
    if ([string]::IsNullOrWhiteSpace($Entry)) { return @() }
    $expected = Normalize-PathEntry ([Environment]::ExpandEnvironmentVariables($Entry.Trim().Trim([char]'"')))
    $foundScopes = @()
    foreach ($scope in @('Machine', 'User', 'Process')) {
        $pathValue = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
        foreach ($rawEntry in ($pathValue -split ';')) {
            if ([string]::IsNullOrWhiteSpace($rawEntry)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($rawEntry.Trim().Trim([char]'"'))
            if ((Normalize-PathEntry $expanded) -ieq $expected) {
                $foundScopes += $scope
                break
            }
        }
    }
    return @($foundScopes)
}

function Write-EnvironmentPathEntryCheck {
    param([string]$Entry, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Entry)) {
        Write-EnvironmentCheckResult 'MISSING' "$Label cannot be checked because its directory is unknown."
        return
    }
    $scopes = @(Get-PathEntryScopes $Entry)
    if ($scopes -contains 'Machine' -or $scopes -contains 'User') {
        Write-EnvironmentCheckResult 'OK' "$Label is present in $($scopes -join ', ') PATH."
    } elseif ($scopes -contains 'Process') {
        Write-EnvironmentCheckResult 'WARN' "$Label is present only in this process PATH; it may not persist in a new terminal."
    } else {
        Write-EnvironmentCheckResult 'MISSING' "$Label is not present in Machine, User, or Process PATH: $Entry"
    }
}

function Find-EnvironmentPathExecutable {
    param([string[]]$Names)
    foreach ($scope in @('Process', 'Machine', 'User')) {
        $pathValue = [Environment]::GetEnvironmentVariable('Path', $scope)
        if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
        foreach ($rawEntry in ($pathValue -split ';')) {
            if ([string]::IsNullOrWhiteSpace($rawEntry)) { continue }
            $directory = [Environment]::ExpandEnvironmentVariables($rawEntry.Trim().Trim([char]'"'))
            if ($directory -match '(?i)\\WindowsApps(?:\\|$)' -or -not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
            foreach ($name in $Names) {
                $candidate = Join-Path $directory $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $pathScopes = @(Get-PathEntryScopes $directory)
                    $scopeText = $pathScopes -join ', '
                    if ([string]::IsNullOrWhiteSpace($scopeText)) { $scopeText = $scope }
                    return [pscustomobject]@{ Path = $candidate; Scope = $scopeText; Directory = $directory; Name = $name }
                }
            }
        }
    }
    return $null
}

function Get-EffectiveCheckValue {
    param([Parameter(Mandatory = $true)]$Values)
    if (-not [string]::IsNullOrWhiteSpace($Values.Process)) { return $Values.Process }
    if (-not [string]::IsNullOrWhiteSpace($Values.Machine)) { return $Values.Machine }
    if (-not [string]::IsNullOrWhiteSpace($Values.User)) { return $Values.User }
    return ''
}

function Write-EnvironmentVariableCheck {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Values)
    if (-not [string]::IsNullOrWhiteSpace($Values.Machine)) {
        Write-EnvironmentCheckResult 'OK' "$Name is set at Machine scope: $($Values.Machine)"
    } elseif (-not [string]::IsNullOrWhiteSpace($Values.User)) {
        Write-EnvironmentCheckResult 'WARN' "$Name is set at User scope only: $($Values.User)"
    } elseif (-not [string]::IsNullOrWhiteSpace($Values.Process)) {
        Write-EnvironmentCheckResult 'WARN' "$Name is set in the current process only: $($Values.Process)"
    } else {
        Write-EnvironmentCheckResult 'MISSING' "$Name is not set."
    }
}

function Show-EnvironmentPathStatus {
    Write-Host ''
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '         Environment Variables and PATH Check            ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host 'This check is read-only; it does not install or change anything.' -ForegroundColor Gray

    Write-Host ''
    Write-Host '--- Java / JDK ---' -ForegroundColor Yellow
    $javaHomeValues = Get-CheckEnvironmentVariable 'JAVA_HOME'
    Write-EnvironmentVariableCheck 'JAVA_HOME' $javaHomeValues
    $javaHome = Get-EffectiveCheckValue $javaHomeValues
    $javaCommand = Find-EnvironmentPathExecutable @('java.exe')
    $javacCommand = Find-EnvironmentPathExecutable @('javac.exe')
    if ($javaHome) {
        $javaBin = Join-Path $javaHome 'bin'
        $javaFile = Join-Path $javaBin 'java.exe'
        $javacFile = Join-Path $javaBin 'javac.exe'
        if ((Test-Path -LiteralPath $javaFile -PathType Leaf) -and (Test-Path -LiteralPath $javacFile -PathType Leaf)) {
            Write-EnvironmentCheckResult 'OK' 'JAVA_HOME points to a JDK containing java.exe and javac.exe.'
        } else {
            Write-EnvironmentCheckResult 'MISSING' "JAVA_HOME does not contain both bin\java.exe and bin\javac.exe: $javaHome"
        }
        Write-EnvironmentPathEntryCheck $javaBin 'JAVA_HOME\bin'
    } elseif ($javaCommand) {
        Write-EnvironmentCheckResult 'WARN' "java.exe is on $($javaCommand.Scope) PATH, but JAVA_HOME is not set."
    }
    if ($javaCommand) { Write-EnvironmentCheckResult 'OK' "java.exe is available from PATH: $($javaCommand.Path)" }
    else { Write-EnvironmentCheckResult 'MISSING' 'java.exe was not found in Machine, User, or Process PATH.' }
    if ($javacCommand) { Write-EnvironmentCheckResult 'OK' "javac.exe is available from PATH: $($javacCommand.Path)" }
    else { Write-EnvironmentCheckResult 'MISSING' 'javac.exe was not found in Machine, User, or Process PATH.' }

    Write-Host ''
    Write-Host '--- Python ---' -ForegroundColor Yellow
    $pythonCommand = Find-EnvironmentPathExecutable @('python.exe', 'python3.exe')
    if ($pythonCommand) {
        Write-EnvironmentCheckResult 'OK' "Python is available from $($pythonCommand.Scope) PATH: $($pythonCommand.Path)"
    } else {
        $pythonLauncher = Find-EnvironmentPathExecutable @('py.exe')
        if ($pythonLauncher) {
            Write-EnvironmentCheckResult 'WARN' "The Python launcher is on PATH ($($pythonLauncher.Path)), but python.exe/python3.exe is not."
        } else {
            Write-EnvironmentCheckResult 'MISSING' 'python.exe/python3.exe was not found in Machine, User, or Process PATH. Python is not installed by this installer.'
        }
    }

    Write-Host ''
    Write-Host '--- Android SDK ---' -ForegroundColor Yellow
    $androidHomeValues = Get-CheckEnvironmentVariable 'ANDROID_HOME'
    $androidSdkRootValues = Get-CheckEnvironmentVariable 'ANDROID_SDK_ROOT'
    Write-EnvironmentVariableCheck 'ANDROID_HOME' $androidHomeValues
    Write-EnvironmentVariableCheck 'ANDROID_SDK_ROOT' $androidSdkRootValues
    $androidRoot = Get-EffectiveCheckValue $androidHomeValues
    if ([string]::IsNullOrWhiteSpace($androidRoot)) { $androidRoot = Get-EffectiveCheckValue $androidSdkRootValues }
    if ([string]::IsNullOrWhiteSpace($androidRoot)) { $androidRoot = $script:SdkRoot }
    if (Test-Path -LiteralPath $androidRoot -PathType Container) {
        Write-EnvironmentCheckResult 'OK' "Android SDK directory exists: $androidRoot"
    } else {
        Write-EnvironmentCheckResult 'MISSING' "Android SDK directory does not exist: $androidRoot"
    }
    $platformTools = Join-Path $androidRoot 'platform-tools'
    $adb = Join-Path $platformTools 'adb.exe'
    if (Test-Path -LiteralPath $adb -PathType Leaf) { Write-EnvironmentCheckResult 'OK' "Android platform-tools found: $adb" }
    else { Write-EnvironmentCheckResult 'MISSING' "adb.exe was not found: $adb" }
    Write-EnvironmentPathEntryCheck $platformTools 'Android platform-tools'
    $cmdlineBin = Join-Path $androidRoot 'cmdline-tools\latest\bin'
    $sdkManager = Join-Path $cmdlineBin 'sdkmanager.bat'
    $androidCli = Join-Path $cmdlineBin 'android.exe'
    if ((Test-Path -LiteralPath $sdkManager -PathType Leaf) -or (Test-Path -LiteralPath $androidCli -PathType Leaf)) {
        Write-EnvironmentCheckResult 'OK' 'Android command-line package manager is installed.'
    } else {
        Write-EnvironmentCheckResult 'MISSING' "sdkmanager.bat or android.exe was not found under $cmdlineBin"
    }
    Write-EnvironmentPathEntryCheck $cmdlineBin 'Android command-line tools'
    $managerHint = Get-SdkPackageManagerHint -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $androidRoot
    $sdkLicenses = Join-Path $androidRoot 'licenses'
    if (Test-Path -LiteralPath (Join-Path $sdkLicenses 'android-sdk-license') -PathType Leaf) {
        $licenseCount = @(Get-ChildItem -LiteralPath $sdkLicenses -File -ErrorAction SilentlyContinue).Count
        Write-EnvironmentCheckResult 'OK' "Accepted SDK licenses are recorded under $sdkLicenses ($licenseCount file(s))"
    } else {
        Write-EnvironmentCheckResult 'MISSING' "No accepted SDK licenses were found under $sdkLicenses. Run: $managerHint --licenses"
    }

    # The packages themselves, because an environment that looks configured can still be missing the
    # Build Tools or a half-extracted NDK that Gradle will refuse to use.
    $buildToolsFolder = Get-LatestVersionFolder (Join-Path $androidRoot 'build-tools') 'aapt2.exe'
    $ndkFolder = Get-LatestVersionFolder (Join-Path $androidRoot 'ndk') 'source.properties'
    $cmakeFolder = Get-LatestVersionFolder (Join-Path $androidRoot 'cmake') 'bin\cmake.exe'
    $buildToolsPackage = ''
    if ($buildToolsFolder) { $buildToolsPackage = 'build-tools;' + (Split-Path -Leaf $buildToolsFolder) }
    $ndkPackage = ''
    if ($ndkFolder) { $ndkPackage = 'ndk;' + (Split-Path -Leaf $ndkFolder) }
    $cmakePackage = ''
    if ($cmakeFolder) { $cmakePackage = 'cmake;' + (Split-Path -Leaf $cmakeFolder) }
    $components = @(
        [pscustomobject]@{ Package = 'platform-tools'; Label = 'Android platform-tools (adb)'; Required = $true },
        [pscustomobject]@{ Package = "platforms;android-$script:ApiLevel"; Label = "Android Platform $script:ApiLevel"; Required = $true },
        [pscustomobject]@{ Package = $buildToolsPackage; Label = 'Android Build Tools'; Required = $true },
        [pscustomobject]@{ Package = $ndkPackage; Label = 'NDK (only needed for C/C++ code)'; Required = $false },
        [pscustomobject]@{ Package = $cmakePackage; Label = 'CMake (only needed for C/C++ code)'; Required = $false }
    )
    foreach ($component in $components) {
        $label = $component.Label
        if ([string]::IsNullOrWhiteSpace($component.Package)) {
            $suffix = ''
            if (-not $component.Required) { $suffix = ' is not installed, which is fine for projects without native code.' }
            else { $suffix = " is not installed. Repair with: $managerHint install" }
            Write-EnvironmentCheckResult $(if ($component.Required) { 'MISSING' } else { 'WARN' }) "$label$suffix"
            continue
        }
        if (Test-SdkPackagePresent -SdkRoot $androidRoot -Package $component.Package) {
            Write-EnvironmentCheckResult 'OK' "$label is installed: $($component.Package)"
        } else {
            Write-EnvironmentCheckResult 'MISSING' "$label is incomplete: $($component.Package) has no usable files on disk. Reinstall it with: $managerHint install `"$($component.Package)`""
        }
    }
    $partialFolders = @(Get-PartialSdkPackageFolders -SdkRoot $androidRoot)
    if ($partialFolders.Count -gt 0) {
        Write-EnvironmentCheckResult 'MISSING' "Incomplete package folder(s) are present: $($partialFolders -join ', '). Delete them before reinstalling those packages, or they may be treated as installed."
    }
    $ndkHomeValue = Get-EffectiveCheckValue (Get-CheckEnvironmentVariable 'ANDROID_NDK_HOME')
    if ($ndkHomeValue -and -not $ndkFolder) {
        Write-EnvironmentCheckResult 'WARN' "ANDROID_NDK_HOME points at $ndkHomeValue, but no complete NDK is installed there. Run option 1 to refresh the environment."
    } elseif ($ndkFolder -and [string]::IsNullOrWhiteSpace($ndkHomeValue)) {
        Write-EnvironmentCheckResult 'WARN' "An NDK is installed at $ndkFolder, but ANDROID_NDK_HOME is not set. Run option 1 to refresh the environment."
    }

    # The Emulator folder is no longer added to PATH automatically, so report its real state instead
    # of leaving a missing PATH entry to look like an installation failure.
    $emulatorRoot = Join-Path $androidRoot 'emulator'
    $emulatorExe = Join-Path $emulatorRoot 'emulator.exe'
    if (Test-Path -LiteralPath $emulatorExe -PathType Leaf) {
        $emulatorScopes = @(Get-PathEntryScopes $emulatorRoot)
        if ($emulatorScopes.Count -gt 0) {
            Write-Host "[INFO] The Android Emulator is installed and appears in $($emulatorScopes -join ', ') PATH. This installer no longer adds it; remove that entry by hand if you do not want it." -ForegroundColor Gray
        } else {
            Write-Host "[INFO] The Android Emulator is installed at $emulatorRoot but is not on PATH. That is the intended default: Android Studio and Flutter use it through ANDROID_HOME, and only the 'emulator' command line needs the extra PATH entry." -ForegroundColor Gray
        }
    } else {
        $emulatorInstall = "$managerHint install `"emulator`" `"system-images;android-$script:ApiLevel;google_apis;x86_64`""
        Write-Host "[INFO] The Android Emulator is not installed under $androidRoot. This installer never downloads it; to add a virtual device run: $emulatorInstall and then create the device with avdmanager or AVD Manager." -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '--- Flutter ---' -ForegroundColor Yellow
    $flutterRootValues = Get-CheckEnvironmentVariable 'FLUTTER_ROOT'
    Write-EnvironmentVariableCheck 'FLUTTER_ROOT' $flutterRootValues
    $flutterRoot = Get-EffectiveCheckValue $flutterRootValues
    if ([string]::IsNullOrWhiteSpace($flutterRoot)) { $flutterRoot = $script:FlutterRoot }
    $flutterBin = Join-Path $flutterRoot 'bin'
    $flutterBat = Join-Path $flutterBin 'flutter.bat'
    if (Test-Path -LiteralPath $flutterBat -PathType Leaf) {
        Write-EnvironmentCheckResult 'OK' "Flutter SDK found: $flutterBat"
    } else {
        Write-EnvironmentCheckResult 'MISSING' "flutter.bat was not found: $flutterBat"
    }
    Write-EnvironmentPathEntryCheck $flutterBin 'Flutter bin'
    $flutterCommand = Find-EnvironmentPathExecutable @('flutter.bat', 'flutter.exe')
    if ($flutterCommand) { Write-EnvironmentCheckResult 'OK' "Flutter command is available from PATH: $($flutterCommand.Path)" }
    else { Write-EnvironmentCheckResult 'MISSING' 'Flutter command was not found in Machine, User, or Process PATH.' }

    Write-Host ''
    Write-Host 'Machine and User PATH changes may require a newly opened terminal.' -ForegroundColor Gray
}

Clear-StaleInstallerWorkDirs
# An unattended run selects its step through the environment and then leaves the menu on its own.
$pendingChoice = [string]$env:ANDROID_SDK_INSTALLER_CHOICE
while ($true) {
    Clear-Host
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '       Android SDK & Flutter Installer for Windows       ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  1. Java SDK + Android SDK Installation (JDK $script:JdkMinMajor & $script:SdkRoot)" -ForegroundColor Yellow
    Write-Host "  2. Flutter Installation ($script:FlutterRoot)" -ForegroundColor Yellow
    Write-Host '  3. Check Environment Paths' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  0. Exit' -ForegroundColor Gray
    if ($script:FailureCount -gt 0) {
        Write-Host ''
        Write-Host "  $script:FailureCount step(s) failed in this session. Option 3 lists what is still missing." -ForegroundColor Yellow
    }
    Write-Host ''
    $choice = $pendingChoice.Trim()
    $pendingChoice = ''
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = Read-InstallerInput -Prompt 'Enter your choice (1, 2, 3, or 0)' -Default '0' -Choices '1|2|3|0' }
    switch ($choice) {
        '1' { try { Install-AndroidSdk } catch { $script:FailureCount++; Close-InlineProgressLine; Write-Host "`nANDROID SDK INSTALLATION FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '2' { try { Install-Flutter } catch { $script:FailureCount++; Close-InlineProgressLine; Write-Host "`nFLUTTER INSTALLATION FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '3' { try { Show-EnvironmentPathStatus } catch { $script:FailureCount++; Close-InlineProgressLine; Write-Host "`nENVIRONMENT PATH CHECK FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '0' {
            if ($script:FailureCount -gt 0) {
                # Run.bat forwards this code, so a scripted run can tell success from a handled failure.
                Write-Host "Exiting with code 1 ($script:FailureCount failed step(s) in this session)." -ForegroundColor Yellow
                exit 1
            }
            exit 0
        }
        default { Write-Host 'Invalid choice. Enter 1, 2, 3, or 0.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
