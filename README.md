# Android SDK & ADB Installer

### Set up Android SDK on Windows — Without Installing Android Studio

---

## 🇬🇧 English

### What is this?

A PowerShell script that **automatically installs and configures the Android SDK** on Windows **without needing Android Studio**. Just provide the cmdline-tools ZIP (from a local folder or direct download link), and the script handles everything — extraction, installing platform-tools, setting environment variables, and accepting licenses.

### Why would I need this?

- You want to use **Flutter**, **React Native**, **Cordova**, or other frameworks that require Android SDK
- You don't want to install the full Android Studio (2+ GB) just for the SDK
- You need **ADB (Android Debug Bridge)** for debugging or managing Android devices
- You want a **clean, minimal SDK setup** without extra clutter
- You need to **quickly set up or reset** the SDK on a new machine

### What does this script do?

| Step | What happens |
|---|---|
| 1. Input | You provide a **folder path** or **download URL** for cmdline-tools |
| 2. Cleanup | Removes any previous `C:\Android` folder (fast) |
| 3. Extract | Extracts the ZIP into `cmdline-tools\latest\bin` |
| 4. SDK Install | Runs `sdkmanager` to install **platform-tools**, **platforms;android-34**, **build-tools;34.0.0** |
| 5. Env Variables | Sets `ANDROID_HOME` (Machine) and updates `PATH` (User) |
| 6. Licenses | Runs `sdkmanager --licenses` — you accept manually with y/n |
| 7. Verify | Shows `sdkmanager --version` and `adb --version` |

### What gets installed to `C:\Android`?

```
C:\Android\
├── cmdline-tools\latest\bin\     ← sdkmanager, avdmanager, etc.
├── platform-tools\               ← adb, fastboot
├── platforms\android-34\         ← Android SDK Platform 34
└── build-tools\34.0.0\           ← aapt, dx, zipalign, etc.
```

### Environment Variables (set automatically)

| Variable | Value | Scope | Purpose |
|---|---|---|---|
| `ANDROID_HOME` | `C:\Android` | Machine | Tells tools where the SDK is |
| `PATH` (append) | `C:\Android\cmdline-tools\latest\bin` | User | Run `sdkmanager` from anywhere |
| `PATH` (append) | `C:\Android\platform-tools` | User | Run `adb` from anywhere |
| `JDK_JAVA_OPTIONS` | `--enable-native-access=ALL-UNNAMED` | Machine | Suppress Java warnings |

### How to use

**Step 1 — Get the cmdline-tools ZIP**

