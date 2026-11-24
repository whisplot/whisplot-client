# Whisplot client

This directory contains the shared Flutter client for Android, iOS, macOS, and Windows. For installation and everyday use, read the [English user manual](../../README.md) or [中文使用说明](../../README.zh-CN.md).

The service is maintained separately. This public client repository does not include service-side source or deployment instructions. To run the app, obtain a trusted HTTPS service address and access code from your administrator.

## Client development

Use Flutter 3.50.0 / Dart 3.14.0 and the locked dependencies. Android builds require an Android SDK and JDK 21. iOS builds require macOS and Xcode; installing on a phone also requires Apple signing and provisioning.

From this directory:

```sh
../../scripts/flutter.sh pub get
../../scripts/flutter.sh analyze
../../scripts/flutter.sh test
../../scripts/flutter.sh run
```

For development, pass `--dart-define=WHISPLOT_SHOW_CONNECTION_SETTINGS=true` to enable the test service form. To configure automatic connection for a local build, use a private, untracked JSON file with `DEFAULT_API_BASE_URL` and `DEFAULT_REGISTRATION_CODE`, and pass its absolute path with `--dart-define-from-file`.

Build an Android ARM64 preview:

```sh
../../scripts/flutter.sh build apk --release --target-platform android-arm64 --split-per-abi
```

The current project uses a test signing key. Configure your own signing before long-term distribution, and retain it for compatible app updates.

Build an unsigned iPhoneOS app:

```sh
../../scripts/flutter.sh build ios --release --no-codesign
```

An unsigned build is not directly installable on an iPhone. Current preview builds do not include push-notification configuration. See the [client guide](../../docs/client-guide.md) for behavior and limitations.

## Windows desktop

Use Flutter 3.50.0 and Visual Studio with the Desktop development with C++ workload and the C++ ATL component for x86 and x64. Run `flutter doctor -v` to check the compiler, CMake, and Windows SDK. Build from a short workspace path so the native plugin project files fit within Windows path limits. From this directory, run:

```powershell
flutter pub get
flutter run -d windows
..\..\scripts\package-windows.ps1
```

Extract the complete ZIP and start `Whisplot.exe` from the extracted folder. Official packages connect to the Whisplot service automatically. Keep the current user's application data and secure storage when updating. While Whisplot runs, use **Settings → Message notifications** to enable Windows taskbar notifications.

Keep the repository's public `fixtures/` test data available when running tests. Several client tests read it using paths relative to this directory. These fixtures contain fixed test vectors.
