import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../services/api_client.dart';
import '../services/local_store.dart';
import '../services/secret_session_cache.dart';
import '../services/media_service.dart';
import '../services/network_monitor.dart';
import '../services/push_service.dart';
import '../services/message_notifications.dart';
import '../services/background_connection.dart';
import '../services/short_invite_service.dart';
import '../services/rtc_session.dart';
import '../services/group_watch.dart';
import 'crypto_service.dart';
import 'default_connection.dart';
import 'models.dart';
import 'temporary_id.dart';
import 'app_platform.dart';
import 'client_security.dart';
import 'group_presence.dart';

class _ConnectionChanged implements Exception {}

typedef ApiClientFactory =
    ApiClient Function({
      required String server,
      required Identity identity,
      required CryptoService crypto,
      required String registrationCode,
    });

class _SavedConnection {
  const _SavedConnection(this.server, this.code);
  final String server, code;
}

class ChatController extends ChangeNotifier with WidgetsBindingObserver {
  ChatController({
    LocalStore? store,
    CryptoService? crypto,
    this.defaultConnection = const DefaultConnection.fromEnvironment(),
    ApiClientFactory? apiFactory,
    MediaService? media,
    MessageNotificationService? notifications,
    BackgroundConnectionService? backgroundConnection,
    GroupPresence? presence,
    this.networkMonitor = const SystemNetworkMonitor(),
    this.networkDebounce = const Duration(milliseconds: 750),
    this.healthInterval = const Duration(seconds: 60),
    this.mediaRetryDelay = const Duration(seconds: 30),
    this.notificationInterval = const Duration(seconds: 15),
    this.readReceiptDelay = const Duration(seconds: 2),
    this.policyVerifier,
    this.authorityPublicKey = AppSecurity.authorityPublicKey,
  }) : store = store ?? LocalStore(),
       crypto = crypto ?? CryptoService(),
       media = media ?? MediaService(crypto: crypto),
       notifications = notifications ?? MessageNotificationService(),
       backgroundConnection =
           backgroundConnection ?? BackgroundConnectionService(),
       _presence = presence ?? GroupPresence(),
       _apiFactory = apiFactory ?? ApiClient.new;
  final LocalStore store;
  final MediaService media;
  final MessageNotificationService notifications;
  final BackgroundConnectionService backgroundConnection;
  final GroupPresence _presence;
  final CryptoService crypto;
  final DefaultConnection defaultConnection;
  final ApiClientFactory _apiFactory;
  final NetworkMonitor networkMonitor;
  final Duration networkDebounce, healthInterval, mediaRetryDelay;
  final Duration notificationInterval;
  final Duration readReceiptDelay;
  final Future<SignedPolicy> Function(Map<String, dynamic>)? policyVerifier;
  final String authorityPublicKey;
  final PushService push = PushService();
  late Identity identity;
  EncryptionIdentity? encryptionIdentity;
  SignedPolicy? _policy;
  Map<String, dynamic> _policyFloor = {};
  Stopwatch? _policyClock;
  int _policyLeaseMilliseconds = 0;
  Timer? _policyRefreshTimer, _policyExpiryTimer;
  Future<void>? _policyRefresh;
  UpgradeRequiredException? participationBlock;
  Map<String, dynamic>? _responsePolicyFloor;
  final Set<String> _availableGroupKeys = {};
  bool viewingLocalHistory = false, checkingPolicy = false;
  static const policyStateKey = 'client-policy-floor-v2';
  static const encryptionSeedKey = 'encryption-identity-x25519-v1';
  static const encryptionEnrollmentKey = 'encryption-identity-enrolled-v1';
  bool get _floorRequiresUpdate =>
      (_policyFloor['minClientBuild'] as int? ?? 0) > AppSecurity.clientBuild ||
      (_policyFloor['protocolVersion'] as int? ?? 0) >
          AppSecurity.protocolVersion ||
      (_policyFloor['privacyEpoch'] as int? ?? 0) > AppSecurity.privacyEpoch;
  bool get participationAllowed =>
      !_disposed &&
      participationBlock == null &&
      _policy != null &&
      _policy!.policy.supportsThisClient &&
      _policy!.policy.isFreshAt(DateTime.now().millisecondsSinceEpoch) &&
      (_policyClock?.elapsedMilliseconds ?? _policyLeaseMilliseconds) <
          _policyLeaseMilliseconds;

  bool canSendToGroup(Group group) =>
      participationAllowed &&
      !isGroupLeft(group) &&
      !group.rekeyRequired &&
      !_currentGroup(group).rekeyRequired &&
      group.keyEpoch >= 1 &&
      group.server == server &&
      group.protocolVersion == AppSecurity.protocolVersion &&
      group.privacyEpoch == AppSecurity.privacyEpoch &&
      group.minClientBuild <= AppSecurity.clientBuild &&
      _availableGroupKeys.contains('${group.storageId}:${group.keyEpoch}') &&
      _currentGroup(group).keyEpoch == group.keyEpoch;

  Group _currentGroup(Group group) {
    final current =
        groups.where((g) => g.storageId == group.storageId).firstOrNull ??
        group;
    final active = activeGroup?.storageId == group.storageId
        ? activeGroup
        : null;
    return current.copyWith(
      historySince: max(
        max(current.historySince, group.historySince),
        active?.historySince ?? 0,
      ),
      joinedAt: max(
        max(current.joinedAt, group.joinedAt),
        active?.joinedAt ?? 0,
      ),
    );
  }

  void viewLocalHistory() {
    viewingLocalHistory = true;
    changed();
  }

  void showParticipationGate() {
    viewingLocalHistory = false;
    changed();
  }

  void _requireParticipation() {
    if (participationAllowed) return;
    final block =
        participationBlock ??
        (_floorRequiresUpdate
            ? const UpgradeRequiredException()
            : const UpgradeRequiredException(
                message: '参与政策尚未验证或已经过期。请联网验证后继续；本机历史仍可查看。',
                expired: true,
              ));
    _enterPolicyBlock(block);
    throw block;
  }

  void _requireGroupSend(Group group) {
    _requireParticipation();
    if (!canSendToGroup(group)) {
      throw const ApiException(
        '本群需要群主更新群密钥后才能继续发送；原有记录保留。',
        code: 'group_key_upgrade_required',
      );
    }
  }

  void _enterPolicyBlock(UpgradeRequiredException block) {
    final changedBlock =
        participationBlock == null ||
        participationBlock!.expired != block.expired;
    participationBlock = block;
    unawaited(_updateBackgroundConnection());
    api?.blockParticipation(block);
    if (changedBlock) {
      viewingLocalHistory = false;
      _invalidateNetwork();
      _reconnectAgain = false;
      _policyExpiryTimer?.cancel();
    }
    online = false;
    error = block.message;
    changed();
  }

  Future<void> refreshPolicy() {
    if (_disposed || !_resumed || api == null) return Future.value();
    return _policyRefresh ??= _refreshPolicy().whenComplete(
      () => _policyRefresh = null,
    );
  }

  Future<void> _refreshPolicy() async {
    final client = api!, epoch = _networkEpoch;
    final wasBlocked = participationBlock != null || _policy == null;
    checkingPolicy = true;
    changed();
    try {
      await _transportReset;
      if (!_current(client, epoch)) return;
      final wire = await client.fetchClientPolicy();
      final signed =
          await (policyVerifier?.call(wire) ??
              SignedPolicy.verify(
                wire,
                crypto: crypto,
                authorityPublicKey: authorityPublicKey,
              ));
      if (!_current(client, epoch)) return;
      final p = signed.policy;
      final responseFloor = _responsePolicyFloor;
      if (responseFloor != null) {
        for (final field in [
          'policyRevision',
          'minClientBuild',
          'protocolVersion',
          'privacyEpoch',
        ]) {
          final required = responseFloor[field];
          if (required is int && (p.toJson()[field] as int) < required) {
            throw const FormatException('服务要求的更新尚未在签名政策中确认，请稍后重试');
          }
        }
      }
      for (final field in [
        'policyRevision',
        'minClientBuild',
        'protocolVersion',
        'privacyEpoch',
      ]) {
        if ((p.toJson()[field] as int) < (_policyFloor[field] as int? ?? 0)) {
          throw const FormatException('服务返回了已被替代的参与政策');
        }
      }
      _policyFloor = await store.mergePolicyFloor(policyStateKey, p.toJson());
      if (!_current(client, epoch)) return;
      for (final field in [
        'policyRevision',
        'minClientBuild',
        'protocolVersion',
        'privacyEpoch',
      ]) {
        if ((p.toJson()[field] as int) < (_policyFloor[field] as int)) {
          throw const FormatException('参与政策已被较新政策替代');
        }
      }
      _policy = signed;
      _policyLeaseMilliseconds =
          p.expiresAt - DateTime.now().millisecondsSinceEpoch;
      _policyClock = Stopwatch()..start();
      _policyExpiryTimer?.cancel();
      _policyRefreshTimer?.cancel();
      if (!p.supportsThisClient) {
        _enterPolicyBlock(const UpgradeRequiredException());
        return;
      }
      if (_policyLeaseMilliseconds <= 0) {
        throw const FormatException('参与政策已经过期');
      }
      participationBlock = null;
      unawaited(_updateBackgroundConnection());
      viewingLocalHistory = false;
      client.acceptVerifiedPolicy();
      _policyExpiryTimer = Timer(
        Duration(milliseconds: _policyLeaseMilliseconds),
        () {
          _enterPolicyBlock(
            const UpgradeRequiredException(
              message: '参与政策已过期，请联网重新验证。本机消息和待发队列保留。',
              expired: true,
            ),
          );
          unawaited(refreshPolicy());
        },
      );
      _policyRefreshTimer = Timer(
        const Duration(minutes: 5),
        () => unawaited(refreshPolicy()),
      );
      if (wasBlocked && _reconnecting == null) unawaited(reconnect());
    } catch (e) {
      if (_current(client, epoch)) {
        if (e is FormatException || !participationAllowed) {
          _enterPolicyBlock(
            _floorRequiresUpdate
                ? const UpgradeRequiredException()
                : UpgradeRequiredException(
                    message:
                        '无法验证当前参与政策，请联网重试。本机记录保留。${e is FormatException ? e.message : ''}',
                    expired: true,
                  ),
          );
        }
        _policyRefreshTimer?.cancel();
        _policyRefreshTimer = Timer(
          const Duration(seconds: 30),
          () => unawaited(refreshPolicy()),
        );
      }
    } finally {
      checkingPolicy = false;
      changed();
    }
  }

  void _observePeerPolicy(ClientPolicy policy) {
    if (policy.policyRevision > (_policyFloor['policyRevision'] as int? ?? 0) ||
        !policy.supportsThisClient) {
      for (final field in [
        'policyRevision',
        'minClientBuild',
        'protocolVersion',
        'privacyEpoch',
      ]) {
        _policyFloor[field] = max(
          _policyFloor[field] as int? ?? 0,
          policy.toJson()[field] as int,
        );
      }
      _enterPolicyBlock(
        const UpgradeRequiredException(
          message: '已收到较新的签名参与政策，正在重新验证。',
          expired: true,
        ),
      );
      unawaited(
        store
            .mergePolicyFloor(policyStateKey, _policyFloor)
            .then((_) => refreshPolicy())
            .catchError((Object _) {}),
      );
    }
  }

  ApiClient? api;
  String server = '', displayName = '', registrationCode = '';
  bool ready = false,
      busy = false,
      online = false,
      _disposed = false,
      _resumed = true,
      _initializing = false;
  AppLifecycleState? _lifecycleState;
  Future<void> _backgroundSync = Future.value();
  String? error;
  List<Group> groups = [];
  List<Group> leftGroups = [];
  Map<String, Map<String, dynamic>> _departures = {};
  final Set<String> _leavingGroups = {};
  final Map<String, Map<String, dynamic>> _rejoinIntents = {};
  final Map<String, Future<bool>> _leaveRequests = {};
  final Map<String, List<Member>> _activeRosters = {};
  bool get isLeavingGroup => _leavingGroups.isNotEmpty;
  bool isGroupLeft(Group group) =>
      _departures.containsKey(group.storageId) ||
      _leavingGroups.contains(group.storageId);
  int get pendingGroupLeaveCount => _departures.values
      .where((d) => d['server'] == server && d['pending'] == true)
      .length;

  Future<void> _reloadGroups() async {
    final origin = server;
    final saved = await store.groups(origin);
    if (_disposed || origin != server) return;
    groups = saved.where((g) => !isGroupLeft(g)).toList();
    leftGroups = saved.where(isGroupLeft).toList();
    unawaited(_updateBackgroundConnection());
  }

  /// Used only after the user confirms deletion of this exact chat space.
  Future<void> deleteGroupLocallyAndLeave(String storageId) async {
    if (_leavingGroups.isNotEmpty) throw const ApiException('正在办理退群，请稍候');
    final origin = server;
    final saved = await store.groups(origin);
    if (_disposed || server != origin || _leavingGroups.isNotEmpty) {
      throw const ApiException('当前连接已变化，请重试');
    }
    final group = saved.where((g) => g.storageId == storageId).firstOrNull;
    if (group == null) {
      final pending = _departures[storageId];
      if (pending?['deleted'] == true) {
        await _finishLocalDeletion(
          Group(
            id: pending!['groupId'] as String,
            server: pending['server'] as String,
            name: '',
            ownerId: '',
          ),
        );
        return;
      }
      throw const ApiException('此聊天空间已变化，请刷新后重试');
    }
    _leavingGroups.add(storageId);
    _presence.remove(storageId);
    if (activeGroup?.storageId == storageId) _cancelReadReceipts();
    changed();
    try {
      await _serializeSend(() async {
        await store.markGroupDeleted(group, const Uuid().v4());
        _departures = await store.groupDepartures();
        _rejoinIntents.remove(storageId);
        _activeRosters.remove(storageId);
        _availableGroupKeys.removeWhere((key) => key.startsWith('$storageId:'));
        unreadHintGroupIds.remove(group.id);
        _notificationFloors.remove(group.storageId);
        unawaited(notifications.clearGroup(group.storageId));
        if (pendingOpenGroupId == group.id) pendingOpenGroupId = null;
        _invalidateNetwork();
        if (activeGroup?.storageId == storageId) await closeGroup();
        await _reloadGroups();
        await _finishLocalDeletion(group);
      });
      await _transportReset;
      await _confirmDeparture(group);
    } finally {
      _leavingGroups.remove(storageId);
      unawaited(reconnect());
      changed();
    }
  }

