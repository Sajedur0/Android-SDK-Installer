# Android SDK ও Flutter ইনস্টলার (Windows)

Windows 10/11-এর জন্য একটি PowerShell ইনস্টলার। Android Studio ছাড়াই এটি JDK 17, Android SDK
(`C:\Android`) এবং Flutter (`C:\flutter`) সেট আপ করে। চাইলে একই ইনস্টলার Android Emulator ও একটি
রেডি-টু-বুট ভার্চুয়াল ডিভাইস (AVD) পর্যন্ত তৈরি করে দেয়।

ইংরেজি বিস্তারিত গাইড: [`README.md`](README.md)

---

## এক নজরে শুরু করুন

1. রিপোজিটরি ক্লোন করুন (অথবা ZIP ডাউনলোড করে খুলুন):

   ```powershell
   git clone https://github.com/Sajedur0/Android-SDK-Installer.git
   ```

2. ফোল্ডারের ভেতরে `Run.bat` ডাবল-ক্লিক করুন। PowerShell অ্যাডমিন অনুমতি (UAC) চাইলে **Yes** দিন।

3. মেনুতে `5` লিখে Enter চাপুন — এটি JDK, Android SDK, Flutter, Emulator এবং AVD একের পর এক
   ইনস্টল করবে। কাজ শেষ হলে **নতুন একটি টার্মিনাল** খুলে যাচাই করুন:

   ```powershell
   java -version
   adb version
   flutter doctor -v
   emulator -list-avds
   ```

> শুধু Android SDK চাইলে `1`, শুধু Flutter চাইলে `2`, আর Emulator চাইলে `4` চাপুন।
> কিছুই না ইনস্টল করে শুধু অবস্থা দেখতে চাইলে `3` চাপুন (এটি read-only)।

---

## মেনু

| অপশন | কাজ |
|---|---|
| **1** | Java (Temurin JDK 17) + Android SDK ইনস্টল |
| **2** | Flutter SDK ইনস্টল (সর্বশেষ stable স্বয়ংক্রিয় ডাউনলোড, অথবা নিজের ZIP/ফোল্ডার/URL) |
| **3** | এনভায়রনমেন্ট ভেরিয়েবল, PATH, SDK প্যাকেজ, Emulator ও AVD পরীক্ষা (কিছু বদলায় না) |
| **4** | Android Emulator + system image + একটি AVD তৈরি (ঐচ্ছিক, প্রায় ৪ GB) |
| **5** | সব একসাথে: 1 + 2 + 4 |
| **0** | বেরিয়ে যান |

মেনুর নিচে একটি স্ট্যাটাস লাইন থাকে, যেমন:

```
Status: Java 17 OK | SDK 36 OK | Flutter OK | Emulator OK | 1 AVD(s)
```

কোন ধাপে সমস্যা হলে সেই সেশন শেষে `0` চাপলে ইনস্টলার exit code `1` দিয়ে শেষ হয়, যাতে
`Run.bat` বা CI বুঝতে পারে কাজ সফল হয়নি।

---

## অপশন ১ — Java + Android SDK

1. **JDK** — Gradle ও Android Gradle Plugin যে রেঞ্জ সমর্থন করে (JDK 17–21) সেখান থেকে সবচেয়ে
   পুরোনোটি বেছে নেয়। কিছু না থাকলে Temurin JDK 17 স্বয়ংক্রিয়ভাবে ইনস্টল হয় এবং `JAVA_HOME`
   হয়। ইতিমধ্যে থাকা নতুন JDK (22+) মুছে ফেলা হয় না, শুধু `JAVA_HOME` হিসেবে ব্যবহার করা হয় না।
2. **Command-line tools** — Google-এর সর্বশেষ build ডাউনলোড করে
   `<SDK>\cmdline-tools\latest`-এ বসায়। একই build আগে থেকে থাকলে ডাউনলোড, staging ও backup
   পুরোপুরি বাদ পড়ে। আগের `latest` ফোল্ডার
   `%ProgramData%\Android-SDK-Installer\backups`-এ চলে যায় (SDK-এর বাইরে, যাতে package manager
   সেগুলোকে প্যাকেজ হিসেবে না ধরে), সর্বশেষ ৩টি backup রাখা হয়।
