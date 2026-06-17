# =========================================================================
# AUTOMATIC ADMIN ELEVATION SECTION
# =========================================================================
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}

# =========================================================================
# MAIN ANDROID SDK INSTALLER SCRIPT
# =========================================================================
$ErrorActionPreference = "Stop"

# 1. Define Core Paths
$sdkRoot = "C:\Android"
$cmdlineToolsFolder = "$sdkRoot\cmdline-tools"
$latestFolder = "$cmdlineToolsFolder\latest"
$zipPath = "$sdkRoot\cmdline-tools.zip"
$platformToolsPath = "$sdkRoot\platform-tools"

Clear-Host
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "         Flexible Android SDK & ADB Installer            " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# 2. Single Input — Auto-Detect: Directory Path or Online URL (loops until valid)
$isLocalFile = $false
$inputSource = ""

while ($true) {
    Write-Host "Enter Directory Address (folder path) OR Online Direct File Link (URL):" -ForegroundColor Yellow
    Write-Host "Example: C:\Users\Zero\Downloads   or   https://dl.google.com/.../commandlinetools-..." -ForegroundColor Gray
    Write-Host ""
    $inputSource = Read-Host "Address / URL"

    if ([string]::IsNullOrWhiteSpace($inputSource)) {
        Write-Host "[-] Input cannot be empty. Please try again." -ForegroundColor Red
        Write-Host ""
        continue
    }

    if ($inputSource -match "^https?://") {
        Write-Host "[+] Detected as Online URL" -ForegroundColor Green
        break
    }

    if (Test-Path -LiteralPath $inputSource -PathType Container) {
        Write-Host "[+] Detected as Local Directory" -ForegroundColor Green
        $zipFiles = Get-ChildItem -LiteralPath $inputSource -Filter "cmdline-tools*.zip" -File
        if ($zipFiles.Count -eq 0) {
            Write-Host "[-] No cmdline-tools*.zip file found in that directory." -ForegroundColor Red
            Write-Host ""
            continue
        }
        if ($zipFiles.Count -eq 1) {
            $inputSource = $zipFiles[0].FullName
            Write-Host "[+] Auto-detected ZIP: $(Split-Path $inputSource -Leaf)" -ForegroundColor Green
        } else {
            Write-Host "Multiple cmdline-tools ZIP files found. Please choose:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $zipFiles.Count; $i++) {
                Write-Host "$($i+1). $($zipFiles[$i].Name) ($([math]::Round($zipFiles[$i].Length / 1MB, 2)) MB)"
            }
            $fileChoice = Read-Host "Enter the number (1-$($zipFiles.Count))"
            $fileIndex = [int]$fileChoice - 1
            if ($fileIndex -lt 0 -or $fileIndex -ge $zipFiles.Count) {
                Write-Host "[-] Invalid selection." -ForegroundColor Red
                Write-Host ""
                continue
            }
            $inputSource = $zipFiles[$fileIndex].FullName
        }
        $isLocalFile = $true
        break
    }

    if (Test-Path -LiteralPath $inputSource -PathType Leaf) {
        Write-Host "[+] Detected as Local File" -ForegroundColor Green
        $isLocalFile = $true
        break
    }

    Write-Host "[-] Invalid input. Provide a valid folder path, file path, or URL." -ForegroundColor Red
    Write-Host ""
}