  Future<void> _finishLocalDeletion(Group group) async {
    await media.deleteGroup(group);
    await store.deleteGroupKeys(group);
    await store.finishGroupDeletion(group);
    _departures = await store.groupDepartures();
  }

  Future<void> _resumeLocalDeletions() async {
    for (final d in _departures.values.toList()) {
      if (d['deleted'] != true || d['cleanupPending'] != true) continue;
      try {
        await _finishLocalDeletion(
          Group(
            id: d['groupId'] as String,
            server: d['server'] as String,
            name: '',
            ownerId: '',
          ),
        );
      } catch (_) {
        error = '聊天空间已退出，部分本地数据尚未清理；重新打开后会继续清理。';
      }
    }
  }

  /// Keep the local archive, but isolate this membership before any network IO.
  Future<bool> leaveActiveGroup({String? expectedStorageId}) async {
    final group = activeGroup;
    if (group == null ||
        (expectedStorageId != null && group.storageId != expectedStorageId)) {
      throw const ApiException('当前群已变化，请重新打开退群操作');
    }
    if (_leavingGroups.isNotEmpty) {
      throw const ApiException('正在办理退群，请稍候');
    }
    if (_departures.containsKey(group.storageId)) {
      return _confirmDeparture(group);
    }
    _leavingGroups.add(group.storageId);
    _presence.remove(group.storageId);
    if (activeGroup?.storageId == group.storageId) _cancelReadReceipts();
    changed();
    try {
      await _serializeSend(() async {
        final leaveId = const Uuid().v4();
        await store.markGroupLeft(group, leaveId);
        _departures[group.storageId] = {
          'leaveId': leaveId,
          'groupId': group.id,
          'server': group.server,
          'pending': true,
        };
        _rejoinIntents.remove(group.storageId);
        await store.deleteState('pending-rejoin:${group.storageId}');
        _activeRosters.remove(group.storageId);
        unreadHintGroupIds.remove(group.id);
        _notificationFloors.remove(group.storageId);
        unawaited(notifications.clearGroup(group.storageId));
        if (pendingOpenGroupId == group.id) pendingOpenGroupId = null;
        _invalidateNetwork();
        await _reloadGroups();
        await _loadMessages(group);
      });
      await _transportReset;
      final confirmed = await _confirmDeparture(group);
      unawaited(reconnect());
      return confirmed;
    } finally {
      _leavingGroups.remove(group.storageId);
      changed();
    }
  }

  Future<bool> _confirmDeparture(Group group) {
    final departure = _departures[group.storageId];
    if (departure == null || departure['pending'] != true) {
      return Future.value(true);
    }
    return _leaveRequests
        .putIfAbsent(group.storageId, () async {
          try {
            final client = api;
            if (client == null || client.server != group.server) return false;
            final leaveId = departure['leaveId'] as String;
            final response = await client.request(
              'POST',
              '/v1/groups/${group.id}/leave',
              {'leaveId': leaveId},
            );
            if (response['left'] != true ||
                response['leaveId'] != leaveId ||
                response['groupId'] != group.id) {
              throw const FormatException('退群确认无效，稍后重试');
            }
            await store.confirmGroupLeft(group, leaveId);
            if (_departures[group.storageId]?['leaveId'] == leaveId) {
              _departures[group.storageId] = {
                ..._departures[group.storageId]!,
                'pending': false,
              };
            }
            unawaited(_updateBackgroundConnection());
            changed();
            return true;
          } catch (e) {
            if (!_disposed && server == group.server) {
              error = '已在本机退出，联网后会自动完成退群：${friendly(e)}';
              _scheduleOutboxRetry();
              changed();
            }
            return false;
          }
        })
        .whenComplete(() {
          _leaveRequests.remove(group.storageId);
        });
  }

  Future<void> _flushDepartures(ApiClient client, int epoch) async {
    for (final entry in _departures.entries.toList()) {
      if (!_current(client, epoch)) return;
      final d = entry.value;
      if (d['server'] != client.server || d['pending'] != true) continue;
      await _confirmDeparture(
        Group(
          id: d['groupId'] as String,
          server: d['server'] as String,
          name: '',
          ownerId: '',
        ),
      );
    }
  }

  Group? activeGroup;
  List<ChatMessage> messages = [];
  int quarantinedMessages = 0;
  String? pendingOpenGroupId;
  final Set<String> unreadHintGroupIds = {};
  Map<String, Member> members = {};
  ConnectionReport connection = const ConnectionReport();
  RtcSession? _rtc;
  Timer? _syncDebounce, _outboxRetry, _networkDebounce, _healthTimer;
  StreamSubscription<NetworkPathChange>? _networkSubscription;
  bool _receivedInitialPath = false, _healthChecking = false;
  int _networkEpoch = 0, _groupEpoch = 0, _rtcAttempt = 0, _messageLoad = 0;
  Future<void> _transportReset = Future.value();
  Future<void>? _reconnecting;
  bool _reconnectAgain = false;
  int _retrySeconds = 2;
  final Map<String, Future<void>> _syncs = {};
  final Map<String, Future<void>> _flushes = {};
  final Set<String> _flushAgain = {};
  final Set<String> _syncAgain = {};
  final Map<String, Timer> _mediaRetries = {};
  final Map<String, int> _mediaRetryMilliseconds = {};
  final Map<String, Future<void>> _keySyncs = {};
  final Map<String, Future<void>> _rekeys = {};
  final _seenP2p = <String>{};
  String? _visibleChatStorageId;
  Set<String> _ownReadReceiptTargets = {};
  final Set<String> _pendingReadReceiptTargets = {};
  Timer? _readReceiptTimer;
  final Map<String, int> _notificationFloors = {};
  final int _notificationStartedAt = DateTime.now().millisecondsSinceEpoch;
  Timer? _notificationTimer;
  bool _pollingNotifications = false;
  bool _notificationsInitialized = false;
  int _notificationPollFailures = 0;
  int _notificationPollOffset = 0;
  int _presenceRequest = 0;
  final Map<String, GroupWatch> _watches = {};
  final Map<String, int> _watchGrantEpochs = {};
  bool _watchSupported = false;
  int _lastGroupDiscovery = -1, _lastSummaryAttempt = -1;
  Timer? _watchSyncTimer;
  Future<void> _watchStates = Future.value();
  DateTime? _nextNotificationPoll;
  Future<void> _sendOperations = Future.value();
  AliasRotationState? _aliasState;
  bool _aliasMigrationComplete = false;
  static const aliasMigrationKey = 'alias-rotation-migrated-v1';
  int get aliasRotationLimit => _aliasState?.limit ?? 1;
  int get aliasMessagesUsed => _aliasState?.used ?? 0;
  static const defaultServer = Invite.defaultServer;
  static const connectionSettingsKey = 'connection-settings-v1';

  bool get hasBundledConnection => defaultConnection.available;
  bool isDefaultServer(String value) => defaultConnection.isForServer(value);
  bool get usingDefaultConnection =>
      hasBundledConnection &&
      isDefaultServer(server) &&
      registrationCode == defaultConnection.registrationCode.trim();

  String get suggestedServer => server.isNotEmpty
      ? server
      : defaultConnection.normalizedServer ??
            const String.fromEnvironment(
              'API_BASE_URL',
              defaultValue: defaultServer,
            );
  bool get configured => server.isNotEmpty && displayName.isNotEmpty;
  bool get isOwner => activeGroup?.ownerId == identity.id;

  int? get activeOnlineCount =>
      activeGroup == null ? null : onlineCountForGroup(activeGroup!);

  int? onlineCountForGroup(Group group) {
    if (_disposed ||
        !_resumed ||
        !ready ||
        !configured ||
        !participationAllowed ||
        group.server != server ||
        isGroupLeft(group) ||
        !groups.any((g) => g.storageId == group.storageId)) {
      return null;
    }
    return _presence.countFor(group.storageId);
  }

  bool get _foreground =>
      (_lifecycleState ?? WidgetsBinding.instance.lifecycleState) == null ||
      (_lifecycleState ?? WidgetsBinding.instance.lifecycleState) ==
          AppLifecycleState.resumed;

  bool _networkAllowedFor(AppLifecycleState? state) =>
      state == null ||
      state == AppLifecycleState.resumed ||
      (state != AppLifecycleState.detached &&
          (isDesktopPlatform ||
              defaultTargetPlatform == TargetPlatform.android));