3. **SDK প্যাকেজ** — ডাউনলোডের আগে TEMP ও SDK ড্রাইভে ফাঁকা জায়গা যাচাই হয়। তারপর একবার
   জিজ্ঞেস করা হয় Android SDK লাইসেন্সগুলো গ্রহণ করবেন কি না:
   - `Y` (বা শুধু Enter) → সব প্রম্পটে আপনার পক্ষে `y` দেওয়া হয়।
   - `N` → প্রম্পটগুলো দেখানো হয়, আপনি নিজে প্রতিটিতে `y` লিখবেন।
   - কোনো অবস্থাতেই আপনার অনুমতি ছাড়া লাইসেন্স গ্রহণ করা হয় না।

   এরপর `platform-tools`, Android Platform 36 (অথবা `-ApiLevel` যা দিয়েছেন), তার সাথে মিলে যাওয়া
   Build Tools, এবং NDK ও CMake ইনস্টল হয়। যা আগে থেকে আছে তা বাদ পড়ে, তাই দ্বিতীয়বার চালালে
   ডাউনলোড প্রায় কিছুই হয় না। CMake ডিফল্টভাবে 3.x লাইন থেকে নেওয়া হয়, কারণ CMake 4 পুরোনো
   `cmake_minimum_required(VERSION 3.4.1)` সমর্থন করে না।
4. **এনভায়রনমেন্ট** — `JAVA_HOME`, `ANDROID_HOME`, `ANDROID_SDK_ROOT`, সম্পূর্ণ NDK থাকলে
   `ANDROID_NDK_HOME`, এবং Machine `PATH`-এ JDK-এর `bin`, `cmdline-tools\latest\bin`,
   `platform-tools`, সর্বশেষ `build-tools` ও CMake-এর `bin` যোগ হয়। `emulator` ফোল্ডার নিজে থেকে
   কখনো যোগ হয় না — সেটি অপশন ৪ করে।

শেষে প্রতিটি প্যাকেজ তার আসল ফাইল দিয়ে যাচাই করা হয় (`adb.exe`, `android.jar`, `aapt2.exe`,
`source.properties`, `cmake.exe`)। ফোল্ডার আছে কিন্তু ফাইল নেই — এমন অসম্পূর্ণ প্যাকেজকে
"ইনস্টল হয়েছে" বলে দেখানো হয় না।

---

## অপশন ২ — Flutter

1. JDK 17+ এবং Git for Windows আছে কি না দেখা হয়; না থাকলে ইনস্টল করার প্রস্তাব দেয়
   (`winget` থাকলে সেটি, নাহলে Adoptium/GitHub থেকে সরাসরি ডাউনলোড)। Enter চাপলেই ইনস্টল হয়ে যায়,
   কারণ Flutter এই দুটো ছাড়া চলে না।
2. এরপর জিজ্ঞেস করবে — **সর্বশেষ stable Flutter স্বয়ংক্রিয়ভাবে ডাউনলোড করবেন?** Enter চাপলে
   Flutter-এর অফিসিয়াল `releases_windows.json` থেকে version, archive URL ও প্রকাশিত SHA-256 নিয়ে
   ডাউনলোড হবে (তথ্য ৬ ঘণ্টা ক্যাশ থাকে)। `N` দিলে একটি Flutter ZIP, আগে থেকে খোলা Flutter ফোল্ডার,
   অথবা সরাসরি ডাউনলোড URL দিতে পারবেন।
3. নতুন Flutter বসানোর আগে পুরোনোটি timestamped backup হিসেবে `C:\flutter.backup-...`-এ রাখা হয়।
   স্বয়ংক্রিয় ডাউনলোড প্রকাশিত SHA-256 দিয়ে যাচাই করা হয়। আপনার দেওয়া ZIP ফাইল মুছে ফেলা হয় না।
4. `FLUTTER_ROOT` সেট হয়, `C:\flutter\bin` Machine `PATH`-এ যোগ হয়, Android SDK থাকলে
   Flutter-কে সেটির সাথে যুক্ত করা হয় এবং `flutter doctor -v` চালানো হয়।

প্রথমবার `flutter --version` চালালে Dart SDK ও engine artifact ডাউনলোড হয় — ইনস্টলার আগেই
জায়গা যাচাই করে।

---

## অপশন ৩ — এনভায়রনমেন্ট চেক

কিছুই ইনস্টল বা পরিবর্তন করে না। দেখায়:

