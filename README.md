# Android SDK & ADB Installer

একটি সম্পূর্ণ PowerShell স্ক্রিপ্ট যা Windows-এ **Android SDK Command-line Tools**, **Platform-Tools (ADB)**, **SDK Platform** এবং **Build-Tools** অটোমেটিক্যালি ডাউনলোড, এক্সট্র্যাক্ট ও কনফিগার করে।

---

## Features

| Feature | Details |
|---|---|
| **Dual Source Input** | Folder Path বা Online URL — যা দিবেন auto-detect করবে |
| **Download Progress** | Online থেকে ডাউনলোড করলে MB ও Percentage দেখাবে |
| **Fast Cleanup** | `rmdir /s /q` দিয়ে পুরনো ফাইল দ্রুত ডিলিট করে |
| **Auto Extraction** | ZIP এক্সট্র্যাক্ট করে `cmdline-tools\latest\bin` স্ট্রাকচারে |
| **SDK Components** | platform-tools, platforms;android-34, build-tools;34.0.0 ইন্সটল করে |
| **Env Variables** | `ANDROID_HOME` (Machine) ও `PATH` (User) অটো সেট করে |
| **License Manager** | `sdkmanager --licenses` রান করে — আপনি manually y/n দিতে পারেন |
| **Version Display** | শেষে `sdkmanager --version` ও `adb --version` দেখায় |
| **Admin Auto-Elevate** | নিজেই Administrator privilege নিয়ে নেয় |
| **Error Retry** | ভুল ইনপুট দিলে error দেখিয়ে exit না করে আবার ইনপুট চায় |

---

## How to Use

### Method 1: Run.bat (Recommended)
Simply double-click **`Run.bat`** — এটি automatically Admin privilege নিয়ে `Android_SDK.ps1` চালাবে।

### Method 2: PowerShell Direct
```powershell
Run.bat
```
অথবা PowerShell এ গিয়ে:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
```

---

## Input Types (Auto-Detect)

আপনি একটি single prompt এ যেকোনো একটা দিতে পারেন:

| Input Type | Example | Behaviour |
|---|---|---|
| **Online URL** | `https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip` | ডাউনলোড করবে (progress bar সহ) |
| **Directory Path** | `C:\Users\Zero\Downloads` | ফোল্ডার স্ক্যান করে `cmdline-tools*.zip` খুঁজে নিবে |
| **File Path** | `C:\Users\Zero\Downloads\cmdline-tools.zip` | সরাসরি ZIP ফাইল হিসেবে নিবে |

> একাধিক ZIP ফাইল পেলে আপনাকে কোনটা নিতে চান সেটি select করতে দেবে।

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
3. Run:
   ```cmd
   adb --version
   sdkmanager --list
   ```
4. Optional — accept licenses again if needed:
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
