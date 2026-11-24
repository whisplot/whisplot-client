import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../core/emoji_catalog.dart';
import '../core/models.dart';
import 'common.dart';
import 'emoji_glyph.dart';
import 'reaction_picker.dart';
import 'reaction_burst.dart';

const reactionOrange = Color(0xFFF37021);
const reactionInk = Color(0xFF3B1908);

class MessageBubble extends StatefulWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onReaction,
    this.content,
    this.reactionsEnabled = true,
    this.onReply,
    this.onQuickLike,
    this.replyMessage,
    this.onOpenReply,
    this.highlighted = false,
  });
  final ChatMessage message;
  final Future<void> Function(String emoji) onReaction;
  final Widget? content;
  final bool reactionsEnabled;
  final VoidCallback? onReply;
  final Future<void> Function()? onQuickLike;
  final ChatMessage? replyMessage;
  final VoidCallback? onOpenReply;
  final bool highlighted;

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble>
    with SingleTickerProviderStateMixin {
  bool copied = false;
  Timer? _copyFeedback;
  double _dragDistance = 0;
  bool _dragging = false, _liking = false;
  final _reactionControls = GlobalKey();
  final _contentControl = GlobalKey();
  final _reactionSurface = GlobalKey();
  final _reactionAnchors = <String, GlobalKey>{};
  late final AnimationController _reactionMotion;
  String? _effectEmoji;
  Offset? _effectTarget;
  int _effectSerial = 0;

  @override
  void initState() {
    super.initState();
    _reactionMotion =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 720),
          value: 1,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed &&
              mounted &&
              _effectEmoji != null) {
            setState(() {
              _effectEmoji = null;
              _effectTarget = null;
            });
          }
        });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _stopReactionMotion();
    }
  }

  void _stopReactionMotion() {
    ++_effectSerial;
    _reactionMotion.stop();
    _effectEmoji = null;
    _effectTarget = null;
  }

  void _queueReactionMotion(String emoji) {
    if (!mounted ||
        !widget.reactionsEnabled ||
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    if (_effectEmoji == emoji && _reactionMotion.isAnimating) return;
    final serial = ++_effectSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          serial != _effectSerial ||
          !widget.reactionsEnabled ||
          MediaQuery.disableAnimationsOf(context) ||
          !TickerMode.valuesOf(context).enabled) {
        return;
      }
      final surface = _reactionSurface.currentContext?.findRenderObject();
      final badge = _reactionAnchors[emoji]?.currentContext?.findRenderObject();
      if (surface is! RenderBox || !surface.attached || !surface.hasSize) {
        return;
      }
      final target = badge is RenderBox && badge.attached && badge.hasSize
          ? surface.globalToLocal(
              badge.localToGlobal(badge.size.center(Offset.zero)),
            )
          : Offset(36, math.max(24, surface.size.height - 30));
      setState(() {
        _effectEmoji = emoji;
        _effectTarget = target;
      });
      _reactionMotion.forward(from: 0);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _feedbackAfterAction(
    String emoji,
    int before,
    String messageId,
    String groupId,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          before != _effectSerial ||
          widget.message.envelope.messageId != messageId ||
          widget.message.envelope.groupId != groupId) {
        return;
      }
      _queueReactionMotion(emoji);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _animatedReactionSurface(Widget child) => Stack(
    key: _reactionSurface,
    clipBehavior: Clip.none,
    children: [
      child,
      if (_effectEmoji != null && _effectTarget != null)
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _reactionMotion,
            builder: (_, _) => ReactionBurst(
              key: ValueKey(
                'reaction-effect-${widget.message.envelope.messageId}',
              ),
              emoji: _effectEmoji!,
              progress: _reactionMotion.value,
              target: _effectTarget!,
            ),
          ),
        ),
    ],
  );

  bool get _canReply => widget.reactionsEnabled && widget.onReply != null;

  @override
  void didUpdateWidget(covariant MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameMessage =
        oldWidget.message.envelope.messageId ==
            widget.message.envelope.messageId &&
        oldWidget.message.envelope.groupId == widget.message.envelope.groupId;
    if (!sameMessage || !widget.reactionsEnabled) {
      _stopReactionMotion();
      _reactionAnchors.clear();
    } else {
      final previous = {
        for (final r in oldWidget.message.reactions) r.emoji: r.count,
      };
      // Identical feedback for everyone: only aggregate counts trigger this.
      // Initial history and changes to selectedByMe never replay an effect.
      final increased = widget.message.reactions.where(
        (r) => r.count > (previous[r.emoji] ?? 0),
      );
      if (increased.isNotEmpty) _queueReactionMotion(increased.last.emoji);
      final present = widget.message.reactions.map((r) => r.emoji).toSet();
      _reactionAnchors.removeWhere((emoji, _) => !present.contains(emoji));
    }
    if (!_canReply) {
      _dragDistance = 0;
      _dragging = false;
    }
  }

  Future<void> _quickLike() async {
    if (!widget.reactionsEnabled || _liking || widget.onQuickLike == null) {
      return;
    }
    _liking = true;
    final before = _effectSerial;
    final messageId = widget.message.envelope.messageId;
    final groupId = widget.message.envelope.groupId;
    try {
      await widget.onQuickLike!();
      if (mounted) {
        unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
        _feedbackAfterAction(
          ReactionEmoji.quickLike,
          before,
          messageId,
          groupId,
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _liking = false;
    }
  }

  bool _quickLikeHitTest(Offset position) {
    // Register on the entire card, including its padding, timestamp and quote.
    // A nested control must keep its own click/gesture handling: rejecting its
    // pointer before entering the arena also avoids delaying voice playback.
    for (final key in [_reactionControls, _contentControl]) {
      final box = key.currentContext?.findRenderObject();
      if (box is RenderBox &&
          box.attached &&
          box.hasSize &&
          (Offset.zero & box.size).contains(box.globalToLocal(position))) {
        return false;
      }
    }
    return true;
  }

  Widget _likeTarget(Widget child) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      if (widget.reactionsEnabled && widget.onQuickLike != null)
        _MessageDoubleTapRecognizer:
            GestureRecognizerFactoryWithHandlers<_MessageDoubleTapRecognizer>(
              _MessageDoubleTapRecognizer.new,
              (recognizer) => recognizer
                ..canStartAt = _quickLikeHitTest
                ..gestureSettings = MediaQuery.maybeGestureSettingsOf(context)
                ..onDoubleTap = _quickLike,
            ),
    },
    child: child,
  );

  void _endDrag({bool cancelled = false}) {
    final reply = !cancelled && _canReply && _dragDistance <= -72;
    setState(() {
      _dragDistance = 0;
      _dragging = false;
    });
    if (reply) {
      unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
      widget.onReply!();
    }
  }

  Widget _swipeTarget(Widget child) => GestureDetector(
    key: ValueKey('reply-swipe-${widget.message.envelope.messageId}'),
    onHorizontalDragStart: _canReply
        ? (_) => setState(() => _dragging = true)
        : null,
    onHorizontalDragUpdate: _canReply
        ? (event) => setState(() {
            _dragDistance = (_dragDistance + event.delta.dx).clamp(-200.0, 0.0);
          })
        : null,
    onHorizontalDragEnd: _canReply ? (_) => _endDrag() : null,
    onHorizontalDragCancel: _canReply ? () => _endDrag(cancelled: true) : null,
    child: AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(
        _canReply ? _dragDistance / (1 + _dragDistance.abs() / 140) : 0,
        0,
        0,
      ),
      child: child,
    ),
  );

  @override
  void dispose() {
    _copyFeedback?.cancel();
    ++_effectSerial;
    _reactionMotion.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.message.text));
      if (!mounted) return;
      _copyFeedback?.cancel();
      setState(() => copied = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('消息已复制', 'Message copied')),
          duration: Duration(seconds: 2),
        ),
      );
      _copyFeedback = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => copied = false);
      });
    } catch (_) {
      if (mounted) {
        showError(
          context,
          context.tr('复制失败，请重试', 'Could not copy. Try again.'),
        );
      }
    }
  }

  Future<void> _react(String emoji) async {
    if (!widget.reactionsEnabled) return;
    final removing = widget.message.reactions.any(
      (r) => r.emoji == emoji && r.selectedByMe,
    );
    final before = _effectSerial;
    final messageId = widget.message.envelope.messageId;
    final groupId = widget.message.envelope.groupId;
    try {
      await widget.onReaction(emoji);
      if (mounted && !removing) {
        _feedbackAfterAction(emoji, before, messageId, groupId);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pickReaction() async {
    if (!widget.reactionsEnabled) return;
    unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
    final selected = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      builder: (_) => const ReactionPicker(),
    );
    if (selected != null && mounted && widget.reactionsEnabled) {
      await _react(selected);
    }
  }

  String _deliveryLabel(ChatMessage message) => message.isRead
      ? context.tr('已读取', 'Read')
      : switch (message.state) {
          'pending' => context.tr('等待发送', 'Waiting to send'),
          'retired' => context.tr('旧密钥待发 · 未自动重发', 'Old key · not resent'),
          'stored' => context.tr('已发送', 'Sent'),
          'p2p' => context.tr('已发送', 'Sent'),
          _ => context.tr('待确认', 'Unconfirmed'),
        };

  Widget _metadata(ColorScheme colors) => Column(
    key: ValueKey('message-metadata-${widget.message.envelope.messageId}'),
    crossAxisAlignment: CrossAxisAlignment.end,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        clockTime(widget.message.createdAt),
        style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
      ),
      Text(
        _deliveryLabel(widget.message),
        textAlign: TextAlign.end,
        style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
      ),
    ],
  );

  Widget _reaction(ReactionSummary reaction) {
    final entry = EmojiCatalog.find(reaction.emoji);
    final label = entry == null
        ? reaction.emoji
        : context.tr(entry.name, entry.englishName);
    final pill = Semantics(
      label: context.tr(
        '$label，${reaction.count} 人回应',
        '$label, ${reaction.count} ${reaction.count == 1 ? 'reaction' : 'reactions'}',
      ),
      button: widget.reactionsEnabled,
      onTap: widget.reactionsEnabled ? () => _react(reaction.emoji) : null,
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: reactionOrange,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey(
                'reaction-${widget.message.envelope.messageId}-${reaction.emoji}',
              ),
              onTap: widget.reactionsEnabled
                  ? () => _react(reaction.emoji)
                  : null,
              borderRadius: BorderRadius.circular(18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EmojiGlyph(emoji: reaction.emoji, size: 23),
                      const SizedBox(width: 5),
                      Text(
                        '${reaction.count}',
                        style: TextStyle(
                          color: reactionInk,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return KeyedSubtree(
      key: _reactionAnchors.putIfAbsent(reaction.emoji, GlobalKey.new),
      child: _effectEmoji == reaction.emoji
          ? AnimatedBuilder(
              animation: _reactionMotion,
              child: pill,
              builder: (_, child) => Transform.scale(
                scale: ReactionBurst.badgeScale(_reactionMotion.value),
                child: child,
              ),
            )
          : pill,
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final replyMessage =
        widget.replyMessage?.envelope.messageId == message.replyToMessageId &&
            widget.replyMessage?.envelope.groupId == message.envelope.groupId
        ? widget.replyMessage
        : null;
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final maxWidth = math.min(720.0, MediaQuery.sizeOf(context).width * .88);
    final stackedFooter =
        MediaQuery.textScalerOf(context).scale(1) > 1.3 ||
        maxWidth < 275 ||
        message.state == 'retired';
    final reactions = KeyedSubtree(
      key: _reactionControls,
      child: Wrap(
        key: ValueKey('message-reactions-${message.envelope.messageId}'),
        spacing: 6,
        runSpacing: 5,
        children: [
          for (final reaction in message.reactions) _reaction(reaction),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _swipeTarget(
                _animatedReactionSurface(
                  IntrinsicWidth(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: math.min(210.0, maxWidth),
                      ),
                      child: _likeTarget(
                        Semantics(
                          hint: widget.reactionsEnabled
                              ? context.tr(
                                  '长按选择表情回应，双击送爱心，左滑引用',
                                  'Hold to react, double-tap for a heart, swipe left to reply',
                                )
                              : null,
                          customSemanticsActions: _canReply
                              ? {
                                  CustomSemanticsAction(
                                    label: context.tr(
                                      '引用消息',
                                      'Reply to message',
                                    ),
                                  ): widget.onReply!,
                                }
                              : null,
                          child: Material(
                            key: ValueKey(
                              'message-card-${message.envelope.messageId}',
                            ),
                            color: widget.highlighted
                                ? Color.alphaBlend(
                                    reactionOrange.withValues(alpha: .14),
                                    colors.surfaceContainerLowest,
                                  )
                                : colors.surfaceContainerLowest,
                            animationDuration:
                                MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 180),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(19),
                              side: BorderSide(
                                color: widget.highlighted
                                    ? reactionOrange.withValues(alpha: .8)
                                    : colors.outlineVariant.withValues(
                                        alpha: .7,
                                      ),
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onLongPress: widget.reactionsEnabled
                                  ? _pickReaction
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  10,
                                  14,
                                  10,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      message.expiredOwnId
                                          ? context.tr('已过期 ID', 'Expired ID')
                                          : displayId(
                                              message.temporarySenderId,
                                            ),
                                      key: ValueKey(
                                        'message-id-${message.envelope.messageId}',
                                      ),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: dark
                                            ? const Color(0xFFE4A1C6)
                                            : const Color(0xFFAC477A),
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    if (message.replyToMessageId != null) ...[
                                      MessageReplyPreview(
                                        key: ValueKey(
                                          'message-reply-${message.envelope.messageId}',
                                        ),
                                        message: replyMessage,
                                        onTap: replyMessage == null
                                            ? null
                                            : widget.onOpenReply,
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                    if (widget.content != null)
                                      KeyedSubtree(
                                        key: _contentControl,
                                        child: widget.content!,
                                      )
                                    else
                                      Text(
                                        message.text,
                                        textAlign: TextAlign.justify,
                                        style: TextStyle(
                                          color: colors.onSurface,
                                          fontSize: 15,
                                          height: 1.5,
                                        ),
                                      ),
                                    const SizedBox(height: 9),
                                    if (message.reactions.isEmpty)
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: _metadata(colors),
                                      )
                                    else if (stackedFooter)
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          reactions,
                                          const SizedBox(height: 5),
                                          Align(
                                            alignment: Alignment.centerRight,
                                            child: _metadata(colors),
                                          ),
                                        ],
                                      )
                                    else
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Expanded(child: reactions),
                                          const SizedBox(width: 8),
                                          _metadata(colors),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (message.voice == null)
                IconButton(
                  key: ValueKey('copy-message-${message.envelope.messageId}'),
                  tooltip: copied
                      ? context.tr('已复制', 'Copied')
                      : context.tr('复制消息', 'Copy message'),
                  onPressed: _copy,
                  visualDensity: VisualDensity.compact,
                  iconSize: 14,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      copied ? Icons.check : Icons.copy_outlined,
                      key: ValueKey(copied),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A regular double-tap recognizer with an early hit-test exclusion for the
/// card's interactive controls. Mouse, touch and gesture-arena cancellation
/// keep Flutter's usual behavior; this does not synthesize raw pointer clicks.
class _MessageDoubleTapRecognizer extends DoubleTapGestureRecognizer {
  bool Function(Offset position)? canStartAt;
  int? _lastAllowedPointer;

  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (!(canStartAt?.call(event.position) ?? true)) {
      // A click on a control also ends a possible first click on the card.
      // Otherwise a third click could accidentally pair with that first one.
      final pointer = _lastAllowedPointer;
      if (pointer != null) rejectGesture(pointer);
      return false;
    }
    return super.isPointerAllowed(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _lastAllowedPointer = event.pointer;
    super.addAllowedPointer(event);
  }
}

/// Text and labels come from the current local record, never a stored snapshot.
class MessageReplyPreview extends StatelessWidget {
  const MessageReplyPreview({
    super.key,
    this.message,
    this.trailing,
    this.onTap,
  });
  final ChatMessage? message;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: .25),
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message == null
                      ? context.tr(
                          '引用消息未在本机保存',
                          'Original message is not on this device',
                        )
                      : message!.expiredOwnId
                      ? context.tr('已过期 ID', 'Expired ID')
                      : displayId(message!.temporarySenderId),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
                if (message != null)
                  Text(
                    message!.voice == null
                        ? message!.text
                        : context.tr('变声语音', 'Voice with effects'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
    if (message == null || onTap == null) return content;
    return Semantics(
      button: true,
      hint: context.tr('查看原消息', 'Go to original message'),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}