- `JAVA_HOME`, `java.exe`/`javac.exe`, এবং PATH-এ কোথায় আছে
- Python (শুধু পরীক্ষা — ইনস্টলার Python ইনস্টল করে না)
- `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `adb`, `sdkmanager`/`android.exe`, লাইসেন্স ফাইল
- platform-tools, Platform, Build Tools, NDK, CMake-এর উপস্থিতি ও অসম্পূর্ণ ফোল্ডার
- Emulator, system image, AVD তালিকা এবং Emulator PATH-এ আছে কি না
- `FLUTTER_ROOT`, `flutter.bat`, PATH
- যেকোনো ঘাটতির জন্য ঠিক যে কমান্ডটি চালাতে হবে

---

## অপশন ৪ — Emulator ও AVD

1. SDK root ও JDK খুঁজে নেয়।
2. হোস্ট CPU অনুযায়ী system image বাছে: Intel/AMD-তে
   `system-images;android-36;google_apis;x86_64`, Windows on ARM-এ `...;arm64-v8a`।
   `-SystemImage` বা `ANDROID_SDK_INSTALLER_SYSTEM_IMAGE` দিয়ে অন্য image বেছে নেওয়া যায়।
3. প্রায় ৪ GB ফাঁকা জায়গা যাচাই করে, লাইসেন্সের একই প্রশ্ন করে, তারপর `platform-tools`,
   `emulator` ও system image ইনস্টল করে (আগে থেকে থাকলে বাদ)।
4. `emulator.exe` ও `system.img` ফাইল দিয়ে যাচাই করে।
5. জিজ্ঞেস করে `<SDK>\emulator` Machine `PATH`-এ যোগ করবে কি না — এখানে ডিফল্ট **Y**, কারণ আপনি
   নিজেই Emulator বেছেছেন। `N` দিলে PATH অপরিবর্তিত থাকে।
6. `avdmanager` দিয়ে signed-in ব্যবহারকারীর প্রোফাইলে AVD তৈরি করে (UAC-তে অন্য অ্যাডমিন
   অ্যাকাউন্ট ব্যবহার করলেও আপনার প্রোফাইলেই), সম্ভব হলে Pixel device profile দিয়ে।
   ডিফল্ট নাম `Pixel_Api36`; `-AvdName` দিয়ে বদলানো যায়।
7. `emulator -accel-check` চালিয়ে হার্ডওয়্যার acceleration (WHPX/Hyper-V বা AEHD) আছে কি না
   জানায়। না থাকলে শুধু সতর্কতা দেখায় — ইনস্টল ব্যর্থ হয় না।

শেষে চালানোর কমান্ড দেখানো হয়, যেমন:

```powershell
emulator -avd Pixel_Api36
```

গতি বাড়াতে Windows-এ **Windows Hypervisor Platform** চালু করুন (Turn Windows features on or off →
Windows Hypervisor Platform), অথবা AMD/Intel-এর জন্য AEHD ইনস্টল করুন, তারপর রিস্টার্ট দিন।

---

## অপশন ৫ — সব একসাথে

`1 → 2 → 4` ক্রমে চলে। কোনো ধাপ ব্যর্থ হলে সেটি লাল রঙে জানিয়ে **বাকি ধাপগুলো চালিয়ে যায়**, যাতে
একটি সমস্যা (যেমন লাইসেন্স আটকে যাওয়া বা নেটওয়ার্কের ঝামেলা) অন্য টুলগুলো ইনস্টল হতে বাধা না দেয়।
শেষে প্রতিটি ধাপের সফল/ব্যর্থ তালিকা দেখায়। কোনো ধাপ ব্যর্থ হলে exit code `1` হয়।

---

## যা যা ইনস্টল হয়

| উপাদান | স্থান / উৎস | প্রয়োজন |
|---|---|---|
| Eclipse Temurin JDK 17 | `C:\Program Files\Eclipse Adoptium` (winget বা Adoptium) | হ্যাঁ |
| Android command-line tools | `C:\Android\cmdline-tools\latest` | হ্যাঁ |
| platform-tools (`adb`) | `C:\Android\platform-tools` | হ্যাঁ |
| Android Platform 36 | `C:\Android\platforms\android-36` | হ্যাঁ |
| Build Tools | `C:\Android\build-tools\<version>` | হ্যাঁ |
| NDK | `C:\Android\ndk\<version>` | না (নেটিভ কোডের জন্য) |
| CMake 3.x | `C:\Android\cmake\<version>` | না |
| Flutter | `C:\flutter` | অপশন ২/৫ |
| Git for Windows | সিস্টেমে | Flutter-এর জন্য দরকার হলে |
| Android Emulator + system image + AVD | `C:\Android\emulator`, `C:\Android\system-images`, `%USERPROFILE%\.android\avd` | না (অপশন ৪/৫) |

Python ইনস্টল করা হয় না; শুধু আছে কি না দেখা হয়।

---

## সিস্টেম চাহিদা

- Windows 10 অথবা 11; Windows PowerShell 5.1+ (PowerShell 7-ও চলে — elevation হলে ইনস্টলার
  নিজেই Windows PowerShell 5.1 হোস্ট ব্যবহার করে)।
- Administrator অনুমতি (Machine PATH ও `C:\`-এ ইনস্টল করার জন্য)।
- ইন্টারনেট। `winget` থাকলে JDK/Git-এর জন্য সেটি, নাহলে Adoptium/GitHub থেকে ডাউনলোড।
- ফাঁকা জায়গা: Flutter-এর ZIP প্রায় ১ GB (খোলার পর আরও বেশি), SDK + NDK + Flutter মিলিয়ে
  কয়েক GB; Emulator ও একটি system image যোগ করলে আরও ৩–৪ GB। প্রতি বড় ডাউনলোডের আগে ইনস্টলার
  জায়গা যাচাই করে এবং কম হলে আগেই থেমে বলে দেয় কত দরকার।
- Emulator দ্রুত চালাতে hardware virtualization (WHPX/Hyper-V বা AEHD)।

---

## এনভায়রনমেন্ট ভেরিয়েবল

ইনস্টলার Machine scope-এ এগুলো সেট করে:

| ভেরিয়েবল | মান | কাজ |
|---|---|---|
| `JAVA_HOME` | ধরা পড়া/ইনস্টল করা JDK | Gradle ও Android build |
| `ANDROID_HOME` | `C:\Android` (বা আপনি দেওয়া SDK root) | সব Android টুল |
| `ANDROID_SDK_ROOT` | `ANDROID_HOME`-এর সমান | পুরোনো টুলের compatibility |
| `ANDROID_NDK_HOME` | সম্পূর্ণ NDK থাকলে তার ফোল্ডার, নাহলে মুছে যায় | নেটিভ build |
| `FLUTTER_ROOT` | `C:\flutter` (বা `-FlutterRoot`) | Flutter SDK |
| `PATH` | JDK `bin`, command-line tools, platform-tools, build-tools, CMake `bin`, Flutter `bin`, চাইলে Emulator | টার্মিনাল থেকে কমান্ড চালানো |

PATH পরিবর্তনের পর **নতুন টার্মিনাল** খুলুন, নাহলে পুরোনো টার্মিনালে নতুন এন্ট্রি দেখা যাবে না।

---

## আনঅ্যাটেনডেড (স্ক্রিপ্ট/CI) ব্যবহার

পাঁচটি প্যারামিটার আছে; বাকি সব আচরণ environment variable দিয়েও নিয়ন্ত্রণ করা যায়:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Android_SDK.ps1 `
  -SdkRoot D:\Android -ApiLevel 36 -FlutterRoot D:\flutter `
  -AvdName Pixel_Api36 -SystemImage "system-images;android-36;google_apis;x86_64"
```