- **Option A (Online):** Get the latest URL from [Android Studio Download Page](https://developer.android.com/studio#command-line-tools-only) (look for "Command line tools only")
- **Option B (Offline):** If you already downloaded the ZIP, note its folder path

**Step 2 — Run the installer**

Double-click **`Run.bat`** (recommended) or run in PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
```

**Step 3 — Provide input**

```
Enter Directory Address (folder path) OR Online Direct File Link (URL):
Example: C:\Users\%USERNAME%\Downloads   or   https://dl.google.com/...

Address / URL:
```

Give any one of these:

| Input Type | Example |
|---|---|
| Online URL | `https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip` |
| Directory (auto-scan) | `C:\Users\%USERNAME%\Downloads` |
| File path (direct) | `C:\Users\%USERNAME%\Downloads\cmdline-tools.zip` |

**Step 4 — Accept licenses**

When prompted, type `y` + Enter for each license shown.

**Step 5 — Done!**

Close the window and open a new Terminal. Run `adb --version` and `sdkmanager --list` to verify.

### System Requirements

- **OS:** Windows 10 / Windows 11
- **PowerShell:** 5.1 or later
- **Internet:** Needed for online download + SDK packages
- **Java:** JDK 17+ (sdkmanager requires Java)

### Files

| File | Purpose |
|---|---|
| `Android_SDK.ps1` | Main PowerShell installer |
| `Run.bat` | Double-click launcher (auto admin + bypass policy) |
| `README.md` | This documentation |

---

## 🇧🇩 বাংলা

### এটা কী?

একটি PowerShell স্ক্রিপ্ট যা **Android Studio ছাড়াই Windows-এ Android SDK সম্পূর্ণরূপে ইনস্টল ও কনফিগার করে**। আপনি শুধু cmdline-tools-এর ZIP ফাইলটির লোকেশন বা ডাউনলোড লিংক দিবেন, বাকি সব — এক্সট্র্যাক্ট করা, platform-tools ইনস্টল করা, এনভায়রনমেন্ট ভেরিয়েবল সেট করা, লাইসেন্স অ্যাকসেপ্ট করা — স্ক্রিপ্ট নিজেই করে ফেলে।

### কেন দরকার?

- **Flutter**, **React Native**, **Cordova** ইত্যাদি ফ্রেমওয়ার্ক ব্যবহার করতে Android SDK লাগে
- শুধুমাত্র SDK-এর জন্য **পুরো Android Studio (২+ GB)** ইনস্টল করতে চান না
- Android ডিভাইস ম্যানেজ বা ডিবাগ করতে **ADB** দরকার
- একটি **পরিষ্কার ও মিনিমাল SDK সেটআপ** চান
- নতুন কম্পিউটারে **দ্রুত SDK সেটআপ** করতে চান

### স্ক্রিপ্টটি কী কী করে?

| ধাপ | কী হয় |
|---|---|
| ১. ইনপুট | আপনি cmdline-tools-এর **ফোল্ডার পাথ** বা **ডাউনলোড URL** দেন |
| ২. ক্লিনআপ | আগের `C:\Android` ফোল্ডার থাকলে দ্রুত ডিলিট করে |
| ৩. এক্সট্র্যাক্ট | ZIP ফাইলকে `cmdline-tools\latest\bin` স্ট্রাকচারে এক্সট্র্যাক্ট করে |
| ৪. SDK ইনস্টল | `sdkmanager` দিয়ে **platform-tools**, **platforms;android-34**, **build-tools;34.0.0** ইনস্টল করে |
| ৫. এনভায়রনমেন্ট | `ANDROID_HOME` (Machine) সেট করে এবং `PATH` (User) আপডেট করে |
| ৬. লাইসেন্স | `sdkmanager --licenses` রান করে — আপনি manually y/n দেন |
| ৭. ভেরিফাই | শেষে `sdkmanager --version` ও `adb --version` দেখায় |

### `C:\Android`-এ কী কী ইনস্টল হয়?

```
C:\Android\
├── cmdline-tools\latest\bin\     ← sdkmanager, avdmanager, ইত্যাদি
├── platform-tools\               ← adb, fastboot
├── platforms\android-34\         ← Android SDK Platform 34
└── build-tools\34.0.0\           ← aapt, dx, zipalign, ইত্যাদি
```

### এনভায়রনমেন্ট ভেরিয়েবল (অটো সেট হয়)

| ভেরিয়েবল | ভ্যালু | স্কোপ | উদ্দেশ্য |
|---|---|---|---|
| `ANDROID_HOME` | `C:\Android` | Machine | টুলসকে SDK-এর লোকেশন জানায় |
| `PATH` (যোগ) | `C:\Android\cmdline-tools\latest\bin` | User | যেকোনো জায়গা থেকে `sdkmanager` চালানো |
| `PATH` (যোগ) | `C:\Android\platform-tools` | User | যেকোনো জায়গা থেকে `adb` চালানো |
| `JDK_JAVA_OPTIONS` | `--enable-native-access=ALL-UNNAMED` | Machine | Java ওয়ার্নিং বন্ধ করে |

### ব্যবহার বিধি

**ধাপ ১ — cmdline-tools-এর ZIP সংগ্রহ করুন**

- **অনলাইন:** [Android Studio Download Page](https://developer.android.com/studio#command-line-tools-only) থেকে লেটেস্ট লিংক নিন ("Command line tools only" সেকশন)
- **অফলাইন:** আগে থেকে ডাউনলোড করা থাকলে ফোল্ডার পাথ নোট করে রাখুন

**ধাপ ২ — ইন্সটলার রান করুন**

`Run.bat`-এ **ডাবল-ক্লিক** করুন (সুপারিশকৃত) অথবা PowerShell-এ রান করুন:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "Android_SDK.ps1"
```

**ধাপ ৩ — ইনপুট দিন**

```
Enter Directory Address (folder path) OR Online Direct File Link (URL):
Example: C:\Users\%USERNAME%\Downloads   or   https://dl.google.com/...

Address / URL:
```

নিচের যেকোনো একটি দিন:

| ইনপুট টাইপ | উদাহরণ |
|---|---|
| অনলাইন URL | `https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip` |
| ডিরেক্টরি (অটো-স্ক্যান) | `C:\Users\%USERNAME%\Downloads` |
| ফাইল পাথ (সরাসরি) | `C:\Users\%USERNAME%\Downloads\cmdline-tools.zip` |

**ধাপ ৪ — লাইসেন্স অ্যাকসেপ্ট করুন**

প্রতিটি লাইসেন্সের জন্য `y` + Enter দিন।

**ধাপ ৫ — শেষ!**

উইন্ডো বন্ধ করে নতুন Terminal খুলুন। `adb --version` এবং `sdkmanager --list` দিয়ে ভেরিফাই করুন।

### সিস্টেম প্রয়োজনীয়তা

- **OS:** Windows 10 / Windows 11
- **PowerShell:** 5.1 বা তার পরের
- **ইন্টারনেট:** অনলাইন ডাউনলোড ও SDK প্যাকেজের জন্য প্রয়োজন
- **Java:** JDK 17+ (sdkmanager চালানোর জন্য)

### ফাইলসমূহ

| ফাইল | উদ্দেশ্য |
|---|---|
| `Android_SDK.ps1` | মূল PowerShell ইন্সটলার স্ক্রিপ্ট |
| `Run.bat` | ডাবল-ক্লিক লঞ্চার (অটো অ্যাডমিন + বাইপাস পলিসি) |
| `README.md` | এই ডকুমেন্টেশন |

---

## License

**Apache License 2.0**
