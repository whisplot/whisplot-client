import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../core/client_security.dart';

/// Presentation only. The controller must also block every send, upload and
/// peer operation, including while the user is viewing local history.
class UpgradeGate extends StatefulWidget {
  const UpgradeGate({
    super.key,
    required this.message,
    required this.onViewHistory,
    required this.onRetry,
    this.checking = false,
    this.updateRequired = true,
    this.onOpenUpdate,
  });

  final String message;
  final VoidCallback onViewHistory;
  final Future<void> Function() onRetry;
  final bool checking, updateRequired;

  /// Optional platform integration must open AppSecurity.updateUrl only.
  /// No server-provided URL is accepted by this widget.
  final Future<void> Function()? onOpenUpdate;

  @override
  State<UpgradeGate> createState() => _UpgradeGateState();
}

class _UpgradeGateState extends State<UpgradeGate> {
  bool _retrying = false, _opening = false, _copying = false;
  String? _feedback;

  Future<void> _retry() async {
    if (_retrying || widget.checking) return;
    setState(() {
      _retrying = true;
      _feedback = null;
    });
    try {
      await widget.onRetry();
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = '暂时无法重新检查，请稍后重试。');
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _copyUpdateUrl() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      await Clipboard.setData(const ClipboardData(text: AppSecurity.updateUrl));
      if (mounted) {
        setState(() => _feedback = '下载网址已复制，请粘贴到浏览器打开。');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = '复制失败，请手动选中下面的网址复制。');
      }
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  Future<void> _openUpdate() async {
    final open = widget.onOpenUpdate;
    if (_opening || open == null) return;
    setState(() {
      _opening = true;
      _feedback = null;
    });
    try {
      await open();
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = '无法打开下载页，请复制网址后在浏览器中打开。');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checking = widget.checking || _retrying;
    return PopScope(
      canPop: false,
      child: Scaffold(
        key: const ValueKey('upgrade-gate'),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(context.tr('安全检查', 'Security check')),
          actions: const [LanguageToggle()],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 42,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      widget.updateRequired
                          ? context.tr(
                              '更新后才能继续聊天',
                              'Update to continue chatting',
                            )
                          : context.tr(
                              '暂时无法确认安全状态',
                              'Security status is temporarily unavailable',
                            ),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    if (widget.message.trim().isNotEmpty) ...[
                      Text(
                        context.appText(widget.message),
                        style: theme.textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      context.tr(
                        '安全检查通过前，不能发送文字、语音、表情或参与点对点聊天。'
                            '查看本机历史不会恢复发送。',
                        'Until the security check passes, text, voice, reactions, and peer-to-peer chat are disabled. Viewing local history does not re-enable sending.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      context.tr(
                        '原身份、群、聊天记录和待发消息会保留。请覆盖安装更新，'
                            '不要卸载或清除应用数据。',
                        'Your identity, groups, history, and pending messages will be preserved. Install the update over the existing app; do not uninstall it or clear its data.',
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (widget.onOpenUpdate != null) ...[
                      FilledButton.icon(
                        key: const ValueKey('open-update-url'),
                        onPressed: _opening ? null : _openUpdate,
                        icon: const Icon(Icons.open_in_new),
                        label: Text(
                          _opening
                              ? context.tr('正在打开…', 'Opening…')
                              : context.tr('打开下载页', 'Open download page'),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    OutlinedButton.icon(
                      key: const ValueKey('copy-update-url'),
                      onPressed: _copying ? null : _copyUpdateUrl,
                      icon: const Icon(Icons.copy_outlined),
                      label: Text(context.tr('复制更新网址', 'Copy update link')),
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      AppSecurity.updateUrl,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      key: const ValueKey('retry-upgrade-check'),
                      onPressed: checking ? null : _retry,
                      icon: checking
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(
                        checking
                            ? context.tr('正在检查…', 'Checking…')
                            : context.tr('重新检查', 'Check again'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const ValueKey('view-local-history'),
                      onPressed: widget.onViewHistory,
                      icon: const Icon(Icons.history),
                      label: Text(
                        context.tr(
                          '只读查看本机历史',
                          'View local history · Read only',
                        ),
                      ),
                    ),
                    if (_feedback != null) ...[
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          context.appText(_feedback!),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