| প্যারামিটার / variable | কাজ |
|---|---|
| `-SdkRoot <path>` | SDK অন্য জায়গায় বসায় |
| `-ApiLevel <n>` | Platform, Build Tools ও ডিফল্ট system image-এর API level (ডিফল্ট 36) |
| `-FlutterRoot <path>` | Flutter অন্য জায়গায় বসায় |
| `-AvdName <name>` | AVD-এর নাম |
| `-SystemImage <id>` | নির্দিষ্ট system image package id |
| `ANDROID_SDK_INSTALLER_ACCEPT_LICENSES=Y` | আনঅ্যাটেনডেড রানে লাইসেন্স প্রম্পটের উত্তর দিতে **অবশ্যই** দরকার। এটি ছাড়া ইনস্টলার আপনার পক্ষে লাইসেন্স গ্রহণ করে না |
| `ANDROID_SDK_INSTALLER_CHOICE` | মেনু না দেখিয়ে সরাসরি `1`, `2`, `3`, `4` বা `5` চালায় |
| `ANDROID_SDK_INSTALLER_INSTALL_JDK=1` | আনঅ্যাটেনডেড রানে JDK 17–21 না থাকলে Temurin ইনস্টল করার সম্মতি |
| `ANDROID_SDK_INSTALLER_INSTALL_GIT=1` | আনঅ্যাটেনডেড রানে Git না থাকলে Git for Windows ইনস্টল করার সম্মতি |
| `ANDROID_SDK_INSTALLER_FLUTTER_SOURCE` | অপশন ২-এর জন্য ZIP/ফোল্ডার/URL |
| `ANDROID_SDK_INSTALLER_FLUTTER_DOWNLOAD=1` | আনঅ্যাটেনডেড রানে সর্বশেষ stable Flutter নিজে থেকেই ডাউনলোড করে (লোকাল ZIP লাগে না)। `N` দিলে লোকাল সোর্স বাধ্যতামূলক |
| `ANDROID_SDK_INSTALLER_FLUTTER_ROOT` | `-FlutterRoot`-এর সমান |
| `ANDROID_SDK_INSTALLER_AVD_NAME` | `-AvdName`-এর সমান |
| `ANDROID_SDK_INSTALLER_SYSTEM_IMAGE` | `-SystemImage`-এর সমান |
| `ANDROID_SDK_INSTALLER_EMULATOR_PATH=Y` / `N` | অপশন ৪-এ Emulator PATH-এ যোগ করবে কি না; না দিলে আনঅ্যাটেনডেড রানে PATH বদলায় না |
| `ANDROID_SDK_INSTALLER_NO_AVD=1` | Emulator ইনস্টল করবে কিন্তু AVD তৈরি করবে না |
| `ANDROID_SDK_INSTALLER_NO_PROGRESS=1` | ইনলাইন প্রোগ্রেস বারের বদলে PowerShell-এর নিজস্ব বার |
| `ANDROID_SDK_INSTALLER_NO_CACHE=1` | ক্যাশ করা package catalog ও command-line tools build ব্যবহার করবে না |
| `ANDROID_SDK_INSTALLER_CMDLINE_TOOLS_BUILD` | নির্দিষ্ট command-line tools build পিন করে |
| `ANDROID_SDK_INSTALLER_CMAKE_MAJOR` | CMake-এর major version (ডিফল্ট 3) |

