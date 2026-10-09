#Requires -Version 5.1
[CmdletBinding()]
param([string]$OriginalUserSid)

$ErrorActionPreference = 'Stop'
$script:SdkRoot = 'C:\Android'
$script:FlutterRoot = 'C:\flutter'
$script:OriginalUserSid = $OriginalUserSid

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
        & $Path @ArgumentList 2>&1 | Out-Host
        $code = $LASTEXITCODE
        return $code
    } finally {
        $ErrorActionPreference = $savedPreference
    }
}

function Invoke-ExternalCapture {
    param([Parameter(Mandatory = $true)][string]$Path, [string[]]$ArgumentList = @())
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Path @ArgumentList 2>&1)
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
    $cmdlineBin = Join-Path $script:SdkRoot 'cmdline-tools\latest\bin'
    $platformTools = Join-Path $script:SdkRoot 'platform-tools'
    if (Test-Path -LiteralPath $cmdlineBin -PathType Container) { Add-PathEntry $cmdlineBin 'Machine' }
    if (Test-Path -LiteralPath $platformTools -PathType Container) { Add-PathEntry $platformTools 'Machine' }
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
    $code = Invoke-ExternalToHost -Path $winget -ArgumentList @('install', '--id', $PackageId, '--exact', '--scope', 'machine', '--accept-source-agreements')
    if ($code -ne 0) { throw "winget could not install $DisplayName (exit code $code)." }
    Refresh-ProcessPath
}

function Find-ExtractedJdkHome {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    $roots = @($Root)
    foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) { $roots += $dir.FullName }
    foreach ($home in $roots) {
        $java = Join-Path $home 'bin\java.exe'
        $javac = Join-Path $home 'bin\javac.exe'
        if ((Test-Path -LiteralPath $java -PathType Leaf) -and (Test-Path -LiteralPath $javac -PathType Leaf)) { return $home }
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
        Download-File $url $zip
        if ((Get-Item -LiteralPath $zip).Length -lt 1048576) { throw 'The Temurin JDK download is too small to be a valid archive.' }
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        Write-Host '[*] Extracting Eclipse Temurin JDK 17...' -ForegroundColor Yellow
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
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
        Download-File $asset.browser_download_url $setup
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
        $home = Split-Path -Parent (Split-Path -Parent $javac.Source)
        $candidate = Join-Path $home 'bin\java.exe'
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
        $home = Split-Path -Parent $bin
        $versionResult = Invoke-ExternalCapture -Path $javaPath -ArgumentList @('-version')
        $versionText = ($versionResult.Output | Out-String)
        $major = 0
        if ($versionText -match 'version\s+"(?<major>\d+)') { $major = [int]$Matches['major'] }
        elseif ($versionText -match '(?:openjdk|java)\s+(?<major>\d+)') { $major = [int]$Matches['major'] }
        if ($major -ge 17 -and (Test-Path -LiteralPath (Join-Path $bin 'javac.exe') -PathType Leaf)) {
            return [pscustomobject]@{ Ready = $true; JavaHome = $home; Major = $major }
        }
    }
    return [pscustomobject]@{ Ready = $false; JavaHome = ''; Major = 0 }
}

