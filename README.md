# Android SDK & ADB Installer

---

## 🇬🇧 English

An automated PowerShell script for Windows that downloads, extracts, and configures **Android SDK Command-line Tools**, **Platform-Tools (ADB)**, **SDK Platform**, and **Build-Tools** with a single command.

### Features

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

### How to Use

**Method 1: Run.bat (Recommended)** — Double-click `Run.bat` to auto-elevate and launch the script.

**Method 2: PowerShell Direct**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
```

### Input Types (Auto-Detect)

| Input Type | Example | Behaviour |
|---|---|---|
| **Online URL** | `https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip` | Downloads with progress bar |
| **Directory Path** | `C:\Users\%USERNAME%\Downloads` | Scans folder for `cmdline-tools*.zip` |
| **File Path** | `C:\Users\%USERNAME%\Downloads\cmdline-tools.zip` | Uses the ZIP file directly |

> If multiple ZIP files are found, you will be prompted to choose one.

### Installation Summary

| Component | Location |
|---|---|
| **Command-line Tools** | `C:\Android\cmdline-tools\latest\bin\` |
| **Platform-Tools (ADB)** | `C:\Android\platform-tools\` |
| **SDK Platform 34** | `C:\Android\platforms\android-34\` |
| **Build-Tools 34.0.0** | `C:\Android\build-tools\34.0.0\` |

**Environment Variables Set:**
- `ANDROID_HOME` → `C:\Android` (Machine)
- `PATH` → appends `cmdline-tools\latest\bin` and `platform-tools` (User)
- `JDK_JAVA_OPTIONS` → `--enable-native-access=ALL-UNNAMED` (Machine)

### After Installation

1. **CLOSE** the current window
2. Open a **NEW** Terminal / CMD window
3. Verify with: `adb --version` and `sdkmanager --list`
4. Accept licenses if needed: `sdkmanager --licenses`

### System Requirements

- **OS:** Windows 10 / Windows 11
- **PowerShell:** 5.1 or later
- **Internet:** Required for online download & SDK components
- **Java:** JDK 17+ recommended (for sdkmanager)

### Files

| File | Purpose |
|---|---|
| `Android_SDK.ps1` | Main PowerShell installer script |
| `Run.bat` | Batch launcher (auto admin + bypass policy) |
| `README.md` | This documentation |

---

## 🇧🇩 বাংলা

একটি সম্পূর্ণ PowerShell স্ক্রিপ্ট যা Windows-এ **Android SDK Command-line Tools**, **Platform-Tools (ADB)**, **SDK Platform** এবং **Build-Tools** অটোমেটিক্যালি ডাউনলোড, এক্সট্র্যাক্ট ও কনফিগার করে।

### বৈশিষ্ট্যসমূহ

| বৈশিষ্ট্য | বিবরণ |
|---|---|
| **ডুয়াল সোর্স ইনপুট** | ফোল্ডার পাথ বা অনলাইন URL — যা দিবেন অটো ডিটেক্ট করবে |
| **ডাউনলোড প্রোগ্রেস** | অনলাইন থেকে ডাউনলোড করলে MB ও পার্সেন্টেজ দেখাবে |
| **দ্রুত ক্লিনআপ** | `rmdir /s /q` দিয়ে পুরনো ফাইল দ্রুত ডিলিট করে |
| **অটো এক্সট্র্যাক্ট** | ZIP এক্সট্র্যাক্ট করে `cmdline-tools\latest\bin` স্ট্রাকচারে |
| **SDK কম্পোনেন্টস** | platform-tools, platforms;android-34, build-tools;34.0.0 ইন্সটল করে |
| **এনভায়রনমেন্ট ভেরিয়েবল** | `ANDROID_HOME` (Machine) ও `PATH` (User) অটো সেট করে |
| **লাইসেন্স ম্যানেজার** | `sdkmanager --licenses` রান করে — আপনি manually y/n দিতে পারেন |
| **ভার্সন দেখানো** | শেষে `sdkmanager --version` ও `adb --version` দেখায় |
| **অটো অ্যাডমিন** | নিজেই Administrator privilege নিয়ে নেয় |
| **এরর রিট্রাই** | ভুল ইনপুট দিলে error দেখিয়ে exit না করে আবার ইনপুট চায় |

### ব্যবহার বিধি

**পদ্ধতি ১: Run.bat (সুপারিশকৃত)** — `Run.bat` এ ডাবল-ক্লিক করুন, এটি নিজেই অ্যাডমিন প্রিভিলেজ নিয়ে `Android_SDK.ps1` চালাবে।

**পদ্ধতি ২: PowerShell ডাইরেক্ট**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
```

### ইনপুট টাইপ (অটো-ডিটেক্ট)

| ইনপুট টাইপ | উদাহরণ | আচরণ |
|---|---|---|
| **অনলাইন URL** | `https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip` | প্রোগ্রেস বার সহ ডাউনলোড করবে |
| **ডিরেক্টরি পাথ** | `C:\Users\%USERNAME%\Downloads` | ফোল্ডার স্ক্যান করে `cmdline-tools*.zip` খুঁজে নিবে |
| **ফাইল পাথ** | `C:\Users\%USERNAME%\Downloads\cmdline-tools.zip` | সরাসরি ZIP ফাইল হিসেবে নিবে |

> একাধিক ZIP ফাইল পেলে আপনি কোনটা নিতে চান সেটি সিলেক্ট করতে পারবেন।

### ইন্সটলেশন সারসংক্ষেপ

| কম্পোনেন্ট | লোকেশন |
|---|---|
| **কমান্ড-লাইন টুলস** | `C:\Android\cmdline-tools\latest\bin\` |
| **প্ল্যাটফর্ম-টুলস (ADB)** | `C:\Android\platform-tools\` |
| **SDK প্ল্যাটফর্ম 34** | `C:\Android\platforms\android-34\` |
| **বিল্ড-টুলস 34.0.0** | `C:\Android\build-tools\34.0.0\` |

**এনভায়রনমেন্ট ভেরিয়েবল সেট হয়:**
- `ANDROID_HOME` → `C:\Android` (Machine)
- `PATH` → `cmdline-tools\latest\bin` ও `platform-tools` যোগ হয় (User)
- `JDK_JAVA_OPTIONS` → `--enable-native-access=ALL-UNNAMED` (Machine)

### ইন্সটলের পরে

1. বর্তমান উইন্ডো **বন্ধ** করুন
2. একটি **নতুন** Terminal / CMD উইন্ডো খুলুন
3. ভেরিফাই করুন: `adb --version` এবং `sdkmanager --list`
4. লাইসেন্স একসেপ্ট করতে: `sdkmanager --licenses`

### সিস্টেম প্রয়োজনীয়তা

- **OS:** Windows 10 / Windows 11
- **PowerShell:** 5.1 বা তার পরের
- **ইন্টারনেট:** অনলাইন ডাউনলোড ও SDK কম্পোনেন্টস এর জন্য প্রয়োজন
- **Java:** JDK 17+ (sdkmanager এর জন্য সুপারিশকৃত)

### ফাইলসমূহ

| ফাইল | উদ্দেশ্য |
|---|---|
| `Android_SDK.ps1` | মূল PowerShell ইন্সটলার স্ক্রিপ্ট |
| `Run.bat` | ব্যাচ লঞ্চার (অটো অ্যাডমিন + বাইপাস পলিসি) |
| `README.md` | এই ডকুমেন্টেশন |

---

## License

This project is licensed under the **Apache License 2.0**.
