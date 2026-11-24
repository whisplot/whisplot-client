import 'package:material_ui/material_ui.dart';
import '../services/app_language.dart';
import '../core/chat_controller.dart';
import '../core/client_security.dart';
import '../services/app_appearance.dart';
import '../services/api_client.dart';
import 'common.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    this.initial = false,
    this.presetServer,
    this.showConnectionSettings = const bool.fromEnvironment(
      'WHISPLOT_SHOW_CONNECTION_SETTINGS',
    ),
  });
  final ChatController controller;
  final bool initial;
  final String? presetServer;
  final bool showConnectionSettings;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController server, code;
  String? codeServer;
  bool saving = false, pushing = false;
  @override
  void initState() {
    super.initState();
    if (!widget.showConnectionSettings) return;
    server = TextEditingController(
      text: widget.presetServer ?? widget.controller.suggestedServer,
    );
    code = TextEditingController(
      text: widget.presetServer == null
          ? widget.controller.registrationCode
          : '',
    );
    codeServer = normalizedAddress(server.text);
  }

  String? normalizedAddress(String value) {
    try {
      return normalizeServer(value, allowLocalHttp: ApiClient.allowsLocalHttp);
    } on FormatException {
      return null;
    }
  }

  void addressChanged(String value) {
    final address = normalizedAddress(value);
    if (address != null && address != codeServer) {
      code.clear();
      codeServer = address;
    }
  }

  @override
  void dispose() {
    if (widget.showConnectionSettings) {
      server.dispose();
      code.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await widget.controller.configure(
        server.text,
        widget.controller.displayName,
        code.text,
      );
      if (mounted) {
        if (widget.controller.online) {
          Navigator.of(context).pop(true);
        } else {
          showError(
            context,
            widget.controller.error ??
                context.tr(
                  '配置已保存，服务暂时不可达',
                  'Settings saved. The service is temporarily unavailable.',
                ),
          );
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.initial
            ? context.tr('连接你的聊天空间', 'Connect to your space')
            : context.tr('设置', 'Settings'),
      ),
      actions: const [LanguageToggle()],
    ),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        if (widget.initial) ...[
          const BrandMark(),
          const SizedBox(height: 24),
          Text(
            context.tr('从一个邀请开始', 'Start with an invitation'),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 28),
        ],
        _appearance(context),
        const SizedBox(height: 28),
        AliasRotationSettings(controller: widget.controller),
        if (widget.showConnectionSettings) ...[
          const SizedBox(height: 28),
          Text(
            context.tr('连接设置', 'Connection settings'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: server,
            onChanged: addressChanged,
            keyboardType: TextInputType.url,
            autocorrect: false,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: context.tr('服务地址', 'Service address'),
              hintText: 'https://whisplot.example.workers.dev',
              prefixIcon: Icon(Icons.cloud_outlined),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: code,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: context.tr('服务接入码', 'Service access code'),
              hintText: context.tr(
                '管理员提供（可选）',
                'Provided by an administrator (optional)',
              ),
              prefixIcon: const Icon(Icons.key_outlined),
            ),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: saving ? null : save,
            icon: saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.arrow_forward),
            label: Text(
              saving
                  ? context.tr('正在连接…', 'Connecting…')
                  : context.tr('保存并连接', 'Save and connect'),
            ),
          ),
        ],
        if (!widget.initial) ...[
          const SizedBox(height: 28),
          AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final notifications = widget.controller.notifications;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.tr('消息提醒', 'Message notifications')),
                    subtitle: Text(context.appText(notifications.status)),
                    value: notifications.enabled,
                    onChanged: pushing || !notifications.supported
                        ? null
                        : (enabled) async {
                            setState(() => pushing = true);
                            try {
                              if (!enabled) {
                                await notifications.disable();
                              } else if (notifications.needsSystemSettings) {
                                await notifications.openSystemSettings();
                              } else {
                                await notifications.enable();
                              }
                              widget.controller.changed();
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            } finally {
                              if (mounted) setState(() => pushing = false);
                            }
                          },
                  ),
                  if (notifications.showSystemSettings)
                    TextButton(
                      onPressed: notifications.openSystemSettings,
                      child: Text(
                        context.tr(
                          '打开系统通知设置',
                          'Open system notification settings',
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (widget.controller.push.supported) ...[
            const SizedBox(height: 12),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(context.tr('离线推送', 'Offline push notifications')),
              children: [
                AnimatedBuilder(
                  animation: widget.controller,
                  builder: (context, _) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.appText(widget.controller.push.status)),
                    trailing: OutlinedButton(
                      onPressed: pushing
                          ? null
                          : () async {
                              setState(() => pushing = true);
                              try {
                                await widget.controller.push.enable();
                                widget.controller.changed();
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              } finally {
                                if (mounted) setState(() => pushing = false);
                              }
                            },
                      child: Text(
                        pushing
                            ? context.tr('开启中…', 'Enabling…')
                            : context.tr('开启', 'Enable'),
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: pushing
                      ? null
                      : () async {
                          try {
                            await widget.controller.push.disable();
                            widget.controller.changed();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                  child: Text(context.tr('关闭离线推送', 'Disable offline push')),
                ),
              ],
            ),
          ],
        ],
        const SizedBox(height: 20),
        ListTile(
          leading: const Icon(Icons.emoji_emotions_outlined),
          title: Text(
            context.tr('表情资源与开源许可', 'Emoji and open-source licenses'),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Whisplot',
            applicationVersion: AppSecurity.version,
          ),
        ),
      ],
    ),
  );
  Widget _appearance(BuildContext context) {
    final appearance = AppearanceScope.of(context);
    return AnimatedBuilder(
      animation: appearance,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('外观', 'Appearance'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          SegmentedButton<AppPalette>(
            segments: [
              ButtonSegment(
                value: AppPalette.warm,
                icon: Icon(Icons.light_mode_outlined),
                label: Text(context.tr('米白', 'Warm white')),
              ),
              ButtonSegment(
                value: AppPalette.black,
                icon: Icon(Icons.dark_mode_outlined),
                label: Text(context.tr('纯黑', 'Pure black')),
              ),
            ],
            selected: {appearance.palette},
            onSelectionChanged: (selection) async {
              try {
                await appearance.select(selection.single);
              } catch (e) {
                if (context.mounted) {
                  showError(
                    context,
                    context.tr(
                      '主题未保存，请重试',
                      'Could not save the theme. Try again.',
                    ),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
