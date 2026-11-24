[English](README.md) | [简体中文](README.zh-CN.md)

# Whisplot

<img src="apps/mobile/assets/branding/app_logo.png" width="96" alt="Whisplot app icon" />

A private group chat app for 10–50 people. Join with an invitation, chat without a phone number or email, and let your display ID change automatically. Everyone's messages share the same centered layout.

## 0.1.0 Build 18

[Download Whisplot 0.1.0](https://github.com/whisplot/whisplot-client/releases/tag/v0.1.0) for Android, macOS, and Windows. Whisplot 0.1.0 connects to the new service. Create a group or join with an invitation from this service. Groups and messages from the former service stay there.

## Install or update

| Device | Download | Requirements |
| --- | --- | --- |
| Android | [ARM64 APK](https://github.com/whisplot/whisplot-client/releases/download/v0.1.0/whisplot-0.1.0-build18-android-arm64.apk) | Android 7.0 or later, ARM64 |
| Mac | [Universal app ZIP](https://github.com/whisplot/whisplot-client/releases/download/v0.1.0/whisplot-0.1.0-build18-macos-universal2.zip) | macOS 12 or later, Apple silicon and Intel |
| Windows | [Setup EXE](https://github.com/whisplot/whisplot-client/releases/download/v0.1.0/Whisplot-0.1.0-build18-windows-x64-setup.exe) or [portable ZIP](https://github.com/whisplot/whisplot-client/releases/download/v0.1.0/Whisplot-0.1.0-build18-windows-x64.zip) | 64-bit Windows |

Find the same packages and SHA-256 checksums on the [Whisplot downloads page](https://whisplot-downloads.pages.dev/).

**Install the update over your current app.** Keep the app data and Keychain items. On Mac, quit Whisplot before replacing the existing app in Applications.

**Android:** open the APK and allow installation from your download app if prompted. This is a test-signed package for sideloading.

**Mac:** unzip, move **Whisplot.app** to **Applications**, and open it. The app uses a local self-signed certificate, without a Developer ID distribution signature or Apple notarization. If macOS blocks the first launch and you trust the download, try opening it, then use **System Settings → Privacy & Security → Open Anyway**. See the [Mac guide](docs/macos.md) and [Apple's instructions](https://support.apple.com/en-us/102445). Including the Intel architecture does not mean it has passed testing on a physical Intel Mac.

## Language

Whisplot opens in **English** by default. Use **中文 / EN** on the Home screen or in Settings to switch instantly. Your selection is remembered after restarting; messages and group names stay as written.

## Open and join

The app creates a device identity and connects to the built-in service automatically. There is no phone number, email address, account password, or real name to enter. The update replaces the saved address of the previous official service.

- **Create a group:** select **New group** (创建群聊), enter its name, then open the invite button in the chat. Select **Copy invite code** (复制邀请码) and share it privately.
- **Join a group:** select **Join with code** (邀请码入群), paste the **22-character code**, and select **Verify and join** (验证并加入). Connect to the same service as the person inviting you. Older full invitation links also work if they are still valid.
- **Reconnect:** switching Wi-Fi or regaining connectivity triggers an automatic retry. If needed, use **Reconnect** or tap the connection banner in the chat.

Invitations require a connection to resolve. They stop working when they expire, are revoked, run out of uses, or the group changes its key. Each group supports up to 50 device identities; ask the owner for a new invitation if needed.

Joining or rejoining retrieves at most the **24 hours before that admission**, plus later messages. This does not erase records already saved on your device. Available history also depends on service retention and the group keys you hold.

## Chat and react

Type and select the send arrow. On Mac, **Enter sends** and **Shift + Enter inserts a new line**. Messages have centered bubbles and normally aligned text, without avatars or separate sides for your own messages. The group name leads the header, with your current ID and the aggregate online count below it.

- **Copy:** select the small copy icon below a text message.
- **Reply:** swipe a text or voice message left and release. A reference appears above the composer; cancel it with ×. Tap a reference in a sent message or the composer to locate the original in this group's local history. Missing originals show a placeholder.
- **Like:** double-tap a message bubble, including its reference, to add **♥️**. Repeating a double-tap keeps the like. Tap your existing heart reaction to remove it.
- **Choose a reaction:** long-press a message. Recent emoji appear above the full collection; browse categories or search in Chinese or English. Every reaction uses the same orange badge, with brief animations that respect Reduce Motion.
- **Put emoji in text:** use the emoji button beside the composer. It inserts at the cursor without sending your draft. The **3,944 emoji** are bundled in the app; browsing needs no extra download or CDN.

Sending text, a reply, or voice takes you to the latest message, including when it is taller than the screen. Manually scrolling or opening an older reference lets you keep reading history without incoming messages pulling you away.

In **Settings → Messages per ID** (每几条消息换 ID), choose **1, 10, or 50**. The default is one message per ID. Text and voice count when queued, including offline; reactions do not. There is no manual rename button. Your earlier IDs display as **Expired ID** (已过期 ID) on your own old messages, while groups and history remain. Other members' copies and the underlying device identity are not erased, so activity can still be associated across IDs.

## Voice, appearance, and screen privacy

Select the microphone, allow access, and record up to **30 seconds**. Stop, preview the changed voice, then send. Processing happens on your device, and only the changed recording is sent. Leaving the recording panel or switching apps cancels an unfinished recording. Voice changing preserves some vocal characteristics and **does not guarantee anonymity**. Playback may temporarily create a plaintext audio file on the device; normal completion and subsequent startup cleanup remove it.

Choose **Warm** (米白) or **Pure black** (纯黑) in **Settings → Appearance**. Android uses a secure window to restrict standard screenshots, recording, and recent-app previews. Mac covers chat content when you switch away from Whisplot and restores it when you return. QQ can remain open; Whisplot no longer checks whether QQ is running.

The Mac cover hides inactive content; it does not prevent recording while Whisplot is visible. Screen privacy and rotating IDs do not provide absolute anonymity.

## Sent, read, online, and notifications

**Waiting to send** (等待发送) means the message remains queued on this device. **Sent** (已发送) means the service accepted it or a peer received it. **Read** (已读取) appears once at least one member other than the sender views the message and returns a verified receipt; every member receiving that receipt sees the same status. Downloading a message is not reading it.

The online count includes you and shows only a total. Home, another group, or a backgrounded app can remain online while its connection continues. It does not imply that anyone is reading. A stopped heartbeat can take about **90 seconds** to disappear; an unavailable count appears as “在线 —”.

Use **Settings → Message notifications** on Android, macOS, or Windows. If your system blocks reminders, select **Open system notification settings** and allow them there. Reminders contain only a generic new-message alert. Clicking it opens the group on Android and macOS and restores Whisplot on Windows.

On Mac, switching apps or clicking the red close button keeps the app running. Click its Dock icon to restore it. **Command + Q** or **Quit Whisplot** exits it.

On Android, the ongoing **“正在保持后台连接”** notification supports the current connection. Switching apps or locking the screen does not deliberately disconnect it. Removing the app from recents, force-stopping it, Doze, or manufacturer restrictions can interrupt reception. Reopen it to catch up. These running connections do not require Google Play services; remote push after full termination is not configured. Physical lock-screen behavior is not claimed as fully verified on all devices.

## Leave or delete a chat space

**Keep history:** open the chat menu, choose **Leave group** (退出群聊), and confirm. Anyone can leave, including the owner. Sending and reception stop for that group; saved messages remain in **Left groups · Local history** (已退出的群 · 本机历史).

**Delete local history too:** swipe the space left on Home, select **Delete**, then confirm **Leave and delete** (退出并删除). On Mac, horizontal trackpad scrolling or a right-click offers the same action. Archived spaces can be deleted too. Cancellation keeps the space and its records; confirmed deletion cannot be undone in the app.

Offline departures show **Leave pending** (退群待确认). Reconnect so the service can confirm. The owner role transfers to a remaining member; the last departure closes the group. The remaining group pauses new messages while its owner updates the key. Keep the updated owner app online, or use **Update original group key** (更新原群密钥) to retry.

Updating the original group's key preserves the group and history, invalidates old invitations, and separates subsequent discussion from the old key. Old messages and copies held by other devices cannot be recalled. Previously issued offline peer tickets can remain valid until expiry, at most 15 minutes from issuance.

## Troubleshooting

**Connection or sending is stuck:** check the network and use **Reconnect**. Resolve any required-update or participation-check prompt; offline participation expires after at most 15 minutes without renewal. Old-key queued messages are retained for review, not automatically resent under a new key. Do not uninstall to troubleshoot.

**An existing group asks for a key:** update every device to the latest version. The owner opens the original group and selects **Update this group's key** (更新本群密钥). If an updated member still lacks the key, the owner can choose **Send keys to updated members** (为已升级成员补发密钥). Reconnect afterward; no replacement group is needed.

**The service reports its daily limit:** your pending messages remain on this device. The app waits at most 15 minutes before checking again; use **Reconnect** for an earlier check. Recovery still depends on the service becoming available.

**Mac asks for Keychain access:** approve only the trusted app in the system dialog. The encrypted local vault reduces repeated reads after migration; initial migration or signing changes can still require authorization. Denying access pauses initialization and preserves the original identity. Keep app data and Keychain items, then retry. Older Mac clients cannot open the migrated database.

**Changing devices:** each installation has its own identity. Use an invitation to join from another device. There is no account recovery or device-history migration flow; uninstalling or clearing data can lose access and local history.

See the [client guide](docs/client-guide.md) and [message notifications](docs/notifications.md).
