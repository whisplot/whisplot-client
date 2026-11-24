# 消息提醒

在**设置 → 消息提醒**开启，并允许系统通知权限。通知仅显示“Whisplot / 你有新消息”，不显示群名、发送者或聊天内容。

- **Mac：**保持 App 运行，切到其他窗口或停留在首页时可收到提醒。点击红色关闭按钮只隐藏窗口，后台继续收信；点击 Dock 图标或消息通知恢复原窗口。Mac 图标显示本次运行中尚未查看的新消息数，查看相应群后清除。菜单**退出**或 **Command + Q** 才会完全退出，此后不接收新消息。
- **Android** 通过前台服务和不含聊天内容的常驻通知保持连接。进程继续运行、网络可用时可以接收消息提醒。划掉任务、强制停止、Doze 或厂商后台限制都可能中断收信。
- **Windows** 在 Whisplot 继续运行时使用任务栏通知。点击通知可恢复 Whisplot 窗口。
- 正在查看的消息、自己发出的消息、表情回应、已读回执，以及打开 App 时补收的旧历史不会重复提醒。
- Android 和 macOS 运行期间，点通知可打开相应群。新进程启动时会清除前一次运行留下的提醒。

如果系统拒绝权限，点**打开系统通知设置**，允许 Whisplot 通知后返回 App。系统的勿扰模式、横幅设置和声音设置仍会影响提醒显示。消息提醒依赖运行中的连接。

## 在线人数

群聊顶部只显示总在线人数，含自己，不显示在线名单和最后上线时间。运行中的客户端定期更新已加入群的 90 秒租约；主页、其他群、后台和锁屏都可续租。在线与已读互不等同，只有前台实际可见的消息才会报告已读。关闭消息提醒不会关闭在线心跳。断网或停止运行后租约过期，人数自动扣除；无法获得可信的新计数时显示“在线 —”。

Android 使用 `specialUse` 类型前台服务，在 Activity 可见时启动，不请求忽略电池优化、不使用录音或定位保活。参考 [Android 前台服务启动限制](https://developer.android.com/develop/background-work/services/fgs/launch)、[服务类型](https://developer.android.com/develop/background-work/services/fgs/service-types)和 [Doze 限制](https://developer.android.com/training/monitoring-device-state/doze-standby)。