  /// Android must start its foreground service while the Activity is still
  /// visible. A failed service does not claim background reliability, but it
  /// also does not deliberately tear down an otherwise usable connection.
  Future<void> _updateBackgroundConnection({bool refresh = false}) {
    final operation = _backgroundSync.then((_) async {
      if (_disposed || !backgroundConnection.supported) return;
      bool eligible() =>
          !_disposed &&
          _resumed &&
          ready &&
          configured &&
          api != null &&
          participationAllowed &&
          (pendingGroupLeaveCount > 0 ||
              groups.any((g) => g.server == server && !isGroupLeft(g)));
      if (!eligible()) {
        await backgroundConnection.stop();
      } else if (_foreground) {
        if (refresh) await backgroundConnection.refresh();
        if (eligible() && _foreground) await backgroundConnection.start();
      }
    });
    _backgroundSync = operation.catchError((Object _) {});
    return _backgroundSync;
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  bool _chatIsVisible(String storageId) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return !_disposed &&
        _foreground &&
        _visibleChatStorageId == storageId &&
        activeGroup?.storageId == storageId &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  /// Called by the actual chat route after accounting for privacy cover,
  /// foreground state and navigation. Downloading messages never calls this.
  void setChatVisibility(String storageId, bool visible) {
    if (_disposed) return;
    if (visible && activeGroup?.storageId == storageId) {
      final becameVisible = _visibleChatStorageId != storageId;
      _visibleChatStorageId = storageId;
      unreadHintGroupIds.remove(activeGroup!.id);
      if (becameVisible) {
        unawaited(notifications.clearGroup(storageId));
      }
    } else if (_visibleChatStorageId == storageId) {
      _visibleChatStorageId = null;
      _cancelReadReceipts();
    }
  }

  /// Reports only messages which have appeared in the visible viewport.
  /// Batches are signed and encrypted using the normal durable outbox. A
  /// receipt has no alias and does not consume the forced ID rotation budget.
  Future<void> markMessagesVisible(
    String storageId,
    Iterable<String> messageIds,
  ) async {
    if (!_chatIsVisible(storageId)) return;
    final group = activeGroup!;
    if (!canSendToGroup(group)) return;
    final visibleIds = messageIds.toSet();
    if (visibleIds.isEmpty) return;
    _pendingReadReceiptTargets.addAll(
      messages
          .where(
            (m) =>
                visibleIds.contains(m.envelope.messageId) &&
                !m.isRead &&
                m.envelope.senderId != identity.id &&
                !_ownReadReceiptTargets.contains(m.envelope.messageId),
          )
          .map((m) => m.envelope.messageId)
          .take(256),
    );
    while (_pendingReadReceiptTargets.length > 256) {
      _pendingReadReceiptTargets.remove(_pendingReadReceiptTargets.first);
    }
    if (_pendingReadReceiptTargets.isEmpty || _readReceiptTimer != null) return;
    // Jitter lets the first reader's receipt suppress concurrent receipts in
    // a busy group. Arrival bursts share one bounded encrypted event.
    final jitter = readReceiptDelay == Duration.zero
        ? 0
        : Random().nextInt(750);
    _readReceiptTimer = Timer(
      readReceiptDelay + Duration(milliseconds: jitter),
      () {
        _readReceiptTimer = null;
        unawaited(flushVisibleReadReceipts().catchError((Object _) {}));
      },
    );
  }

  void _cancelReadReceipts() {
    _readReceiptTimer?.cancel();
    _readReceiptTimer = null;
    _pendingReadReceiptTargets.clear();
  }

  @visibleForTesting
  Future<void> flushVisibleReadReceipts() async {
    _readReceiptTimer?.cancel();
    _readReceiptTimer = null;
    final group = activeGroup, view = _groupEpoch;
    if (group == null) {
      _pendingReadReceiptTargets.clear();
      return;
    }
    final storageId = group.storageId;
    final visibleIds = Set<String>.from(_pendingReadReceiptTargets);
    _pendingReadReceiptTargets.clear();
    await _serializeSend(() async {
      if (!_chatIsVisible(storageId) ||
          view != _groupEpoch ||
          !canSendToGroup(group)) {
        return;
      }
      final eligible = messages
          .where(
            (m) =>
                visibleIds.contains(m.envelope.messageId) &&
                !m.isRead &&
                m.envelope.senderId != identity.id &&
                !_ownReadReceiptTargets.contains(m.envelope.messageId),
          )
          .map((m) => m.envelope.messageId)
          .take(ReadReceiptEvent.maxBatchSize)
          .toList();
      if (eligible.isEmpty) return;
      final key = await store.groupKey(group);
      if (key == null) return;
      final eventId = const Uuid().v4();
      final envelope = await crypto.encryptPayload(
        identity: identity,
        groupId: group.id,
        messageId: eventId,
        groupKey: key,
        keyEpoch: group.keyEpoch,
        payload: {
          'type': 'reaction',
          // Older clients treat this as an invisible removal targeting only
          // this control event, never a real message or a user's reaction.
          'targetMessageId': eventId,
          'action': 'remove',
          'counter': 1,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'readReceiptV1': {'v': 1, 'messageIds': eligible},
        },
      );
      if (!_chatIsVisible(storageId) ||
          view != _groupEpoch ||
          !canSendToGroup(group)) {
        return;
      }
      await store.queue(group, envelope);
      _ownReadReceiptTargets.addAll(eligible);
      await _publishQueued(group, envelope);
    });
  }

  String friendly(Object e) {
    if (e is SecretAccessBlockedException) {
      return '钥匙串访问已暂停，不会继续弹窗。确认系统已允许访问后，点击重新尝试或重新连接；原身份和聊天记录保留。';
    }
    if (e is FormatException) return e.message;
    if (e is ApiException) {
      return switch (e.code) {
        'media_storage_full' => '群语音存储空间已满，文字仍可发送',
        'media_not_found' => '语音已过期或暂时不可用',
        'group_client_upgrade_required' => '请安装最新的 0.4.0 修订包后参与本群',
        'group_left' => '你已退出本群，本机历史仍可查看',
        'group_closed' => '所有成员已退出，本群已关闭',
        'rate_limited' => '请求过于频繁，稍后会自动重试',
        _ => e.message,
      };
    }
    if (e is TimeoutException) return '连接超时，消息已保存在本机，联网后会重试';
    return '网络或本机存储暂时不可用，请稍后重试';
  }

  void clearError() {
    error = null;
    changed();
  }

  Future<void> retryInitialization() async {
    if (_initializing || ready || _disposed) return;
    store.retrySecretAccess();
    error = null;
    changed();
    await initialize();
  }

  Future<void> initialize() async {
    if (_initializing || ready || _disposed) return;
    _initializing = true;
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    _resumed = _networkAllowedFor(_lifecycleState);
    _presence.onChanged = changed;
    backgroundConnection.onChanged = changed;
    store.onSecretMigrationProgress = changed;
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    try {
      await store.open();
      if (_disposed) return;
      final seed = await store.readSecret('identity-seed');
      if (_disposed) return;
      final hasHistory = await store.hasChatData();
      if (_disposed) return;
      final persistedAlias = await store.readAliasState();
      if (_disposed) return;
      final aliasMigrated = await store.readSecret(aliasMigrationKey);
      if (_disposed) return;
      final savedConnection = await store.readSecret(connectionSettingsKey);
      if (_disposed) return;
      final oldServer = savedConnection == null
          ? await store.readSecret('server')
          : null;
      final oldCode = savedConnection == null
          ? await store.readSecret('registration-code')
          : null;
      if (_disposed) return;
      if (seed == null &&
          (hasHistory ||
              persistedAlias != null ||
              aliasMigrated != null ||
              savedConnection != null ||
              oldServer != null ||
              oldCode != null)) {
        throw const FormatException(
          '已有聊天记录或连接配置，但无法读取原来的设备密钥。请检查安全存储访问权限并重新打开应用；现有记录不会被新身份覆盖。',
        );
      }
      identity = await crypto.identity(seed == null ? null : unb64(seed));
      if (_disposed) return;
      if (seed == null) {
        await store.writeSecret('identity-seed', b64(identity.seed));
      }
      final encryptionSeed = await store.readSecret(encryptionSeedKey);
      if (_disposed) return;
      if (encryptionSeed == null &&
          await store.readSecret(encryptionEnrollmentKey) != null) {
        throw const FormatException('无法读取原来的群加密私钥。请恢复安全存储访问权限；不会用新密钥覆盖身份。');
      }
      encryptionIdentity = await crypto.encryptionIdentity(
        encryptionSeed == null ? null : unb64(encryptionSeed),
      );
      if (_disposed) return;
      if (encryptionSeed == null) {
        await store.writeSecret(
          encryptionSeedKey,
          b64(encryptionIdentity!.seed),
        );
      }
      _departures = await store.groupDepartures();
      await _resumeLocalDeletions();
      for (final id in _departures.keys) {
        final intent = await store.readState('pending-rejoin:$id');
        if (intent != null) _rejoinIntents[id] = intent;
      }
      _policyFloor = await store.readState(policyStateKey) ?? {};
      if (_floorRequiresUpdate) {
        participationBlock = const UpgradeRequiredException();
      }
      await _restoreAliasState(hasHistory: hasHistory);
      if (_disposed) return;
      // Identity and local data remain usable if a connection needs repair or
      // the first automatic network request fails.
      ready = true;
      _startNetworkMonitoring();
      final connection = await _restoreConnection(
        hasHistory: hasHistory,
        saved: savedConnection,
        oldServer: oldServer,
        oldCode: oldCode,
      );
      if (_disposed) return;
      if (connection != null) {
        server = connection.server;
        registrationCode = connection.code;
      }
      if (configured) {
        await _reloadGroups();
        _setApi();
        unawaited(reconnect());
      }
      push.onMessage = () async {
        if (activeGroup != null) {
          await syncActive();
        } else {
          await refreshGroups();
        }
      };
      push.onStatusChanged = changed;
      push.onGroupHint = handlePushHint;
      notifications.onStatusChanged = changed;
      notifications.onOpenGroup = (storageId) async {
        if (_disposed || !ready) return;
        final group = groups.where((g) => g.storageId == storageId).firstOrNull;
        if (group == null || isGroupLeft(group)) return;
        pendingOpenGroupId = group.id;
        changed();
      };
      unawaited(
        notifications.initialize().then((_) {
          if (!_disposed) _notificationsInitialized = true;
        }),
      );
      _notificationTimer ??= Timer.periodic(notificationInterval, (_) {
        unawaited(pollMessageNotifications());
      });
      unawaited(_updateBackgroundConnection());
      unawaited(
        push.initialize().then((_) {
          changed();
        }),
      );
    } catch (e) {
      if (e is SecretAccessBlockedException || store.secretAccessBlocked) {
        ready = false;
      }
      error = '初始化失败：${friendly(e)}';
    } finally {
      _initializing = false;
    }
    changed();
  }

  Future<_SavedConnection?> _restoreConnection({
    required bool hasHistory,
    required String? saved,
    required String? oldServer,
    required String? oldCode,
  }) async {
    if (saved != null) {
      try {
        final value = jsonDecode(saved);
        if (value is! Map<String, dynamic> ||
            value['v'] is! int ||
            value['v'] != 1 ||
            value['server'] is! String ||
            value['code'] is! String ||
            (value['server'] as String).trim().isEmpty ||
            RegExp(r'[\r\n]').hasMatch(value['code'] as String)) {
          throw const FormatException();
        }
        return await _restoreSavedConnection(
          normalizeServer(
            value['server'] as String,
            allowLocalHttp: ApiClient.allowsLocalHttp,
          ),
          value['code'] as String,
        );
      } on FormatException {
        throw const FormatException('已保存的连接配置损坏，请在设置中修复；现有身份和聊天记录已保留');
      }
    }
    if (oldServer != null || oldCode != null) {
      if (oldServer == null || oldServer.trim().isEmpty) {
        throw const FormatException('本机连接配置不完整，请在设置中恢复原来的服务；不会自动切换默认服务');
      }
      return _restoreSavedConnection(
        normalizeServer(oldServer, allowLocalHttp: ApiClient.allowsLocalHttp),
        oldCode ?? '',
      );
    }
    if (hasHistory) {
      throw const FormatException('已有聊天记录但缺少服务配置，请在设置中恢复原来的服务；现有数据已保留');
    }
    if (!hasBundledConnection) {
      if (defaultConnection.server.trim().isNotEmpty &&
          defaultConnection.registrationCode.trim().isNotEmpty) {
        throw const FormatException('应用的默认服务配置无效，请在设置中填写有效的 HTTPS 服务地址');
      }
      return null;
    }
    final connection = _SavedConnection(
      defaultConnection.normalizedServer!,
      defaultConnection.registrationCode.trim(),
    );
    await _saveConnection(connection);
    return connection;
  }

  Future<_SavedConnection> _restoreSavedConnection(
    String previous,
    String code,
  ) async {
    const previousOfficialOrigins = {
      'https://nearlink-api.nearlink-lovelyjhwsb.workers.dev',
      'https://hello-mentor-entry.pages.dev',
    };
    if (!previousOfficialOrigins.contains(Uri.parse(previous).origin) ||
        !defaultConnection.available ||
        !defaultConnection.isForServer(defaultServer)) {
      return _SavedConnection(previous, code);
    }
    final connection = _SavedConnection(
      defaultConnection.normalizedServer!,
      defaultConnection.registrationCode.trim(),
    );
    await store.writeState(policyStateKey, {});
    await _saveConnection(connection);
    _policyFloor = {};
    participationBlock = null;
    return connection;
  }

  Future<void> _saveConnection(_SavedConnection connection) =>
      store.writeSecret(
        connectionSettingsKey,
        jsonEncode({
          'v': 1,
          'server': connection.server,
          'code': connection.code,
        }),
      );

  void _setApi() {
    _stopWatches();
    _watchSupported = false;
    _networkEpoch++;
    _presenceRequest++;
    _presence.clear();
    _notificationPollFailures = 0;
    _nextNotificationPoll = null;
    _cancelMediaRetries();
    _reconnectAgain = true;
    defaultConnection.resolveCode(server, registrationCode);
    api?.close();
    api = _apiFactory(
      server: server,
      identity: identity,
      crypto: crypto,
      registrationCode: registrationCode,
    );
    _policy = null;
    _policyClock = null;
    _policyRefreshTimer?.cancel();
    _policyExpiryTimer?.cancel();
    unawaited(_updateBackgroundConnection());
    api!.ensureParticipation = _requireParticipation;
    api!.onUpgradeRequired = (block) {
      _responsePolicyFloor = block.policy;
      _enterPolicyBlock(block);
      unawaited(refreshPolicy());
    };
    if (participationBlock != null) {
      api!.blockParticipation(participationBlock!);
    }
    push.api = api;
  }

  Future<void> configure(String newServer, String name, String code) async {
    store.retrySecretAccess();
    final normalized = normalizeServer(
      newServer,
      allowLocalHttp: ApiClient.allowsLocalHttp,
    );
    final nextCode = defaultConnection.resolveCode(
      normalized,
      code,
      fillDefault: true,
    );
    // The legacy name argument is accepted for source compatibility only.
    // Connection settings cannot reset the alias or its durable message budget.
    await _serializeSend(() => _restoreAliasState());
    await _saveConnection(_SavedConnection(normalized, nextCode));
    await closeGroup();
    server = normalized;
    registrationCode = nextCode;
    online = false;
    _setApi();
    await _reloadGroups();
    await reconnect();
  }

  Future<T> _serializeSend<T>(Future<T> Function() work) {
    final result = _sendOperations.then((_) => work());
    _sendOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _applyAliasState(AliasRotationState value) {
    _aliasState = value;
    displayName = value.alias;
    final own = members[identity.id];
    if (own != null) {
      members[identity.id] = Member(own.id, own.publicKey, value.alias);
    }
  }

  Future<String> _restoreAliasState({bool? hasHistory}) async {
    var encoded = await store.readAliasState();
    if (encoded == null) {
      if (_aliasMigrationComplete ||
          await store.readSecret(aliasMigrationKey) != null) {
        throw const FormatException('临时ID计数记录缺失，请恢复完整本机数据；为避免重复使用旧ID，已停止发送');
      }
      final previous = await store.readSecret('display-name') ?? displayName;
      final history = hasHistory ?? await store.hasChatData();
      final state = AliasRotationState(
        alias: !history && TemporaryId.isValid(previous)
            ? previous
            : TemporaryId.generate(differentFrom: previous),
      );
      encoded = await crypto.sealAliasState(identity, state.toJson());
      await store.updateAliasState(null, encoded, ownDeviceId: identity.id);
      _applyAliasState(state);
    } else {
      _applyAliasState(
        AliasRotationState.fromJson(
          await crypto.openAliasState(identity, encoded),
        ),
      );
      if (!_aliasMigrationComplete) {
        await store.anonymizeOwnMemberNames(identity.id);
      }
    }
    // A committed state survives a crash before this marker. Complete migration
    // in that case; a marker without state must never silently reset the budget.
    if (!_aliasMigrationComplete) {
      if (await store.readSecret(aliasMigrationKey) == null) {
        await store.writeSecret(aliasMigrationKey, '1');
      }
      await store.deleteSecret('display-name');
      _aliasMigrationComplete = true;
    }
    return encoded;
  }

  Future<void> setAliasRotationLimit(int value) => _serializeSend(() async {
    if (_disposed) throw StateError('Controller closed');
    final previous = await _restoreAliasState();
    final next = _aliasState!.withLimit(value);
    final encoded = await crypto.sealAliasState(identity, next.toJson());
    await store.updateAliasState(previous, encoded, ownDeviceId: identity.id);
    _applyAliasState(next);
    changed();
  });

  bool _current(ApiClient client, int epoch) =>
      !_disposed && identical(client, api) && epoch == _networkEpoch;

  void _startNetworkMonitoring() {
    _networkSubscription ??= networkMonitor.changes.listen(
      (change) {
        final initial = !_receivedInitialPath;
        _receivedInitialPath = true;
        if (initial && change.available) {
          return; // Initial bootstrap is in flight.
        }
        _networkDebounce?.cancel();
        _networkDebounce = Timer(networkDebounce, () {
          if (_disposed || !_resumed || api == null) return;
          _invalidateNetwork();
          if (change.available) {
            unawaited(reconnect());
          } else {
            error = '网络已断开，消息保存在本机，连接恢复后会自动重试';
            _scheduleOutboxRetry();
            changed();
          }
        });
      },
      onError: (Object _) {
        // A missing/failed platform monitor must not disable fallback recovery.
      },
    );
    _healthTimer ??= Timer.periodic(healthInterval, (_) {
      unawaited(_checkNetworkHealth());
    });
  }

  Future<void> _checkNetworkHealth() async {
    if (_disposed ||
        !_resumed ||
        api == null ||
        _healthChecking ||
        api!.quotaRetryAfter > Duration.zero ||
        _reconnecting != null ||
        (online &&
            pendingGroupLeaveCount == 0 &&
            groups.any((group) => !isGroupLeft(group)) &&
            _watchCoverageHealthy) ||
        connection.socketOnline) {
      return;
    }
    _healthChecking = true;
    if (!participationAllowed) {
      try {
        await refreshPolicy();
        if (participationAllowed) await reconnect();
      } finally {
        _healthChecking = false;
      }
      return;
    }
    final client = api!, epoch = _networkEpoch;
    try {
      await client.checkHealth();
      if (_current(client, epoch) && (!online || pendingGroupLeaveCount > 0)) {
        await reconnect();
      }
    } catch (e) {
      if (_current(client, epoch)) {
        online = false;
        error = friendly(e);
        _invalidateNetwork();
        _scheduleOutboxRetry();
        changed();
      }
    } finally {
      _healthChecking = false;
    }
  }

  /// Invalidate callbacks immediately, then close the old native RTC session
  /// before replacing the HTTP pool. A pending request is aborted by the reset,
  /// so the next route never has to wait for its original network timeout.
  void _invalidateNetwork() {
    _stopWatches();
    final epoch = ++_networkEpoch, client = api;
    _presenceRequest++;
    _presence.clear();
    _notificationPollFailures = 0;
    _nextNotificationPoll = null;
    _rtcAttempt++;
    _reconnectAgain = true;
    online = false;
    _syncDebounce?.cancel();
    _outboxRetry?.cancel();
    _cancelMediaRetries();
    final rtc = _rtc;
    _rtc = null;
    connection = const ConnectionReport(note: '网络变化，正在恢复连接');
    final previousReset = _transportReset;
    final stopping = rtc?.stop();
    _transportReset = () async {
      await previousReset;
      await stopping;
      if (client != null && _current(client, epoch)) client.resetTransport();
    }();
    changed();
  }

  void _connectionLost() {
    if (_disposed || !_resumed || !participationAllowed) return;
    _invalidateNetwork();
    error = '连接暂时中断，正在自动重试';
    _scheduleOutboxRetry();
    changed();
  }

  /// Explicit user retry also reloads routing when proxy settings changed
  /// without a native interface/path notification.
  Future<void> retryConnection() {
    store.retrySecretAccess();
    if (api == null || !_resumed || _disposed) return Future.value();
    if (!api!.prepareManualQuotaRetry()) return Future.value();
    _invalidateNetwork();
    return reconnect();
  }

  Future<void> reconnect() {
    if (api == null || !_resumed || _disposed) return Future.value();
    final pending = _reconnecting;
    if (pending != null) return pending;
    _reconnectAgain = true;
    final operation = _drainReconnects();
    _reconnecting = operation;
    return operation.whenComplete(() {
      if (identical(_reconnecting, operation)) _reconnecting = null;
      if (_reconnectAgain && !_disposed && _resumed) unawaited(reconnect());
    });
  }

  Future<void> _drainReconnects() async {
    while (_reconnectAgain && !_disposed && _resumed && api != null) {
      _reconnectAgain = false;
      final client = api!, epoch = _networkEpoch;
      try {
        await _transportReset;
        if (!_current(client, epoch)) continue;
        if (!participationAllowed) await refreshPolicy();
        if (!_current(client, epoch) || !participationAllowed) continue;
        if (encryptionIdentity == null) {
          final saved = await store.readSecret(encryptionSeedKey);
          encryptionIdentity = await crypto.encryptionIdentity(
            saved == null ? null : unb64(saved),
          );
          if (saved == null) {
            await store.writeSecret(
              encryptionSeedKey,
              b64(encryptionIdentity!.seed),
            );
          }
        }
        if (!_current(client, epoch)) continue;
        await store.writeSecret(
          encryptionEnrollmentKey,
          encryptionIdentity!.publicKey,
        );
        if (!_current(client, epoch)) continue;
        await client.request('POST', '/v1/devices', {
          'displayName': displayName,
          'encryptionPublicKey': encryptionIdentity!.publicKey,
        });
        if (!_current(client, epoch)) continue;
        await _flushDepartures(client, epoch);
        if (!_current(client, epoch)) continue;
        await refreshGroups(client: client);
        if (!_current(client, epoch)) continue;
        online = true;
        error = null;
        if (activeGroup == null) _retrySeconds = 2;
        _outboxRetry?.cancel();
        if (pendingGroupLeaveCount > 0) _scheduleOutboxRetry();
        unawaited(push.retryRegistration());
        for (final group in groups.toList()) {
          if (!_current(client, epoch)) break;
          await _refreshMembers(group, client: client);
          if (canSendToGroup(_currentGroup(group))) {
            await flushOutbox(_currentGroup(group));
          }
        }
        if (!_current(client, epoch)) continue;
        final group = activeGroup;
        if (group != null && !isGroupLeft(group)) {
          await _refreshMembers(group, client: client);
          await syncActive();
          if (_current(client, epoch) && _rtc == null) {
            await _connectRtc(_currentGroup(group));
          }
        }
      } catch (e) {
        if (_current(client, epoch) && e is! TransportChangedException) {
          online = false;
          error = friendly(e);
          _scheduleOutboxRetry();
        }
      }
      changed();
    }
  }

  Future<void> refreshGroups({ApiClient? client}) async {
    if (api == null || _disposed || !_resumed) return;
    final requestClient = client ?? api!, epoch = _networkEpoch;
    final presenceRequest = ++_presenceRequest;
    final presenceStartedAt = _presence.now;
    final intentsAtRequest = Map<String, Map<String, dynamic>>.from(
      _rejoinIntents,
    );
    _lastSummaryAttempt = presenceStartedAt;
    final response = await requestClient.request('GET', '/v1/groups');
    if (!_current(requestClient, epoch)) return;
    final summaries = (response['groups'] as List)
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    await _acceptGroupSummaries(
      requestClient,
      epoch,
      summaries,
      presenceStartedAt: presenceStartedAt,
      presenceRequest: presenceRequest,
      intentsAtRequest: intentsAtRequest,
    );
    if (!_current(requestClient, epoch)) return;
    _watchSupported = response['watchVersion'] == 1;
    _lastGroupDiscovery = _presence.now;
    _reconcileWatches(requestClient, epoch, summaries);
  }

  Future<void> _acceptGroupSummaries(
    ApiClient requestClient,
    int epoch,
    List<Map<String, dynamic>> summaries, {
    required int presenceStartedAt,
    int? presenceRequest,
    bool replacePresence = true,
    Map<String, Map<String, dynamic>> intentsAtRequest = const {},
  }) async {
    final presenceSummaries = <String, Map<String, dynamic>>{};
    for (final json in summaries) {
      if (!_current(requestClient, epoch)) return;
      var group = Group.fromJson(
        Map<String, dynamic>.from(json),
        requestClient.server,
      );
      group = await _withAdmissionFloor(group, Map<String, dynamic>.from(json));
      if (!_current(requestClient, epoch)) return;
      if (isGroupLeft(group)) {
        final intent = intentsAtRequest[group.storageId];
        final leave = _departures[group.storageId];
        if (intent == null ||
            leave == null ||
            leave['pending'] == true ||
            _leavingGroups.contains(group.storageId) ||
            intent['leaveId'] != leave['leaveId'] ||
            _rejoinIntents[group.storageId]?['leaveId'] != intent['leaveId'] ||
            group.keyEpoch < (intent['keyEpoch'] as int)) {
          continue;
        }
        // Only an explicit, persisted rejoin intent can recover a lost reply.
        // Requests started before that intent may never revive a departure.
        await store.recoverPendingKey(group);
        if (!_current(requestClient, epoch) ||
            _leavingGroups.contains(group.storageId)) {
          return;
        }
        await store.finishGroupJoin(group, leave['leaveId'] as String);
        _notificationFloors[group.storageId] = group.lastSeq;
        media.allowGroup(group);
        _departures.remove(group.storageId);
        _rejoinIntents.remove(group.storageId);
        await store.deleteState('pending-rejoin:${group.storageId}');
      }
      await store.recoverPendingKey(
        group,
      ); // Membership confirms a join whose response may have been lost.
      await store.saveGroup(group);
      // Only accepted memberships establish the initial baseline. A stale
      // listing after leaving must not establish the next admission's floor.
      if (!isGroupLeft(group)) {
        _notificationFloors.putIfAbsent(group.storageId, () => group.lastSeq);
        presenceSummaries[group.storageId] = Map<String, dynamic>.from(json);
      }
      await store.deleteState('pending-admission:${group.storageId}');
    }
    if (!_current(requestClient, epoch)) return;
    await _reloadGroups();
    if (!_current(requestClient, epoch)) return;
    if ((presenceRequest == null || presenceRequest == _presenceRequest) &&
        _resumed &&
        participationAllowed) {
      presenceSummaries.removeWhere(
        (storageId, _) =>
            !groups.any((g) => g.storageId == storageId && !isGroupLeft(g)),
      );
      _presence.accept(
        presenceSummaries,
        requestStartedAt: presenceStartedAt,
        replace: replacePresence,
      );
    }
    if (activeGroup case final current?) {
      final updated = _currentGroup(current);
      if (updated.keyEpoch != current.keyEpoch ||
          updated.membershipRevision != current.membershipRevision ||
          updated.rekeyRequired != current.rekeyRequired ||
          updated.minClientBuild != current.minClientBuild) {
        _groupEpoch++;
        _rtcAttempt++;
        final previous = _rtc;
        _rtc = null;
        unawaited(previous?.stop());
      }
      activeGroup = updated;
    }
    online = true;
    changed();
  }

  void _stopWatches() {
    _watchSyncTimer?.cancel();
    _watchSyncTimer = null;
    for (final watch in _watches.values) {
      unawaited(watch.stop());
    }
    _watches.clear();
    _watchGrantEpochs.clear();
    _lastGroupDiscovery = -1;
  }

  bool get _watchCoverageHealthy =>
      _watchSupported &&
      groups
          .where((group) => !isGroupLeft(group))
          .every((group) => _watches[group.storageId]?.healthy == true);

  void _reconcileWatches(
    ApiClient client,
    int epoch,
    List<Map<String, dynamic>> summaries,
  ) {
    if (!_watchSupported) {
      _stopWatches();
      return;
    }
    final admitted = summaries.map((group) => group['groupId']).toSet();
    final eligible = groups.where(
      (group) => admitted.contains(group.id) && !isGroupLeft(group),
    );
    final desired = eligible.map((group) => group.storageId).toSet();
    for (final id in _watches.keys.toList()) {
      if (!desired.contains(id)) unawaited(_watches.remove(id)?.stop());
    }
    for (final group in eligible) {
      if (_watches.containsKey(group.storageId)) continue;
      late GroupWatch watch;
      bool current() =>
          _current(client, epoch) &&
          _resumed &&
          participationAllowed &&
          !isGroupLeft(group) &&
          identical(_watches[group.storageId], watch);
      watch = GroupWatch(
        api: client,
        groupId: group.id,
        allowed: current,
        now: () => _presence.now,
        interval: notificationInterval,
        onState: (summary, startedAt) {
          final operation = _watchStates.then((_) async {
            if (!current()) return;
            final before = _currentGroup(group);
            final grant = summary['grantedKeyEpoch'];
            final previousGrant = _watchGrantEpochs[group.storageId];
            final grantChanged =
                grant is int && previousGrant != null && grant != previousGrant;
            await _acceptGroupSummaries(
              client,
              epoch,
              [summary],
              presenceStartedAt: startedAt,
              replacePresence: false,
            );
            if (!current()) return;
            final after = _currentGroup(group);
            if (grantChanged ||
                before.keyEpoch != after.keyEpoch ||
                before.membershipRevision != after.membershipRevision ||
                before.rekeyRequired != after.rekeyRequired ||
                before.minClientBuild != after.minClientBuild) {
              await _refreshMembers(after, client: client);
              if (!current()) return;
              if (activeGroup?.storageId == after.storageId && _rtc == null) {
                unawaited(_startGroupNetworking(after));
              }
            }
            if (grant is int && grant >= 0 && grant <= after.keyEpoch) {
              _watchGrantEpochs[group.storageId] = grant;
            }
            _scheduleWatchSync();
          });
          // Keep one failed update from poisoning subsequent independent rooms.
          _watchStates = operation.catchError((Object _) {});
          return operation;
        },
        onUnavailable: (reason) {
          if (!current()) return;
          if (reason == 'watch_removed' || reason == 'group_left') {
            _presence.remove(group.storageId);
            _watchGrantEpochs.remove(group.storageId);
            _watches.remove(group.storageId);
            unawaited(watch.stop());
          }
          _scheduleWatchSync();
        },
      );
      _watches[group.storageId] = watch;
      unawaited(watch.start());
    }
  }

  void _scheduleWatchSync() {
    if (_disposed || _watchSyncTimer != null) return;
    _watchSyncTimer = Timer(const Duration(milliseconds: 250), () {
      _watchSyncTimer = null;
      unawaited(pollMessageNotifications());
    });
  }

  Future<Group> createGroup(String name) async {
    _requireParticipation();
    if (api == null) throw const ApiException('请先配置服务');
    final client = api!, epoch = _networkEpoch;
    if (name.trim().isEmpty || name.trim().length > 60) {
      throw const FormatException('群名称需要 1～60 个字符');
    }
    final id = const Uuid().v4();
    final draft = Group(
      id: id,
      server: client.server,
      name: name.trim(),
      ownerId: identity.id,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      keyEpoch: 1,
      protocolVersion: AppSecurity.protocolVersion,
      privacyEpoch: AppSecurity.privacyEpoch,
      minClientBuild: AppSecurity.clientBuild,
    );
    await store.saveKey(draft, crypto.randomBytes(32));
    _availableGroupKeys.add('${draft.storageId}:${draft.keyEpoch}');
    _checkClient(client, draft, epoch: epoch);
    final response = await client.request('POST', '/v1/groups', {
      'groupId': id,
      'name': name.trim(),
    });
    _checkClient(client, draft, epoch: epoch);
    final group = Group.fromJson(response, client.server);
    await store.saveGroup(group);
    await _reloadGroups();
    _checkClient(client, group, epoch: epoch);
    changed();
    return group;
  }

  Future<Invite> createInvite(Group group) async {
    _requireGroupSend(group);
    final client = api!, epoch = _networkEpoch;
    _checkClient(client, group, epoch: epoch);
    final key = await store.groupKey(group);
    if (key == null) throw const ApiException('缺少群密钥，请重新导入邀请码');
    final secret = crypto.randomBytes(32), id = const Uuid().v4();
    final expires = DateTime.now()
        .add(const Duration(hours: 24))
        .millisecondsSinceEpoch;
    _checkClient(client, group, epoch: epoch);
    await client.request('POST', '/v1/groups/${group.id}/invites', {
      'inviteId': id,
      'secretHash': await crypto.hash(secret),
      'expiresAt': expires,
      'maxUses': 49,
      'keyEpoch': group.keyEpoch,
    });
    _checkClient(client, group, epoch: epoch);
    await store.addInvite(group, id, expires);
    return Invite(
      server: group.server,
      groupId: group.id,
      name: group.name,
      inviteId: id,
      secret: b64(secret),
      groupKey: b64(key),
      expiresAt: expires,
      keyEpoch: group.keyEpoch,
      protocolVersion: group.protocolVersion,
      privacyEpoch: group.privacyEpoch,
      minClientBuild: group.minClientBuild,
    );
  }

  Invite parseInvite(String value) => Invite.parse(
    value,
    validateServer: (s) =>
        normalizeServer(s, allowLocalHttp: ApiClient.allowsLocalHttp),
  );
  Future<String> shareInvite(Invite invite) async {
    _requireParticipation();
    final client = api, epoch = _networkEpoch;
    if (client == null || invite.server != client.server) {
      throw const ApiException('请先连接邀请码对应的服务');
    }
    final code = await ShortInviteService.create(invite, client);
    if (!_current(client, epoch)) throw _ConnectionChanged();
    _requireParticipation();
    return code;
  }

  Future<Invite> resolveInvite(String value) async {
    if (!ShortInviteService.isCode(value)) return parseInvite(value);
    _requireParticipation();
    final client = api, epoch = _networkEpoch;
    if (client == null) throw const ApiException('请先连接聊天服务');
    final invite = await ShortInviteService.resolve(value, client);
    if (!_current(client, epoch)) throw _ConnectionChanged();
    _requireParticipation();
    return invite;
  }

  Future<Group> join(Invite invite) async {
    _requireParticipation();
    if (invite.keyEpoch < 1 ||
        invite.protocolVersion != AppSecurity.protocolVersion ||
        invite.privacyEpoch != AppSecurity.privacyEpoch ||
        invite.minClientBuild > AppSecurity.clientBuild) {
      throw const ApiException('此邀请码属于旧版或尚未支持的群，请群主更新群密钥后提供新邀请码');
    }
    if (invite.server != server) {
      throw const ApiException('请先在连接设置中切换到邀请码对应的服务');
    }
    if (api == null) throw const ApiException('请先连接服务');
    final client = api!, epoch = _networkEpoch;
    final draft = Group(
      id: invite.groupId,
      server: client.server,
      name: invite.name,
      ownerId: '',
      keyEpoch: invite.keyEpoch,
      protocolVersion: invite.protocolVersion,
      privacyEpoch: invite.privacyEpoch,
      minClientBuild: invite.minClientBuild,
    );
    if (_leavingGroups.contains(draft.storageId) ||
        _departures[draft.storageId]?['pending'] == true ||
        _departures[draft.storageId]?['cleanupPending'] == true ||
        _leaveRequests.containsKey(draft.storageId)) {
      throw const ApiException('请先联网完成退群，再使用新的邀请码重新加入');
    }
    final departureId = _departures[draft.storageId]?['leaveId'];
    final existing = await store.groupKey(draft);
    if (existing != null && b64(existing) != invite.groupKey) {
      throw const ApiException('此邀请码与本机已有群密钥不一致，已拒绝覆盖');
    }
    // Staging survives a lost success response without allowing a rejected
    // invitation to overwrite/block a future valid group key.
    _checkClient(client, draft, epoch: epoch, allowLeft: true);
    final joinStartedAt = DateTime.now().millisecondsSinceEpoch;
    final newAdmission =
        departureId != null ||
        !groups.any((g) => g.storageId == draft.storageId);
    await store.prepareGroupJoin(
      draft,
      departureId,
      joinStartedAt,
      newAdmission: newAdmission,
    );
    if (departureId != null) {
      _rejoinIntents[draft.storageId] = {
        'leaveId': departureId,
        'keyEpoch': invite.keyEpoch,
      };
    }
    await store.savePendingKey(draft, unb64(invite.groupKey));
    _checkClient(client, draft, epoch: epoch, allowLeft: true);
    late Map<String, dynamic> response;
    try {
      response = await client
          .request('POST', '/v1/groups/${invite.groupId}/join', {
            'inviteId': invite.inviteId,
            'secret': invite.secret,
            'keyEpoch': invite.keyEpoch,
          });
    } on ApiException catch (e) {
      if (e.status != null && e.status! >= 400 && e.status! < 500) {
        await store.discardPendingKey(draft);
        await store.deleteState('pending-admission:${draft.storageId}');
        _rejoinIntents.remove(draft.storageId);
        await store.deleteState('pending-rejoin:${draft.storageId}');
      }
      rethrow;
    }
    _checkClient(client, draft, epoch: epoch, allowLeft: true);
    await store.saveKey(draft, unb64(invite.groupKey));
    _availableGroupKeys.add('${draft.storageId}:${draft.keyEpoch}');
    await store.discardPendingKey(draft);
    final group = await _withAdmissionFloor(
      Group.fromJson(response, client.server),
      response,
    );
    await store.saveGroup(group);
    if ((_departures[draft.storageId] != null &&
            _departures[draft.storageId]?['leaveId'] != departureId) ||
        _leavingGroups.contains(draft.storageId)) {
      throw _ConnectionChanged();
    }
    await store.finishGroupJoin(group, departureId);
    if (newAdmission) _notificationFloors[group.storageId] = group.lastSeq;
    media.allowGroup(group);
    _departures.remove(group.storageId);
    _rejoinIntents.remove(group.storageId);
    await store.deleteState('pending-rejoin:${group.storageId}');
    await _reloadGroups();
    _checkClient(client, group, epoch: epoch);
    changed();
    return group;
  }

  Future<Group> _withAdmissionFloor(
    Group group,
    Map<String, dynamic> response,
  ) async {
    if (response.containsKey('historySince')) return group;
    final pending = await store.readState(
      'pending-admission:${group.storageId}',
    );
    if (pending == null) return group;
    return group.copyWith(
      joinedAt: pending['joinedAt'] as int,
      historySince: pending['historySince'] as int,
    );
  }

  Future<void> revokeInvite(Group group, String id) async {
    final client = api!, epoch = _networkEpoch;
    _checkClient(client, group, epoch: epoch);
    await client.request('DELETE', '/v1/groups/${group.id}/invites/$id');
    _checkClient(client, group, epoch: epoch);
    await store.deleteInvite(group, id);
  }

  Future<void> openGroup(Group group) async {
    await closeGroup();
    final view = _groupEpoch;
    if (await store.groupKey(group) != null) {
      _availableGroupKeys.add('${group.storageId}:${group.keyEpoch}');
    }
    if (_disposed || view != _groupEpoch) return;
    activeGroup = group;
    unreadHintGroupIds.remove(group.id);
    final roster = await store.members(group);
    if (_disposed || view != _groupEpoch) return;
    members = {for (final m in roster) m.id: m};
    members.putIfAbsent(
      identity.id,
      () => Member(identity.id, identity.publicKey, displayName),
    );
    await _loadMessages(group);
    changed();
    if (participationAllowed && !isGroupLeft(group)) {
      unawaited(_startGroupNetworking(group));
    }
  }

  Future<void> handlePushHint(String groupId, bool opened) async {
    if (_departures.values.any(
      (d) => d['groupId'] == groupId && d['server'] == server,
    )) {
      return;
    }
    if (opened && activeGroup?.id != groupId) pendingOpenGroupId = groupId;
    unreadHintGroupIds.add(groupId);
    changed();
    if (!ready || !configured || api == null || !participationAllowed) return;
    if (activeGroup?.id == groupId) {
      pendingOpenGroupId = null;
      unreadHintGroupIds.remove(groupId);
      await syncActive();
    } else {
      try {
        await refreshGroups();
      } catch (e) {
        error = '有群消息待同步，恢复连接后重试';
        _scheduleOutboxRetry();
        changed();
      }
    }
  }

  void consumeNotification(String id) {
    if (pendingOpenGroupId == id) pendingOpenGroupId = null;
  }

  Future<void> _startGroupNetworking(Group group) async {
    if (!participationAllowed || isGroupLeft(group)) return;
    final epoch = _networkEpoch, view = _groupEpoch;
    try {
      await _refreshMembers(group);
      if (epoch != _networkEpoch) return;
      if (view != _groupEpoch) {
        if (activeGroup?.storageId == group.storageId) {
          unawaited(_startGroupNetworking(activeGroup!));
        }
        return;
      }
      await syncActive();
      await flushOutbox(_currentGroup(group));
    } catch (e) {
      if (e is! _ConnectionChanged &&
          e is! TransportChangedException &&
          epoch == _networkEpoch) {
        error = friendly(e);
        _scheduleOutboxRetry();
        changed();
      }
    }
    if (epoch == _networkEpoch &&
        view == _groupEpoch &&
        activeGroup?.storageId == group.storageId &&
        _resumed &&
        _rtc == null) {
      await _connectRtc(_currentGroup(group));
    }
  }

  void _checkClient(
    ApiClient client,
    Group group, {
    int? epoch,
    bool allowLeft = false,
  }) {
    _requireParticipation();
    if (_disposed ||
        (!allowLeft && isGroupLeft(group)) ||
        !identical(client, api) ||
        client.server != group.server ||
        (epoch != null && epoch != _networkEpoch)) {
      throw _ConnectionChanged();
    }
  }

  Future<void> _refreshMembers(
    Group group, {
    ApiClient? client,
    bool autoRekey = true,
  }) async {
    final requestClient = client ?? api!, epoch = _networkEpoch;
    _checkClient(requestClient, group, epoch: epoch);
    final response = await requestClient.request(
      'GET',
      '/v1/groups/${group.id}',
    );
    _checkClient(requestClient, group, epoch: epoch);
    final summary = Group.fromJson(response, group.server);
    if (summary.keyEpoch < _currentGroup(group).keyEpoch ||
        summary.membershipRevision < _currentGroup(group).membershipRevision) {
      throw const FormatException('群密钥版本发生回退，已停止同步');
    }
    await store.saveGroup(summary);
    _checkClient(requestClient, group, epoch: epoch);
    await _reloadGroups();
    _checkClient(requestClient, group, epoch: epoch);
    final accepted = _currentGroup(group);
    if (summary.keyEpoch != accepted.keyEpoch ||
        summary.membershipRevision != accepted.membershipRevision) {
      throw const ApiException('群成员已变化，请重新同步');
    }
    if (activeGroup?.storageId == group.storageId) {
      if (activeGroup!.keyEpoch != accepted.keyEpoch) {
        _groupEpoch++;
        _rtcAttempt++;
        final previous = _rtc;
        _rtc = null;
        unawaited(previous?.stop());
      }
      activeGroup = accepted;
    }
    final roster = (response['members'] as List)
        .map((j) => Member.fromJson(Map<String, dynamic>.from(j)))
        .toList();
    for (final member in roster) {
      if (await crypto.hash(unb64(member.publicKey)) != member.id) {
        throw const FormatException('群成员身份无效');
      }
    }
    _checkClient(requestClient, group, epoch: epoch);
    await store.saveMembers(group, roster, ownDeviceId: identity.id);
    _checkClient(requestClient, group, epoch: epoch);
    if (summary.keyEpoch != _currentGroup(group).keyEpoch ||
        summary.membershipRevision != _currentGroup(group).membershipRevision) {
      throw const ApiException('群成员已变化，请重新同步');
    }
    _activeRosters[group.storageId] = roster;
    if (activeGroup?.storageId == group.storageId) {
      members = {for (final m in roster) m.id: m};
      changed();
    }
    if (accepted.rekeyRequired) {
      if (autoRekey && accepted.ownerId == identity.id) {
        await _runRekey(accepted);
      }
    } else {
      await _syncGroupKey(accepted, roster, requestClient, epoch);
    }
  }

  bool _eligibleKeyRecipient(Group group, Member member) =>
      member.encryptionPublicKey != null &&
      member.clientBuild >=
          max(
            group.minClientBuild,
            _policyFloor['minClientBuild'] as int? ?? 0,
          ) &&
      member.protocolVersion == AppSecurity.protocolVersion &&
      member.privacyEpoch == AppSecurity.privacyEpoch;

  Future<void> _syncGroupKey(
    Group group,
    List<Member> roster,
    ApiClient client,
    int epoch,
  ) {
    if (group.keyEpoch < 1 || group.rekeyRequired || isGroupLeft(group)) {
      return Future.value();
    }
    final key = '$epoch:${group.storageId}:${group.keyEpoch}';
    return _keySyncs.putIfAbsent(
      key,
      () => _acquireGroupKey(group, roster, client, epoch).whenComplete(() {
        _keySyncs.remove(key);
      }),
    );
  }

  Future<void> _acquireGroupKey(
    Group group,
    List<Member> roster,
    ApiClient client,
    int epoch,
  ) async {
    _checkClient(client, group, epoch: epoch);
    var key = await store.groupKey(group);
    if (key == null) {
      final response = await client.request(
        'GET',
        '/v1/groups/${group.id}/keys',
      );
      _checkClient(client, group, epoch: epoch);
      if (response['keyEpoch'] != group.keyEpoch) {
        throw const ApiException('群密钥已更新，请重新同步');
      }
      final raw = response['wrappedKey'];
      if (raw != null) {
        final owner = roster.where((m) => m.id == group.ownerId).firstOrNull;
        if (owner == null || encryptionIdentity == null) {
          throw const FormatException('群主或本机加密身份不可用');
        }
        final wrapped = WrappedGroupKey.fromJson(
          Map<String, dynamic>.from(raw),
        );
        if (wrapped.keyEpoch != group.keyEpoch) {
          throw const FormatException('密钥分发版本不匹配');
        }
        key = await crypto.unwrapGroupKey(
          wrapped: wrapped,
          groupId: group.id,
          ownerPublicKey: owner.publicKey,
          expectedOwnerId: owner.id,
          recipient: identity,
          encryptionIdentity: encryptionIdentity!,
        );
        _checkClient(client, group, epoch: epoch);
        await store.saveKey(group, key);
      }
    }
    if (key != null && group.ownerId == identity.id) {
      final recipients = roster
          .where(
            (m) =>
                _eligibleKeyRecipient(group, m) &&
                m.grantedKeyEpoch < group.keyEpoch,
          )
          .toList();
      if (recipients.isNotEmpty) {
        final wraps = await _wrapForMembers(
          group,
          group.keyEpoch,
          key,
          recipients,
        );
        _checkClient(client, group, epoch: epoch);
        await client.request('POST', '/v1/groups/${group.id}/keys', {
          'keyEpoch': group.keyEpoch,
          'wrappedKeys': wraps,
        });
        _checkClient(client, group, epoch: epoch);
      }
    }
    if (key != null) {
      _availableGroupKeys.add('${group.storageId}:${group.keyEpoch}');
      changed();
    }
  }

  Future<List<Map<String, dynamic>>> _wrapForMembers(
    Group group,
    int epoch,
    List<int> key,
    List<Member> roster,
  ) async {
    final wrapped = <Map<String, dynamic>>[];
    for (final member in roster.where((m) => _eligibleKeyRecipient(group, m))) {
      final value = await crypto.wrapGroupKey(
        sender: identity,
        groupId: group.id,
        keyEpoch: epoch,
        groupKey: key,
        recipientId: member.id,
        recipientPublicKey: member.encryptionPublicKey!,
      );
      wrapped.add(value.toJson());
    }
    return wrapped;
  }

  Future<void> grantPendingKeys() async {
    final group = activeGroup;
    if (group == null) return;
    _requireParticipation();
    await _refreshMembers(group);
    await _loadMessages(_currentGroup(group));
    changed();
  }

  Future<void> rekeyActiveGroup() {
    final group = activeGroup;
    if (group == null) return Future.value();
    return _runRekey(group);
  }

  Future<void> _runRekey(Group group) => _rekeys.putIfAbsent(
    group.storageId,
    () => _rekeyGroup(group).whenComplete(() {
      _rekeys.remove(group.storageId);
    }),
  );

  Future<void> _rekeyGroup(Group original) async {
    _requireParticipation();
    if (original.ownerId != identity.id || api == null) {
      throw const ApiException('只有群主可以更新群密钥');
    }
    final client = api!, epoch = _networkEpoch;
    await _refreshMembers(original, client: client, autoRekey: false);
    _checkClient(client, original, epoch: epoch);
    final group = _currentGroup(original);
    final stateName = 'pending-rekey:${group.storageId}';
    var operation = await store.readState(stateName);
    if (operation != null &&
        group.keyEpoch > (operation['expectedKeyEpoch'] as int)) {
      // A lost successful response is recovered using the owner's wrapped key.
      await store.deleteState(stateName);
      operation = null;
      if (!group.rekeyRequired) {
        await _loadMessages(group);
        changed();
        return;
      }
    }
    if (operation == null) {
      final roster = _activeRosters[group.storageId] ?? const <Member>[];
      if (!roster.any(
        (m) => m.id == identity.id && _eligibleKeyRecipient(group, m),
      )) {
        throw const ApiException('本机加密公钥尚未登记，请重新连接后重试');
      }
      final nextEpoch = group.keyEpoch + 1, key = crypto.randomBytes(32);
      late List<Map<String, dynamic>> wrapped;
      try {
        wrapped = await _wrapForMembers(group, nextEpoch, key, roster);
      } finally {
        key.fillRange(0, key.length, 0);
      }
      operation = {
        'rotationId': const Uuid().v4(),
        'expectedKeyEpoch': group.keyEpoch,
        'wrappedKeys': wrapped,
      };
      await store.writeGroupState(group, stateName, operation);
    }
    _checkClient(client, group, epoch: epoch);
    try {
      await client.request('POST', '/v1/groups/${group.id}/rekey', operation);
    } on ApiException catch (e) {
      // Definitively rejected recipient snapshots may be regenerated. Unknown
      // transport outcomes must retain the same rotation ID for safe recovery.
      if ({
        'recipient_not_enrolled',
        'recipient_key_mismatch',
      }.contains(e.code)) {
        await store.deleteState(stateName);
      }
      rethrow;
    }
    _checkClient(client, group, epoch: epoch);
    await _refreshMembers(group, client: client, autoRekey: false);
    _checkClient(client, group, epoch: epoch);
    await store.deleteState(stateName);
    final updated = _currentGroup(group);
    if (updated.rekeyRequired) {
      _scheduleOutboxRetry();
      throw const ApiException('成员再次变化，正在重新更新群密钥');
    }
    await _loadMessages(updated);
    await _connectRtc(updated);
    changed();
  }

  Future<void> _connectRtc(Group group) async {
    if (!canSendToGroup(group)) return;
    final client = api, epoch = _networkEpoch, attempt = ++_rtcAttempt;
    final old = _rtc;
    _rtc = null;
    await old?.stop();
    if (client == null ||
        attempt != _rtcAttempt ||
        !_current(client, epoch) ||
        !_resumed ||
        client.server != group.server ||
        activeGroup?.storageId != group.storageId) {
      return;
    }
    late RtcSession session;
    bool current() =>
        identical(_rtc, session) &&
        _current(client, epoch) &&
        activeGroup?.storageId == group.storageId;
    session = RtcSession(
      api: client,
      group: group,
      ticketProvider: () async {
        _requireGroupSend(group);
        final wire = await client.request(
          'GET',
          '/v1/groups/${group.id}/participation',
        );
        _checkClient(client, group, epoch: epoch);
        final ticket = await ParticipationTicket.verify(
          wire,
          crypto: crypto,
          expectedGroupId: group.id,
          expectedKeyEpoch: group.keyEpoch,
          expectedDeviceId: identity.id,
          expectedPublicKey: identity.publicKey,
          expectedEncryptionPublicKey: encryptionIdentity?.publicKey,
          authorityPublicKey: authorityPublicKey,
        );
        _checkClient(client, group, epoch: epoch);
        _observePeerPolicy(ticket.policy);
        _requireGroupSend(group);
        return ticket;
      },
      canParticipate: () => current() && canSendToGroup(group),
      memberPublicKey: (id) => members[id]?.publicKey,
      onPeerPolicy: _observePeerPolicy,
      allowedMembers: () => current() ? members.keys.toSet() : {},
      onMembersChanged: () async {
        if (current()) await _refreshMembers(group, client: client);
      },
      onEnvelope: (envelope) async {
        if (current()) await _receiveP2p(group, envelope);
      },
      onMailbox: () async {
        if (current()) _scheduleSync();
      },
      onConnectionLost: () {
        if (current()) _connectionLost();
      },
      onReport: (report) {
        if (current()) {
          connection = report;
          if (report.socketOnline) _retrySeconds = 2;
          changed();
        }
      },
    );
    _rtc = session;
    unawaited(session.start());
  }

  void _scheduleSync() {
    final epoch = _networkEpoch;
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 250), () {
      if (_disposed || epoch != _networkEpoch) return;
      unawaited(
        syncActive().catchError((Object e) {
          if (epoch == _networkEpoch &&
              !_disposed &&
              e is! _ConnectionChanged &&
              e is! TransportChangedException) {
            online = false;
            error = friendly(e);
            _scheduleOutboxRetry();
            changed();
          }
        }),
      );
    });
  }

