import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/chat_controller.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/join_page.dart';

import 'mobile_ui_test.dart' show UiController, mobileSize;

Invite sampleInvite() => Invite(
  server: ChatController.defaultServer,
  groupId: '11111111-1111-4111-8111-111111111111',
  name: '好友小群',
  inviteId: '22222222-2222-4222-8222-222222222222',
  secret: b64(List<int>.filled(32, 7)),
  groupKey: b64(List<int>.filled(32, 8)),
  expiresAt: DateTime.now()
      .add(const Duration(hours: 24))
      .millisecondsSinceEpoch,
  keyEpoch: 3,
  protocolVersion: 2,
  privacyEpoch: 2,
  minClientBuild: 5,
);

class InviteUiController extends UiController {
  InviteUiController(this.invitation) {
    server = invitation.server;
    activeGroup = Group(
      id: invitation.groupId,
      server: invitation.server,
      name: invitation.name,
      ownerId: identity.id,
      keyEpoch: invitation.keyEpoch,
      protocolVersion: invitation.protocolVersion,
      privacyEpoch: invitation.privacyEpoch,
      minClientBuild: invitation.minClientBuild,
    );
  }
  final Invite invitation;
  Invite? joinedInvitation;

  @override
  Future<Invite> createInvite(Group group) async => invitation;

  static final shortCode = b64(List<int>.filled(16, 31));
  @override
  Future<String> shareInvite(Invite invite) async => shortCode;

  @override
  Future<Invite> resolveInvite(String value) async =>
      value == shortCode ? invitation : parseInvite(value);

  @override
  Future<Group> join(Invite invite) {
    joinedInvitation = invite;
    return super.join(invite);
  }
}

void main() {
  for (final size in [const Size(360, 640), const Size(320, 480)]) {
    testWidgets('share sheet copies the displayed prefix-free code at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final invite = sampleInvite();
      final controller = InviteUiController(invite);
      addTearDown(controller.dispose);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: ChatPage(controller: controller)),
      );
      await tester.tap(find.byTooltip('邀请朋友'));
      await tester.pumpAndSettle();
      final displayed = tester.widget<SelectableText>(
        find.byKey(const ValueKey('compact-invite-code')),
      );
      expect(displayed.data, InviteUiController.shortCode);
      expect(displayed.data!.length, 22);
      expect(displayed.data, isNot(contains('nearlink://')));
      expect(find.text('复制完整邀请码'), findsNothing);
      await tester.ensureVisible(find.text('复制邀请码'));
      await tester.tap(find.text('复制邀请码'));
      await tester.pumpAndSettle();
      expect(copied, displayed.data);
      expect(find.text('邀请码已复制，请私下分享'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  final representations = <String, String Function(Invite)>{
    '22-character short code': (_) => InviteUiController.shortCode,
    'compact code': (invite) => invite.encodeCompact(),
    'old complete link': (invite) => invite.encode(),
    'old code without its fixed prefix': (invite) =>
        invite.encode().split('#').last,
  };
  for (final entry in representations.entries) {
    testWidgets(
      'join form accepts ${entry.key} without changing key metadata',
      (tester) async {
        await mobileSize(tester);
        final invite = sampleInvite();
        final controller = InviteUiController(invite);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          MaterialApp(home: JoinPage(controller: controller)),
        );
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.minLines, 1);
        expect(field.maxLines, 3);
        expect(field.decoration!.hintText, '粘贴邀请码');
        await tester.enterText(find.byType(TextField), entry.value(invite));
        await tester.ensureVisible(find.text('验证并加入'));
        await tester.tap(find.text('验证并加入'));
        await tester.pumpAndSettle();
        expect(controller.joinCalls, 1);
        final parsed = controller.joinedInvitation!;
        expect(parsed.server, invite.server);
        expect(parsed.groupId, invite.groupId);
        expect(parsed.inviteId, invite.inviteId);
        expect(parsed.secret, invite.secret);
        expect(parsed.groupKey, invite.groupKey);
        expect(parsed.keyEpoch, invite.keyEpoch);
        expect(parsed.protocolVersion, invite.protocolVersion);
        expect(parsed.privacyEpoch, invite.privacyEpoch);
        expect(parsed.minClientBuild, invite.minClientBuild);
        expect(controller.configureCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'custom-service compact invite still requires explicit switching',
    (tester) async {
      await mobileSize(tester);
      final existing = sampleInvite();
      final custom = Invite(
        server: 'https://different.example',
        groupId: existing.groupId,
        name: existing.name,
        inviteId: existing.inviteId,
        secret: existing.secret,
        groupKey: existing.groupKey,
        expiresAt: existing.expiresAt,
        keyEpoch: existing.keyEpoch,
        protocolVersion: existing.protocolVersion,
        privacyEpoch: existing.privacyEpoch,
        minClientBuild: existing.minClientBuild,
      );
      final controller = InviteUiController(existing)
        ..registrationCode = 'test-only-current-service-access';
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: JoinPage(controller: controller)),
      );
      await tester.enterText(find.byType(TextField), custom.encodeCompact());
      await tester.ensureVisible(find.text('验证并加入'));
      await tester.tap(find.text('验证并加入'));
      await tester.pumpAndSettle();
      expect(find.text('邀请码使用另一个服务'), findsOneWidget);
      expect(find.textContaining('https://different.example'), findsWidgets);
      expect(controller.configureCalls, 0);
      expect(controller.joinCalls, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(controller.server, existing.server);
      expect(controller.registrationCode, 'test-only-current-service-access');
      expect(controller.joinCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
