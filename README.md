# Android SDK & Flutter Installer for Windows

A PowerShell 5.1+ installer for Windows 10/11. It installs the Android SDK under `C:\Android` and Flutter under `C:\flutter`, without requiring the Android Studio IDE. The installer requests Administrator privileges because it updates Machine environment variables and installs under the root of `C:`.

---

## English

### Menu options

- **1. Java SDK + Android SDK Installation** — installs Eclipse Temurin JDK 17, then the latest Google Android command-line tools, then the SDK packages under `C:\Android`. No folder, ZIP, or URL selection is needed.
- **2. Flutter Installation** — select a Flutter ZIP, an extracted Flutter SDK folder, or a direct download URL. Flutter is installed to `C:\flutter`.
- **3. Check Environment Paths** — inspect Java/JDK, Python, Android SDK, and Flutter environment variables, PATH entries, and required executables. This check is read-only.
- **0. Exit** — close the installer.

Double-click `Run.bat` to open the menu. PowerShell asks for Administrator approval before the installer changes Machine environment variables.

### Download and extraction progress

Every download and every extraction the installer performs shows a live bar on one console line, so a long step never looks frozen:

```
[*] Downloading Eclipse Temurin JDK 17 (x64) from Adoptium...
    [##################------------------------]  40.9%     77.7 MB / 190.0 MB      4.1 MB/s  elapsed 00:18  left 00:25
    [+] Eclipse Temurin JDK 17 (190.0 MB) downloaded in 00:46, average 4.1 MB/s
```

The bar reports:

| Field | Meaning |
|---|---|
| Bar + percentage | How much of the transfer is finished |
| `77.7 MB / 190.0 MB` | Megabytes (or GB) moved so far and the total size |
| `4.1 MB/s` | Current transfer speed, smoothed so the number does not jump |
| `elapsed 00:18` | Time already spent on this step |
| `left 00:25` | Estimated minutes and seconds remaining |
| `( 1204/ 9830 files)` | File counter shown while extracting or staging |

The same bar covers the JDK download, the Git for Windows download, the Android command-line tools download, the Flutter download, every ZIP extraction, and the local copies into `C:\Android` and `C:\flutter`. It adapts to the console width, and when the server does not send a size it keeps showing the downloaded amount and speed with a moving marker instead of a percentage. In hosts without a real console line (PowerShell ISE, redirected logs, remoting) the same numbers are reported through the native `Write-Progress` bar. Set `ANDROID_SDK_INSTALLER_NO_PROGRESS=1` to turn the bars off.

### Environment path check

Choose **3. Check Environment Paths** to check the Machine, User, and current Process scopes. The read-only check reports `JAVA_HOME` and JDK executables, Python executables or the `py` launcher, Android SDK variables and tools, `FLUTTER_ROOT`, and whether their expected directories are in `PATH`. Python is checked only; this installer does not install it. Open a new terminal after a Machine or User PATH change.

### Java SDK + Android SDK install flow

Choose **1** and the installer runs these steps automatically:

1. **Java SDK** — if no JDK 17+ is found, Eclipse Temurin JDK 17 is installed without a prompt. It uses `winget` when available, otherwise downloads Temurin JDK 17 from Adoptium.
2. **Android command-line tools** — the latest Google command-line tools build is looked up from the Android developer download page (with a built-in fallback build if that page cannot be read), downloaded with a live progress bar, and installed to `C:\Android\cmdline-tools\latest`. A previous `latest` folder is kept in a timestamped backup.
3. **SDK packages** — accept the license prompts (enter `y`), then the installer installs **platform-tools**, **Android Platform 36**, and the latest available **Build Tools 36.x**, plus the latest stable **NDK** and **CMake** when the package catalog provides them. The installer does not silently accept third-party license agreements.
4. **Environment** — `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `ANDROID_NDK_HOME` (when NDK is installed) are set, and Machine `PATH` receives the JDK `bin`, `cmdline-tools\latest\bin`, `platform-tools`, the latest `build-tools`, `emulator` (if present), and the latest `cmake\<version>\bin` (if present).

Finally the installer verifies the required files (`adb.exe`, `android.jar`, and `aapt2.exe`) before reporting success. The Android Emulator and system images are not downloaded by default; install them separately with `sdkmanager` if you want a virtual device.

### Flutter install flow

1. Choose **2** and paste a folder, ZIP path, or direct URL. The folder search accepts `flutter*.zip` and already-extracted Flutter SDK folders.
2. Flutter is staged before replacing `C:\flutter`; any previous installation is preserved in a timestamped backup. Downloads, ZIP extraction, and staging all report size, speed, and time left on a progress bar. The selected source file is not deleted.
3. The installer checks for a **JDK 17+** and **Git for Windows**. If either is missing, it offers to install Temurin JDK 17 or Git. It uses `winget` when that command is available (including the real App Installer copy, which elevated sessions often miss on PATH). If `winget` is absent or fails, it downloads Eclipse Temurin JDK 17 from Adoptium and Git for Windows from GitHub. Review and approve package terms if a GUI installer is shown.
4. Flutter's `bin` is added to Machine `PATH`. If Android Platform 36 is installed under `C:\Android`, the installer sets Flutter's Android SDK path and runs the Android license check and `flutter doctor -v`.

### Environment variables

The installer sets these at Machine scope and updates the current installer session:

| Variable / PATH entry | Value | Purpose |
|---|---|---|
| `ANDROID_HOME` | `C:\Android` | Android SDK location recommended by Android tooling |
| `ANDROID_SDK_ROOT` | `C:\Android` | Compatibility with tools that still read the deprecated variable; kept equal to `ANDROID_HOME` |
| `ANDROID_NDK_HOME` | Latest installed `C:\Android\ndk\<version>` | NDK location, set when the NDK is installed |
| `JAVA_HOME` | Detected JDK 17+ location | JDK used by Gradle and Android builds |
| `FLUTTER_ROOT` | `C:\flutter` | Flutter SDK location |
| `PATH` | Android command-line tools, `platform-tools`, JDK `bin`, and `C:\flutter\bin` when installed | Run `sdkmanager`, `adb`, `java`, `git`, and `flutter` from a terminal |

Open a **new terminal** after installation so it receives the updated environment.

### Requirements and notes

- Windows 10 or Windows 11; Windows PowerShell 5.1 or later.
- Administrator approval is required for the C-drive installs, Machine PATH, and system environment variables.
- Internet is required to fetch SDK packages and optional JDK/Git prerequisites. `winget` is used when available; otherwise Temurin JDK 17 is downloaded from Adoptium and Git for Windows from GitHub.
- Allow several GB of free disk space, especially when installing the NDK and CMake.
- The installer does not delete an existing `C:\Android` SDK. It preserves previous `latest` command-line tools and Flutter installations in timestamped backups.
- The official `sdkmanager` tool is deprecated by Google. If an Android CLI executable is present, the installer uses `android sdk install`; otherwise it uses the compatible `sdkmanager.bat` interface.

### Verify

Open a new PowerShell or Command Prompt and run:

```powershell
java -version
git --version
adb version
flutter doctor -v
```

For the SDK package list, use `android sdk list` if the Android CLI is installed, or `sdkmanager --list` otherwise.

---

## Repository files

| File | Purpose |
|---|---|
| `Android_SDK.ps1` | Main installer and menu |
| `Run.bat` | Launcher; PowerShell handles UAC elevation |
| `tests/Progress.Tests.ps1` | Progress-bar, extraction, and copy tests for Windows PowerShell 5.1 and PowerShell 7 |
| `.github/workflows/validate.yml` | Runs those tests on a Windows runner for every push and pull request |
| `.gitattributes` | Keeps Windows batch files on CRLF line endings |
| `README.md` | This guide |

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