  Future<void> syncActive() async {
    final group = activeGroup;
    if (group == null ||
        isGroupLeft(group) ||
        api == null ||
        !_resumed ||
        _disposed ||
        !participationAllowed) {
      return;
    }
    await _syncForGroup(group);
  }

  Future<void> _syncForGroup(Group group, {int? pageLimit}) async {
    final epoch = _networkEpoch,
        operationKey = '$_networkEpoch:${group.storageId}';
    final current = _syncs[operationKey];
    if (current != null) {
      _syncAgain.add(operationKey);
      return current;
    }
    return _syncs.putIfAbsent(
      operationKey,
      () => _syncGroup(group, pageLimit: pageLimit).whenComplete(() {
        _syncs.remove(operationKey);
        if (_syncAgain.remove(operationKey) &&
            epoch == _networkEpoch &&
            activeGroup?.storageId == group.storageId) {
          _scheduleSync();
        }
      }),
    );
  }

  /// Healthy watch sockets refresh presence and sequence numbers without an
  /// authenticated HTTP write on each pulse. HTTP remains the fallback for old
  /// services or missing subscriptions, plus a 15-minute membership check.
  /// Each pass syncs at most two changed groups/two pages, rotating fairly.
  Future<void> pollMessageNotifications() async {
    if (_disposed ||
        !_resumed ||
        !ready ||
        !configured ||
        api == null ||
        !participationAllowed ||
        _pollingNotifications ||
        api!.quotaRetryAfter > Duration.zero ||
        _reconnecting != null ||
        (_nextNotificationPoll?.isAfter(DateTime.now()) ?? false)) {
      return;
    }
    _pollingNotifications = true;
    final client = api!, epoch = _networkEpoch;
    try {
      final needsSummary =
          !_watchCoverageHealthy ||
          _lastGroupDiscovery < 0 ||
          _presence.now - _lastGroupDiscovery >=
              const Duration(minutes: 15).inMilliseconds;
      // Several independent room events may arrive together. Never turn a
      // partially reconnecting watch set into an HTTP polling storm.
      if (needsSummary &&
          (!_watchSupported ||
              _lastSummaryAttempt < 0 ||
              _presence.now - _lastSummaryAttempt >=
                  notificationInterval.inMilliseconds)) {
        await refreshGroups(client: client);
      }
      if (!_current(client, epoch)) return;
      final candidates = groups.where((g) => !isGroupLeft(g)).toList();
      if (candidates.isNotEmpty) {
        final start = _notificationPollOffset % candidates.length;
        var synced = 0;
        for (var i = 0; i < candidates.length && synced < 2; i++) {
          final group = candidates[(start + i) % candidates.length];
          _notificationPollOffset = (start + i + 1) % candidates.length;
          if (!_current(client, epoch) || !_resumed) return;
          if (group.lastSeq <= await store.cursor(group)) continue;
          // Active rooms use their live mailbox hint when connected. The
          // poller is the fallback when no live signalling connection exists.
          if (activeGroup?.storageId == group.storageId &&
              connection.socketOnline) {
            continue;
          }
          await _syncForGroup(group, pageLimit: 2);
          synced++;
        }
      }
      _notificationPollFailures = 0;
      _nextNotificationPoll = null;
      if (error == const StorageQuotaException().message) {
        error = null;
        changed();
      }
    } catch (e) {
      if (!_current(client, epoch)) return;
      if (e is StorageQuotaException) {
        error = e.message;
        online = false;
        changed();
      }
      _notificationPollFailures = min(_notificationPollFailures + 1, 4);
      _nextNotificationPoll = DateTime.now().add(
        Duration(seconds: 15 * (1 << _notificationPollFailures)),
      );
      // Normal network recovery owns the chat error. Reminder polling should
      // not interrupt reading or show a fresh banner every time it retries.
    } finally {
      _pollingNotifications = false;
    }
  }

