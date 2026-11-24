import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/home_page.dart';
import 'package:nearlink/ui/join_page.dart';
import 'package:nearlink/ui/settings_page.dart';

class UiController extends ChatController {
  UiController() {
    ready = true;
    displayName = '临时·ABC234';
    identity = const Identity(seed: [], publicKey: 'public', id: 'device-a');
  }
  @override
  int aliasRotationLimit = 1;
  @override
  int aliasMessagesUsed = 0;
  @override
  Future<void> setAliasRotationLimit(int value) async {
    aliasRotationLimit = value;
    changed();
  }

  int configureCalls = 0;
  int joinCalls = 0;
  bool failConfiguration = false;
  // These tests exercise ordinary UI flows; policy behavior is covered by
  // dedicated controller and read-only UI tests rather than an absent lease.
  bool uiParticipationAllowed = true;
  bool uiGroupSendAllowed = true;

  @override
  bool get participationAllowed => uiParticipationAllowed;

  @override
  bool canSendToGroup(Group group) =>
      uiParticipationAllowed && uiGroupSendAllowed;

  final openedGroups = <String>[];

  @override
  Future<Group> createGroup(String name) async => Group(
    id: 'created-group',
    server: server,
    name: name,
    ownerId: identity.id,
  );

  @override
  Future<void> openGroup(Group group) async {
    activeGroup = group;
    openedGroups.add(group.id);
    unreadHintGroupIds.remove(group.id);
    messages = [];
    changed();
  }

  @override
  Future<void> closeGroup() async {
    activeGroup = null;
    messages = [];
    changed();
  }

  @override
  Future<void> configure(String newServer, String name, String code) async {
    configureCalls++;
    server = newServer;
    displayName = name;
    registrationCode = code;
    online = !failConfiguration;
    error = failConfiguration ? '服务暂时不可达，请检查网络' : null;
    changed();
  }

  @override
  Future<Group> join(Invite invite) async {
    joinCalls++;
    return Group(
      id: invite.groupId,
      server: invite.server,
      name: invite.name,
      ownerId: 'owner',
    );
  }
}

Invite differentBackendInvite() => Invite(
  server: 'https://different.example',
  groupId: '11111111-1111-4111-8111-111111111111',
  name: '测试小群',
  inviteId: '22222222-2222-4222-8222-222222222222',
  secret: b64(List<int>.filled(32, 7)),
  groupKey: b64(List<int>.filled(32, 8)),
  expiresAt: DateTime.now()
      .add(const Duration(hours: 1))
      .millisecondsSinceEpoch,
);

