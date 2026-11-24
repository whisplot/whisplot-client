import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import 'package:flutter/services.dart';
import '../core/chat_controller.dart';
import '../core/models.dart';
import 'common.dart';
import 'settings_page.dart';

class JoinPage extends StatefulWidget {
  const JoinPage({super.key, required this.controller});
  final ChatController controller;
  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  final input = TextEditingController();
  bool busy = false;
  Invite? preview;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> join() async {
    setState(() => busy = true);
    try {
      final invite = await widget.controller.resolveInvite(input.text);
      if (!mounted) return;
      setState(() => preview = invite);
      if (!widget.controller.configured) {
        final configured = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsPage(
              controller: widget.controller,
              initial: true,
              presetServer: invite.server,
            ),
          ),
        );
        if (configured != true) return;
      } else if (invite.server != widget.controller.server) {
        final approved = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              context.tr('邀请码使用另一个服务', 'This invite uses a different service'),
            ),
            content: Text(
              context.tr(
                '目标地址：\n${invite.server}\n\n只有信任这个服务时才继续。接下来需要单独填写它的接入码，不会自动发送当前服务的接入码。',
                'Service address:\n${invite.server}\n\nOnly continue if you trust this service. You will need to enter its access code separately; the current service’s access code will not be sent automatically.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(context.tr('取消', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(context.tr('查看连接设置', 'Review connection settings')),
              ),
            ],
          ),
        );
        if (approved != true || !mounted) return;
        final configured = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsPage(
              controller: widget.controller,
              presetServer: invite.server,
            ),
          ),
        );
        if (configured != true) return;
      }
      final group = await widget.controller.join(invite);
      if (mounted) Navigator.pop(context, group);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr('邀请码入群', 'Join with an invite code')),
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(
          Icons.mark_chat_unread_outlined,
          size: 62,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 22),
        Text(
          context.tr('朋友已经在等你', 'Your friends are waiting'),
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(
            '粘贴朋友发来的邀请码。',
            'Paste the invite code shared by a friend.',
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: input,
          minLines: 1,
          maxLines: 3,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: context.tr('粘贴邀请码', 'Paste an invite code'),
            labelText: context.tr('邀请码', 'Invite code'),
            alignLabelWithHint: true,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              final clip = await Clipboard.getData(Clipboard.kTextPlain);
              if (clip?.text != null) input.text = clip!.text!;
            },
            icon: const Icon(Icons.content_paste, size: 18),
            label: Text(context.tr('从剪贴板粘贴', 'Paste from clipboard')),
          ),
        ),
        if (preview != null) ...[
          Text(preview!.name, style: Theme.of(context).textTheme.titleLarge),
          Text(preview!.server),
          const SizedBox(height: 16),
        ],
        FilledButton.icon(
          onPressed: busy ? null : join,
          icon: const Icon(Icons.login),
          label: Text(
            busy
                ? context.tr('正在加入…', 'Joining…')
                : context.tr('验证并加入', 'Verify and join'),
          ),
        ),
        const SizedBox(height: 24),
        InfoCard(
          icon: Icons.key_outlined,
          title: context.tr('邀请码包含访问密钥', 'Invite codes include an access key'),
          body: context.tr(
            '只从信任的人那里获取邀请码，不要公开发布。你的群密钥会保存在本机安全存储中。',
            'Only accept invite codes from people you trust, and do not share them publicly. Your group keys are kept in secure storage on this device.',
          ),
        ),
      ],
    ),
  );
}