উদাহরণ — পুরো টুলচেইন নীরবে ইনস্টল:

```powershell
$env:ANDROID_SDK_INSTALLER_CHOICE = '5'
$env:ANDROID_SDK_INSTALLER_ACCEPT_LICENSES = 'Y'
$env:ANDROID_SDK_INSTALLER_FLUTTER_DOWNLOAD = '1'
$env:ANDROID_SDK_INSTALLER_EMULATOR_PATH = 'N'
powershell -NoProfile -ExecutionPolicy Bypass -File .\Android_SDK.ps1
```

> `ANDROID_SDK_INSTALLER_ACCEPT_LICENSES=Y` শুধু তখনই দিন, যখন আপনি সত্যিই Google-এর Android SDK
> লাইসেন্স শর্তগুলোতে সম্মত। ইনস্টলার নিজে থেকে কারো পক্ষে লাইসেন্স গ্রহণ করে না।

---

## যাচাই

নতুন PowerShell/Command Prompt খুলে চালান:

```powershell
java -version
git --version
adb version
flutter --version
flutter doctor -v
emulator -list-avds
```

Android SDK প্যাকেজের তালিকা:

```powershell
sdkmanager --list
# অথবা নতুন Android CLI থাকলে:
android sdk list
```

`emulator` কমান্ড না পাওয়া গেলে অপশন ৪ আবার চালিয়ে PATH-এ যোগ করুন, অথবা পূর্ণ পথ ব্যবহার করুন:
`C:\Android\emulator\emulator.exe -avd Pixel_Api36`

---

## সাধারণ সমস্যা ও সমাধান