Future<void> mobileSize(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'notification tap switches chats and a later tap can switch again',
    (tester) async {
      await mobileSize(tester);
      final controller = UiController()
        ..server = 'https://original.example'
        ..displayName = '小林';
      const groupA = Group(
        id: 'group-a',
        server: 'https://original.example',
        name: '群 A',
        ownerId: 'device-a',
      );
      const groupB = Group(
        id: 'group-b',
        server: 'https://original.example',
        name: '群 B',
        ownerId: 'device-a',
      );
      controller.groups = [groupA, groupB];
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: controller)),
      );
      await tester.tap(find.text('群 A'));
      await tester.pumpAndSettle();
      expect(controller.activeGroup?.id, 'group-a');
      await controller.handlePushHint('group-b', false);
      await tester.pumpAndSettle();
      expect(controller.activeGroup?.id, 'group-a');
      expect(find.text('群 A'), findsOneWidget);
      await controller.handlePushHint('group-b', true);
      await tester.pumpAndSettle();
      expect(controller.activeGroup?.id, 'group-b');
      expect(find.text('群 B'), findsOneWidget);
      expect(controller.pendingOpenGroupId, isNull);
      await controller.handlePushHint('group-a', true);
      await tester.pumpAndSettle();
      expect(controller.activeGroup?.id, 'group-a');
      expect(find.text('群 A'), findsOneWidget);
      expect(controller.openedGroups, ['group-a', 'group-b', 'group-a']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cold-start target waits for local group metadata before opening',
    (tester) async {
      final controller = UiController()
        ..server = 'https://original.example'
        ..displayName = '小林'
        ..pendingOpenGroupId = 'group-b';
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(controller.activeGroup, isNull);
      controller.groups = [
        const Group(
          id: 'group-b',
          server: 'https://original.example',
          name: '冷启动目标群',
          ownerId: 'device-a',
        ),
      ];
      controller.changed();
      await tester.pumpAndSettle();
      expect(find.text('冷启动目标群'), findsOneWidget);
      expect(controller.activeGroup?.id, 'group-b');
      expect(controller.pendingOpenGroupId, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual setup fallback stays usable on a compact Android screen',
    (tester) async {
      await mobileSize(tester);
      final controller = UiController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(padding: const EdgeInsets.only(top: 24, bottom: 54)),
            child: child!,
          ),
          home: HomePage(controller: controller),
        ),
      );
      expect(tester.takeException(), isNull);
      final setup = find.text('设置 Whisplot');
      await tester.ensureVisible(setup);
      await tester.tap(setup);
      await tester.pumpAndSettle();
      expect(find.text('连接你的聊天空间'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('连接设置'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('editing a server address clears its old access code', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = UiController()
      ..server = 'https://original.example'
      ..displayName = '临时·ABC234'
      ..registrationCode = 'original-private-access-code';
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          controller: controller,
          showConnectionSettings: true,
        ),
      ),
    );
    final address = find.widgetWithText(TextField, '服务地址');
    final code = find.widgetWithText(TextField, '服务接入码');
    expect(
      tester.widget<TextField>(code).controller!.text,
      'original-private-access-code',
    );
    await tester.ensureVisible(address);
    await tester.enterText(address, 'https://different.example');
    expect(tester.widget<TextField>(code).controller!.text, isEmpty);
    await tester.ensureVisible(find.text('保存并连接'));
    await tester.tap(find.text('保存并连接'));
    await tester.pumpAndSettle();
    expect(controller.configureCalls, 1);
    expect(controller.server, 'https://different.example');
    expect(controller.registrationCode, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'automatically configured home goes straight to invitation entry',
    (tester) async {
      await mobileSize(tester);
      final controller = UiController()
        ..server = ChatController.defaultServer
        ..displayName = '临时·ABC234'
        ..online = true;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: controller)),
      );
      expect(find.text('ABC234'), findsOneWidget);
      expect(find.text('临时·ABC234'), findsNothing);
      expect(find.text('爱咋聊，就咋聊'), findsOneWidget);
      expect(find.text('已连接'), findsOneWidget);
      expect(find.text('设置 Whisplot'), findsNothing);
      await tester.tap(find.text('邀请码入群'));
      await tester.pumpAndSettle();
      expect(find.byType(JoinPage), findsOneWidget);
      expect(find.widgetWithText(TextField, '服务接入码'), findsNothing);
      expect(controller.configureCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'create dialog owns its controller until its exit animation ends',
    (tester) async {
      await mobileSize(tester);
      final controller = UiController()
        ..server = 'https://example.com'
        ..displayName = '临时·ABC234';
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: HomePage(controller: controller)),
      );
      await tester.tap(find.text('创建群聊'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '群名称'), '测试建群');
      await tester.tap(find.text('创建'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelling a different-server invite sends no join or setup', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = UiController()
      ..server = 'https://original.example'
      ..displayName = '小林'
      ..registrationCode = 'original-private-access-code';
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: JoinPage(controller: controller)),
    );
    await tester.enterText(
      find.byType(TextField),
      differentBackendInvite().encode(),
    );
    await tester.ensureVisible(find.text('验证并加入'));
    await tester.tap(find.text('验证并加入'));
    await tester.pumpAndSettle();
    expect(find.text('邀请码使用另一个服务'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(controller.configureCalls, 0);
    expect(controller.joinCalls, 0);
    expect(controller.server, 'https://original.example');
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty chat remains usable above a compact native keyboard', (
    tester,
  ) async {
    await mobileSize(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    final controller = UiController()
      ..server = 'https://example.com'
      ..displayName = '临时·ABC234'
      ..activeGroup = const Group(
        id: 'g',
        server: 'https://example.com',
        name: '空群',
        ownerId: 'device-a',
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('different-server setup does not prefill the old access code', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = UiController()
      ..server = 'https://original.example'
      ..displayName = '小林'
      ..registrationCode = 'original-private-access-code';
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: JoinPage(controller: controller)),
    );
    await tester.enterText(
      find.byType(TextField),
      differentBackendInvite().encode(),
    );
    await tester.ensureVisible(find.text('验证并加入'));
    await tester.tap(find.text('验证并加入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看连接设置'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('连接设置'), findsNothing);
    expect(controller.server, 'https://original.example');
    expect(controller.registrationCode, 'original-private-access-code');
    expect(controller.configureCalls, 0);
    expect(controller.joinCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('voice panel opens and cancels without changing a text draft', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = UiController()
      ..server = 'https://example.com'
      ..activeGroup = const Group(
        id: 'voice-group',
        server: 'https://example.com',
        name: '语音测试群',
        ownerId: 'device-a',
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    await tester.enterText(find.byType(TextField), '保留这段文字草稿');
    await tester.tap(find.byTooltip('变声语音'));
    await tester.pumpAndSettle();
    expect(find.text('开始录音（最长 30 秒）'), findsOneWidget);
    expect(find.textContaining('原声不上传'), findsOneWidget);
    expect(find.text('发送变声语音'), findsNothing);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('开始录音（最长 30 秒）'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '保留这段文字草稿',
    );
    expect(controller.messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed connection keeps settings open with a retryable error', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = UiController()..failConfiguration = true;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          controller: controller,
          initial: true,
          showConnectionSettings: true,
        ),
      ),
    );
    expect(find.widgetWithText(TextField, '临时ID（自动生成）'), findsNothing);
    expect(find.byTooltip('一键换临时ID'), findsNothing);
    final address = find.widgetWithText(TextField, '服务地址');
    final code = find.widgetWithText(TextField, '服务接入码');
    await tester.scrollUntilVisible(
      address,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(address, 'https://unreachable.example');
    await tester.ensureVisible(code);
    await tester.enterText(code, 'test-code');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存并连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存并连接'));
    await tester.pumpAndSettle();
    expect(controller.configureCalls, 1);
    expect(find.text('保存并连接'), findsOneWidget);
    expect(find.text('服务暂时不可达，请检查网络'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued offline text is visible without claiming read delivery', (
    tester,
  ) async {
    await mobileSize(tester);
    final controller = UiController()
      ..server = 'https://original.example'
      ..displayName = '小林';
    controller.activeGroup = const Group(
      id: 'group-a',
      server: 'https://original.example',
      name: '周末小群',
      ownerId: 'device-a',
    );
    controller.messages = [
      ChatMessage(
        envelope: const Envelope(
          groupId: 'group-a',
          messageId: 'message-a',
          senderId: 'device-a',
          nonce: '',
          ciphertext: '',
          signature: '',
        ),
        text: '断网时输入的消息',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        state: 'pending',
      ),
    ];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: ChatPage(controller: controller)),
    );
    await tester.pump();
    expect(find.text('断网时输入的消息'), findsOneWidget);
    expect(find.textContaining('等待发送'), findsOneWidget);
    expect(find.textContaining('已读'), findsNothing);
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