# 3. Fast cleanup of any existing installation
if (Test-Path $sdkRoot) {
    Write-Host "`n[*] Cleaning up previous installation (fast mode)..." -ForegroundColor Yellow
    & cmd /c "rmdir /s /q `"$sdkRoot`" 2>nul"
}

# 4. Create Main SDK Directory
New-Item -ItemType Directory -Path $sdkRoot | Out-Null
Write-Host "[+] Directory created successfully: $sdkRoot" -ForegroundColor Green

# 5. Process File Based on Selection Source
if ($isLocalFile) {
    Write-Host "[*] Copying your local ZIP file..." -ForegroundColor Yellow
    Copy-Item -Path $inputSource -Destination $zipPath -Force
} else {
    Write-Host "[*] Downloading from URL (progress shown below)..." -ForegroundColor Yellow
    $wc = New-Object System.Net.WebClient
    $wc.DownloadProgressChanged += {
        param($sender, $e)
        $pct = $e.ProgressPercentage
        $dl = $e.BytesReceived
        $total = $e.TotalBytesToReceive
        if ($total -gt 0) {
            Write-Progress -Activity "Downloading cmdline-tools..." -Status "$([math]::Round($dl/1MB, 2)) MB / $([math]::Round($total/1MB, 2)) MB ($pct%)" -PercentComplete $pct
        }
    }
    $wc.DownloadFileAsync($inputSource, $zipPath)
    while ($wc.IsBusy) { Start-Sleep -Milliseconds 100 }
    Write-Progress -Activity "Downloading cmdline-tools..." -Completed
}

# 6. Extract Files safely via Temporary Directory
$tempExtractPath = "$sdkRoot\temp_extract"
Write-Host "[*] Extracting Command-line Tools..." -ForegroundColor Yellow
Expand-Archive -Path $zipPath -DestinationPath $tempExtractPath -Force

# Reconstruct proper folder hierarchy (`cmdline-tools\latest\bin`)
New-Item -ItemType Directory -Path $latestFolder | Out-Null
$extractedCmdlineTools = "$tempExtractPath\cmdline-tools"
if (Test-Path $extractedCmdlineTools) {
    Get-ChildItem -Path $extractedCmdlineTools | ForEach-Object {
        Move-Item -Path $_.FullName -Destination $latestFolder -Force
    }
}

# Cleanup temporary files
Remove-Item -Path $tempExtractPath -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $zipPath) { Remove-Item $zipPath }
Write-Host "[+] Command-line Tools configured successfully." -ForegroundColor Green

# 7. Download Platform-Tools (ADB) via sdkmanager
Write-Host "[*] Installing Platform-Tools, SDK Platform 34 & Build-Tools..." -ForegroundColor Yellow
$sdkManagerBin = "$latestFolder\bin\sdkmanager.bat"

Start-Process -FilePath $sdkManagerBin -ArgumentList '"platform-tools"', '"platforms;android-34"', '"build-tools;34.0.0"' -Wait -NoNewWindow

if (Test-Path $platformToolsPath) {
    Write-Host "[+] Platform-Tools (ADB) installed successfully." -ForegroundColor Green
} else {
    Write-Warning "[-] Platform-tools folder missing. Please check your internet connection."
}

# 8. Configure System Environment Variables and PATH
Write-Host "[*] Configuring System Environment Variables and PATH..." -ForegroundColor Yellow

[Environment]::SetEnvironmentVariable("ANDROID_HOME", $sdkRoot, "Machine")

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$binPath = "$latestFolder\bin"
$adbPath = $platformToolsPath

if ($userPath -notlike "*$binPath*") { $userPath = "$userPath;$binPath" }
if ($userPath -notlike "*$adbPath*") { $userPath = "$userPath;$adbPath" }

[Environment]::SetEnvironmentVariable("Path", $userPath, "User")
Write-Host "[+] Added SDK binaries and ADB to your User PATH." -ForegroundColor Green

# 9. Suppress Java Restriction Warnings
[Environment]::SetEnvironmentVariable("JDK_JAVA_OPTIONS", "--enable-native-access=ALL-UNNAMED", "Machine")
Write-Host "[+] Successfully suppressed Java native access restrictions warnings." -ForegroundColor Green

# 10. Accept SDK Licenses (interactive — you type y/n)
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host "         Accept Android SDK Licenses (if prompted)       " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Type 'y' and press Enter to accept each license." -ForegroundColor Yellow
Write-Host ""
& cmd /c "`"$sdkManagerBin`" --licenses"
Write-Host ""

# 11. Show installed versions
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               INSTALLED VERSIONS                        " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[*] sdkmanager version:" -ForegroundColor Yellow
& cmd /c "`"$sdkManagerBin`" --version"
Write-Host ""
Write-Host "[*] adb version:" -ForegroundColor Yellow
$adbBin = "$platformToolsPath\adb.exe"
if (Test-Path $adbBin) {
    & $adbBin --version
} else {
    Write-Warning "adb.exe not found at $adbBin"
}
Write-Host ""

Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "                INSTALLATION COMPLETE!                  " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Please CLOSE this window and open a NEW Terminal/CMD window." -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter to exit..."