function Ensure-Jdk {
    $jdk = Get-JdkInfo
    if (-not $jdk.Ready) {
        Write-Host 'A JDK 17 or newer is required for Android builds.' -ForegroundColor Yellow
        $answer = Read-Host 'Install Eclipse Temurin JDK 17 now? (Y/N)'
        if ($answer -notmatch '(?i)^y(es)?$') { throw 'Install a JDK 17+ and run this installer again.' }
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

function Test-AndroidSdkRootFolder {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $false }
    foreach ($name in @('platform-tools', 'platforms', 'build-tools', 'licenses', 'ndk', 'cmake', 'emulator')) {
        if (Test-Path -LiteralPath (Join-Path $Folder $name) -PathType Container) { return $true }
    }
    return $false
}

function Copy-ExistingAndroidSdkComponents {
    param([string]$SourceRoot, [string]$TargetRoot)
    if ([string]::IsNullOrWhiteSpace($SourceRoot) -or -not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { return }
    $source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
    if ($source -ieq $target) { return }
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) { throw 'robocopy.exe was not found; existing SDK packages could not be copied safely.' }
    foreach ($name in @('platform-tools', 'platforms', 'build-tools', 'licenses', 'ndk', 'cmake', 'emulator', 'system-images', 'sources', 'extras')) {
        $src = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
        $dst = Join-Path $target $name
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Write-Host "[*] Importing existing SDK component: $name" -ForegroundColor Yellow
        $code = Invoke-ExternalToHost -Path $robocopy -ArgumentList @($src, $dst, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NP', '/NFL', '/NDL')
        if ($code -ge 8) { throw "Could not copy SDK component '$name' (robocopy exit code $code). The source was not deleted." }
    }
}

function Get-AndroidSourcesFromFolder {
    param([string]$Folder)
    $sdkRoot = ''
    if (Test-AndroidSdkRootFolder $Folder) { $sdkRoot = (Get-Item -LiteralPath $Folder).FullName }
    $sources = @()
    foreach ($zip in (Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)(command.?line.?tools|cmdline.?tools).*\.zip$' } | Sort-Object LastWriteTime -Descending)) {
        $sources += [pscustomobject]@{ Kind = 'Zip'; Path = $zip.FullName; Name = $zip.Name; Size = $zip.Length; SdkRoot = $sdkRoot }
    }
    foreach ($tools in (Get-CmdlineToolsFolders $Folder)) {
        if (-not ($sources | Where-Object { $_.Path -ieq $tools })) {
            $sources += [pscustomobject]@{ Kind = 'Folder'; Path = $tools; Name = "Extracted tools: $tools"; Size = 0; SdkRoot = $sdkRoot }
        }
    }
    return @($sources)
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

function Read-AndroidSource {
    while ($true) {
        Write-Host 'Paste an Android SDK folder, a folder containing commandlinetools/cmdline-tools, a ZIP path, or a direct URL.' -ForegroundColor Yellow
        Write-Host "Example: $env:USERPROFILE\Downloads" -ForegroundColor Gray
        $value = (Read-Host 'Folder / ZIP / URL').Trim().Trim([char]'"').Trim([char]"'").Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { Write-Host 'Input cannot be empty.' -ForegroundColor Red; continue }
        if ($value -match '^https?://') { return [pscustomobject]@{ Kind = 'Url'; Path = $value; Name = $value; Size = 0; SdkRoot = '' } }
        if (Test-Path -LiteralPath $value -PathType Leaf) {
            if ([IO.Path]::GetExtension($value) -ine '.zip') { Write-Host 'Select a .zip file or a folder.' -ForegroundColor Red; continue }
            $zip = Get-Item -LiteralPath $value
            $parent = Split-Path -Parent $zip.FullName
            $sdkRoot = ''
            if (Test-AndroidSdkRootFolder $parent) { $sdkRoot = $parent }
            return [pscustomobject]@{ Kind = 'Zip'; Path = $zip.FullName; Name = $zip.Name; Size = $zip.Length; SdkRoot = $sdkRoot }
        }
        if (Test-Path -LiteralPath $value -PathType Container) {
            $candidates = @(Get-AndroidSourcesFromFolder $value)
            if ($candidates.Count -eq 0) { Write-Host 'No command-line tools ZIP or extracted tools folder was found.' -ForegroundColor Red; continue }
            $selected = Select-SourceCandidate $candidates 'Matching Android SDK sources:'
            if ($null -ne $selected) { return $selected }
            continue
        }
        Write-Host 'Path not found. Try again.' -ForegroundColor Red
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

function Download-File {
    param([string]$Url, [string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    try {
        $client.Headers.Add('User-Agent', 'Android-SDK-Installer')
        $client.DownloadFile($Url, $Destination)
    } finally { $client.Dispose() }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'The download did not create an output file.' }
}

function Find-ExtractedAndroidTools {
    param([string]$Root)
    $folders = @(Get-CmdlineToolsFolders $Root)
    if ($folders.Count -gt 0) { return $folders[0] }
    return $null
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
    if ($AndroidCli -and (Test-Path -LiteralPath $AndroidCli -PathType Leaf)) {
        $cliPackages = @($Packages | ForEach-Object { $_ -replace ';', '/' })
        Write-Host "[*] Installing with Android CLI: $($cliPackages -join ', ')" -ForegroundColor Yellow
        $cliArgs = @("--sdk=$SdkRoot", 'sdk', 'install') + $cliPackages
        return (Invoke-ExternalToHost -Path $AndroidCli -ArgumentList $cliArgs)
    }
    Write-Host "[*] Installing with sdkmanager: $($Packages -join ', ')" -ForegroundColor Yellow
    $managerArgs = @("--sdk_root=$SdkRoot") + $Packages
    return (Invoke-ExternalToHost -Path $SdkManager -ArgumentList $managerArgs)
}

function Install-AndroidSdk {
    Write-Host ''
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host '         Android SDK Installation (C:\Android)          ' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Ensure-Jdk
    $source = Read-AndroidSource
    if ($null -eq $source) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }

    $work = Join-Path $env:TEMP ('AndroidSdkInstaller-' + [guid]::NewGuid().ToString('N'))
    $zip = Join-Path $work 'commandlinetools.zip'
    $extract = Join-Path $work 'extract'
    $stage = Join-Path $work 'latest-staged'
    $backup = ''
    try {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        if ($source.Kind -eq 'Url') {
            Write-Host '[*] Downloading command-line tools to a temporary folder...' -ForegroundColor Yellow
            Download-File $source.Path $zip
        } elseif ($source.Kind -eq 'Zip') {
            Write-Host '[*] Copying the ZIP to a temporary folder. The source file will not be deleted.' -ForegroundColor Yellow
            Copy-Item -LiteralPath $source.Path -Destination $zip -Force
        } else { $toolsSource = $source.Path }

        if ($source.Kind -ne 'Folder') {
            if ((Get-Item -LiteralPath $zip).Length -lt 1024) { throw 'The selected file is too small to be a command-line tools ZIP.' }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Write-Host '[*] Extracting Android command-line tools...' -ForegroundColor Yellow
            Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
            $toolsSource = Find-ExtractedAndroidTools $extract
            if (-not $toolsSource) { throw 'The ZIP does not contain a cmdline-tools folder with sdkmanager.bat or android.exe.' }
        }

        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Get-ChildItem -LiteralPath $toolsSource -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force }
        if (-not (Test-CmdlineToolsDirectory $stage)) { throw 'The selected folder does not contain usable Android command-line tools.' }

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
        if ($source.SdkRoot) { Copy-ExistingAndroidSdkComponents $source.SdkRoot $script:SdkRoot }
        Grant-OriginalUserModifyAccess $script:SdkRoot
        Set-AndroidEnvironment

        $bin = Join-Path $latest 'bin'
        $sdkManager = Join-Path $bin 'sdkmanager.bat'
        $androidCli = Join-Path $bin 'android.exe'
        if (-not (Test-Path -LiteralPath $sdkManager -PathType Leaf)) { $sdkManager = '' }
        if (-not (Test-Path -LiteralPath $androidCli -PathType Leaf)) { $androidCli = '' }
        if (-not $sdkManager -and -not $androidCli) { throw 'No usable SDK package manager was found after extraction.' }

        if ($sdkManager) {
            Write-Host ''
            Write-Host '[*] Review the Android SDK license prompts and enter Y to accept each license.' -ForegroundColor Yellow
            $licenseCode = Invoke-ExternalToHost -Path $sdkManager -ArgumentList @("--sdk_root=$script:SdkRoot", '--licenses')
            if ($licenseCode -ne 0) { throw "SDK license setup failed (sdkmanager exit code $licenseCode)." }
        } else { Write-Warning 'sdkmanager.bat is absent; the Android CLI will manage licenses during package installation.' }

        $available = @()
        if ($sdkManager) { $available = @(Get-AvailableSdkPackages $sdkManager $script:SdkRoot) }
        $buildTools = Get-LatestSdkPackage $available 'build-tools' '36'
        if (-not $buildTools) { $buildTools = 'build-tools;36.0.0' }
        $corePackages = @('platform-tools', 'platforms;android-36', $buildTools)
        $coreCode = Install-SdkPackages $sdkManager $androidCli $script:SdkRoot $corePackages
        if ($coreCode -ne 0) { throw "Core SDK installation failed (exit code $coreCode). Check network access and license prompts." }

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
            $existingNative = @()
            if (Test-Path -LiteralPath (Join-Path $script:SdkRoot 'ndk') -PathType Container) { $existingNative += 'NDK' }
            if (Test-Path -LiteralPath (Join-Path $script:SdkRoot 'cmake') -PathType Container) { $existingNative += 'CMake' }
            if ($existingNative.Count -gt 0) { Write-Host "Existing native tool folders found: $($existingNative -join ', ')" -ForegroundColor Gray }
            else { Write-Warning 'The SDK package catalog did not provide stable NDK/CMake versions; native plugins may require installing them later.' }
        }

        $required = @(
            (Join-Path $script:SdkRoot 'platform-tools\adb.exe'),
            (Join-Path $script:SdkRoot 'platforms\android-36\android.jar'),
            (Join-Path $script:SdkRoot ($buildTools.Replace(';', '\') + '\aapt2.exe'))
        )
        $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if ($missing.Count -gt 0) { throw "SDK verification failed. Missing: $($missing -join ', ')" }

        Add-PathEntry $bin 'Machine'
        Add-PathEntry (Join-Path $script:SdkRoot 'platform-tools') 'Machine'
        Broadcast-EnvironmentChange
        Write-Host ''
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host 'ANDROID SDK INSTALLATION VERIFIED' -ForegroundColor Green
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host "SDK root: $script:SdkRoot"
        Write-Host 'Installed: command-line tools, platform-tools, Android API 36, and Build Tools.'
        if ($nativeCode -eq 0) { Write-Host "Installed NDK/CMake: $($native -join ', ')" }
        if ($backup) { Write-Host "Previous command-line tools backup: $backup" -ForegroundColor Gray }
        Write-Host 'ANDROID_HOME, ANDROID_SDK_ROOT, and Machine PATH have been configured.' -ForegroundColor Green
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
            Download-File $source.Path $zip
        } elseif ($source.Kind -eq 'Zip') {
            Write-Host '[*] Copying the ZIP to a temporary folder. The source file will not be deleted.' -ForegroundColor Yellow
            Copy-Item -LiteralPath $source.Path -Destination $zip -Force
        } else { $flutterSource = $source.Path }

        if ($source.Kind -ne 'Folder') {
            if ((Get-Item -LiteralPath $zip).Length -lt 1048576) { throw 'The selected file is too small to be a Flutter SDK ZIP.' }
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Write-Host '[*] Extracting Flutter. This may take several minutes...' -ForegroundColor Yellow
            Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
            $folders = @(Get-FlutterFolders $extract)
            if ($folders.Count -eq 0) { throw 'The ZIP does not contain a Flutter SDK with bin\flutter.bat.' }
            $flutterSource = $folders[0]
        }
        if (-not (Test-Path -LiteralPath (Join-Path $flutterSource 'bin\flutter.bat') -PathType Leaf)) { throw 'The selected folder does not contain bin\flutter.bat.' }

        if ($source.Kind -eq 'Folder') {
            New-Item -ItemType Directory -Path $stage -Force | Out-Null
            Get-ChildItem -LiteralPath $flutterSource -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force }
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
            $configCode = Invoke-ExternalToHost -Path $flutterBat -ArgumentList @('config', '--android-sdk', $script:SdkRoot)
            if ($configCode -ne 0) { Write-Warning "Flutter could not save the SDK path (exit code $configCode); ANDROID_HOME is still set." }
            Write-Host '[*] Checking Android SDK licenses through Flutter...' -ForegroundColor Yellow
            $licenseCode = Invoke-ExternalToHost -Path $flutterBat -ArgumentList @('doctor', '--android-licenses')
            if ($licenseCode -ne 0) { Write-Warning "Flutter's license check returned $licenseCode. Review its output and the SDK license files." }
        } else {
            Write-Warning 'Android Platform 36 was not found in C:\Android. Run Android SDK Installation first to build Android apps with Flutter.'
        }

        Add-PathEntry $flutterBin 'Machine'
        Broadcast-EnvironmentChange
        Write-Host '[*] Verifying Flutter installation...' -ForegroundColor Yellow
        $versionCode = Invoke-ExternalToHost -Path $flutterBat -ArgumentList @('--version')
        if ($versionCode -ne 0) { throw "flutter --version failed (exit code $versionCode). Files remain in C:\flutter for troubleshooting." }
        if (Test-Path -LiteralPath $sdkPlatform -PathType Leaf) {
            Write-Host '[*] Running flutter doctor -v...' -ForegroundColor Yellow
            $doctorCode = Invoke-ExternalToHost -Path $flutterBat -ArgumentList @('doctor', '-v')
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
    Write-Host '  1. Android SDK Installation (C:\Android)' -ForegroundColor Yellow
    Write-Host '  2. Flutter Installation (C:\flutter)' -ForegroundColor Yellow
    Write-Host '  3. Check Environment Paths' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  0. Exit' -ForegroundColor Gray
    Write-Host ''
    $choice = (Read-Host 'Enter your choice (1, 2, 3, or 0)').Trim()
    switch ($choice) {
        '1' { try { Install-AndroidSdk } catch { Write-Host "`nANDROID SDK INSTALLATION FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '2' { try { Install-Flutter } catch { Write-Host "`nFLUTTER INSTALLATION FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '3' { try { Show-EnvironmentPathStatus } catch { Write-Host "`nENVIRONMENT PATH CHECK FAILED: $($_.Exception.Message)" -ForegroundColor Red }; Wait-ForEnter 'Press Enter to return to the menu...' }
        '0' { exit 0 }
        default { Write-Host 'Invalid choice. Enter 1, 2, 3, or 0.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
}
