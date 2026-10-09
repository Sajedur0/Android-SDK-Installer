#Requires -Version 5.1
[CmdletBinding()]
param([string]$OriginalUserSid)

$ErrorActionPreference = 'Stop'
$script:SdkRoot = 'C:\Android'
$script:FlutterRoot = 'C:\flutter'
$script:OriginalUserSid = $OriginalUserSid
# True while an inline (single-line, redrawn) progress bar owns the current console line.
$script:InlineProgressActive = $false

# Remember the signed-in user's SID before UAC so C:\ installs remain usable by that user.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ([string]::IsNullOrWhiteSpace($script:OriginalUserSid)) { $script:OriginalUserSid = $currentIdentity.User.Value }
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Requesting Administrator privileges...' -ForegroundColor Yellow
    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $elevationArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -OriginalUserSid `"$script:OriginalUserSid`""
    try {
        $elevated = Start-Process -FilePath $powerShellExe -ArgumentList $elevationArgs -Verb RunAs -Wait -PassThru
        exit $elevated.ExitCode
    } catch {
        Write-Host "Administrator elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host 'Press Enter to exit'
        exit 1
    }
}

function Wait-ForEnter {
    param([string]$Message = 'Press Enter to continue...')
    [void](Read-Host $Message)
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

function Add-PathEntry {
    param([Parameter(Mandatory = $true)][string]$Entry, [ValidateSet('User', 'Machine')][string]$Scope = 'Machine')
    $wanted = Normalize-PathEntry $Entry
    if (-not $wanted) { return }
    $current = [Environment]::GetEnvironmentVariable('Path', $Scope)
    $items = @()
    if (-not [string]::IsNullOrWhiteSpace($current)) { $items = @($current -split ';' | Where-Object { $_.Trim() }) }
    $exists = $false
    foreach ($item in $items) { if ((Normalize-PathEntry $item) -ieq $wanted) { $exists = $true; break } }
    if (-not $exists) {
        $items += $Entry
        $newValue = $items -join ';'
        if ($newValue.Length -gt 30000) { throw "The $Scope PATH is too long. Remove obsolete entries and retry." }
        [Environment]::SetEnvironmentVariable('Path', $newValue, $Scope)
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
    [Environment]::SetEnvironmentVariable('ANDROID_HOME', $script:SdkRoot, 'Machine')
    [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $script:SdkRoot, 'Machine')
    $env:ANDROID_HOME = $script:SdkRoot
    $env:ANDROID_SDK_ROOT = $script:SdkRoot

    $ndk = Get-LatestVersionFolder (Join-Path $script:SdkRoot 'ndk')
    if ($ndk) {
        [Environment]::SetEnvironmentVariable('ANDROID_NDK_HOME', $ndk, 'Machine')
        $env:ANDROID_NDK_HOME = $ndk
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
    $buildTools = Get-LatestVersionFolder (Join-Path $script:SdkRoot 'build-tools')
    if ($buildTools) { $entries += $buildTools }
    $cmake = Get-LatestVersionFolder (Join-Path $script:SdkRoot 'cmake')
    if ($cmake) { $entries += (Join-Path $cmake 'bin') }
    foreach ($entry in $entries) {
        if (Test-Path -LiteralPath $entry -PathType Container) { Add-PathEntry $entry 'Machine' }
    }
}

function Grant-OriginalUserModifyAccess {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container) -or -not $script:OriginalUserSid) { return }
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (-not (Test-Path -LiteralPath $icacls)) { Write-Warning "icacls.exe was not found; the signed-in user may not be able to update $Path later."; return }
    $ace = "*$($script:OriginalUserSid):(OI)(CI)M"
    $code = Invoke-ExternalToHost -Path $icacls -ArgumentList @($Path, '/grant', $ace, '/T', '/C', '/Q')
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
    $code = Invoke-ExternalInteractive -Path $winget -ArgumentList @('install', '--id', $PackageId, '--exact', '--scope', 'machine', '--accept-source-agreements')
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

function Install-TemurinJdkFromAdoptium {
    $arch = Get-NativeWindowsArch
    $adoptiumArch = if ($arch -eq 'arm64') { 'aarch64' } else { 'x64' }
    $url = "https://api.adoptium.net/v3/binary/latest/17/ga/windows/$adoptiumArch/jdk/hotspot/normal/eclipse?project=jdk"
    $work = Join-Path $env:TEMP ('TemurinJdk-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $work 'temurin-jdk-17.zip'
    $extract = Join-Path $work 'extract'
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Write-Host "[*] Downloading Eclipse Temurin JDK 17 ($adoptiumArch) from Adoptium..." -ForegroundColor Yellow
        Download-File $url $zip 'Eclipse Temurin JDK 17'
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

function Install-GitFromGitHub {
    $arch = Get-NativeWindowsArch
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host '[*] Looking up the latest Git for Windows release...' -ForegroundColor Yellow
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' -Headers @{ 'User-Agent' = 'Android-SDK-Installer' }
    $asset = $null
    foreach ($item in @($release.assets)) {
        $name = [string]$item.name
        if ($arch -eq 'arm64') {
            if ($name -match '(?i)^Git-.+-arm64\.exe$') { $asset = $item; break }
        } elseif ($name -match '(?i)^Git-.+-64-bit\.exe$' -and $name -notmatch '(?i)(busybox|mingit|portable)') {
            $asset = $item
            break
        }
    }
    if (-not $asset) { throw 'Could not find a Git for Windows installer in the latest GitHub release.' }

    $work = Join-Path $env:TEMP ('GitInstaller-' + [guid]::NewGuid().ToString('N'))
    $setup = Join-Path $work $asset.name
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Write-Host "[*] Downloading $($asset.name)..." -ForegroundColor Yellow
        Download-File $asset.browser_download_url $setup $asset.name
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
    foreach ($javaPath in $candidates) {
        $key = $javaPath.ToLowerInvariant()
        if ($seen -contains $key -or -not (Test-Path -LiteralPath $javaPath -PathType Leaf)) { continue }
        $seen += $key
        $bin = Split-Path -Parent $javaPath
        $javaHomeDir = Split-Path -Parent $bin
        $versionResult = Invoke-ExternalCapture -Path $javaPath -ArgumentList @('-version')
        $versionText = ($versionResult.Output | Out-String)
        $major = 0
        if ($versionText -match 'version\s+"(?<major>\d+)') { $major = [int]$Matches['major'] }
        elseif ($versionText -match '(?:openjdk|java)\s+(?<major>\d+)') { $major = [int]$Matches['major'] }
        if ($major -ge 17 -and (Test-Path -LiteralPath (Join-Path $bin 'javac.exe') -PathType Leaf)) {
            return [pscustomobject]@{ Ready = $true; JavaHome = $javaHomeDir; Major = $major }
        }
    }
    return [pscustomobject]@{ Ready = $false; JavaHome = ''; Major = 0 }
}

function Ensure-Jdk {
    param([switch]$AutoInstall)
    $jdk = Get-JdkInfo
    if (-not $jdk.Ready) {
        if ($AutoInstall) {
            Write-Host 'A JDK 17 or newer is required. No suitable JDK was found, so Eclipse Temurin JDK 17 will be installed automatically.' -ForegroundColor Yellow
        } else {
            Write-Host 'A JDK 17 or newer is required for Android builds.' -ForegroundColor Yellow
            $answer = Read-Host 'Install Eclipse Temurin JDK 17 now? (Y/N)'
            if ($answer -notmatch '(?i)^y(es)?$') { throw 'Install a JDK 17+ and run this installer again.' }
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
        $answer = Read-Host 'Install Git for Windows now? (Y/N)'
        if ($answer -notmatch '(?i)^y(es)?$') { throw 'Install Git for Windows and run the Flutter installer again.' }
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
        $answer = Read-Host "Enter a number (1-$($Candidates.Count), Enter for 1, 0 to cancel)"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Candidates[0] }
        if ($answer -eq '0') { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Candidates.Count) { return $Candidates[$number - 1] }
        Write-Host 'Invalid selection.' -ForegroundColor Red
    }
}

function Read-FlutterSource {
    while ($true) {
        Write-Host 'Paste a folder containing flutter*.zip, an extracted Flutter folder, a ZIP path, or a direct URL.' -ForegroundColor Yellow
        Write-Host "Example: $env:USERPROFILE\Downloads" -ForegroundColor Gray
        $value = (Read-Host 'Folder / ZIP / URL').Trim().Trim([char]'"').Trim([char]"'").Trim()
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

function Receive-FileWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Activity
    )
    $destinationDir = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($destinationDir) -and -not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }

    $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Url)
    $request.UserAgent = 'Android-SDK-Installer'
    $request.AllowAutoRedirect = $true
    $request.Timeout = 60000
    $request.ReadWriteTimeout = 300000

    $response = $request.GetResponse()
    try {
        $totalBytes = [double]$response.ContentLength
        if ($totalBytes -lt 0) { $totalBytes = 0 }
        $finalUri = $Url
        try { if ($null -ne $response.ResponseUri) { $finalUri = [string]$response.ResponseUri } } catch { }
        $source = $response.GetResponseStream()
        try {
            $output = [IO.File]::Create($Destination)
            try {
                $buffer = New-Object 'byte[]' 524288
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $received = [double]0
                $speed = [double]0
                $lastRender = [double]-1
                $lastSampleAt = [double]0
                $lastSampleBytes = [double]0
                Show-TransferProgress -Activity $Activity -ReceivedBytes 0 -TotalBytes $totalBytes -BytesPerSecond 0 -ElapsedSeconds 0 -RemainingSeconds -1
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
                $average = if ($seconds -gt 0) { $received / $seconds } else { 0 }
                return [pscustomobject]@{ Bytes = $received; Seconds = $seconds; AverageSpeed = $average; Source = $finalUri }
            } finally { $output.Dispose() }
        } finally { $source.Dispose() }
    } finally { $response.Close() }
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
        [Parameter(Position = 2)][string]$Label
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = ''
        try { $Label = [IO.Path]::GetFileName(([Uri]$Url).AbsolutePath) } catch { $Label = '' }
        if ([string]::IsNullOrWhiteSpace($Label)) { $Label = [IO.Path]::GetFileName($Destination) }
    }
    $activity = "Downloading $Label"
    $result = $null
    try {
        $result = Receive-FileWithProgress -Url $Url -Destination $Destination -Activity $activity
    } catch {
        $failure = $_.Exception.Message
        Reset-TransferProgress -Activity $activity
        $partial = [double]0
        if (Test-Path -LiteralPath $Destination -PathType Leaf) { try { $partial = (Get-Item -LiteralPath $Destination).Length } catch { $partial = 0 } }
        if ($partial -gt 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "The download of $Label stopped after $(Format-ByteSize $partial). $failure"
        }
        $serverResponse = $null
        if ($_.Exception -is [Net.WebException]) { $serverResponse = $_.Exception.Response }
        if ($null -ne $serverResponse) {
            $status = ''
            try { $status = "$([int]$serverResponse.StatusCode) $($serverResponse.StatusCode)" } catch { $status = $failure }
            throw "The server rejected the download of ${Label}: $status"
        }
        Write-Host "[!] The live progress bar could not start for $Label ($failure). Retrying with a plain download..." -ForegroundColor Yellow
        try { $result = Receive-FileSimple -Url $Url -Destination $Destination }
        catch { throw "The download failed for ${Label}: $($_.Exception.Message)" }
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'The download did not create an output file.' }
    if ($result.Seconds -gt 0) {
        $summary = ('{0} ({1}) downloaded in {2}, average {3}/s' -f $Label, (Format-ByteSize $result.Bytes), (Format-DurationClock $result.Seconds), (Format-ByteSize $result.AverageSpeed))
    } else {
        $summary = ('{0} ({1}) downloaded.' -f $Label, (Format-ByteSize $result.Bytes))
    }
    Complete-TransferProgress -Activity $activity -Summary $summary
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

    Write-Warning 'sdkmanager did not record the accepted licenses. Writing the SDK license files directly...'
    Write-SdkLicenseFiles -SdkRoot $SdkRoot
    Write-Host '[*] Verifying the written license files...' -ForegroundColor Yellow
    if (Test-SdkLicensesAccepted -SdkManager $SdkManager -SdkRoot $SdkRoot) {
        Write-Host '[+] All Android SDK licenses accepted.' -ForegroundColor Green
        return $true
    }

    if ($Mode -eq 'Auto') {
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

function Get-AvailableSdkPackages {
    param([string]$SdkManager, [string]$SdkRoot)
    $packages = @()
    if (-not (Test-Path -LiteralPath $SdkManager -PathType Leaf)) { return $packages }
    $catalogResult = Invoke-ExternalCapture -Path $SdkManager -ArgumentList @("--sdk_root=$SdkRoot", '--list')
    $output = @($catalogResult.Output)
    $code = $catalogResult.ExitCode
    if ($code -ne 0) { Write-Warning "Could not read the SDK package catalog (sdkmanager exit code $code). Optional NDK/CMake packages may be skipped."; return $packages }
    $ansi = [string][char]27 + '\[[0-9;]*m'
    foreach ($entry in $output) {
        $line = $entry.ToString() -replace $ansi, ''
        if ($line -match '^\s*(?<package>(?:build-tools|cmake|ndk)[;/]\d+(?:\.\d+)+)\s*\|') { $packages += ($Matches['package'] -replace '/', ';') }
    }
    return @($packages | Sort-Object -Unique)
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

function Install-SdkPackages {
    param([AllowEmptyString()][string]$SdkManager, [AllowEmptyString()][string]$AndroidCli, [string]$SdkRoot, [string[]]$Packages)
    # Installs run with the console attached so the tool's own progress and any late license prompt
    # stay visible and answerable.
    $cliUsable = [bool]($AndroidCli -and (Test-Path -LiteralPath $AndroidCli -PathType Leaf))
    $managerUsable = [bool]($SdkManager -and (Test-Path -LiteralPath $SdkManager -PathType Leaf))
    if ($cliUsable) {
        $cliPackages = @($Packages | ForEach-Object { $_ -replace ';', '/' })
        Write-Host "[*] Installing with Android CLI: $($cliPackages -join ', ')" -ForegroundColor Yellow
        $cliArgs = @("--sdk=$SdkRoot", 'sdk', 'install') + $cliPackages
        $cliCode = Invoke-ExternalInteractive -Path $AndroidCli -ArgumentList $cliArgs
        if (($cliCode -eq 0) -or -not $managerUsable) { return $cliCode }
        Write-Warning "The Android CLI returned $cliCode. Retrying the same packages with sdkmanager..."
    }
    if (-not $managerUsable) { return 1 }
    Write-Host "[*] Installing with sdkmanager: $($Packages -join ', ')" -ForegroundColor Yellow
    $managerArgs = @("--sdk_root=$SdkRoot") + $Packages
    return (Invoke-ExternalInteractive -Path $SdkManager -ArgumentList $managerArgs)
}

function Get-LatestVersionFolder {
    param([string]$Parent)
    if (-not (Test-Path -LiteralPath $Parent -PathType Container)) { return $null }
    $best = $null
    $bestVersion = $null
    foreach ($dir in (Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue)) {
        $version = [version]'0.0'
        if (-not [version]::TryParse($dir.Name, [ref]$version)) { continue }
        if ($null -eq $bestVersion -or $version -gt $bestVersion) { $best = $dir.FullName; $bestVersion = $version }
    }
    return $best
}

function Get-LatestCmdlineToolsUrl {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Last known build, used only if the Android developer page cannot be read.
    $fallbackBuild = '15859902'
    $build = $null
    Write-Host '[*] Looking up the latest Google command-line tools version...' -ForegroundColor Yellow
    try {
        $page = Invoke-WebRequest -UseBasicParsing -Uri 'https://developer.android.com/studio' -Headers @{ 'User-Agent' = 'Android-SDK-Installer' }
        $hits = @([regex]::Matches([string]$page.Content, 'commandlinetools-win-(\d+)_latest\.zip'))
        $numbers = @($hits | ForEach-Object { [long]$_.Groups[1].Value } | Sort-Object -Descending)
        if ($numbers.Count -gt 0) { $build = [string]$numbers[0] }
    } catch {
        Write-Warning "Could not read the Android developer download page: $($_.Exception.Message)"
    }
    if (-not $build) {
        Write-Warning "Using the fallback command-line tools build $fallbackBuild."
        $build = $fallbackBuild
    }
    Write-Host "[*] Latest command-line tools build: $build" -ForegroundColor Yellow
    return "https://dl.google.com/android/repository/commandlinetools-win-$($build)_latest.zip"
}

function Install-AndroidSdk {
    Write-Host ''
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '        Java SDK + Android SDK Installation               ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan

    Write-Host ''
    Write-Host '[Step 1/4] Java SDK: Eclipse Temurin JDK 17' -ForegroundColor Cyan
    # Automatically download and install Eclipse Temurin JDK 17 when no JDK 17+ is present (no prompt).
    Ensure-Jdk -AutoInstall

    Write-Host ''
    Write-Host '[Step 2/4] Android command-line tools (latest Google release)' -ForegroundColor Cyan
    $toolsUrl = Get-LatestCmdlineToolsUrl
    $work = Join-Path $env:TEMP ('AndroidSdkInstaller-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $work 'commandlinetools.zip'
    $extract = Join-Path $work 'extract'
    $stage = Join-Path $work 'latest-staged'
    $backup = ''
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        Write-Host '[*] Downloading Android command-line tools...' -ForegroundColor Yellow
        Download-File $toolsUrl $zip 'Android command-line tools'
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

        $toolsRoot = Join-Path $script:SdkRoot 'cmdline-tools'
        $latest = Join-Path $toolsRoot 'latest'
        New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
        if (Test-Path -LiteralPath $latest -PathType Container) {
            $backup = Join-Path $toolsRoot ('latest.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            Write-Host "[*] Preserving old command-line tools at $backup" -ForegroundColor Yellow
            Move-Item -LiteralPath $latest -Destination $backup
        }
        try { Move-Item -LiteralPath $stage -Destination $latest }
        catch {
            if ($backup -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $latest)) { Move-Item -LiteralPath $backup -Destination $latest -ErrorAction SilentlyContinue }
            throw
        }

        New-Item -ItemType Directory -Path $script:SdkRoot -Force | Out-Null
        Grant-OriginalUserModifyAccess $script:SdkRoot
        Set-AndroidEnvironment

        Write-Host ''
        Write-Host '[Step 3/4] Android SDK packages' -ForegroundColor Cyan
        $bin = Join-Path $latest 'bin'
        $sdkManager = Join-Path $bin 'sdkmanager.bat'
        $androidCli = Join-Path $bin 'android.exe'
        if (-not (Test-Path -LiteralPath $sdkManager -PathType Leaf)) { $sdkManager = '' }
        if (-not (Test-Path -LiteralPath $androidCli -PathType Leaf)) { $androidCli = '' }
        if (-not $sdkManager -and -not $androidCli) { throw 'No usable SDK package manager was found after extraction.' }

        Write-Host ''
        Write-Host '[*] Android SDK packages can only be downloaded after their licenses are accepted.' -ForegroundColor Yellow
        $licenseChoice = (Read-Host 'Accept every Android SDK license now? (Y = accept all, N = answer each prompt yourself)').Trim()
        $licenseMode = if ($licenseChoice -match '^[Nn]') { 'Review' } else { 'Auto' }
        $licenseCommand = if ($sdkManager) { "`"$sdkManager`" --sdk_root=$script:SdkRoot --licenses" } else { "the Android CLI in $bin" }
        $licensesAccepted = Accept-SdkLicenses -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot -Mode $licenseMode
        if (-not $licensesAccepted) {
            throw "The Android SDK licenses were not accepted, so no package can be installed. Run $licenseCommand, enter Y at each prompt, then choose option 1 again."
        }

        $available = @()
        if ($sdkManager) { $available = @(Get-AvailableSdkPackages $sdkManager $script:SdkRoot) }
        $buildTools = Get-LatestSdkPackage $available 'build-tools' '36'
        if (-not $buildTools) { $buildTools = 'build-tools;36.0.0' }
        $corePackages = @('platform-tools', 'platforms;android-36', $buildTools)
        $coreCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $corePackages
        if (($coreCode -ne 0) -and $sdkManager -and -not (Test-SdkLicensesAccepted -SdkManager $sdkManager -SdkRoot $script:SdkRoot)) {
            # A declined license surfaces as a failed install, so offer the prompts once more.
            Write-Warning 'Some licenses are still unaccepted. Enter Y at each prompt, then the install runs again.'
            if (Accept-SdkLicenses -SdkManager $sdkManager -AndroidCli $androidCli -SdkRoot $script:SdkRoot -Mode 'Review') {
                $coreCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $corePackages
            }
        }
        if ($coreCode -ne 0) { throw "Core SDK installation failed (exit code $coreCode). Check network access and the license prompts: $licenseCommand" }
        # platform-tools did not exist during the Step 2 call above, so its PATH entry was skipped.
        # Persist PATH now that the core packages are installed, so a later verification failure
        # cannot leave platform-tools (adb) missing from Machine PATH. Step 4 repeats this (idempotent).
        Set-AndroidEnvironment

        $native = @()
        $cmake = Get-LatestSdkPackage $available 'cmake'
        $ndk = Get-LatestSdkPackage $available 'ndk'
        if ($cmake) { $native += $cmake }
        if ($ndk) { $native += $ndk }
        $nativeCode = $null
        if ($native.Count -gt 0) {
            $nativeCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $native
            if ($nativeCode -ne 0) { Write-Warning "Core packages are installed, but native packages failed: $($native -join ', ') (exit code $nativeCode)." }
        } else {
            Write-Warning 'The SDK package catalog did not provide stable NDK/CMake versions; native plugins may require installing them later.'
        }

        $required = @(
            (Join-Path $script:SdkRoot 'platform-tools\adb.exe'),
            (Join-Path $script:SdkRoot 'platforms\android-36\android.jar'),
            (Join-Path $script:SdkRoot ($buildTools.Replace(';', '\') + '\aapt2.exe'))
        )
        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if ($missing.Count -gt 0) { throw "SDK verification failed. Missing: $($missing -join ', ')" }

        Write-Host ''
        Write-Host '[Step 4/4] Setting environment variables and PATH entries' -ForegroundColor Cyan
        Set-AndroidEnvironment
        Broadcast-EnvironmentChange
        Write-Host ''
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host 'JAVA + ANDROID SDK INSTALLATION VERIFIED' -ForegroundColor Green
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host "JAVA_HOME: $([Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine'))"
        Write-Host "SDK root: $script:SdkRoot"
        Write-Host "Installed: Temurin JDK 17, command-line tools (build $(Split-Path -Leaf $toolsUrl)), platform-tools, Android API 36, and Build Tools."
        if ($nativeCode -eq 0) { Write-Host "Installed NDK/CMake: $($native -join ', ')" }
        if ($backup) { Write-Host "Previous command-line tools backup: $backup" -ForegroundColor Gray }
        Write-Host 'JAVA_HOME, ANDROID_HOME, ANDROID_SDK_ROOT, and Machine PATH have been configured.' -ForegroundColor Green
        Write-Host 'Open a new terminal before building.' -ForegroundColor Yellow
    } finally {
        if (Test-Path -LiteralPath $work -PathType Container) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
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
        $sdkPlatform = Join-Path $script:SdkRoot 'platforms\android-36\android.jar'

        if (Test-Path -LiteralPath $sdkPlatform -PathType Leaf) {
            Set-AndroidEnvironment
            Write-Host '[*] Connecting Flutter to C:\Android...' -ForegroundColor Yellow
            $configCode = Invoke-ExternalInteractive -Path $flutterBat -ArgumentList @('config', '--android-sdk', $script:SdkRoot)
            if ($configCode -ne 0) { Write-Warning "Flutter could not save the SDK path (exit code $configCode); ANDROID_HOME is still set." }
            Write-Host '[*] Confirming the Android SDK licenses through Flutter (they were accepted during the Android SDK installation)...' -ForegroundColor Yellow
            # Flutter re-asks "Accept? (y/N)" per license, so answer them instead of stalling on a
            # prompt that a captured run would never display.
            $licenseCode = Invoke-ExternalInteractive -Path $flutterBat -ArgumentList @('doctor', '--android-licenses') -Answers (Get-SdkLicenseAnswers 'y')
            if ($licenseCode -ne 0) { Write-Warning "Flutter's license check returned $licenseCode. Review its output and the SDK license files." }
        } else {
            Write-Warning 'Android Platform 36 was not found in C:\Android. Run Android SDK Installation first to build Android apps with Flutter.'
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
    $sdkLicenses = Join-Path $androidRoot 'licenses'
    if (Test-Path -LiteralPath (Join-Path $sdkLicenses 'android-sdk-license') -PathType Leaf) {
        $licenseCount = @(Get-ChildItem -LiteralPath $sdkLicenses -File -ErrorAction SilentlyContinue).Count
        Write-EnvironmentCheckResult 'OK' "Accepted SDK licenses are recorded under $sdkLicenses ($licenseCount file(s))"
    } else {
        Write-EnvironmentCheckResult 'MISSING' "No accepted SDK licenses were found under $sdkLicenses. Run: `"$sdkManager`" --sdk_root=$androidRoot --licenses"
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
        Write-Host "[INFO] The Android Emulator is not installed under $androidRoot. The installer never downloads it; run `"$sdkManager`" --sdk_root=$androidRoot `"emulator`" `"system-images;android-36;google_apis;x86_64`" and create the device with AVD Manager or avdmanager." -ForegroundColor Gray
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

while ($true) {
    Clear-Host
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '       Android SDK & Flutter Installer for Windows       ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  1. Java SDK + Android SDK Installation (JDK 17 & C:\Android)' -ForegroundColor Yellow
    Write-Host '  2. Flutter Installation (C:\flutter)' -ForegroundColor Yellow
    Write-Host '  3. Check Environment Paths' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  0. Exit' -ForegroundColor Gray
    Write-Host ''
    $choice = (Read-Host 'Enter your choice (1, 2, 3, or 0)').Trim()
    switch ($choice) {
        '1' { try { Install-AndroidSdk } catch { Close-InlineProgressLine; Write-Host "`nANDROID SDK INSTALLATION FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '2' { try { Install-Flutter } catch { Close-InlineProgressLine; Write-Host "`nFLUTTER INSTALLATION FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '3' { try { Show-EnvironmentPathStatus } catch { Close-InlineProgressLine; Write-Host "`nENVIRONMENT PATH CHECK FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '0' { exit 0 }
        default { Write-Host 'Invalid choice. Enter 1, 2, 3, or 0.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