**UAC অনুমতি বাতিল হয়েছে** — ইনস্টলার Machine PATH ও `C:\`-এ লিখতে পারে না। `Run.bat` আবার চালিয়ে
**Yes** দিন। বাতিল করলে exit code `1` হয়।

**`winget` পাওয়া যায়নি** — সমস্যা নেই; ইনস্টলার Adoptium (JDK) ও GitHub (Git) থেকে সরাসরি
ডাউনলোড করে এবং SHA-256 যাচাই করে।

**Flutter-এর স্বয়ংক্রিয় ডাউনলোড ব্যর্থ** — ইন্টারনেট/প্রক্সি সমস্যা বা Flutter-এর release list
পাওয়া যাচ্ছে না। অপশন ২ আবার চালিয়ে `N` দিন, তারপর Flutter-এর ZIP/ফোল্ডার/URL দিন, অথবা
`ANDROID_SDK_INSTALLER_FLUTTER_SOURCE` সেট করুন।

**লাইসেন্স সংক্রান্ত ব্যর্থতা** — অপশন ১ আবার চালিয়ে `Y` দিন, অথবা নিজে চালান:
`sdkmanager --sdk_root=C:\Android --licenses`। অসম্পূর্ণ প্যাকেজ ফোল্ডার থাকলে (অপশন ৩ দেখায়)
সেগুলো মুছে আবার চেষ্টা করুন।

**কমান্ড পাওয়া যাচ্ছে না (`adb`, `flutter`, `emulator`)** — নতুন টার্মিনাল খুলুন। তবু না হলে
অপশন ৩ দেখুন; PATH-এ এন্ট্রি নেই বলে দেবে। `emulator` শুধু অপশন ৪-এ যোগ হয়।

**`ANDROID_HOME` আগে থেকেই অন্য SDK-তে পয়েন্ট করছে** — ইনস্টলার সেটিকেই ব্যবহার করে এবং
জিজ্ঞেস করে। জোর করে `C:\Android`-এ বসাতে চাইলে `-SdkRoot C:\Android` দিন।

**জায়গা কম** — `-SdkRoot` দিয়ে বড় ড্রাইভে SDK বসান। ইনস্টলার আগেই বলে দেবে কত জায়গা দরকার।
পুরোনো `C:\flutter.backup-*` ফোল্ডার ও
`%ProgramData%\Android-SDK-Installer\backups`-এর পুরোনো backup মুছে জায়গা খালি করা যায়।

**Emulator খুব ধীর / `accel-check` ব্যর্থ** — BIOS/UEFI-তে virtualization চালু করুন, Windows
feature-এ **Windows Hypervisor Platform** টিক দিন, অথবা AEHD ইনস্টল করুন; তারপর রিস্টার্ট দিন।

**প্রগ্রেস বার দেখা যাচ্ছে না** — PowerShell ISE বা redirected আউটপুটে ইনলাইন বার কাজ করে না;
সেক্ষেত্রে PowerShell-এর নিজস্ব progress bar দেখায়। চাইলে
`ANDROID_SDK_INSTALLER_NO_PROGRESS=1` দিন।

---

## ডেভেলপারদের জন্য

টেস্ট চালানো (কিছুই ইনস্টল করে না):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Progress.Tests.ps1
pwsh -NoProfile -File tests/Progress.Tests.ps1
```

প্রোগ্রেস বার না ডাউনলোড করে দেখতে:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Progress.Demo.ps1
```

GitHub Actions (`.github/workflows/ci.yml`) প্রতিটি push/PR-এ Windows-এ PowerShell 5.1 ও 7
দিয়ে সব স্ক্রিপ্ট parse করে, টেস্ট চালায় এবং PSScriptAnalyzer দিয়ে lint করে।

---

## ফাইল তালিকা

| ফাইল | কাজ |
|---|---|
| `Android_SDK.ps1` | মূল ইনস্টলার ও মেনু |
| `Run.bat` | লঞ্চার; PowerShell নিজেই UAC elevation করে |
| `tests/Progress.Tests.ps1` | হেল্পার ও regression টেস্ট (Windows PowerShell 5.1 ও 7) |
| `tests/Progress.Demo.ps1` | ডাউনলোড ছাড়া প্রোগ্রেস বারের ডেমো |
| `.github/workflows/ci.yml` | Windows CI |
| `README.md` | ইংরেজি বিস্তারিত গাইড |
| `README.bn.md` | এই বাংলা গাইড |
| `LICENSE` | Apache License 2.0 |
| `NOTICE` | কপিরাইট ও তৃতীয় পক্ষের লাইসেন্স তথ্য |

---

## লাইসেন্স

Apache License 2.0 — পূর্ণ টেক্সট [`LICENSE`](LICENSE)-এ। ইনস্টলার যে JDK, Android SDK, Flutter ও
Git ডাউনলোড করে সেগুলোর নিজস্ব লাইসেন্স আছে ([`NOTICE`](NOTICE)-এ উল্লেখ করা); এই রিপোজিটরির
লাইসেন্স সেগুলোর উপর কোনো অধিকার দেয় না। Android SDK লাইসেন্স গ্রহণ সবসময় আপনার নিজের সিদ্ধান্ত —
ইনস্টলার আলাদা অনুমতি ছাড়া তা করে না।
