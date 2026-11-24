# Whisplot for Mac

[English user manual](../README.md) · [中文使用说明](../README.zh-CN.md) · [0.1.0 release](https://github.com/whisplot/whisplot-client/releases/tag/v0.1.0)

Whisplot 0.1.0 supports macOS 12 or later. The ZIP includes Apple silicon and Intel executables.

## Install and update

1. Download the Mac ZIP from the [Whisplot downloads page](https://whisplot-downloads.pages.dev/).
2. Quit the existing app, unzip, and move the whole **Whisplot.app** into Applications. Keep the complete bundle, including its nested components.
3. Open Whisplot. English is the default. Use **中文 / EN** on Home or in Settings to switch languages; your selection is remembered.

The application identifier and encrypted storage remain compatible with earlier versions. Existing identity, groups and history stay on this Mac. Open Whisplot after upgrading and avoid launching an older app copy. Do not uninstall data, clear the app container or delete Keychain items to update.

The app uses a local self-signed certificate, without Developer ID distribution signing or Apple notarization. If macOS blocks the first launch and you trust the download, try opening it and then use **System Settings → Privacy & Security → Open Anyway**. Follow [Apple’s instructions](https://support.apple.com/en-us/102445); managed Macs may restrict this option. You do not need to import the signing certificate or disable system security globally.

## Language and notifications

The language button updates app controls, status labels, dialogs and new system notification text. User messages, group names, IDs and invitations stay as written. Previously delivered notifications keep their original language. The preference is stored in a normal settings file and never requests Keychain access.

Enable **Message notifications** in Settings and allow the system prompt. If macOS has blocked reminders, use **Open system notification settings**. Notifications contain no sender, group name or message text. The red close button hides the existing window while keeping its connection alive; the Dock icon or a notification restores it. **Quit Whisplot / Command+Q** fully exits and stops local reception.

## Keychain and privacy

The release retains its existing local signing certificate and immutable vault service. The service owns a single master key; after unlocking, the app reuses it during the current run. Migration from older storage can still request system authorization. A missing or damaged vault stops initialization instead of creating a replacement identity. Keep original items and enter passwords only in macOS system dialogs.

The Mac privacy cover hides chat content when you switch away and restores it when you return. Whisplot no longer checks whether QQ is running, so both apps can stay open. This cover does not prevent recording while Whisplot is visible. Voice changing and rotating IDs do not guarantee that activity cannot be associated across messages.

## Local development

See the [client development guide](client-guide.md). A generic Flutter or ad-hoc package build is not the installed fixed-signer release. Do not re-sign nested vault components with `codesign --deep`; it can invalidate their trust and Keychain access. A future switch to Developer ID needs a planned migration of both signing requirements.

Whisplot releases support Android, macOS, and Windows x64.
