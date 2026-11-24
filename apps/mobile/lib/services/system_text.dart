/// Exact translations for app-owned status and error strings. Unknown values
/// stay unchanged. Never apply this helper to messages, names, IDs or invites.
String translateSystemText(String value, {required bool english}) {
  // Retained error wording from older components must use the current brand.
  const oldUpdate = '请更新导师好后继续参与讨论。本机聊天记录和待发消息仍然保留。';
  const currentUpdate = '请更新 Whisplot 后继续参与讨论。本机聊天记录和待发消息仍然保留。';
  if (value == oldUpdate) value = currentUpdate;
  if (!english) return value;
  final exact = _englishSystemText[value];
  if (exact != null) return exact;
  for (final prefix in const {
    '初始化失败：': 'Initialization failed: ',
    '已在本机退出，联网后会自动完成退群：': 'Left locally; leaving will finish when connected: ',
    'FormatException: ': '',
    'Bad state: ': '',
  }.entries) {
    if (value.startsWith(prefix.key)) {
      return '${prefix.value}${translateSystemText(value.substring(prefix.key.length), english: true)}';
    }
  }
  const voiceSuffix = '；语音保留在待发队列，其他消息可以继续发送';
  if (value.endsWith(voiceSuffix)) {
    return '${translateSystemText(value.substring(0, value.length - voiceSuffix.length), english: true)}; the voice message remains queued. Other messages can still be sent.';
  }
  final quarantined = RegExp(
    r'^(\d+) 条消息未通过验证，已隔离；其他消息仍正常(?:同步|显示)$',
  ).firstMatch(value);
  if (quarantined != null) {
    return '${quarantined[1]} messages failed verification and were isolated. Other messages remain available.';
  }
  final conflicts = RegExp(
    r'^发现 (\d+) 条冲突消息，已以验证通过的云端暂存副本为准$',
  ).firstMatch(value);
  if (conflicts != null) {
    return '${conflicts[1]} conflicting messages were replaced with verified relay copies.';
  }
  final response = RegExp(r'^服务返回了无法识别的响应（(\d+)）$').firstMatch(value);
  if (response != null) {
    return 'The service returned an unrecognized response (${response[1]}).';
  }
  return value;
}

