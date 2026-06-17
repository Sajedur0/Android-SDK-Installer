# Android SDK & ADB Installer

An automated PowerShell script for Windows that downloads, extracts, and configures **Android SDK Command-line Tools**, **Platform-Tools (ADB)**, **SDK Platform**, and **Build-Tools** with a single command.

---

## Features

| Feature | Details |
|---|---|
| **Dual Source Input** | Auto-detects whether you provided a folder path or an online URL |
| **Download Progress** | Shows real-time MB and percentage progress for online downloads |
| **Fast Cleanup** | Uses `rmdir /s /q` for quick removal of previous installations |
| **Auto Extraction** | Extracts ZIP into the correct `cmdline-tools\latest\bin` structure |
| **SDK Components** | Installs platform-tools, platforms;android-34, build-tools;34.0.0 |
| **Env Variables** | Automatically sets `ANDROID_HOME` (Machine) and `PATH` (User) |
| **License Manager** | Runs `sdkmanager --licenses` — you manually accept each with y/n |
| **Version Display** | Shows `sdkmanager --version` and `adb --version` at the end |
| **Auto Admin Elevation** | Self-elevates to Administrator privileges automatically |
| **Error Retry** | Loops on invalid input instead of crashing |

---

## How to Use

### Method 1: Run.bat (Recommended)
Double-click **`Run.bat`** — it automatically elevates to Admin and launches `Android_SDK.ps1`.

### Method 2: PowerShell Direct
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
```

---

## Input Types (Auto-Detect)

A single prompt accepts any of the following:

| Input Type | Example | Behaviour |
|---|---|---|
| **Online URL** | `https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip` | Downloads with progress bar |
| **Directory Path** | `C:\Users\%USERNAME%\Downloads` | Scans folder for `cmdline-tools*.zip` |
| **File Path** | `C:\Users\%USERNAME%\Downloads\cmdline-tools.zip` | Uses the ZIP file directly |

> If multiple ZIP files are found, you will be prompted to choose one.

---

## What Gets Installed

| Component | Location |
|---|---|
| **Command-line Tools** | `C:\Android\cmdline-tools\latest\bin\` |
| **Platform-Tools (ADB)** | `C:\Android\platform-tools\` |
| **SDK Platform 34** | `C:\Android\platforms\android-34\` |
| **Build-Tools 34.0.0** | `C:\Android\build-tools\34.0.0\` |

### Environment Variables Set

| Variable | Value | Scope |
|---|---|---|
| `ANDROID_HOME` | `C:\Android` | Machine |
| `PATH` (append) | `C:\Android\cmdline-tools\latest\bin` | User |
| `PATH` (append) | `C:\Android\platform-tools` | User |
| `JDK_JAVA_OPTIONS` | `--enable-native-access=ALL-UNNAMED` | Machine |

---

## After Installation

1. **CLOSE** the current window
2. Open a **NEW** Terminal / CMD window
3. Verify installation:
   ```cmd
   adb --version
   sdkmanager --list
   ```
4. Re-accept licenses if needed:
   ```cmd
   sdkmanager --licenses
   ```

---

## System Requirements

- **OS:** Windows 10 / Windows 11
- **PowerShell:** 5.1 or later
- **Internet:** Required for online download & SDK components
- **Java:** JDK 17+ recommended (for sdkmanager)

---

## Files

| File | Purpose |
|---|---|
| `Android_SDK.ps1` | Main PowerShell installer script |
| `Run.bat` | Batch launcher (auto admin + bypass policy) |
| `README.md` | This documentation |

---

## License

This project is licensed under the **Apache License 2.0**.
