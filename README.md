# Android SDK & Flutter Installer for Windows

A PowerShell 5.1+ installer for Windows 10/11. It installs the Android SDK under `C:\Android` and Flutter under `C:\flutter`, without requiring the Android Studio IDE. The installer requests Administrator privileges because it updates Machine environment variables and installs under the root of `C:`.

---

## English

### Menu options

- **1. Android SDK Installation** — select a local command-line-tools ZIP, an extracted tools folder, or a direct download URL. The SDK packages are installed to `C:\Android`.
- **2. Flutter Installation** — select a Flutter ZIP, an extracted Flutter SDK folder, or a direct download URL. Flutter is installed to `C:\flutter`.
- **3. Check Environment Paths** — inspect Java/JDK, Python, Android SDK, and Flutter environment variables, PATH entries, and required executables. This check is read-only.
- **0. Exit** — close the installer.

Double-click `Run.bat` to open the menu. PowerShell asks for Administrator approval before the installer changes Machine environment variables.

### Environment path check

Choose **3. Check Environment Paths** to check the Machine, User, and current Process scopes. The read-only check reports `JAVA_HOME` and JDK executables, Python executables or the `py` launcher, Android SDK variables and tools, `FLUTTER_ROOT`, and whether their expected directories are in `PATH`. Python is checked only; this installer does not install it. Open a new terminal after a Machine or User PATH change.

### Android SDK install flow

1. Choose **1** and paste the path to a folder, a ZIP file, or a direct URL. If no JDK 17+ is installed, the installer automatically installs **Eclipse Temurin JDK 17** first (no prompt): it uses `winget` when available, otherwise downloads Temurin JDK 17 from Adoptium, and sets `JAVA_HOME`.
2. For a folder, the installer searches for files such as `commandlinetools-win-*_latest.zip`, `cmdline-tools*.zip`, and extracted `cmdline-tools` / `commandlinetools` folders. A folder containing an existing SDK layout is also supported. If several candidates are found, choose a number; pressing Enter selects the first (newest ZIPs are listed first).
3. The selected tools are staged in a temporary folder and installed to `C:\Android\cmdline-tools\latest`. The original ZIP is never deleted. If the selected folder is an existing SDK root, its `platform-tools`, `platforms`, `build-tools`, licenses, NDK, CMake, emulator, and other SDK component folders are merged into `C:\Android` without deleting the source. Destination-only files are not deleted; files at matching paths may be refreshed from the selected source. Replaced command-line tools are kept in a timestamped backup.
4. The installer installs **platform-tools**, **Android Platform 36**, and the latest available **Build Tools 36.x**. It also installs the latest stable **NDK** and **CMake** versions reported by the SDK package catalog when those packages are available.
5. SDK license prompts are interactive. Read each prompt and enter `y` to accept. The installer does not silently accept third-party license agreements.
6. It verifies the required files (`adb.exe`, `android.jar`, and `aapt2.exe`) before reporting success.

The Android Emulator and system images are not downloaded as new packages by default. If they already exist in the selected SDK root, they are copied over; otherwise, they are optional and not required just to compile an Android app. Install them separately if you want to run a virtual device.

### Flutter install flow

1. Choose **2** and paste a folder, ZIP path, or direct URL. The folder search accepts `flutter*.zip` and already-extracted Flutter SDK folders.
2. Flutter is staged before replacing `C:\flutter`; any previous installation is preserved in a timestamped backup. The selected source file is not deleted.
3. The installer checks for a **JDK 17+** and **Git for Windows**. If either is missing, it offers to install Temurin JDK 17 or Git. It uses `winget` when that command is available (including the real App Installer copy, which elevated sessions often miss on PATH). If `winget` is absent or fails, it downloads Eclipse Temurin JDK 17 from Adoptium and Git for Windows from GitHub. Review and approve package terms if a GUI installer is shown.
4. Flutter's `bin` is added to Machine `PATH`. If Android Platform 36 is installed under `C:\Android`, the installer sets Flutter's Android SDK path and runs the Android license check and `flutter doctor -v`.

### Environment variables

The installer sets these at Machine scope and updates the current installer session:

| Variable / PATH entry | Value | Purpose |
|---|---|---|
| `ANDROID_HOME` | `C:\Android` | Android SDK location recommended by Android tooling |
| `ANDROID_SDK_ROOT` | `C:\Android` | Compatibility with tools that still read the deprecated variable; kept equal to `ANDROID_HOME` |
| `JAVA_HOME` | Detected JDK 17+ location | JDK used by Gradle and Android builds |
| `FLUTTER_ROOT` | `C:\flutter` | Flutter SDK location |
| `PATH` | Android command-line tools, `platform-tools`, JDK `bin`, and `C:\flutter\bin` when installed | Run `sdkmanager`, `adb`, `java`, `git`, and `flutter` from a terminal |

Open a **new terminal** after installation so it receives the updated environment.

### Requirements and notes

- Windows 10 or Windows 11; Windows PowerShell 5.1 or later.
- Administrator approval is required for the C-drive installs, Machine PATH, and system environment variables.
- Internet is required to fetch SDK packages and optional JDK/Git prerequisites. `winget` is used when available; otherwise Temurin JDK 17 is downloaded from Adoptium and Git for Windows from GitHub.
- Allow several GB of free disk space, especially when installing the NDK and CMake.
- The installer does not delete an existing `C:\Android` SDK or the source ZIP. It preserves previous `latest` command-line tools and Flutter installations in timestamped backups.
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
| `.gitattributes` | Keeps Windows batch files on CRLF line endings |
| `README.md` | This guide |

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
