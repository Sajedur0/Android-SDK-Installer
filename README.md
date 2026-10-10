# Android SDK & Flutter Installer for Windows

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A PowerShell 5.1+ installer for Windows 10/11. It installs the Android SDK under `C:\Android` and Flutter under `C:\flutter`, without requiring the Android Studio IDE. The installer requests Administrator privileges because it updates Machine environment variables and installs under the root of `C:`.

---

## English

### Menu options

- **1. Java SDK + Android SDK Installation** — installs Eclipse Temurin JDK 17, then the latest Google Android command-line tools, then the SDK packages. No folder, ZIP, or URL selection is needed. The SDK goes to `C:\Android` unless `ANDROID_HOME` already points at a usable SDK, in which case that SDK is reused (see [Unattended runs and overrides](#unattended-runs-and-overrides)).
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

### Testing the progress bar

`tests/Progress.Tests.ps1` loads only the helper functions out of `Android_SDK.ps1` and checks them, so it is safe to run on any Windows machine and never installs anything. It verifies the size and time formatting, that the rendered bar never exceeds the console width from 40 to 200 columns, that ZIP extraction and folder copies keep every file byte-for-byte, that an entry pointing outside the destination folder is skipped, and that a failed download leaves no partial or resumable file. It also checks package markers (a folder without its `source.properties`, `android.jar`, `aapt2.exe`, `cmake.exe`, or `adb.exe` is never reported as installed), catalog parsing and version selection for Build Tools, NDK, and CMake, disk-space and SHA-256 behaviour, that an unanswered prompt falls back to its default instead of hanging, and the regression guards for the emulator PATH entry and license handling.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Progress.Tests.ps1   # Windows PowerShell 5.1
pwsh -NoProfile -File tests/Progress.Tests.ps1                                  # PowerShell 7
```

To watch the bar animate without downloading anything, run the demo. It drives the same rendering code with simulated transfers (a JDK download, the command-line tools, a Flutter extraction with a file counter, and a server that reports no size). Set `ANDROID_SDK_INSTALLER_DEMO_CONSOLE_WIDTH` to preview a narrower or wider console.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Progress.Demo.ps1
```

### Environment path check

Choose **3. Check Environment Paths** to check the Machine, User, and current Process scopes. It also prints a component matrix for platform-tools, the platform, Build Tools, NDK, and CMake, marking each as present, missing, or incomplete, and gives the exact `sdkmanager install` / `android sdk install` repair command for whatever is missing. The read-only check reports `JAVA_HOME` and JDK executables, Python executables or the `py` launcher, Android SDK variables and tools, whether accepted SDK license files are recorded under `<SDK>\licenses`, the optional Android Emulator install and `PATH` state, `FLUTTER_ROOT`, and whether their expected directories are in `PATH`. Python is checked only; this installer does not install it. Open a new terminal after a Machine or User PATH change.

### Java SDK + Android SDK install flow

Choose **1** and the installer runs these steps automatically:

1. **Java SDK** — the installer looks for a JDK in the range Gradle and the Android Gradle Plugin actually support (17 to 21) and uses the oldest one it finds. If only a newer JDK (22+) or nothing suitable exists, Eclipse Temurin JDK 17 is installed without a prompt and becomes `JAVA_HOME`; the newer JDK is left installed and untouched. `winget` is used when available, otherwise Temurin JDK 17 is downloaded from Adoptium and its published SHA-256 is verified.
2. **Android command-line tools** — the latest build number is read from the Android developer download page (with a built-in fallback build, and a seven-day cache so repeated runs do not re-download a 4 MB page). When the installed build already matches the latest build, the download, staging, and backup are skipped entirely. Otherwise the archive is downloaded with a live progress bar, resumed if a transfer was interrupted, and installed to `<SDK>\cmdline-tools\latest`. The previous `latest` folder is moved to `%ProgramData%\Android-SDK-Installer\backups`, out of the SDK root, and only the three newest backups are kept.
3. **SDK packages** — free space on both TEMP and the SDK volume is checked before anything is downloaded. The installer then asks once whether to accept every Android SDK license. `Y` (or Enter) answers each `sdkmanager --licenses` prompt for you; `N` shows the prompts so you can review each license and type `y` yourself. Licenses are never accepted without that choice: when a prompt is answered `N`, the installer reports the refusal instead of writing the license hash files for you. If `sdkmanager` did not record an approval you gave, the published license files are written under `<SDK>\licenses` and verified again. Packages are installed next: **platform-tools**, **Android Platform 36** (or the API level you pass) and its matching **Build Tools** in one `sdkmanager` call, then **NDK** and **CMake**. Anything already present in the SDK is skipped, so a second run downloads nothing, and a retry after a failing tool only requests what is still missing. CMake is resolved to the 3.x line by default because CMake 4 removed the `cmake_minimum_required(VERSION 3.4.1)` compatibility that most NDK projects still declare.
4. **Environment** — `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `ANDROID_NDK_HOME` (only when a *complete* NDK is installed) are set, and Machine `PATH` receives the JDK `bin`, `cmdline-tools\latest\bin`, `platform-tools`, the latest `build-tools`, and the latest `cmake\<version>\bin` (if present). The `emulator` folder is never added automatically. PATH is edited through the registry so unrelated `%VARIABLE%` entries keep their expandable form instead of being written out as literal text.

Finally the installer verifies each package by the file that makes it usable (`adb.exe`, `android.jar`, `aapt2.exe`, `ndk\<version>\source.properties`, `cmake\<version>\bin\cmake.exe`). A folder that exists without its marker file is reported as incomplete and is never advertised as installed, and success is only claimed when every package it mentions is on disk. If the core packages are fine but NDK or CMake are not, the run ends with `ANDROID SDK INSTALLATION PARTIAL - CORE OK, NATIVE PACKAGES MISSING` plus the exact retry command, because a project without native code still builds. The Android Emulator and system images are opt-in only: the installer never downloads them and never adds an existing `C:\Android\emulator` folder to `PATH`. Android Studio, Gradle, and `flutter emulators` reach the Emulator through `ANDROID_HOME`, so no PATH entry is needed for them. To use the `emulator -avd <name>` command line yourself, install and register it afterwards:

```powershell
sdkmanager --sdk_root=C:\Android "emulator" "system-images;android-36;google_apis;x86_64"
avdmanager create avd -n api36 -k "system-images;android-36;google_apis;x86_64"
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';C:\Android\emulator', 'Machine')
```

Choose **3. Check Environment Paths** to see a `[INFO]` line reporting whether an installed Emulator is or is not on `PATH`.

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
| `ANDROID_NDK_HOME` | Latest `C:\Android\ndk\<version>` folder that contains `source.properties` | NDK location. Cleared again when no complete NDK is installed, so a half-extracted folder is never advertised |
| `JAVA_HOME` | Detected JDK 17+ location | JDK used by Gradle and Android builds |
| `FLUTTER_ROOT` | `C:\flutter` | Flutter SDK location |
| `PATH` | Android command-line tools, `platform-tools`, JDK `bin`, and `C:\flutter\bin` when installed | Run `sdkmanager`, `adb`, `java`, `git`, and `flutter` from a terminal |

Open a **new terminal** after installation so it receives the updated environment.

### Requirements and notes

- Windows 10 or Windows 11; Windows PowerShell 5.1 or later.
- Administrator approval is required for the C-drive installs, Machine PATH, and system environment variables.
- Internet is required to fetch SDK packages and optional JDK/Git prerequisites. `winget` is used when available; otherwise Temurin JDK 17 is downloaded from Adoptium and Git for Windows from GitHub.
- Allow several GB of free disk space, especially when installing the NDK and CMake. The installer
  checks the free space of TEMP and of the SDK volume before each large download and stops early with
  the amount it still needs.
- The installer does not delete an existing `C:\Android` SDK. It preserves previous `latest` command-line
  tools and Flutter installations in timestamped backups; command-line tools backups live under
  `%ProgramData%\Android-SDK-Installer\backups` (outside the SDK, where the package managers would keep
  scanning them) and only the three newest are kept.
- An `ANDROID_HOME` that already points at a working SDK is reused rather than repointed, and the
  installer asks before installing a second SDK at `C:\Android`.
- Gradle and the Android Gradle Plugin support JDK 17 to 21. A newer installed JDK is left alone, and
  Temurin JDK 17 is installed beside it and becomes `JAVA_HOME`.
- Machine `PATH` is edited through the registry, preserving `REG_EXPAND_SZ` entries; the change is
  refused if the resulting value would exceed 30,000 characters.
- The official `sdkmanager` tool is deprecated by Google. If an Android CLI executable is present, the installer uses `android sdk install` and retries the same packages with the compatible `sdkmanager.bat` interface if the Android CLI reports an error. The deprecation warning is printed as plain text, not as a PowerShell error.
- `sdkmanager`, `flutter`, and `winget` run with the console attached, so their prompts and progress bars stay visible and answerable. That matters for `--licenses`: when the output is piped, the prompts never render and every license silently defaults to "no", which ends in `8 of 8 SDK package licenses not accepted`.

### Unattended runs and overrides

The installer takes two parameters, and every optional behaviour is also available as an environment
variable so a scripted run needs no console at all.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File Android_SDK.ps1 -SdkRoot D:\Android -ApiLevel 36
```

| Setting | Effect |
|---|---|
| `-SdkRoot <path>` | Install the SDK somewhere other than the detected `ANDROID_HOME` or `C:\Android`. |
| `-ApiLevel <n>` | Which Android Platform and Build Tools major to install (default 36). |
| `ANDROID_SDK_INSTALLER_ACCEPT_LICENSES=Y` | Required to answer the license prompts in an unattended run. Without it the installer refuses to accept licenses on your behalf and stops. |
| `ANDROID_SDK_INSTALLER_FLUTTER_SOURCE` | Flutter ZIP path, extracted SDK folder, or URL for option 2 in an unattended run. |
| `ANDROID_SDK_INSTALLER_CHOICE` | Menu entry to run immediately (`1`, `2`, or `3`); the installer then exits with its normal exit code. |
| `ANDROID_SDK_INSTALLER_CMDLINE_TOOLS_BUILD` | Pin the command-line tools build number instead of reading it from the download page. |
| `ANDROID_SDK_INSTALLER_CMAKE_MAJOR` | Which CMake major to install (default 3). |
| `ANDROID_SDK_INSTALLER_NO_CACHE=1` | Never reuse the cached package catalog or command-line tools build lookup. |
| `ANDROID_SDK_INSTALLER_RECURSIVE_ACL=1` | Apply the ownership grant to every existing file recursively (slower on an installed NDK). |
| `ANDROID_SDK_INSTALLER_NO_PROGRESS=1` | Use the PowerShell progress bar instead of the inline one. |
| `ANDROID_SDK_INSTALLER_ASSUME_INTERACTIVE=1` / `..._ASSUME_NONINTERACTIVE=1` | Force console access on or off, for headless test runs. |

`ANDROID_SDK_INSTALLER_ROOT` and `ANDROID_SDK_INSTALLER_API_LEVEL` do the same job as the two parameters
when a run cannot pass them.

Failed steps are counted, and exiting the menu returns `1` instead of `0` when anything failed, so
`Run.bat` and CI can tell success from a handled error. Downloads are retried three times and resume
from the partial `.part` file, SHA-256 hashes are verified when the publisher provides one (Adoptium
and the GitHub release API do) and always printed, and free space is checked before anything large is
fetched. Staging folders abandoned by an interrupted run are cleaned up at startup.

### Verify

Open a new PowerShell or Command Prompt and run:

```powershell
java -version
git --version
adb version
flutter doctor -v
```

For the SDK package list, use `android sdk list` if the Android CLI is installed, or `sdkmanager --list` otherwise. The Emulator is not installed or registered on `PATH` by default, so the `emulator` command is expected to be missing until you add it with the optional commands above; `adb version` and `flutter doctor -v` do not need it.

---

## Repository files

| File | Purpose |
|---|---|
| `Android_SDK.ps1` | Main installer and menu |
| `Run.bat` | Launcher; PowerShell handles UAC elevation |
| `tests/Progress.Tests.ps1` | Helper tests for Windows PowerShell 5.1 and PowerShell 7: progress bar, extraction, copies, package markers, catalog parsing, disk space, hashes, prompts, and PATH handling |
| `tests/Progress.Demo.ps1` | Animates the real progress bar with simulated transfers; downloads nothing |
| `LICENSE` | Apache License 2.0, kept word-for-word canonical so license scanners recognise it |
| `NOTICE` | Copyright line and the licenses of the components the installer downloads |
| `.gitattributes` | Keeps Windows batch files on CRLF line endings |
| `README.md` | This guide |

## License

Apache License 2.0 — the full text ships in [`LICENSE`](LICENSE), so a copy of this repository already
satisfies section 4(a), and [`NOTICE`](NOTICE) carries the attribution. The `LICENSE` file is kept
word-for-word canonical, with the appendix placeholders unreplaced, because editing it breaks GitHub's
and other scanners' license detection. Put your own copyright notice in your copies of the files instead:

```
Copyright 2026 Sajedur Rahman Roni

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

The JDK, Android SDK packages, Flutter, and Git that the installer downloads keep their own licenses;
this license grants no rights in them. Accepting the Android SDK license terms is always the user's own
action through `sdkmanager --licenses`, never something the installer does without being asked.