  bool _isContentPayload(Map<String, dynamic> payload) =>
      payload['type'] == null ||
      payload['type'] == 'text' ||
      payload['type'] == 'voice';

  void _notifyNewMessage(Group group, String messageId) {
    if (_disposed || isGroupLeft(group)) return;
    final notify = !_chatIsVisible(group.storageId);
    if (notify) unreadHintGroupIds.add(group.id);
    unawaited(
      notifications
          .notifyIncoming(
            groupStorageId: group.storageId,
            messageId: messageId,
            shouldNotify: notify,
            stillEligible: () =>
                !_disposed &&
                group.server == server &&
                !isGroupLeft(group) &&
                !_chatIsVisible(group.storageId),
          )
          .catchError((Object _) {}),
    );
  }

  Future<void> _syncGroup(Group group, {int? pageLimit}) async {
    final client = api!, epoch = _networkEpoch;
    _checkClient(client, group, epoch: epoch);
    var cursor = await store.cursor(group);
    final starting = cursor;
    final notificationFloor = _notificationFloors.putIfAbsent(
      group.storageId,
      () => group.lastSeq,
    );
    var pages = 0;
    var roster = {for (final m in await store.members(group)) m.id: m};
    roster[identity.id] = Member(identity.id, identity.publicKey, displayName);
    while (_resumed) {
      _checkClient(client, group, epoch: epoch);
      final page = await client.request(
        'GET',
        '/v1/groups/${group.id}/messages?after=$cursor&limit=100',
      );
      _checkClient(client, group, epoch: epoch);
      final suppliedFloor = (page['historySince'] as num?)?.toInt() ?? 0;
      final suppliedJoin = (page['joinedAt'] as num?)?.toInt() ?? 0;
      if (suppliedFloor > group.historySince || suppliedJoin > group.joinedAt) {
        group = group.copyWith(
          historySince: max(group.historySince, suppliedFloor),
          joinedAt: max(group.joinedAt, suppliedJoin),
        );
        await store.saveGroup(group);
        _checkClient(client, group, epoch: epoch);
        await _reloadGroups();
        _checkClient(client, group, epoch: epoch);
        group = _currentGroup(group);
        if (activeGroup?.storageId == group.storageId) activeGroup = group;
      }
      final batch = (page['messages'] as List)
          .map((j) => Map<String, dynamic>.from(j))
          .where(
            (j) =>
                group.historySince == 0 ||
                (j['storedAt'] is num &&
                    (j['storedAt'] as num) >= group.historySince),
          )
          .toList();
      final invalid = <String>{};
      final locked = <String>{};
      final confirmedVoices = <VoiceAttachment>[];
      final freshMessageIds = <String>[];
      for (final json in batch) {
        Envelope envelope;
        try {
          envelope = Envelope.fromJson(json);
        } catch (_) {
          invalid.add(json['messageId'] as String);
          continue;
        }
        if (!roster.containsKey(envelope.senderId)) {
          await _refreshMembers(
            group,
            client: client,
          ); // network failure retries the page instead of quarantining it
          roster = {for (final m in await store.members(group)) m.id: m};
        }
        final member = roster[envelope.senderId];
        if (member == null) {
          invalid.add(envelope.messageId);
          continue;
        }
        try {
          final key = await store.groupKey(group, epoch: envelope.keyEpoch);
          if (key == null) {
            if (envelope.groupId != group.id ||
                !await crypto.verify(
                  member.publicKey,
                  envelope.signingText,
                  envelope.signature,
                )) {
              throw const FormatException('消息签名无效');
            }
            locked.add(envelope.messageId);
            continue;
          }
          final decoded = await crypto.decrypt(
            envelope,
            key,
            member.publicKey,
            expectedGroupId: group.id,
          );
          if (envelope.senderId == identity.id && decoded['type'] == 'voice') {
            confirmedVoices.add(VoiceAttachment.fromJson(decoded['voice']));
          }
          if (envelope.senderId != identity.id &&
              _isContentPayload(decoded) &&
              (json['seq'] as num).toInt() > notificationFloor &&
              await store.messageRecord(group, envelope.messageId) == null) {
            freshMessageIds.add(envelope.messageId);
          }
        } catch (_) {
          invalid.add(json['messageId'] as String);
        }
      }
      final next = (page['nextCursor'] as num).toInt();
      if (next < cursor || (page['hasMore'] == true && next == cursor)) {
        throw const FormatException('服务返回了无效的同步游标');
      }
      _checkClient(client, group, epoch: epoch);
      final conflicts = await store.ingestPage(
        group,
        batch,
        next,
        invalidIds: invalid,
        lockedIds: locked,
      );
      // Only release pending voice storage after the verified page commits.
      for (final voice in confirmedVoices) {
        try {
          await media.markMessageStored(group, voice);
        } catch (_) {}
      }
      _checkClient(client, group, epoch: epoch);
      for (final messageId in freshMessageIds) {
        _notifyNewMessage(group, messageId);
      }
      if (conflicts > 0) error = '发现 $conflicts 条冲突消息，已以验证通过的云端暂存副本为准';
      cursor = next;
      pages++;
      if (page['hasMore'] != true ||
          (pageLimit != null && pages >= pageLimit)) {
        break;
      }
    }
    final quarantined = await store.quarantinedCount(group);
    _checkClient(client, group, epoch: epoch);
    if (cursor > starting && quarantined == 0) {
      await client.request('POST', '/v1/groups/${group.id}/ack', {
        'seq': cursor,
      });
    }
    _checkClient(client, group, epoch: epoch);
    if (quarantined > 0) error = '$quarantined 条消息未通过验证，已隔离；其他消息仍正常同步';
    online = true;
    if (activeGroup?.storageId == group.storageId) {
      await _loadMessages(group);
      changed();
    }
  }