const _englishSystemText = <String, String>{
  '未开启': 'Off',
  '已关闭': 'Off',
  '已开启': 'On',
  '前台提醒已开启': 'Foreground reminders on',
  '系统未允许': 'Not allowed by the system',
  '提醒暂不可用': 'Reminders temporarily unavailable',
  '无法开启提醒': 'Unable to enable reminders',
  '无法打开系统通知设置': 'Unable to open system notification settings',
  '无法修改提醒': 'Unable to change reminders',
  '无法确认系统通知权限': 'Unable to check notification permission',
  '后台连接未开启': 'Background connection off',
  '后台连接已开启': 'Background connection on',
  '后台连接暂不可用': 'Background connection temporarily unavailable',
  '系统暂未允许后台连接': 'The system has not allowed background connection',
  '推送尚未配置': 'Remote push is not configured',
  'Mac 版暂不提供系统推送；保持应用运行可同步，退出后重开补收':
      'Remote push is unavailable on Mac. Keep the app running to receive messages, or reopen it to catch up.',
  '推送已配置，尚未启用': 'Push is configured but not enabled',
  '推送登记失败，恢复连接后会重试':
      'Push registration failed; it will retry after reconnecting',
  '推送令牌暂不可用，打开 App 仍可同步': 'Push token unavailable; open the app to sync',
  '此构建未配置 Firebase 或推送初始化超时，打开 App 后仍可同步':
      'Push is not configured or initialization timed out. Open the app to sync.',
  'Mac 版暂不提供系统推送': 'Remote push is unavailable on Mac',
  '此构建尚未配置 Firebase/APNs；请先添加客户端配置':
      'Firebase/APNs is not configured in this build',
  '系统通知未授权': 'Notification permission not granted',
  '当前服务的推送已关闭': 'Push is off for this service',
  '推送登记暂不可用，恢复连接后会重试':
      'Push registration unavailable; it will retry after reconnecting',
  '等待 Apple 推送令牌，下次恢复前台时重试':
      'Waiting for an Apple push token; retrying when the app returns to the foreground',
  '暂未取得推送令牌，下次恢复前台时重试':
      'No push token yet; retrying when the app returns to the foreground',
  '设备已登记，但后端尚未配置推送凭证':
      'Device registered, but the service has not configured push',
  '推送已登记；是否送达仍受系统与网络影响':
      'Push registered; delivery depends on the system and network',
  '正在关闭当前服务的推送': 'Turning off push for this service',
  '已关闭当前服务的推送登记': 'Push registration removed for this service',
  '本机已关闭推送；联网后会撤销后端登记':
      'Push is off locally; registration will be removed when connected',
  '尚未连接': 'Not connected',
  '正在连接': 'Connecting',
  '网络变化，正在恢复连接': 'Network changed; reconnecting',
  '连接暂时中断，正在自动重试': 'Connection interrupted; retrying automatically',
  '网络已断开，消息保存在本机，连接恢复后会自动重试':
      'Offline. Messages are saved locally and will retry when connected.',
  '连接超时，消息已保存在本机，联网后会重试':
      'Connection timed out. Messages are saved locally and will retry when connected.',
  '网络或本机存储暂时不可用，请稍后重试':
      'Network or local storage is temporarily unavailable. Please try again.',
  '此群需要完成安全更新和密钥迁移': 'This group requires a security update and key migration',
  '安全通行证已到期，正在重新验证': 'Participation credential expired; revalidating',
  '已启用中继后备': 'Relay fallback enabled',
  '未配置中继；部分网络需要通过离线消息同步收发':
      'No relay configured; some networks will use message sync',
  '成员状态暂未同步，消息通过离线同步补齐':
      'Membership is still syncing; messages will catch up through sync',
  '部分点对点连接失败，离线消息仍可同步':
      'Some peer connections failed; message sync remains available',
  '部分连接未建立，消息通过离线同步补齐':
      'Some connections are unavailable; messages will catch up through sync',
  '点对点连接变化，消息可通过离线同步补齐':
      'Peer connection changed; message sync can fill the gaps',
  '点对点恢复暂未成功，离线消息仍可同步':
      'Peer reconnection is pending; message sync remains available',
  '已拒绝旧版或无法认证的点对点连接':
      'An outdated or unauthenticated peer connection was rejected',
  '信令已断开，正在重连': 'Signaling disconnected; reconnecting',
  '正在更新中继凭证': 'Refreshing relay credentials',
  '请更新 Whisplot 后继续参与讨论。本机聊天记录和待发消息仍然保留。':
      'Update Whisplot to continue chatting. Local history and queued messages are preserved.',
  '正在验证当前参与政策。本机聊天记录保留。':
      'Checking the current participation policy. Local history is preserved.',
  '参与政策尚未验证或已经过期。请联网验证后继续；本机历史仍可查看。':
      'Participation policy is unverified or expired. Connect to verify it; local history remains available.',
  '参与政策已过期，请联网重新验证。本机消息和待发队列保留。':
      'Participation policy expired. Connect to verify it again. Local and queued messages are preserved.',
  '已收到较新的签名参与政策，正在重新验证。':
      'A newer signed participation policy was received; revalidating.',
  '本群需要群主更新群密钥后才能继续发送；原有记录保留。':
      'The owner must update the group key before new messages can be sent. History is preserved.',
  '服务要求的更新尚未在签名政策中确认，请稍后重试':
      'The required update is not yet confirmed by the signed policy. Try again shortly.',
  '服务返回了已被替代的参与政策': 'The service returned a superseded participation policy',
  '参与政策已被较新政策替代': 'A newer participation policy has replaced this one',
  '参与政策已经过期': 'Participation policy expired',
  '无法获取有效的参与政策': 'Unable to obtain a valid participation policy',
  '参与政策响应过大': 'Participation policy response exceeds the size limit',
  '参与政策格式无效': 'Invalid participation policy format',
  '安全策略字段无效': 'Invalid security policy field',
  '安全策略格式无效': 'Invalid security policy format',
  '安全凭证编码无效': 'Invalid security credential encoding',
  '安全凭证已过期或时间无效，请联网校准':
      'The security credential expired or has an invalid time. Connect to revalidate.',
  '安全凭证格式无效': 'Invalid security credential format',
  '安全凭证签名无效': 'Invalid security credential signature',
  '群参与凭证或密钥代次不匹配': 'Group participation credential or key epoch does not match',
  '参与身份无效': 'Invalid participant identity',
  '群参与凭证身份不匹配': 'Group participation identity does not match',
  '参与者版本过低': 'Participant app version is too old',
  '群参与凭证不可用': 'Group participation credential unavailable',
  '点对点数据无效': 'Invalid peer data',
  '未认证或旧协议消息已拒绝': 'Unauthenticated or outdated-protocol message rejected',
  '消息身份或密钥代次不匹配': 'Message identity or key epoch does not match',
  '正在办理退群，请稍候': 'Leaving the group. Please wait.',
  '当前连接已变化，请重试': 'The connection changed. Please try again.',
  '此聊天空间已变化，请刷新后重试': 'This space changed. Refresh and try again.',
  '当前群已变化，请重新打开退群操作': 'The current group changed. Reopen the leave action.',
  '退群确认无效，稍后重试': 'Invalid leave confirmation. Try again later.',
  '群语音存储空间已满，文字仍可发送':
      'Group voice storage is full. Text messages can still be sent.',
  '语音已过期或暂时不可用': 'Voice message expired or temporarily unavailable',
  '请安装最新的 0.4.0 修订包后参与本群':
      'Install the latest Whisplot update to participate in this group',
  '你已退出本群，本机历史仍可查看': 'You left this group. Local history is still available.',
  '所有成员已退出，本群已关闭': 'Everyone has left; this group is closed',
  '请求过于频繁，稍后会自动重试': 'Too many requests; retrying shortly',
  '操作过于频繁，请稍后重试': 'Too many requests. Please try again later.',
  '请先配置服务': 'Configure a service first',
  '请先连接聊天服务': 'Connect to the chat service first',
  '请先连接服务': 'Connect to the service first',
  '群名称需要 1～60 个字符': 'Group names must contain 1–60 characters',
  '缺少群密钥，请重新导入邀请码': 'Group key missing. Import the invitation again.',
  '请先连接邀请码对应的服务': 'Connect to the invitation’s service first',
  '此邀请码属于旧版或尚未支持的群，请群主更新群密钥后提供新邀请码':
      'This invitation belongs to an outdated or unsupported group. Ask the owner to update the group key and send a new invitation.',
  '请先在连接设置中切换到邀请码对应的服务':
      'Switch to the invitation’s service in connection settings first',
  '请先联网完成退群，再使用新的邀请码重新加入':
      'Connect to finish leaving, then rejoin using a new invitation',
  '此邀请码与本机已有群密钥不一致，已拒绝覆盖':
      'This invitation conflicts with the saved group key. The existing key was not replaced.',
  '群密钥版本发生回退，已停止同步': 'Group key version rolled back; sync stopped',
  '群成员已变化，请重新同步': 'Group membership changed. Sync again.',
  '群成员身份无效': 'Invalid group member identity',
  '群密钥已更新，请重新同步': 'Group key updated. Sync again.',
  '群主或本机加密身份不可用': 'Owner or local encryption identity unavailable',
  '密钥分发版本不匹配': 'Key distribution version does not match',
  '只有群主可以更新群密钥': 'Only the owner can update the group key',
  '本机加密公钥尚未登记，请重新连接后重试':
      'The local encryption key is not registered. Reconnect and try again.',
  '成员再次变化，正在重新更新群密钥': 'Membership changed again; updating the group key',
  '消息签名无效': 'Invalid message signature',
  '服务返回了无效的同步游标': 'The service returned an invalid sync cursor',
  '聊天已切换，请在原群重新操作': 'The chat changed. Retry in the original group.',
  '引用消息不在当前群的有效记录中': 'The referenced message is not available in this group',
  '引用消息记录与签名不一致': 'The referenced message does not match its signature',
  '引用消息尚未解密，请同步后重试':
      'The referenced message is not decrypted yet. Sync and try again.',
  '只能引用文字或语音消息': 'Only text and voice messages can be quoted',
  '聊天已关闭，请重新打开原群': 'The chat closed. Reopen the original group.',
  '群密钥不可用': 'Group key unavailable',
  '语音不属于当前群或连接尚未配置':
      'This voice message is not in the current group, or the connection is not configured',
  '不支持这个表情': 'This emoji is not supported',
  '目标消息不在当前群的有效记录中': 'The target message is not available in this group',
  '缺少群密钥，已保留待发消息': 'Group key missing. Queued messages are preserved.',
  '当前服务尚不支持变声语音，请管理员升级；文字仍可发送':
      'This service does not support altered voice yet. Ask the administrator to update it; text still works.',
  '变声处理失败，请重新录制': 'Voice processing failed. Record again.',
  '需要麦克风权限才能录制变声语音，可在系统设置中开启':
      'Microphone permission is required. Enable it in system settings.',
  '录音中断，请重新录制': 'Recording interrupted. Record again.',
  '录音设备已停止，请重新录制': 'The recording device stopped. Record again.',
  '无法启动麦克风，请检查系统权限':
      'Unable to start the microphone. Check system permissions.',
  '录音太短，请至少说一句话后再停止':
      'Recording is too short. Say at least a sentence before stopping.',
  '已离开录音窗口，录音已取消。需要时请重新录制。':
      'Recording cancelled because the recording window was left. Record again when ready.',
  '此聊天空间已删除，语音操作已取消': 'This space was deleted. Voice operation cancelled.',
  '语音标识无效': 'Invalid voice attachment ID',
  '本机待发送语音已满，请联网发送现有语音后重试':
      'Local voice queue is full. Connect to send pending recordings, then try again.',
  '语音校验失败，文件可能已损坏': 'Voice verification failed. The file may be damaged.',
  '语音与当前服务不匹配': 'The voice attachment does not match the current service',
  '找不到本机待发送语音，请重新录制': 'Pending recording not found. Record it again.',
  '服务返回了无效的语音上传结果': 'The service returned an invalid voice upload result',
  '服务返回了无效的语音文件': 'The service returned an invalid voice file',
  '语音时长校验失败': 'Voice duration verification failed',
  '邀请码已失效，请重新获取': 'Invitation expired or unavailable. Request a new one.',
  '邀请码无效，请确认连接的服务或重新获取':
      'Invalid invitation. Check the service or request a new code.',
  '当前服务尚未支持短邀请码': 'This service does not support short invitation codes yet',
  '请重新生成邀请码': 'Generate a new invitation code',
  '邀请码与当前服务不一致': 'The invitation does not match the current service',
  '无法确认短邀请码，请重试': 'Unable to verify the short invitation. Please try again.',
  '请输入有效的邀请码': 'Enter a valid invitation code',
  '邀请码内容无效': 'Invalid invitation contents',
  '邀请码无效或已过期，请重新获取': 'Invalid or expired invitation. Request a new one.',
  '内置接入码仅用于默认服务；请填写这个服务自己的接入码':
      'The built-in access code is only for the default service. Enter this service’s own code.',
  '请输入完整服务地址，例如 https://nearlink.example.workers.dev':
      'Enter a complete service URL, such as https://chat.example.com',
  '服务地址必须使用 HTTPS；本机 HTTP 仅限显式开启的调试构建':
      'The service URL must use HTTPS. Local HTTP is only available in explicitly enabled debug builds.',
  '服务响应超过大小限制': 'The service response exceeds the size limit',
  '请求失败': 'Request failed',
  '服务今日写入额度已用完，消息保存在本机，额度恢复后会自动重试':
      'The service has reached its daily write limit. Messages are saved on this device and will retry when the quota resets.',
  '服务响应格式错误': 'Invalid service response format',
  '邀请码标识无效': 'Invalid invitation ID',
  '邀请码密钥无效': 'Invalid invitation key',
  '服务地址过长': 'Service URL is too long',
  '邀请码过长': 'Invitation code is too long',
  '请粘贴有效的邀请码': 'Paste a valid invitation code',
  '请粘贴邀请码': 'Paste an invitation code',
  '邀请码版本无效': 'Invalid invitation version',
  '邀请码安全版本无效': 'Invalid invitation security version',
  '邀请码不完整': 'Incomplete invitation',
  '邀请码已过期': 'Invitation expired',
  '邀请码数值无效': 'Invalid invitation value',
  '邀请码校验失败，请重新复制': 'Invitation verification failed. Copy it again.',
  '服务地址无效': 'Invalid service URL',
  '邀请码包含多余内容': 'Invitation contains extra data',
  '暂时无法重新检查，请稍后重试。': 'Unable to check again right now. Please try later.',
  '下载网址已复制，请粘贴到浏览器打开。': 'Download URL copied. Paste it into your browser.',
  '复制失败，请手动选中下面的网址复制。': 'Copy failed. Select and copy the URL below manually.',
  '无法打开下载页，请复制网址后在浏览器中打开。':
      'Unable to open the download page. Copy the URL into your browser.',
  '消息已复制': 'Message copied',
  '已复制': 'Copied',
  '连接提示': 'Connection notice',
  '请私下分享': 'Share privately',
  '邀请码包含访问密钥': 'Invitations contain access keys',
  '10～50 人的邀请制聊天空间': 'Invite-only spaces for 10–50 people',
  '通过邀请码加入，与朋友自在聊天。': 'Join by invitation and chat freely with friends.',
  '只从信任的人那里获取邀请码，不要公开发布。你的群密钥会保存在本机安全存储中。':
      'Accept invitations only from people you trust. Do not post them publicly. Group keys are stored securely on your device.',
  '任何拿到邀请码的人，都能在有效期内加入并获得群密钥。不要发到公开页面。':
      'Anyone with a valid invitation can join and receive the group key. Do not post it publicly.',
  '群成员状态已变化，请重试入群': 'Membership changed. Try joining again.',
  '群成员状态已变化，请重新入群': 'Membership changed. Rejoin the group.',
  '入群操作已失效': 'The join operation expired',
  '你已退出此群，无法继续发送消息': 'You left this group and can no longer send messages',
  '临时ID状态已变化，请重试发送': 'The ID state changed. Try sending again.',
  '此聊天空间已删除': 'This space was deleted',
  '临时ID计数状态损坏，已停止发送以避免重复使用':
      'ID rotation state is damaged. Sending stopped to prevent reuse.',
  '仅支持每1、10或50条更换临时ID': 'Choose ID rotation after 1, 10 or 50 messages',
  '临时ID计数记录缺失，请恢复完整本机数据；为避免重复使用旧ID，已停止发送':
      'ID rotation records are missing. Restore complete local data; sending stopped to prevent reuse.',
  '临时ID计数无法解密，已保留原数据并停止发送':
      'Unable to decrypt ID rotation state. Original data is preserved and sending stopped.',
  '钥匙串访问已暂停，不会继续弹窗。确认系统已允许访问后，点击重新尝试或重新连接；原身份和聊天记录保留。':
      'Keychain access is paused; no more dialogs will be requested. After allowing access in the system prompt, choose Retry or Reconnect. Your identity and history are preserved.',
  '已有聊天记录或连接配置，但无法读取原来的设备密钥。请检查安全存储访问权限并重新打开应用；现有记录不会被新身份覆盖。':
      'Local data exists, but the original identity key cannot be read. Check secure-storage permission and reopen the app. Existing records will not be replaced with a new identity.',
  '无法读取原来的群加密私钥。请恢复安全存储访问权限；不会用新密钥覆盖身份。':
      'Unable to read the original group encryption key. Restore secure-storage access; the identity will not be replaced.',
  '已保存的连接配置损坏，请在设置中修复；现有身份和聊天记录已保留':
      'Saved connection settings are damaged. Repair them in Settings. Identity and history are preserved.',
  '本机连接配置不完整，请在设置中恢复原来的服务；不会自动切换默认服务':
      'Local connection settings are incomplete. Restore the original service in Settings; the app will not switch services automatically.',
  '已有聊天记录但缺少服务配置，请在设置中恢复原来的服务；现有数据已保留':
      'History exists but service settings are missing. Restore the original service in Settings. Existing data is preserved.',
  '应用的默认服务配置无效，请在设置中填写有效的 HTTPS 服务地址':
      'The default service configuration is invalid. Enter a valid HTTPS service URL in Settings.',
  '本机密钥库格式异常，原记录已保留':
      'Invalid local vault format. Original records are preserved.',
  '找不到原身份密钥，已停止迁移并保留聊天记录':
      'Original identity key not found. Migration stopped and history is preserved.',
  '密钥库访问已取消，请手动重试。': 'Vault access cancelled. Retry manually when ready.',
  '密钥库会话已结束。': 'The vault session ended.',
  '密钥库操作已取消，请手动重试。': 'Vault operation cancelled. Retry manually when ready.',
  '原来的密钥库文件无法读取，已停止初始化以保护原身份。':
      'The existing vault cannot be read. Startup stopped to protect the original identity.',
  '旧密钥列表存在重复项目，已暂停迁移。': 'Duplicate legacy key entries found. Migration paused.',
  '迁移中的旧密钥项目无法读取，已暂停；原身份不会被替换。':
      'A legacy key cannot be read. Migration paused; the original identity will not be replaced.',
  '原密钥库的解锁密钥不存在，已停止初始化以保护原身份。':
      'The existing vault master key is missing. Startup stopped to protect the original identity.',
  '密钥库解锁密钥格式异常，已停止初始化。': 'Invalid vault master key format. Startup stopped.',
  '密钥库超过大小限制。': 'The vault exceeds the size limit.',
  '密钥库完整性校验失败，已停止初始化；不会替换原身份。':
      'Vault integrity verification failed. Startup stopped; the original identity will not be replaced.',
  '密钥库格式异常，已停止初始化；不会替换原身份。':
      'Invalid vault format. Startup stopped; the original identity will not be replaced.',
  '密钥项目名称格式异常。': 'Invalid key entry name.',
  '密钥库主密钥格式无效': 'Invalid vault master key format',
  '密钥库主密钥长度无效': 'Invalid vault master key length',
  '无法确认原密钥项目，已停止迁移': 'Unable to verify the original key. Migration stopped.',
  '身份密钥损坏': 'Identity key is damaged',
  '密钥分发身份损坏': 'Key distribution identity is damaged',
  '密钥接收身份无效': 'Invalid key recipient identity',
  '密钥协商失败': 'Key agreement failed',
  '群密钥参数无效': 'Invalid group key parameters',
  '群密钥签名或接收身份无效': 'Invalid group key signature or recipient identity',
  '本机密钥分发身份不一致': 'Local key distribution identity does not match',
  '群密钥长度无效': 'Invalid group key length',
  '群密钥代次无效': 'Invalid group key epoch',
  '消息身份验证失败': 'Message authentication failed',
  '密文损坏': 'Encrypted data is damaged',
  '消息正文无效': 'Invalid message payload',
  '已读回执绑定无效': 'Invalid read receipt binding',
  '消息时间无效': 'Invalid message timestamp',
  '已读回执格式无效': 'Invalid read receipt format',
  '引用消息格式无效': 'Invalid quoted message format',
  '每条消息请限制在4000字节以内': 'Keep each message within 4,000 bytes',
  '消息临时ID无效': 'Invalid message ID label',
  '语音消息格式无效': 'Invalid voice message format',
  '表情事件无效': 'Invalid reaction event',
  '扩展表情事件无效': 'Invalid extended reaction event',
  '此版本不支持该消息类型，请升级客户端':
      'This app version does not support the message type. Please update.',
  '群密钥封装格式无效': 'Invalid wrapped group key format',
  '不支持的消息版本': 'Unsupported message version',
  '消息密钥代次无效': 'Invalid message key epoch',
  '消息格式无效': 'Invalid message format',
  '消息长度无效': 'Invalid message length',
  '语音附件描述无效': 'Invalid voice attachment description',
};
