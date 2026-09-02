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

function Wait-Esc {
    param([string]$Prompt = "Press Esc to exit...")
    Write-Host $Prompt -ForegroundColor Yellow
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        if ($key.VirtualKeyCode -eq 27) { break }
    }
}

# 1. Define Core Paths
$sdkRoot = "C:\Android"
$cmdlineToolsFolder = "$sdkRoot\cmdline-tools"
$latestFolder = "$cmdlineToolsFolder\latest"
$zipPath = "$sdkRoot\cmdline-tools.zip"
$platformToolsPath = "$sdkRoot\platform-tools"

# =========================================================================
# TOOL MENU
# =========================================================================
:toolMenu while ($true) {
    Clear-Host
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "         Flexible Android SDK & ADB Installer            " -ForegroundColor Cyan
    Write-Host "                    Tool Menu                           " -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Android SDK Installation" -ForegroundColor Yellow
    Write-Host "  2. Flutter Installation" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  0. Exit" -ForegroundColor Gray
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    $menuChoice = Read-Host "Enter your choice (1-2, 0 to exit)"

    switch ($menuChoice) {
        "1" { break toolMenu }
        "2" {
            Clear-Host
            Write-Host "=========================================================" -ForegroundColor Cyan
            Write-Host "               Flutter Installation                    " -ForegroundColor Cyan
            Write-Host "=========================================================" -ForegroundColor Cyan
            Write-Host ""

            # Flutter paths
            $flutterRoot = "C:\flutter"
            $flutterBin = "$flutterRoot\bin"
            $flutterZipPath = "C:\flutter.zip"
            $tempFlutterExtract = "C:\temp_flutter_extract"
            $isFlutterLocalFile = $false
            $flutterInputSource = ""

            # Input loop - Directory / File / URL
            while ($true) {
                Write-Host "Enter Directory Address (folder path) OR Online Direct File Link (URL):" -ForegroundColor Yellow
                Write-Host "Example: C:\Users\$env:USERNAME\Downloads   or   https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_...-stable.zip" -ForegroundColor Gray
                Write-Host ""
                $flutterInputSource = Read-Host "Address / URL"
                # Fix Copy as path quotes: "D:\path\file.zip" -> D:\path\file.zip
                $flutterInputSource = $flutterInputSource.Trim().Trim('"').Trim("'").Trim()

                if ([string]::IsNullOrWhiteSpace($flutterInputSource)) {
                    Write-Host "[-] Input cannot be empty. Please try again." -ForegroundColor Red
                    Write-Host ""
                    continue
                }

                if ($flutterInputSource -match "^https?://") {
                    Write-Host "[+] Detected as Online URL" -ForegroundColor Green
                    break
                }

                if (Test-Path -LiteralPath $flutterInputSource -PathType Container) {
                    Write-Host "[+] Detected as Local Directory" -ForegroundColor Green
                    $zipFiles = Get-ChildItem -LiteralPath $flutterInputSource -Filter "flutter*.zip" -File
                    if ($zipFiles.Count -eq 0) {
                        # Fallback: try any zip containing flutter
                        $zipFiles = Get-ChildItem -LiteralPath $flutterInputSource -Filter "*.zip" -File | Where-Object { $_.Name -like "*flutter*" }
                    }
                    if ($zipFiles.Count -eq 0) {
                        Write-Host "[-] No flutter*.zip file found in that directory." -ForegroundColor Red
                        Write-Host ""
                        continue
                    }
                    if ($zipFiles.Count -eq 1) {
                        $flutterInputSource = $zipFiles[0].FullName
                        Write-Host "[+] Auto-detected ZIP: $(Split-Path $flutterInputSource -Leaf)" -ForegroundColor Green
                    } else {
                        Write-Host "Multiple flutter ZIP files found. Please choose:" -ForegroundColor Yellow
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
                        $flutterInputSource = $zipFiles[$fileIndex].FullName
                    }
                    $isFlutterLocalFile = $true
                    break
                }

                if (Test-Path -LiteralPath $flutterInputSource -PathType Leaf) {
                    Write-Host "[+] Detected as Local File" -ForegroundColor Green
                    $isFlutterLocalFile = $true
                    break
                }

                Write-Host "[-] Invalid input. Provide a valid folder path, file path, or URL." -ForegroundColor Red
                Write-Host ""
            }

            # Cleanup previous Flutter installation
            if (Test-Path $flutterRoot) {
                Write-Host "`n[*] Cleaning up previous Flutter installation (fast mode)..." -ForegroundColor Yellow
                & cmd /c "rmdir /s /q `"$flutterRoot`" 2>nul"
            }
            if (Test-Path $tempFlutterExtract) {
                & cmd /c "rmdir /s /q `"$tempFlutterExtract`" 2>nul"
            }
            if (Test-Path $flutterZipPath) { Remove-Item $flutterZipPath -Force -ErrorAction SilentlyContinue }

            # Download or Copy
            if ($isFlutterLocalFile) {
                Write-Host "[*] Copying your local Flutter ZIP file..." -ForegroundColor Yellow
                Copy-Item -Path $flutterInputSource -Destination $flutterZipPath -Force
            } else {
                Write-Host "[*] Downloading Flutter from URL (progress shown below)..." -ForegroundColor Yellow
                $wc = New-Object System.Net.WebClient
                $wc.DownloadProgressChanged += {
                    param($sender, $e)
                    $pct = $e.ProgressPercentage
                    $dl = $e.BytesReceived
                    $total = $e.TotalBytesToReceive
                    if ($total -gt 0) {
                        Write-Progress -Activity "Downloading Flutter..." -Status "$([math]::Round($dl/1MB, 2)) MB / $([math]::Round($total/1MB, 2)) MB ($pct%)" -PercentComplete $pct
                    }
                }
                $wc.DownloadFileAsync($flutterInputSource, $flutterZipPath)
                while ($wc.IsBusy) { Start-Sleep -Milliseconds 100 }
                Write-Progress -Activity "Downloading Flutter..." -Completed
            }

            # Extract to temp then move flutter folder to C:\flutter
            Write-Host "[*] Extracting Flutter..." -ForegroundColor Yellow
            Expand-Archive -Path $flutterZipPath -DestinationPath $tempFlutterExtract -Force

            # Find flutter folder inside temp
            $extractedFlutter = Get-ChildItem -Path $tempFlutterExtract -Directory | Where-Object { $_.Name -eq "flutter" } | Select-Object -First 1
            if (-not $extractedFlutter) {
                # Some zips may extract directly without top folder, fallback: move all contents
                $extractedFlutter = Get-ChildItem -Path $tempFlutterExtract | Select-Object -First 1
                if ($extractedFlutter -and $extractedFlutter.PSIsContainer) {
                    # If single folder, assume it's flutter
                    Move-Item -Path $extractedFlutter.FullName -Destination $flutterRoot -Force
                } else {
                    New-Item -ItemType Directory -Path $flutterRoot -Force | Out-Null
                    Get-ChildItem -Path $tempFlutterExtract | ForEach-Object { Move-Item -Path $_.FullName -Destination $flutterRoot -Force }
                }
            } else {
                Move-Item -Path $extractedFlutter.FullName -Destination $flutterRoot -Force
            }

            # Cleanup temp and zip
            Remove-Item -Path $tempFlutterExtract -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path $flutterZipPath) { Remove-Item $flutterZipPath -Force -ErrorAction SilentlyContinue }
            Write-Host "[+] Flutter extracted successfully to $flutterRoot" -ForegroundColor Green

            # Add flutter\bin to User PATH
            Write-Host "[*] Configuring PATH for Flutter..." -ForegroundColor Yellow
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if ($userPath -notlike "*$flutterBin*") {
                if ([string]::IsNullOrEmpty($userPath)) { $userPath = $flutterBin } else { $userPath = "$userPath;$flutterBin" }
                [Environment]::SetEnvironmentVariable("Path", $userPath, "User")
                Write-Host "[+] Added $flutterBin to User PATH." -ForegroundColor Green
            } else {
                Write-Host "[*] Flutter bin already in PATH." -ForegroundColor Gray
            }
            # Also update current session PATH
            if ($env:Path -notlike "*$flutterBin*") { $env:Path += ";$flutterBin" }

            # Show Flutter version / status
            Write-Host ""
            Write-Host "=========================================================" -ForegroundColor Cyan
            Write-Host "                 FLUTTER VERSION                       " -ForegroundColor Cyan
            Write-Host "=========================================================" -ForegroundColor Cyan
            Write-Host ""
            $flutterBat = "$flutterBin\flutter.bat"
            if (Test-Path $flutterBat) {
                Write-Host "[*] flutter version:" -ForegroundColor Yellow
                & cmd /c "`"$flutterBat`" --version"
                Write-Host ""
            } else {
                Write-Warning "flutter.bat not found at $flutterBat"
            }

            Write-Host "=========================================================" -ForegroundColor Cyan
            Write-Host "               FLUTTER INSTALL COMPLETE!               " -ForegroundColor Cyan
            Write-Host "=========================================================" -ForegroundColor Cyan
            Write-Host "Please open a NEW Terminal/CMD window to use flutter." -ForegroundColor Yellow
            Write-Host ""
            Wait-Esc "Press Esc to return to menu..."
            continue toolMenu
        }
        "0" { Wait-Esc "Press Esc to exit..."; Exit }
        default {
            Write-Host "[-] Invalid choice. Please enter 1, 2 or 0." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue toolMenu
        }
    }
}

Clear-Host
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "              Android SDK Installation                   " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""

# 2. Single Input — Auto-Detect: Directory Path or Online URL (loops until valid)
$isLocalFile = $false
$inputSource = ""

while ($true) {
    Write-Host "Enter Directory Address (folder path) OR Online Direct File Link (URL):" -ForegroundColor Yellow
    Write-Host "Example: C:\Users\$env:USERNAME\Downloads   or   https://dl.google.com/.../commandlinetools-..." -ForegroundColor Gray
    Write-Host ""
    $inputSource = Read-Host "Address / URL"
    # Fix Copy as path quotes: "D:\path\file.zip" -> D:\path\file.zip
    $inputSource = $inputSource.Trim().Trim('"').Trim("'").Trim()

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

# 9. Accept SDK Licenses (interactive — you type y/n)
Write-Host "`n=========================================================" -ForegroundColor Cyan
Write-Host "         Accept Android SDK Licenses (if prompted)       " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "Type 'y' and press Enter to accept each license." -ForegroundColor Yellow
Write-Host ""
& cmd /c "`"$sdkManagerBin`" --licenses"
Write-Host ""

# 10. Show installed versions
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "               INSTALLED VERSIONS                        " -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[*] sdkmanager version:" -ForegroundColor Yellow
# Fix: sdkmanager 22.0+ prints deprecation WARNING (deprecated in favor of 'android' CLI) - filter it
$rawVersion = & cmd /c "`"$sdkManagerBin`" --version 2>&1"
$cleanVersion = $rawVersion | Where-Object { $_ -match "^\s*\d+(\.\d+)*\s*$" } | Select-Object -Last 1
if ($cleanVersion) {
    Write-Host $cleanVersion.ToString().Trim()
} else {
    $filtered = $rawVersion | Where-Object { $_ -notmatch "WARNING|deprecated|The 'android' binary|https://d\.android\.com" -and $_.ToString().Trim() -ne "" }
    if ($filtered) { $filtered | ForEach-Object { Write-Host $_ } }
}
# Also show new Android CLI version if available (replacement for sdkmanager in 22.0+)
$androidBin = "$latestFolder\bin\android.bat"
if (-not (Test-Path $androidBin)) { $androidBin = "$latestFolder\bin\android.exe" }
if (Test-Path $androidBin) {
    Write-Host ""
    Write-Host "[*] android CLI version:" -ForegroundColor Yellow
    & cmd /c "`"$androidBin`" --version 2>&1" | Where-Object { $_ -notmatch "^\s*$" } | ForEach-Object { Write-Host $_ }
}
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
Write-Host "Please open a NEW Terminal/CMD window to use adb / sdkmanager." -ForegroundColor Yellow
Write-Host ""
Wait-Esc "Press Esc to exit..."