  Future<void> _loadMessages(Group group) async {
    if (_disposed || activeGroup?.storageId != group.storageId) return;
    final view = _groupEpoch, load = ++_messageLoad;
    final roster = {for (final m in await store.members(group)) m.id: m};
    roster[identity.id] = Member(identity.id, identity.publicKey, displayName);
    final loaded = <ChatMessage>[];
    final textRecords =
        <
          ({
            Envelope envelope,
            Map<String, dynamic> clear,
            Map<String, Object?> record,
          })
        >[];
    final reactions = <ReactionEvent>[];
    final receipts = <ReadReceiptEvent>[];
    for (final record in await store.messages(group)) {
      final envelope = Envelope.fromJson(
        jsonDecode(record['envelope'] as String),
      );
      final member = roster[envelope.senderId];
      if (member == null) continue;
      final key = await store.groupKey(group, epoch: envelope.keyEpoch);
      if (key == null) continue;
      late Map<String, dynamic> clear;
      try {
        clear = await crypto.decrypt(
          envelope,
          key,
          member.publicKey,
          expectedGroupId: group.id,
        );
      } catch (_) {
        if (_disposed ||
            view != _groupEpoch ||
            load != _messageLoad ||
            activeGroup?.storageId != group.storageId) {
          return;
        }
        await store.quarantine(group, envelope.messageId);
        continue;
      }
      if (ReadReceiptEvent.isPayload(clear)) {
        receipts.add(ReadReceiptEvent.fromPayload(envelope, clear));
      } else if (clear['type'] == 'reaction') {
        reactions.add(ReactionEvent.fromPayload(envelope, clear));
      } else {
        textRecords.add((envelope: envelope, clear: clear, record: record));
      }
    }
    final folded = foldReactions(reactions);
    final readers = <String, Set<String>>{};
    final ownReadTargets = <String>{};
    for (final receipt in receipts) {
      for (final id in receipt.messageIds) {
        readers.putIfAbsent(id, () => {}).add(receipt.envelope.senderId);
        if (receipt.envelope.senderId == identity.id) ownReadTargets.add(id);
      }
    }
    for (final entry in textRecords) {
      loaded.add(
        ChatMessage(
          envelope: entry.envelope,
          text: entry.clear['type'] == 'voice' ? '' : entry.clear['text'],
          voice: entry.clear['type'] == 'voice'
              ? VoiceAttachment.fromJson(entry.clear['voice'])
              : null,
          senderName: entry.clear['senderName'] as String?,
          replyToMessageId:
              (entry.clear['replyTo'] as Map<String, dynamic>?)?['messageId']
                  as String?,
          expiredOwnId:
              entry.envelope.senderId == identity.id &&
              entry.clear['senderName'] != displayName,
          createdAt: entry.clear['createdAt'],
          state: entry.record['state'] == 'locked'
              ? 'stored'
              : entry.record['state'] as String,
          seq: entry.record['seq'] as int?,
          isRead:
              readers[entry.envelope.messageId]?.any(
                (reader) => reader != entry.envelope.senderId,
              ) ??
              false,
          reactions: summarizeReactions(
            folded[entry.envelope.messageId],
            identity.id,
          ),
        ),
      );
    }
    final quarantined = await store.quarantinedCount(group);
    if (!_disposed &&
        view == _groupEpoch &&
        load == _messageLoad &&
        activeGroup?.storageId == group.storageId) {
      messages = loaded;
      _ownReadReceiptTargets = ownReadTargets;
      quarantinedMessages = quarantined;
      if (quarantined > 0 && participationBlock == null) {
        error = '$quarantined 条消息未通过验证，已隔离；其他消息仍正常显示';
      }
    }
  }

