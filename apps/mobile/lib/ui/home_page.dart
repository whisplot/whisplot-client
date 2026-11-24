import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../core/chat_controller.dart';
import '../core/models.dart';
import 'chat_page.dart';
import 'common.dart';
import 'join_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller});
  final ChatController controller;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ChatController get controller => widget.controller;
  bool _openingNotification = false;
  bool _confirmingDelete = false;
  final Set<String> _deletingSpaces = {};
  @override
  void initState() {
    super.initState();
    controller.addListener(_notificationChanged);
    _notificationChanged();
  }

  @override
  void dispose() {
    controller.removeListener(_notificationChanged);
    super.dispose();
  }

  void _notificationChanged() {
    if (_openingNotification || !controller.ready || !controller.configured) {
      return;
    }
    final id = controller.pendingOpenGroupId;
    if (id == null) return;
    Group? target;
    for (final group in controller.groups) {
      if (group.id == id) {
        target = group;
        break;
      }
    }
    if (target == null) return;
    _openingNotification = true;
    final selected = target;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      controller.consumeNotification(id);
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (mounted) await open(context, selected, waitForClose: false);
      _openingNotification = false;
      _notificationChanged();
    });
  }

  Future<void> open(
    BuildContext context,
    Group group, {
    bool waitForClose = true,
  }) async {
    try {
      await controller.openGroup(group);
      if (context.mounted) {
        final route = Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChatPage(controller: controller)),
        );
        Future<void> finish() async {
          if (controller.activeGroup?.storageId == group.storageId) {
            await controller.closeGroup();
          }
        }

        if (waitForClose) {
          await route;
          await finish();
        } else {
          unawaited(route.then((_) => finish()));
        }
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> create(BuildContext context) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => const _CreateGroupDialog(),
    );
    if (value == null || !context.mounted) return;
    try {
      final group = await controller.createGroup(value);
      if (context.mounted) await open(context, group);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> join(BuildContext context) async {
    final group = await Navigator.push<Group>(
      context,
      MaterialPageRoute(builder: (_) => JoinPage(controller: controller)),
    );
    if (group != null && context.mounted) await open(context, group);
  }

  Future<void> deleteSpace(Group group) async {
    final storageId = group.storageId;
    if (_confirmingDelete || _deletingSpaces.contains(storageId)) return;
    _confirmingDelete = true;
    final alreadyLeft = controller.isGroupLeft(group);
    bool confirmed;
    try {
      confirmed =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(context.tr('删除聊天空间？', 'Delete this chat space?')),
              content: Text(
                alreadyLeft
                    ? context.tr(
                        '将删除“${group.name}”的全部本机聊天记录，无法撤销。其他成员的记录不受影响。',
                        'Delete all local history for “${group.name}”? This cannot be undone. Other members’ history is unaffected.',
                      )
                    : context.tr(
                        '将退出“${group.name}”，并删除该群的全部本机聊天记录，无法撤销。'
                            '\n\n其他成员的记录不受影响。离线时先停止本机收发，联网后自动确认退群。'
                            '${group.ownerId == controller.identity.id ? '\n\n你是群主，退群后群主身份会自动交接。' : ''}',
                        'Leave “${group.name}” and delete all its local history? This cannot be undone.'
                            '\n\nOther members’ history is unaffected. If offline, this device stops sending and receiving immediately; leaving is confirmed automatically when connected.'
                            '${group.ownerId == controller.identity.id ? '\n\nYou own this group. Ownership will transfer automatically after you leave.' : ''}',
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(context.tr('取消', 'Cancel')),
                ),
                FilledButton(
                  key: const ValueKey('confirm-delete-space'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(
                    alreadyLeft
                        ? context.tr('删除记录', 'Delete history')
                        : context.tr('退出并删除', 'Leave and delete'),
                  ),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _confirmingDelete = false;
    }
    if (!confirmed || !mounted) return;
    // Target the exact server + group selected before the dialog. A list refresh
    // must never redirect this destructive action to another chat space.
    if (![
      ...controller.groups,
      ...controller.leftGroups,
    ].any((entry) => entry.storageId == storageId)) {
      return;
    }
    setState(() => _deletingSpaces.add(storageId));
    try {
      await controller.deleteGroupLocallyAndLeave(storageId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr(
                '聊天空间及本机记录已删除',
                'Chat space and local history deleted',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _deletingSpaces.remove(storageId));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      if (!controller.ready) {
        final migration = controller.store.secretMigrationProgress;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Whisplot'),
            actions: const [LanguageToggle()],
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: controller.error == null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        if (migration != null &&
                            !migration.migrationComplete) ...[
                          const SizedBox(height: 20),
                          Text(
                            context.tr('正在整理原来的密钥', 'Migrating existing keys'),
                          ),
                          const SizedBox(height: 8),
                          Text('${migration.completed} / ${migration.total}'),
                          const SizedBox(height: 12),
                          Text(
                            context.tr(
                              '这一步只需完成一次。请处理系统对旧项目的授权提示；中途取消后可以继续，原身份和记录会保留。',
                              'This is a one-time step. Allow access to the existing items in the system prompts. You can resume after cancelling; your identity and history are preserved.',
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          context.appText(controller.error!),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          key: const ValueKey('retry-initialization'),
                          onPressed: controller.retryInitialization,
                          child: Text(context.tr('重新尝试', 'Try again')),
                        ),
                      ],
                    ),
            ),
          ),
        );
      }
      if (!controller.configured) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Whisplot'),
            actions: const [LanguageToggle()],
          ),
          body: SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Spacer(),
                        const BrandMark(size: 76),
                        const SizedBox(height: 32),
                        Text(
                          context.tr(
                            '换个名字，\n自在开聊。',
                            'A fresh ID.\nA freer chat.',
                          ),
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(fontSize: 44, height: 1.2),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Whisplot',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          context.tr('爱咋聊，就咋聊', 'Chat your way'),
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.7,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 32),
                        InfoCard(
                          icon: Icons.devices_outlined,
                          title: context.tr(
                            '10～50 人的邀请制聊天空间',
                            'Invite-only spaces for 10–50 people',
                          ),
                          body: context.tr(
                            '通过邀请码加入，与朋友自在聊天。',
                            'Join with an invite code and chat with friends.',
                          ),
                        ),
                        const Spacer(),
                        if (controller.error != null) ...[
                          InfoCard(
                            icon: Icons.info_outline,
                            title: context.tr('连接提示', 'Connection notice'),
                            body: context.appText(controller.error!),
                            warning: true,
                          ),
                          const SizedBox(height: 14),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SettingsPage(
                                  controller: controller,
                                  initial: true,
                                ),
                              ),
                            ),
                            icon: Icon(Icons.arrow_forward),
                            label: Text(
                              context.tr('设置 Whisplot', 'Set up Whisplot'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Center(
                          child: TextButton(
                            onPressed: () => join(context),
                            child: Text(
                              context.tr('我已经有邀请码', 'I have an invite code'),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandMark(size: 36),
              const SizedBox(width: 11),
              const Flexible(
                child: Text(
                  'Whisplot',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            const LanguageToggle(),
            IconButton(
              tooltip: context.tr('设置', 'Settings'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsPage(controller: controller),
                ),
              ),
              icon: Icon(Icons.tune),
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: controller.retryConnection,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 100),
            children: [
              if (!controller.participationAllowed) ...[
                InfoCard(
                  icon: Icons.lock_outline,
                  title: context.tr('本机历史 · 只读', 'Local history · Read only'),
                  body: context.tr(
                    '当前无法参与群聊。已有记录保留，发送、录音、表情和邀请已停用。',
                    'Chat participation is currently unavailable. Your history is preserved; sending, recording, reactions, and invites are disabled.',
                  ),
                ),
                TextButton(
                  onPressed: controller.showParticipationGate,
                  child: Text(
                    context.tr('返回更新与验证页面', 'Back to updates and verification'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayId(controller.displayName),
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.tr('爱咋聊，就咋聊', 'Chat your way'),
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: controller.online
                          ? colors.primaryContainer
                          : colors.errorContainer,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Text(
                      controller.online
                          ? context.tr('已连接', 'Connected')
                          : context.tr('等待网络', 'Waiting for network'),
                      style: TextStyle(
                        fontSize: 12,
                        color: controller.online
                            ? colors.primary
                            : colors.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: controller.participationAllowed
                          ? () => join(context)
                          : null,
                      icon: Icon(Icons.login),
                      label: Text(context.tr('邀请码入群', 'Join with code')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: controller.participationAllowed
                          ? () => create(context)
                          : null,
                      icon: Icon(Icons.add),
                      label: Text(context.tr('创建群聊', 'New group')),
                    ),
                  ),
                ],
              ),
              if (controller.error != null) ...[
                const SizedBox(height: 18),
                InfoCard(
                  icon: Icons.info_outline,
                  title: context.tr('连接提示', 'Connection notice'),
                  body: context.appText(controller.error!),
                  warning: true,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: controller.retryConnection,
                    child: Text(context.tr('重新连接', 'Reconnect')),
                  ),
                ),
              ],
              if (controller.pendingGroupLeaveCount > 0) ...[
                const SizedBox(height: 18),
                InfoCard(
                  icon: Icons.cloud_sync_outlined,
                  title: context.tr('退群待确认', 'Leaving groups · Pending'),
                  body: context.tr(
                    '${controller.pendingGroupLeaveCount} 个群已停止本机收发，联网后将自动确认退群。',
                    '${controller.pendingGroupLeaveCount} ${controller.pendingGroupLeaveCount == 1 ? 'group has' : 'groups have'} stopped sending and receiving on this device. Leaving will be confirmed automatically when connected.',
                  ),
                ),
              ],
              const SizedBox(height: 30),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('我的聊天空间', 'My chat spaces'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${controller.groups.length}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (controller.groups.isEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 42,
                    horizontal: 24,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.forum_outlined,
                        size: 46,
                        color: colors.onSurfaceVariant,
                      ),
                      SizedBox(height: 18),
                      Text(
                        context.tr('第一段对话，从邀请开始', 'Start with an invitation'),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        context.tr(
                          '加入朋友的群，或者创建一个新空间。',
                          'Join a friend’s group or create a new space.',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                )
              else
                ...controller.groups.map(
                  (group) => Padding(
                    key: ValueKey('space-${group.storageId}'),
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _SwipeDeleteSpace(
                      storageId: group.storageId,
                      busy: _deletingSpaces.contains(group.storageId),
                      onDelete: () => deleteSpace(group),
                      child: Material(
                        color: colors.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(21),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(21),
                          onTap: () => open(context, group),
                          child: Padding(
                            padding: const EdgeInsets.all(17),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 25,
                                  backgroundColor: colors.surfaceContainerLow,
                                  child: Text(
                                    group.name.characters.first,
                                    style: TextStyle(
                                      color: colors.primary,
                                      fontSize: 21,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 15),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        group.name,
                                        style: TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        group.ownerId == controller.identity.id
                                            ? context.tr(
                                                '你是群主',
                                                'You own this group',
                                              )
                                            : context.tr(
                                                '邀请加入的群聊',
                                                'Joined by invitation',
                                              ),
                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (controller.unreadHintGroupIds.contains(
                                  group.id,
                                ))
                                  Container(
                                    width: 8,
                                    height: 8,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                      color: colors.primary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                Icon(
                                  Icons.chevron_right,
                                  color: colors.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (controller.leftGroups.isNotEmpty) ...[
                const SizedBox(height: 12),
                Material(
                  color: colors.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(21),
                  clipBehavior: Clip.antiAlias,
                  child: ExpansionTile(
                    key: const PageStorageKey('left-groups'),
                    title: Text(
                      context.tr('已退出的群 · 本机历史', 'Left groups · Local history'),
                    ),
                    leading: const Icon(Icons.history),
                    children: [
                      for (final group in controller.leftGroups)
                        _SwipeDeleteSpace(
                          key: ValueKey('archived-space-${group.storageId}'),
                          storageId: group.storageId,
                          busy: _deletingSpaces.contains(group.storageId),
                          onDelete: () => deleteSpace(group),
                          child: Material(
                            color: colors.surfaceContainerLowest,
                            child: ListTile(
                              key: ValueKey('left-group-${group.storageId}'),
                              title: Text(group.name),
                              subtitle: Text(
                                context.tr('仅浏览本机记录', 'Local history only'),
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => open(context, group),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                  SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      context.tr(
                        '聊天内容在本机加密后发送',
                        'Messages are encrypted on this device before sending',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Reveals an explicit action instead of deleting when a swipe crosses a
/// threshold. A second confirmation is always required by [onDelete].
class _SwipeDeleteSpace extends StatefulWidget {
  const _SwipeDeleteSpace({
    super.key,
    required this.storageId,
    required this.busy,
    required this.onDelete,
    required this.child,
  });

  final String storageId;
  final bool busy;
  final Future<void> Function() onDelete;
  final Widget child;

  @override
  State<_SwipeDeleteSpace> createState() => _SwipeDeleteSpaceState();
}

class _SwipeDeleteSpaceState extends State<_SwipeDeleteSpace>
    with SingleTickerProviderStateMixin {
  static const _actionWidth = 88.0;
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  void _settle(bool open) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _slide.value = open ? 1 : 0;
    } else {
      _slide.animateTo(open ? 1 : 0, curve: Curves.easeOutCubic);
    }
  }

  Future<void> _delete() async {
    if (widget.busy) return;
    await widget.onDelete();
    if (mounted) _settle(false);
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      customSemanticsActions: widget.busy
          ? null
          : {
              CustomSemanticsAction(
                label: context.tr('删除聊天空间', 'Delete chat space'),
              ): _delete,
            },
      child: Listener(
        // A Mac trackpad emits horizontal scroll signals rather than a touch
        // drag. Only claim horizontal gestures; keep vertical list scrolling.
        onPointerSignal: (event) {
          if (widget.busy || event is! PointerScrollEvent) return;
          if (event.scrollDelta.dx.abs() <= event.scrollDelta.dy.abs() ||
              event.scrollDelta.dx.abs() < 2) {
            return;
          }
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {
            _settle(event.scrollDelta.dx > 0);
          });
        },
        child: AnimatedBuilder(
          animation: _slide,
          builder: (context, _) => ClipRRect(
            borderRadius: BorderRadius.circular(21),
            child: GestureDetector(
              key: ValueKey('swipe-space-${widget.storageId}'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: widget.busy
                  ? null
                  : (details) => _slide.value =
                        (_slide.value - details.delta.dx / _actionWidth).clamp(
                          0.0,
                          1.0,
                        ),
              onHorizontalDragEnd: widget.busy
                  ? null
                  : (details) {
                      final velocity = details.primaryVelocity ?? 0;
                      _settle(
                        velocity.abs() > 350
                            ? velocity < 0
                            : _slide.value >= .4,
                      );
                    },
              onHorizontalDragCancel: widget.busy
                  ? null
                  : () => _settle(_slide.value >= .4),
              onTap: _slide.value > 0 && !widget.busy
                  ? () => _settle(false)
                  : null,
              onSecondaryTap: widget.busy ? null : () => _settle(true),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: ExcludeSemantics(
                        excluding: _slide.value < .5,
                        child: IgnorePointer(
                          ignoring: _slide.value < .5 || widget.busy,
                          child: Semantics(
                            button: true,
                            label: context.tr('删除聊天空间', 'Delete chat space'),
                            enabled: !widget.busy,
                            onTap: widget.busy ? null : _delete,
                            excludeSemantics: true,
                            child: SizedBox(
                              width: _actionWidth,
                              height: double.infinity,
                              child: Material(
                                color: colors.error,
                                child: InkWell(
                                  key: ValueKey(
                                    'delete-space-${widget.storageId}',
                                  ),
                                  onTap: widget.busy ? null : _delete,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (widget.busy)
                                        SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: colors.onError,
                                          ),
                                        )
                                      else
                                        Icon(
                                          Icons.delete_outline,
                                          color: colors.onError,
                                        ),
                                      const SizedBox(height: 4),
                                      Text(
                                        widget.busy
                                            ? context.tr('删除中', 'Deleting')
                                            : context.tr('删除', 'Delete'),
                                        style: TextStyle(color: colors.onError),
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
                  Transform.translate(
                    offset: Offset(-_actionWidth * _slide.value, 0),
                    child: AbsorbPointer(
                      absorbing: _slide.value > 0 || widget.busy,
                      child: widget.child,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog();
  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  final name = TextEditingController();
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.tr('创建聊天空间', 'Create a chat space')),
    content: TextField(
      controller: name,
      autofocus: true,
      maxLength: 60,
      decoration: InputDecoration(
        labelText: context.tr('群名称', 'Group name'),
        hintText: context.tr('例如：周末出走计划', 'For example: Weekend plans'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.tr('取消', 'Cancel')),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, name.text),
        child: Text(context.tr('创建', 'Create')),
      ),
    ],
  );
}
