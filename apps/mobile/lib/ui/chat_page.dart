import 'dart:async';
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import '../core/chat_controller.dart';
import '../core/models.dart';
import '../core/app_platform.dart';
import 'common.dart';
import 'message_bubble.dart';
import 'reaction_picker.dart';
import 'voice_composer.dart';
import 'voice_bubble.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.controller});
  final ChatController controller;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  final composer = TextEditingController();
  final composerFocus = FocusNode();
  final scroll = ScrollController();
  bool sending = false, voiceOpen = false, emojiOpen = false, leaving = false;
  int _lastLength = 0;
  String? _draftGroupId, _replyToMessageId, _lastTailId;
  final _messageViewportKey = GlobalKey();
  final Map<String, GlobalKey> _visibleMessageKeys = {};
  bool _visibilityScheduled = false;
  String? _reportedVisibleGroup;
  String? _locatingMessageId, _highlightedMessageId;
  bool _followNewMessages = true;
  bool _latestScrollIntent = false;
  int _locationRequest = 0;
  int? _followingRequest;
  bool _userScrolling = false;
  Timer? _highlightTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _draftGroupId = widget.controller.activeGroup?.storageId;
    widget.controller.addListener(_changed);
    scroll.addListener(_scheduleVisibleMessages);
    _scheduleVisibleMessages();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_chatIsVisible && _reportedVisibleGroup != null) {
      widget.controller.setChatVisibility(_reportedVisibleGroup!, false);
      _cancelMessageLocation();
    }
    _scheduleVisibleMessages();
  }

  bool get _chatIsVisible {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return mounted &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        TickerMode.valuesOf(context).enabled;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _reportedVisibleGroup != null) {
      widget.controller.setChatVisibility(_reportedVisibleGroup!, false);
      _cancelMessageLocation();
    }
    _scheduleVisibleMessages();
  }

  void _scheduleVisibleMessages() {
    if (!mounted || _visibilityScheduled) return;
    _visibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityScheduled = false;
      if (!mounted) return;
      final c = widget.controller;
      final group = c.activeGroup;
      if (_reportedVisibleGroup != null &&
          _reportedVisibleGroup != group?.storageId) {
        c.setChatVisibility(_reportedVisibleGroup!, false);
      }
      _reportedVisibleGroup = group?.storageId;
      if (group == null) return;
      final visible = _chatIsVisible;
      c.setChatVisibility(group.storageId, visible);
      if (!visible) return;
      final viewport = _messageViewportKey.currentContext?.findRenderObject();
      if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
        return;
      }
      final bounds = viewport.localToGlobal(Offset.zero) & viewport.size;
      final ids = <String>[];
      for (final message in c.messages) {
        final id = message.envelope.messageId;
        final item = _visibleMessageKeys[id]?.currentContext
            ?.findRenderObject();
        if (item is! RenderBox || !item.attached || !item.hasSize) continue;
        final rect = item.localToGlobal(Offset.zero) & item.size;
        final intersection = rect.intersect(bounds);
        // Ignore cached/offscreen rows and a sliver at the viewport edge.
        final minimumHeight = rect.height < 96 ? rect.height / 2 : 48.0;
        if (intersection.width > 0 &&
            intersection.height >= minimumHeight &&
            minimumHeight > 0) {
          ids.add(id);
        }
      }
      if (ids.isNotEmpty) {
        unawaited(
          c.markMessagesVisible(group.storageId, ids).catchError((Object _) {}),
        );
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _changed() {
    final activeId = widget.controller.activeGroup?.storageId;
    if (_draftGroupId != activeId) {
      _cancelMessageLocation();
      _followNewMessages = true;
      if (_draftGroupId != null) {
        widget.controller.setChatVisibility(_draftGroupId!, false);
      }
      _draftGroupId = activeId;
      _visibleMessageKeys.clear();
      if (mounted) setState(() => _replyToMessageId = null);
    }
    final ids = widget.controller.messages
        .map((m) => m.envelope.messageId)
        .toSet();
    _visibleMessageKeys.removeWhere((id, _) => !ids.contains(id));
    _scheduleVisibleMessages();
    final tailId = widget.controller.messages.lastOrNull?.envelope.messageId;
    if (widget.controller.messages.length != _lastLength ||
        tailId != _lastTailId) {
      _lastLength = widget.controller.messages.length;
      _lastTailId = tailId;
      if (_followNewMessages) _latestScrollIntent = true;
      if (activeId != null) _scheduleLatestScroll(activeId, _locationRequest);
    }
  }

  @override
  void dispose() {
    _cancelMessageLocation(stopScroll: false);
    WidgetsBinding.instance.removeObserver(this);
    if (_reportedVisibleGroup != null) {
      widget.controller.setChatVisibility(_reportedVisibleGroup!, false);
    }
    widget.controller.removeListener(_changed);
    composer.dispose();
    composerFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> send() async {
    if (composer.text.trim().isEmpty || sending) return;
    final c = widget.controller, group = widget.controller.activeGroup;
    if (group == null || !c.canSendToGroup(group)) return;
    final text = composer.text;
    final replyToMessageId = _replyToMessageId;
    final scrollRequest = _beginSendScroll();
    setState(() => sending = true);
    try {
      await c.send(
        text,
        replyToMessageId: replyToMessageId,
        expectedStorageId: group.storageId,
      );
      if (mounted && c.activeGroup?.storageId == group.storageId) {
        if (composer.text == text) composer.clear();
        _clearSentReply(group.storageId, replyToMessageId);
        _scheduleLatestScroll(group.storageId, scrollRequest);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  void _clearSentReply(String storageId, String? sentReplyId) {
    if (mounted &&
        widget.controller.activeGroup?.storageId == storageId &&
        _replyToMessageId == sentReplyId) {
      setState(() => _replyToMessageId = null);
    }
  }

  ChatMessage? _localMessage(String? messageId) {
    final c = widget.controller, group = widget.controller.activeGroup;
    if (messageId == null || group == null) return null;
    return c.messages
        .where(
          (m) =>
              m.envelope.groupId == group.id &&
              m.envelope.messageId == messageId,
        )
        .firstOrNull;
  }

  void _cancelMessageLocation({bool stopScroll = true}) {
    if (stopScroll &&
        (_locatingMessageId != null || _followingRequest != null) &&
        scroll.hasClients) {
      scroll.jumpTo(scroll.position.pixels);
    }
    _locationRequest++;
    _followingRequest = null;
    _latestScrollIntent = false;
    _locatingMessageId = null;
    _highlightedMessageId = null;
    _highlightTimer?.cancel();
  }

  int _beginSendScroll() {
    _cancelMessageLocation();
    _userScrolling = false;
    _followNewMessages = true;
    _latestScrollIntent = true;
    return _locationRequest;
  }

  bool _canFollowLatest(String storageId, int request) =>
      mounted &&
      request == _locationRequest &&
      _followNewMessages &&
      _latestScrollIntent &&
      !_userScrolling &&
      _locatingMessageId == null &&
      _chatIsVisible &&
      widget.controller.activeGroup?.storageId == storageId;

  double? _actualTailBottom() {
    final messages = widget.controller.messages;
    if (messages.isEmpty) return null;
    final viewport = _messageViewportKey.currentContext?.findRenderObject();
    final tail = _visibleMessageKeys[messages.last.envelope.messageId]
        ?.currentContext
        ?.findRenderObject();
    if (viewport is! RenderBox ||
        !viewport.attached ||
        !viewport.hasSize ||
        tail is! RenderBox ||
        !tail.attached ||
        !tail.hasSize) {
      return null;
    }
    return tail.localToGlobal(Offset.zero, ancestor: viewport).dy +
        tail.size.height;
  }

  bool _atActualBottom({double tolerance = 1}) {
    if (!scroll.hasClients || !scroll.position.hasContentDimensions) {
      return false;
    }
    final bottom = _actualTailBottom();
    return bottom != null &&
        bottom <= scroll.position.viewportDimension + tolerance &&
        scroll.position.extentAfter <= tolerance;
  }

  void _scheduleLatestScroll(String storageId, int request) {
    if (!_canFollowLatest(storageId, request) || _followingRequest == request) {
      return;
    }
    _followingRequest = request;
    unawaited(_scrollToLatest(storageId, request).catchError((Object _) {}));
  }

  /// maxScrollExtent is only an estimate until the last lazy row is built.
  /// Keep following that row through content and composer layout, then require
  /// two stable frames at its actual bottom. The shared request also lets a
  /// drag, quote, privacy cover or room change cancel every pending correction.
  Future<void> _scrollToLatest(String storageId, int request) async {
    var stableFrames = 0;
    String? stableTail;
    double? stableExtent, stableViewport;
    try {
      for (var attempt = 0; attempt < 40; attempt++) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted ||
            !_canFollowLatest(storageId, request) ||
            !scroll.hasClients) {
          return;
        }
        final position = scroll.position;
        if (!position.hasContentDimensions) continue;
        final tailId =
            widget.controller.messages.lastOrNull?.envelope.messageId;
        if (tailId == null) return;
        final bottom = _actualTailBottom();
        final extent = position.maxScrollExtent;
        final viewport = position.viewportDimension;
        if (_atActualBottom() &&
            stableTail == tailId &&
            stableExtent == extent &&
            stableViewport == viewport) {
          if (++stableFrames >= 2) return;
        } else {
          stableFrames = 0;
        }
        stableTail = tailId;
        stableExtent = extent;
        stableViewport = viewport;
        // The list has 20 px bottom padding. Once mounted, align the real row
        // (including its copy button) instead of a stale estimated end offset.
        final destination =
            (bottom == null ? extent : position.pixels + bottom + 20 - viewport)
                .clamp(position.minScrollExtent, extent);
        if ((destination - position.pixels).abs() <= .5) continue;
        if (MediaQuery.disableAnimationsOf(context)) {
          scroll.jumpTo(destination);
        } else {
          await scroll.animateTo(
            destination,
            duration: Duration(milliseconds: bottom == null ? 220 : 130),
            curve: Curves.easeOutCubic,
          );
        }
      }
    } finally {
      if (request == _locationRequest) _followingRequest = null;
    }
  }

  bool _locationIsCurrent(int request, String storageId, String messageId) =>
      mounted &&
      request == _locationRequest &&
      _chatIsVisible &&
      widget.controller.activeGroup?.storageId == storageId &&
      _localMessage(messageId) != null;

  /// The list is lazy, so a distant quote does not yet have a BuildContext.
  /// Seek using measured rows, then align the real target rather than relying
  /// on a fixed row height. Each step rechecks the room and request identity.
  Future<void> _locateMessage(String messageId, String storageId) async {
    if (!_chatIsVisible ||
        widget.controller.activeGroup?.storageId != storageId ||
        _localMessage(messageId) == null ||
        !scroll.hasClients) {
      return;
    }
    _cancelMessageLocation();
    final request = _locationRequest;
    _locatingMessageId = messageId;
    _followNewMessages = false;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    double? lowerBound, upperBound;
    try {
      for (var attempt = 0; attempt < 24; attempt++) {
        if (!_locationIsCurrent(request, storageId, messageId) ||
            !scroll.hasClients) {
          return;
        }
        final target = _visibleMessageKeys[messageId]?.currentContext;
        if (target != null && target.mounted) {
          await Scrollable.ensureVisible(
            target,
            alignment: .35,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 320),
            curve: Curves.easeInOutCubic,
          );
          if (!_locationIsCurrent(request, storageId, messageId)) return;
          setState(() => _highlightedMessageId = messageId);
          _highlightTimer = Timer(const Duration(milliseconds: 1400), () {
            if (mounted && request == _locationRequest) {
              setState(() => _highlightedMessageId = null);
            }
          });
          return;
        }
        final viewport = _messageViewportKey.currentContext?.findRenderObject();
        if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
          return;
        }
        final messages = widget.controller.messages;
        final targetIndex = messages.indexWhere(
          (m) => m.envelope.messageId == messageId,
        );
        final mountedRows = <({int index, double top, double height})>[];
        for (var i = 0; i < messages.length; i++) {
          final item = _visibleMessageKeys[messages[i].envelope.messageId]
              ?.currentContext
              ?.findRenderObject();
          if (item is RenderBox && item.attached && item.hasSize) {
            mountedRows.add((
              index: i,
              top: item.localToGlobal(Offset.zero, ancestor: viewport).dy,
              height: item.size.height,
            ));
          }
        }
        if (targetIndex < 0 || mountedRows.isEmpty) return;
        final first = mountedRows.first, last = mountedRows.last;
        final position = scroll.position;
        final before = position.pixels;
        final towardStart = targetIndex < first.index;
        if (towardStart) {
          upperBound = before;
        } else if (targetIndex > last.index) {
          lowerBound = before;
        }
        final anchor = towardStart ? first : last;
        final averageHeight = mountedRows.length == 1
            ? anchor.height
            : (last.top + last.height - first.top) /
                  (last.index - first.index + 1);
        var offset =
            before +
            anchor.top +
            (targetIndex - anchor.index) * averageHeight -
            viewport.size.height * .35;
        if (lowerBound != null && upperBound != null) {
          // Measured bounds prevent oscillation when messages have very
          // different heights (for example a voice note beside long text).
          if (offset <= lowerBound || offset >= upperBound) {
            offset = (lowerBound + upperBound) / 2;
          }
        }
        offset = offset.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((offset - before).abs() < 1) return;
        if (reduceMotion) {
          scroll.jumpTo(offset);
        } else {
          await scroll.animateTo(
            offset,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeInOutCubic,
          );
        }
        if (!_locationIsCurrent(request, storageId, messageId)) return;
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      if (mounted && request == _locationRequest) _locatingMessageId = null;
    }
  }

  void _openReply(String messageId, String storageId) {
    unawaited(_locateMessage(messageId, storageId).catchError((Object _) {}));
  }

  void _quoteMessage(String messageId, String storageId) {
    final c = widget.controller, group = widget.controller.activeGroup;
    if (group == null ||
        group.storageId != storageId ||
        !c.canSendToGroup(group) ||
        _localMessage(messageId) == null) {
      return;
    }
    setState(() => _replyToMessageId = messageId);
    composerFocus.requestFocus();
  }

  Future<void> recordVoice() async {
    if (voiceOpen) return;
    final c = widget.controller, group = widget.controller.activeGroup;
    if (group == null || !c.canSendToGroup(group)) return;
    final replyToMessageId = _replyToMessageId;
    int? sentScrollRequest;
    FocusScope.of(context).unfocus();
    setState(() => voiceOpen = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: 600),
        sheetAnimationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 220),
          reverseDuration: Duration(milliseconds: 180),
        ),
        builder: (_) => SingleChildScrollView(
          child: VoiceComposer(
            onSend: (wav) async {
              if (c.activeGroup?.storageId != group.storageId) {
                throw FormatException(
                  context.tr(
                    '聊天已经切换，请在原群重新录制',
                    'The chat changed. Record again in the original group.',
                  ),
                );
              }
              final scrollRequest = _beginSendScroll();
              await c.sendVoice(
                wav,
                replyToMessageId: replyToMessageId,
                expectedStorageId: group.storageId,
              );
              _clearSentReply(group.storageId, replyToMessageId);
              sentScrollRequest = scrollRequest;
            },
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => voiceOpen = false);
        final request = sentScrollRequest;
        if (request != null) _scheduleLatestScroll(group.storageId, request);
      }
    }
  }

  Future<void> insertEmoji() async {
    final c = widget.controller, group = widget.controller.activeGroup;
    if (emojiOpen || group == null || !c.canSendToGroup(group)) return;
    final before = composer.value;
    FocusScope.of(context).unfocus();
    setState(() => emojiOpen = true);
    try {
      final emoji = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        constraints: const BoxConstraints(maxWidth: 560),
        sheetAnimationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 220),
          reverseDuration: Duration(milliseconds: 180),
        ),
        builder: (_) => const ReactionPicker(inserting: true),
      );
      if (!mounted ||
          emoji == null ||
          c.activeGroup?.storageId != group.storageId ||
          !c.canSendToGroup(c.activeGroup!)) {
        return;
      }
      final value = composer.value;
      final selection = value.text == before.text
          ? before.selection
          : value.selection;
      final valid = selection.isValid && selection.end <= value.text.length;
      final start = valid ? selection.start : value.text.length;
      final end = valid ? selection.end : value.text.length;
      composer.value = LengthLimitingTextInputFormatter(1000).formatEditUpdate(
        value,
        TextEditingValue(
          text: value.text.replaceRange(start, end, emoji),
          selection: TextSelection.collapsed(offset: start + emoji.length),
        ),
      );
    } finally {
      if (mounted) setState(() => emojiOpen = false);
    }
  }

  Future<void> leaveGroup() async {
    final c = widget.controller, group = widget.controller.activeGroup;
    if (group == null || c.isGroupLeft(group) || c.isLeavingGroup || leaving) {
      return;
    }
    setState(() => leaving = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(context.tr('退出群聊？', 'Leave group?')),
          content: Text(
            context.tr(
              '退出“${group.name}”后将停止收发消息，未发出的消息不再发送。本机聊天记录会保留在“已退出的群”中。\n\n群主退出后会自动交接；最后一位成员退出时关闭群聊。离线时先停止本机收发，联网后确认退群。',
              'Leaving “${group.name}” stops incoming and outgoing messages, including queued messages. Local history stays in Left groups.\n\nOwnership transfers automatically when the owner leaves. The group closes when its last member leaves. If offline, messaging stops now and leaving is confirmed when connected.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.tr('取消', 'Cancel')),
            ),
            FilledButton(
              key: const ValueKey('confirm-leave-group'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.tr('退出群聊', 'Leave group')),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
      if (c.activeGroup?.storageId != group.storageId) return;
      final confirmedByServer = await c.leaveActiveGroup(
        expectedStorageId: group.storageId,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if ((c.activeGroup == null ||
              c.activeGroup?.storageId == group.storageId) &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            confirmedByServer
                ? context.tr(
                    '已退出群聊，聊天记录保留在本机历史',
                    'You left the group. History remains on this device.',
                  )
                : context.tr(
                    '已停止本机收发，退群请求将在联网后确认',
                    'Messaging stopped on this device. Leaving will be confirmed when online.',
                  ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => leaving = false);
    }
  }

  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (!isDesktopPlatform ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    // Let an input method finish its marked text (for example Chinese pinyin).
    // Confirming a candidate must not send the message.
    final composing = composer.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      if (event is KeyDownEvent) {
        final value = composer.value;
        final selection = value.selection;
        final start = selection.isValid ? selection.start : value.text.length;
        final end = selection.isValid ? selection.end : value.text.length;
        composer.value = LengthLimitingTextInputFormatter(1000)
            .formatEditUpdate(
              value,
              TextEditingValue(
                text: value.text.replaceRange(start, end, '\n'),
                selection: TextSelection.collapsed(offset: start + 1),
              ),
            );
      }
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent) unawaited(send());
    return KeyEventResult.handled;
  }

  Future<void> invite() async {
    final c = widget.controller, group = widget.controller.activeGroup;
    if (group == null) return;
    try {
      final value = await c.createInvite(group);
      final code = await c.shareInvite(value);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 600),
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('邀请朋友加入', 'Invite friends'),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr(
                    '${group.name} · 有效期 24 小时',
                    '${group.name} · valid for 24 hours',
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    code,
                    key: const ValueKey('compact-invite-code'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 20,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr(
                    '复制给朋友，粘贴即可加入。',
                    'Copy this code for a friend to paste and join.',
                  ),
                ),
                const SizedBox(height: 20),
                InfoCard(
                  icon: Icons.key_outlined,
                  title: context.tr('请私下分享', 'Share privately'),
                  body: context.tr(
                    '任何拿到邀请码的人，都能在有效期内加入并获得群密钥。不要发到公开页面。',
                    'Anyone with this code can join and receive the group key before it expires. Keep it off public pages.',
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      try {
                        await Clipboard.setData(ClipboardData(text: code));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.tr(
                                '邀请码已复制，请私下分享',
                                'Invite code copied. Share it privately.',
                              ),
                            ),
                          ),
                        );
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    icon: Icon(Icons.copy),
                    label: Text(context.tr('复制邀请码', 'Copy invite code')),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () async {
                      try {
                        await c.revokeInvite(group, value.inviteId);
                        if (context.mounted) Navigator.pop(context);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                    child: Text(context.tr('撤销这个邀请', 'Revoke this invite')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> manageInvites() async {
    final c = widget.controller, group = widget.controller.activeGroup;
    if (group == null) return;
    final colors = Theme.of(context).colorScheme;
    final items = await c.store.invitations(group);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              context.tr('本机创建的邀请', 'Invites created here'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(context.tr('暂无邀请', 'No invites yet')),
              ),
            ...items.map(
              (item) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${context.tr('邀请', 'Invite')} ${(item['inviteId'] as String).substring(0, 8)}',
                ),
                subtitle: Text(
                  '${context.tr('到期', 'Expires')} ${DateTime.fromMillisecondsSinceEpoch(item['expiresAt'] as int).toLocal().toString().substring(0, 16)}',
                ),
                trailing: TextButton(
                  onPressed: () async {
                    try {
                      await c.revokeInvite(group, item['inviteId'] as String);
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: Text(context.tr('撤销', 'Revoke')),
                ),
              ),
            ),
            Text(
              context.tr(
                '撤销仅阻止新成员使用该邀请，不会移除已加入成员或撤销已经分享的群密钥。',
                'Revoking an invite stops new joins. It does not remove existing members or recall shared group keys.',
              ),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  void diagnostics() {
    final c = widget.controller, r = widget.controller.connection;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('连接状态', 'Connection'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 20),
                _metric(
                  context.tr('信令连接', 'Signaling'),
                  r.socketOnline
                      ? context.tr('已连接', 'Connected')
                      : context.tr('等待重连', 'Reconnecting'),
                ),
                _metric(
                  context.tr('P2P 直连', 'Direct P2P'),
                  context.tr('${r.direct} 条', '${r.direct}'),
                ),
                _metric(
                  context.tr('TURN 中继', 'TURN relay'),
                  context.tr('${r.relay} 条', '${r.relay}'),
                ),
                _metric(
                  context.tr('连接中 / 路径未确认', 'Connecting / route pending'),
                  context.tr('${r.connecting} 条', '${r.connecting}'),
                ),
                _metric(
                  context.tr('最近建连耗时', 'Last connection time'),
                  r.lastConnectMs == null
                      ? context.tr('暂无数据', 'No data yet')
                      : '${r.lastConnectMs} ms',
                ),
                _metric(
                  context.tr('隔离的异常消息', 'Quarantined messages'),
                  context.tr(
                    '${c.quarantinedMessages} 条',
                    '${c.quarantinedMessages}',
                  ),
                ),
                const SizedBox(height: 14),
                Text(context.appText(r.note)),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      Navigator.pop(context);
                      try {
                        await c.retryConnection();
                      } catch (e) {
                        if (mounted) showError(this.context, e);
                      }
                    },
                    child: Text(context.tr('重新连接并同步', 'Reconnect and sync')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> updateGroupKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('更新原群密钥', 'Update group key')),
        content: Text(
          context.tr(
            '保留本群、成员和历史，生成全新的群密钥。只有已升级并登记加密公钥的成员会获得新密钥；其他成员升级后由群主补发。旧邀请码失效，旧待发消息不会自动重发。',
            'Create a new group key while keeping this group, its members and history. Upgraded members with registered encryption keys receive it now; the owner can grant it to others after they update. Old invites expire, and pending messages using the old key are not resent automatically.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('更新群密钥', 'Update group key')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.controller.rekeyActiveGroup();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _metric(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        Text(value, style: TextStyle(fontWeight: FontWeight.w600)),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final c = widget.controller, group = widget.controller.activeGroup;
      if (group == null) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final r = c.connection;
      final canSend = c.canSendToGroup(group);
      final isLeft = c.isGroupLeft(group);
      return Scaffold(
        appBar: AppBar(
          centerTitle: true,
          toolbarHeight: 88,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                group.name,
                key: const ValueKey('chat-group-name'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                displayId(c.displayName),
                key: const ValueKey('chat-current-id'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, letterSpacing: 1),
              ),
              const SizedBox(height: 1),
              Text(
                isLeft
                    ? context.tr('已退出', 'Left')
                    : context.tr(
                        '${c.members.length} 位成员 · ${c.activeOnlineCount == null ? '在线 —' : '${c.activeOnlineCount} 人在线'}',
                        '${c.members.length} ${c.members.length == 1 ? 'member' : 'members'} · ${c.activeOnlineCount ?? '—'} online',
                      ),
                key: const ValueKey('chat-online-count'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ],
          ),
          actions: [
            if (c.isOwner && !isLeft)
              IconButton(
                tooltip: context.tr('邀请朋友', 'Invite friends'),
                onPressed: canSend ? invite : null,
                icon: Icon(Icons.person_add_alt),
              ),
            if (!isLeft)
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'rekey') {
                    unawaited(updateGroupKey());
                  } else if (value == 'grant') {
                    unawaited(
                      c.grantPendingKeys().catchError((Object e) {
                        if (context.mounted) showError(context, e);
                      }),
                    );
                  } else if (value == 'leave') {
                    unawaited(leaveGroup());
                  } else {
                    unawaited(manageInvites());
                  }
                },
                itemBuilder: (_) => [
                  if (c.isOwner && !isLeft)
                    PopupMenuItem(
                      value: 'invites',
                      child: Text(context.tr('管理邀请', 'Manage invites')),
                    ),
                  if (c.isOwner && !isLeft && c.participationAllowed) ...[
                    PopupMenuItem(
                      value: 'rekey',
                      child: Text(context.tr('更新本群密钥', 'Update group key')),
                    ),
                    PopupMenuItem(
                      value: 'grant',
                      child: Text(
                        context.tr(
                          '为已升级成员补发密钥',
                          'Grant keys to updated members',
                        ),
                      ),
                    ),
                  ],
                  if (!isLeft)
                    PopupMenuItem(
                      value: 'leave',
                      enabled: !leaving && !c.isLeavingGroup,
                      child: Text(
                        context.tr('退出群聊', 'Leave group'),
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                ],
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (!canSend)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(
                        isLeft
                            ? context.tr(
                                '已退出的群 · 本机历史，只读。',
                                'Left group · local history is read-only.',
                              )
                            : !c.participationAllowed
                            ? context.tr(
                                '本机历史 · 只读，参与验证完成前不能发送。',
                                'Local history is read-only until participation is verified.',
                              )
                            : group.rekeyRequired
                            ? context.tr(
                                '成员已变更，正在更新群密钥，完成后可继续聊天。',
                                'Membership changed. Chat resumes after the group key is updated.',
                              )
                            : group.keyEpoch == 0
                            ? context.tr(
                                '本群正在等待群主更新密钥，历史保留。',
                                'Waiting for the owner to update the group key. History is kept.',
                              )
                            : context.tr(
                                '当前群密钥尚未就绪，请等待群主补发后重新同步。',
                                'The current key is not ready. Sync again after the owner grants it.',
                              ),
                      ),
                      if (c.isOwner &&
                          !isLeft &&
                          c.participationAllowed &&
                          (group.keyEpoch == 0 || group.rekeyRequired))
                        TextButton(
                          onPressed: updateGroupKey,
                          child: Text(context.tr('更新原群密钥', 'Update group key')),
                        ),
                    ],
                  ),
                ),
              Material(
                color: colors.surfaceContainerLow,
                child: InkWell(
                  onTap: isLeft ? null : diagnostics,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          r.socketOnline ? Icons.sensors : Icons.cloud_queue,
                          size: 16,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isLeft
                                ? context.tr(
                                    '已退出 · 仅浏览本机记录',
                                    'Left · local history only',
                                  )
                                : r.socketOnline
                                ? context.tr(
                                    '直连 ${r.direct} · 中继 ${r.relay} · 离线同步已连接',
                                    'Direct ${r.direct} · relay ${r.relay} · sync connected',
                                  )
                                : canSend
                                ? context.tr(
                                    '正在恢复连接 · 本机可继续编辑和排队',
                                    'Reconnecting · you can keep drafting and queue messages',
                                  )
                                : context.tr(
                                    '只读历史 · 当前不能发送',
                                    'Read-only history · sending unavailable',
                                  ),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.primary,
                            ),
                          ),
                        ),
                        Icon(Icons.chevron_right, size: 16),
                      ],
                    ),
                  ),
                ),
              ),
              if (c.error != null)
                Container(
                  color: colors.errorContainer,
                  padding: const EdgeInsets.only(
                    left: 16,
                    right: 4,
                    top: 3,
                    bottom: 3,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.appText(c.error!),
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      IconButton(
                        tooltip: context.tr('关闭提示', 'Dismiss notice'),
                        visualDensity: VisualDensity.compact,
                        onPressed: c.clearError,
                        icon: Icon(Icons.close, size: 16),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ClipRect(
                  key: _messageViewportKey,
                  child: c.messages.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.waving_hand_outlined,
                                    size: 46,
                                    color: colors.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    isLeft
                                        ? context.tr(
                                            '没有本机聊天记录',
                                            'No local messages',
                                          )
                                        : context.tr('来打个招呼吧', 'Say hello'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    isLeft
                                        ? context.tr(
                                            '退出后不再接收本群消息。',
                                            'You no longer receive messages from this group.',
                                          )
                                        : context.tr(
                                            '这里的消息会在发送前加密。',
                                            'Messages are encrypted before sending.',
                                          ),
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        )
                      : NotificationListener<UserScrollNotification>(
                          onNotification: (event) {
                            if (event.depth != 0) return false;
                            if (event.direction != ScrollDirection.idle) {
                              // A drag or wheel movement takes control from a
                              // pending quote seek without cancelling the
                              // user's own scrolling activity.
                              _cancelMessageLocation(stopScroll: false);
                              _userScrolling = true;
                              _followNewMessages = false;
                              setState(() {});
                            } else if (_userScrolling) {
                              _userScrolling = false;
                              _followNewMessages = _atActualBottom(
                                tolerance: 48,
                              );
                            }
                            return false;
                          },
                          child:
                              NotificationListener<ScrollMetricsNotification>(
                                onNotification: (event) {
                                  if (event.depth == 0) {
                                    _scheduleLatestScroll(
                                      group.storageId,
                                      _locationRequest,
                                    );
                                  }
                                  return false;
                                },
                                child: ListView.builder(
                                  controller: scroll,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 20,
                                  ),
                                  itemCount: c.messages.length,
                                  itemBuilder: (context, index) =>
                                      _bubble(context, c.messages[index], c),
                                ),
                              ),
                        ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLowest,
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_replyToMessageId != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: MessageReplyPreview(
                          key: const ValueKey('composer-reply-preview'),
                          message: _localMessage(_replyToMessageId),
                          onTap: _localMessage(_replyToMessageId) == null
                              ? null
                              : () => _openReply(
                                  _replyToMessageId!,
                                  group.storageId,
                                ),
                          trailing: IconButton(
                            tooltip: context.tr('取消引用', 'Cancel reply'),
                            onPressed: () =>
                                setState(() => _replyToMessageId = null),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                      ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: context.tr('变声语音', 'Voice with effects'),
                          onPressed: voiceOpen || !canSend ? null : recordVoice,
                          icon: const Icon(Icons.mic_none_rounded),
                        ),
                        IconButton(
                          tooltip: context.tr('表情', 'Emoji'),
                          onPressed: emojiOpen || !canSend ? null : insertEmoji,
                          icon: const Icon(Icons.sentiment_satisfied_alt),
                        ),
                        Expanded(
                          child: Focus(
                            canRequestFocus: false,
                            onKeyEvent: _composerKey,
                            child: TextField(
                              controller: composer,
                              focusNode: composerFocus,
                              enabled: canSend,
                              minLines: 1,
                              maxLines: 5,
                              maxLength: 1000,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                hintText: isDesktopPlatform
                                    ? context.tr(
                                        'Enter 发送 · Shift+Enter 换行',
                                        'Enter to send · Shift+Enter for a new line',
                                      )
                                    : context.tr('输入消息…', 'Type a message…'),
                                hintStyle: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                ),
                                counterText: '',
                                fillColor: colors.surfaceContainerLow,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 15,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 9),
                        IconButton.filled(
                          tooltip: context.tr('发送', 'Send'),
                          onPressed: sending || !canSend ? null : send,
                          icon: sending
                              ? const SizedBox(
                                  width: 19,
                                  height: 19,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(Icons.arrow_upward),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  Widget _bubble(BuildContext context, ChatMessage m, ChatController c) {
    final group = c.activeGroup;
    return KeyedSubtree(
      key: _visibleMessageKeys.putIfAbsent(m.envelope.messageId, GlobalKey.new),
      child: MessageBubble(
        key: ValueKey('${c.activeGroup?.storageId}:${m.envelope.messageId}'),
        message: m,
        highlighted: _highlightedMessageId == m.envelope.messageId,
        reactionsEnabled:
            group != null &&
            m.envelope.groupId == group.id &&
            c.canSendToGroup(group),
        replyMessage: m.envelope.groupId == group?.id
            ? _localMessage(m.replyToMessageId)
            : null,
        onOpenReply: group == null || m.replyToMessageId == null
            ? null
            : () => _openReply(m.replyToMessageId!, group.storageId),
        onReply: group == null
            ? null
            : () => _quoteMessage(m.envelope.messageId, group.storageId),
        onQuickLike: group == null
            ? null
            : () => c.quickLike(
                m.envelope.messageId,
                expectedStorageId: group.storageId,
              ),
        onReaction: (emoji) => c.toggleReaction(
          m.envelope.messageId,
          emoji,
          expectedStorageId: group?.storageId,
        ),
        content: m.voice == null
            ? null
            : VoiceBubble(
                key: ValueKey(
                  'voice:${c.activeGroup?.storageId}:${m.envelope.messageId}',
                ),
                durationMs: m.voice!.durationMs,
                loader: () => c.loadVoice(m),
              ),
      ),
    );
  }
}