  void _checkSendContext(Group group, int view, {String? expectedStorageId}) {
    if (_disposed) throw StateError('Controller closed');
    if (activeGroup?.storageId != group.storageId ||
        view != _groupEpoch ||
        (expectedStorageId != null && expectedStorageId != group.storageId)) {
      throw const ApiException('聊天已切换，请在原群重新操作');
    }
    _requireGroupSend(group);
  }

  Future<void> _validateReplyTarget(Group group, String? messageId) async {
    if (messageId == null) return;
    final record = await store.messageRecord(group, messageId);
    if (record == null) throw const FormatException('引用消息不在当前群的有效记录中');
    final envelope = Envelope.fromJson(
      jsonDecode(record['envelope'] as String),
    );
    if (envelope.messageId != messageId) {
      throw const FormatException('引用消息记录与签名不一致');
    }
    final roster = await store.members(group);
    final publicKey = envelope.senderId == identity.id
        ? identity.publicKey
        : roster.where((m) => m.id == envelope.senderId).firstOrNull?.publicKey;
    final key = await store.groupKey(group, epoch: envelope.keyEpoch);
    if (publicKey == null || key == null) {
      throw const FormatException('引用消息尚未解密，请同步后重试');
    }
    final payload = await crypto.decrypt(
      envelope,
      key,
      publicKey,
      expectedGroupId: group.id,
    );
    if (payload['type'] == 'reaction') {
      throw const FormatException('只能引用文字或语音消息');
    }
  }

  Future<void> send(
    String text, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) {
    final group = activeGroup, view = _groupEpoch;
    if (group == null) {
      return expectedStorageId == null
          ? Future.value()
          : Future.error(const ApiException('聊天已关闭，请重新打开原群'));
    }
    return _serializeSend(() async {
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      await _validateReplyTarget(group, replyToMessageId);
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      final previous = await _restoreAliasState();
      final key = await store.groupKey(group);
      if (key == null) throw const ApiException('群密钥不可用');
      final consumed = _aliasState!.consume();
      final envelope = await crypto.encrypt(
        identity: identity,
        groupId: group.id,
        messageId: const Uuid().v4(),
        text: text.trim(),
        replyToMessageId: replyToMessageId,
        senderName: consumed.senderName,
        groupKey: key,
        keyEpoch: group.keyEpoch,
      );
      final encoded = await crypto.sealAliasState(
        identity,
        consumed.next.toJson(),
      );
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      await store.queueWithAliasState(
        group,
        envelope,
        expectedState: previous,
        nextState: encoded,
        ownDeviceId: identity.id,
      );
      _applyAliasState(consumed.next);
      await _publishQueued(group, envelope);
    });
  }

  Future<void> sendVoice(
    Uint8List wav, {
    String? replyToMessageId,
    String? expectedStorageId,
  }) {
    final group = activeGroup, view = _groupEpoch;
    if (group == null) {
      return expectedStorageId == null
          ? Future.value()
          : Future.error(const ApiException('聊天已关闭，请重新打开原群'));
    }
    final snapshot = Uint8List.fromList(wav);
    final operation = _serializeSend(() async {
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      await _validateReplyTarget(group, replyToMessageId);
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      final previous = await _restoreAliasState();
      final key = await store.groupKey(group);
      if (key == null) throw const ApiException('群密钥不可用');
      late VoiceAttachment voice;
      try {
        voice = await media.prepareVoice(group, snapshot);
      } finally {
        snapshot.fillRange(0, snapshot.length, 0);
      }
      var queued = false;
      try {
        final consumed = _aliasState!.consume();
        final envelope = await crypto.encryptPayload(
          identity: identity,
          groupId: group.id,
          messageId: const Uuid().v4(),
          groupKey: key,
          keyEpoch: group.keyEpoch,
          payload: {
            'type': 'voice',
            if (replyToMessageId != null)
              'replyTo': {'v': 1, 'messageId': replyToMessageId},
            'voice': voice.toJson(),
            'senderName': consumed.senderName,
            'createdAt': DateTime.now().millisecondsSinceEpoch,
          },
        );
        final encoded = await crypto.sealAliasState(
          identity,
          consumed.next.toJson(),
        );
        _checkSendContext(group, view, expectedStorageId: expectedStorageId);
        await store.queueWithAliasState(
          group,
          envelope,
          expectedState: previous,
          nextState: encoded,
          ownDeviceId: identity.id,
        );
        queued = true;
        _applyAliasState(consumed.next);
        await _publishQueued(group, envelope);
      } finally {
        if (!queued) {
          await media.discardPrepared(group, voice);
        }
      }
    });
    return operation.whenComplete(
      () => snapshot.fillRange(0, snapshot.length, 0),
    );
  }

  Future<Uint8List> loadVoice(ChatMessage message) async {
    final group = activeGroup, client = api, voice = message.voice;
    final epoch = _networkEpoch, view = _groupEpoch;
    if (group == null ||
        client == null ||
        voice == null ||
        message.envelope.groupId != group.id ||
        client.server != group.server ||
        !messages.any(
          (m) => m.envelope.messageId == message.envelope.messageId,
        )) {
      throw const FormatException('语音不属于当前群或连接尚未配置');
    }
    final wav = await media.loadVoice(client, group, voice);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_resumed ||
        !_foreground ||
        !_current(client, epoch) ||
        view != _groupEpoch ||
        activeGroup?.storageId != group.storageId ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      wav.fillRange(0, wav.length, 0);
      throw _ConnectionChanged();
    }
    return wav;
  }

  Future<void> _publishQueued(Group group, Envelope envelope) async {
    await _loadMessages(group);
    changed();
    if (!canSendToGroup(group) || envelope.keyEpoch != group.keyEpoch) return;
    if (activeGroup?.storageId == group.storageId) {
      unawaited(_rtc?.broadcast(envelope));
    }
    unawaited(flushOutbox(group));
  }

  Future<void> quickLike(String messageId, {String? expectedStorageId}) =>
      _reactToMessage(
        messageId,
        ReactionEmoji.quickLike,
        expectedStorageId: expectedStorageId,
        onlySet: true,
      );

  Future<void> toggleReaction(
    String messageId,
    String emoji, {
    String? expectedStorageId,
  }) => _reactToMessage(messageId, emoji, expectedStorageId: expectedStorageId);

  Future<void> _reactToMessage(
    String messageId,
    String emoji, {
    String? expectedStorageId,
    bool onlySet = false,
  }) {
    final group = activeGroup, view = _groupEpoch;
    if (group == null) {
      return expectedStorageId == null
          ? Future.value()
          : Future.error(const ApiException('聊天已关闭，请重新打开原群'));
    }
    if (!ReactionEmoji.contains(emoji)) {
      throw const FormatException('不支持这个表情');
    }
    return _serializeSend(() async {
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      final key = await store.groupKey(group);
      if (key == null) throw const ApiException('群密钥不可用');
      final roster = {
        for (final member in await store.members(group)) member.id: member,
      };
      roster[identity.id] = Member(
        identity.id,
        identity.publicKey,
        displayName,
      );
      final ownEvents = <ReactionEvent>[];
      var foundTarget = false;
      for (final record in await store.messages(group)) {
        final envelope = Envelope.fromJson(
          jsonDecode(record['envelope'] as String),
        );
        final member = roster[envelope.senderId];
        if (member == null) continue;
        final historyKey = await store.groupKey(
          group,
          epoch: envelope.keyEpoch,
        );
        if (historyKey == null) continue;
        final clear = await crypto.decrypt(
          envelope,
          historyKey,
          member.publicKey,
          expectedGroupId: group.id,
        );
        if (envelope.messageId == messageId && clear['type'] != 'reaction') {
          foundTarget = true;
        }
        if (clear['type'] == 'reaction' &&
            envelope.senderId == identity.id &&
            clear['targetMessageId'] == messageId) {
          ownEvents.add(ReactionEvent.fromPayload(envelope, clear));
        }
      }
      if (!foundTarget) throw const FormatException('目标消息不在当前群的有效记录中');
      final previous = foldReactions(ownEvents)[messageId]?[identity.id];
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      if (onlySet && previous?.emoji == emoji) return;
      final removing = !onlySet && previous?.emoji == emoji;
      final envelope = await crypto.encryptPayload(
        identity: identity,
        groupId: group.id,
        messageId: const Uuid().v4(),
        groupKey: key,
        keyEpoch: group.keyEpoch,
        payload: {
          'type': 'reaction',
          'targetMessageId': messageId,
          ...ReactionEmoji.payloadFields(removing ? null : emoji),
          'counter': (previous?.counter ?? 0) + 1,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
      _checkSendContext(group, view, expectedStorageId: expectedStorageId);
      await store.queue(group, envelope);
      await _publishQueued(group, envelope);
    });
  }

  Future<void> _receiveP2p(Group group, Envelope envelope) async {
    if (!canSendToGroup(group) || envelope.keyEpoch != group.keyEpoch) return;
    final epoch = _networkEpoch;
    if (_seenP2p.contains(envelope.messageId)) return;
    final member = members[envelope.senderId],
        key = await store.groupKey(group);
    if (member == null || key == null) return;
    final clear = await crypto.decrypt(
      envelope,
      key,
      member.publicKey,
      expectedGroupId: group.id,
    );
    if (epoch != _networkEpoch || !canSendToGroup(group)) return;
    final isNew = await store.messageRecord(group, envelope.messageId) == null;
    final floor = _currentGroup(group).historySince;
    if (floor > 0 &&
        (clear['createdAt'] is! int || (clear['createdAt'] as int) < floor)) {
      return;
    }
    _seenP2p.add(envelope.messageId);
    if (_seenP2p.length > 2000) _seenP2p.remove(_seenP2p.first);
    await store.saveP2p(group, envelope);
    if (isNew &&
        envelope.senderId != identity.id &&
        _isContentPayload(clear) &&
        (clear['createdAt'] as int) >= _notificationStartedAt) {
      _notifyNewMessage(group, envelope.messageId);
    }
    if (activeGroup?.storageId == group.storageId) {
      await _loadMessages(group);
      changed();
    }
    // The mailbox covers members outside the bounded RTC neighbor set.
  }

  Future<void> flushOutbox(Group group) async {
    if (isGroupLeft(group) ||
        group.rekeyRequired ||
        api == null ||
        !_resumed ||
        _disposed ||
        api!.server != group.server ||
        !participationAllowed) {
      return;
    }
    final epoch = _networkEpoch,
        operationKey = '$_networkEpoch:${group.storageId}';
    final current = _flushes[operationKey];
    if (current != null) {
      _flushAgain.add(operationKey);
      return current;
    }
    return _flushes.putIfAbsent(
      operationKey,
      () => _flush(group).whenComplete(() {
        _flushes.remove(operationKey);
        if (_flushAgain.remove(operationKey) && epoch == _networkEpoch) {
          unawaited(flushOutbox(group));
        }
      }),
    );
  }

  Future<void> _flush(Group group) async {
    final client = api!, epoch = _networkEpoch;
    var delivered = false;
    final waitingForMedia = _mediaRetries[group.storageId]?.isActive == true;
    final deferredVoices = <String>{};
    Object? voiceFailure;
    try {
      while (_resumed) {
        _checkClient(client, group, epoch: epoch);
        final queued = (await store.outbox(
          group,
        )).where((e) => !deferredVoices.contains(e.messageId)).toList();
        if (queued.isEmpty) break;
        final decodedOutbox = <String, Map<String, dynamic>>{};
        final order = {
          for (var i = 0; i < queued.length; i++) queued[i].messageId: i,
        };
        // Never let accumulated read controls hold newly queued text/voice
        // behind them. Classification stays encrypted on disk and in transit.
        for (final envelope in queued) {
          if (envelope.keyEpoch != _currentGroup(group).keyEpoch ||
              envelope.keyEpoch < 1) {
            continue;
          }
          _checkClient(client, group, epoch: epoch);
          _requireGroupSend(group);
          final key = await store.groupKey(group, epoch: envelope.keyEpoch);
          if (key == null) throw const ApiException('缺少群密钥，已保留待发消息');
          decodedOutbox[envelope.messageId] = await crypto.decrypt(
            envelope,
            key,
            identity.publicKey,
            expectedGroupId: group.id,
          );
        }
        int priority(Envelope e) =>
            ReadReceiptEvent.isPayload(decodedOutbox[e.messageId] ?? const {})
            ? 1
            : 0;
        queued.sort((a, b) {
          final priorityOrder = priority(a).compareTo(priority(b));
          return priorityOrder == 0
              ? order[a.messageId]!.compareTo(order[b.messageId]!)
              : priorityOrder;
        });
        for (final envelope in queued) {
          _checkClient(client, group, epoch: epoch);
          if (envelope.keyEpoch != _currentGroup(group).keyEpoch ||
              envelope.keyEpoch < 1) {
            await store.markRetired(group, envelope.messageId);
            continue;
          }
          _requireGroupSend(group);
          final decoded = decodedOutbox[envelope.messageId]!;
          final voice = decoded['type'] == 'voice'
              ? VoiceAttachment.fromJson(decoded['voice'])
              : null;
          if (voice != null) {
            if (voiceFailure != null || waitingForMedia) {
              deferredVoices.add(envelope.messageId);
              continue;
            }
            try {
              _checkClient(client, group, epoch: epoch);
              await media.ensureUploaded(
                client,
                group,
                voice,
                checkCurrent: () {
                  if (!_resumed) throw _ConnectionChanged();
                  _checkClient(client, group, epoch: epoch);
                  _requireGroupSend(group);
                },
              );
            } catch (e) {
              _checkClient(client, group, epoch: epoch);
              final itemFailure =
                  e is FormatException ||
                  (e is ApiException &&
                      (const {
                            'media_storage_full',
                            'media_not_found',
                          }.contains(e.code) ||
                          const {404, 405, 415}.contains(e.status)));
              if (!itemFailure) {
                rethrow; // A failed route still backs off once for the entire queue.
              }
              deferredVoices.add(envelope.messageId);
              voiceFailure =
                  e is ApiException &&
                      const {404, 405, 415}.contains(e.status) &&
                      e.code != 'media_not_found'
                  ? const ApiException('当前服务尚不支持变声语音，请管理员升级；文字仍可发送')
                  : e;
              continue;
            }
          }
          _checkClient(client, group, epoch: epoch);
          _requireGroupSend(group);
          final result = await client.request(
            'POST',
            '/v1/groups/${group.id}/messages',
            envelope.toJson(),
          );
          _checkClient(client, group, epoch: epoch);
          await store.markStored(
            group,
            envelope.messageId,
            (result['seq'] as num).toInt(),
            (result['storedAt'] as num).toInt(),
          );
          delivered = true;
          if (voice != null) {
            try {
              await media.markMessageStored(group, voice);
            } catch (_) {}
          }
        }
      }
      _checkClient(client, group, epoch: epoch);
      if (delivered) {
        online = true;
        _retrySeconds = 2;
      }
      if (voiceFailure != null) {
        error = '${friendly(voiceFailure)}；语音保留在待发队列，其他消息可以继续发送';
        _scheduleMediaRetry(group, client, epoch);
      } else if (!waitingForMedia) {
        _mediaRetries.remove(group.storageId)?.cancel();
        _mediaRetryMilliseconds.remove(group.storageId);
      }
      if (activeGroup?.storageId == group.storageId) {
        await _loadMessages(group);
        changed();
      }
    } catch (e) {
      if (e is! _ConnectionChanged &&
          e is! TransportChangedException &&
          _current(client, epoch)) {
        online = false;
        error = friendly(e);
        _scheduleOutboxRetry();
        changed();
      }
    }
  }

  void _scheduleOutboxRetry() {
    if (!_resumed ||
        _disposed ||
        !participationAllowed ||
        _outboxRetry?.isActive == true) {
      return;
    }
    final milliseconds = max(
      _retrySeconds * 1000 + Random().nextInt(1000),
      api?.quotaRetryAfter.inMilliseconds ?? 0,
    );
    _retrySeconds = (_retrySeconds * 2).clamp(2, 60);
    _outboxRetry = Timer(Duration(milliseconds: milliseconds), () {
      _invalidateNetwork();
      unawaited(reconnect());
    });
  }

  // A missing attachment or full media store says nothing about connectivity.
  // Retry only this group's outbox; successful WS/normal text traffic must not
  // reset this independent backoff or repeatedly tear down a healthy RTC link.
  void _scheduleMediaRetry(Group group, ApiClient client, int epoch) {
    final id = group.storageId;
    if (!_resumed || _disposed || _mediaRetries[id]?.isActive == true) return;
    final delay = max(
      _mediaRetryMilliseconds[id] ?? mediaRetryDelay.inMilliseconds,
      client.quotaRetryAfter.inMilliseconds,
    );
    _mediaRetryMilliseconds[id] = (delay * 2).clamp(1, 15 * 60 * 1000);
    _mediaRetries[id] = Timer(Duration(milliseconds: delay), () {
      _mediaRetries.remove(id);
      if (_resumed && _current(client, epoch)) {
        unawaited(flushOutbox(group));
      }
    });
  }

  void _cancelMediaRetries() {
    for (final timer in _mediaRetries.values) {
      timer.cancel();
    }
    _mediaRetries.clear();
  }

  Future<void> closeGroup() async {
    _cancelReadReceipts();
    _groupEpoch++;
    _rtcAttempt++;
    _syncDebounce?.cancel();
    final rtc = _rtc;
    _rtc = null;
    activeGroup = null;
    _visibleChatStorageId = null;
    _ownReadReceiptTargets = {};
    messages = [];
    members = {};
    quarantinedMessages = 0;
    _seenP2p.clear();
    connection = const ConnectionReport();
    await rtc?.stop();
    changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state != AppLifecycleState.resumed) _cancelReadReceipts();
    if (state == AppLifecycleState.resumed && _notificationsInitialized) {
      unawaited(notifications.refreshPermission());
    }
    // Visibility controls read receipts, not network eligibility. Android's
    // foreground service keeps the existing engine eligible to run; macOS
    // keeps its normal process. Neither mode counts background messages read.
    final networking = _networkAllowedFor(state);
    if (networking == _resumed) {
      if (state == AppLifecycleState.resumed) {
        unawaited(_updateBackgroundConnection(refresh: true));
        unawaited(pollMessageNotifications());
      }
      return;
    }
    _resumed = networking;
    unawaited(
      _updateBackgroundConnection(refresh: state == AppLifecycleState.resumed),
    );
    if (!_resumed) {
      _syncDebounce?.cancel();
      _outboxRetry?.cancel();
      _networkDebounce?.cancel();
      _invalidateNetwork();
    } else {
      _invalidateNetwork();
      unawaited(reconnect());
    }
  }

  @override
  void dispose() {
    _cancelReadReceipts();
    _disposed = true;
    store.onSecretMigrationProgress = null;
    _networkEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    _networkDebounce?.cancel();
    _healthTimer?.cancel();
    _notificationTimer?.cancel();
    _stopWatches();
    _presence.dispose();
    _policyRefreshTimer?.cancel();
    _policyExpiryTimer?.cancel();
    unawaited(_networkSubscription?.cancel());
    _syncDebounce?.cancel();
    _outboxRetry?.cancel();
    _cancelMediaRetries();
    unawaited(_rtc?.stop());
    unawaited(push.dispose());
    unawaited(notifications.dispose());
    unawaited(backgroundConnection.dispose());
    api?.close();
    unawaited(store.close());
    super.dispose();
  }
}
