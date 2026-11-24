import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/core/models.dart';
import 'package:nearlink/ui/chat_page.dart';
import 'package:nearlink/ui/settings_page.dart';
import 'mobile_ui_test.dart' show UiController, mobileSize;

void main() {
  testWidgets(
    'Anonymous registration has automatic ID settings and no nickname input',
    (tester) async {
      await mobileSize(tester);
      final controller = UiController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(controller: controller, initial: true)),
      );
      expect(find.text('从一个邀请开始'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('1 条'),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('1 条'), findsOneWidget);
      expect(find.text('10 条'), findsOneWidget);
      expect(find.text('50 条'), findsOneWidget);
      expect(find.text('每几条消息换 ID'), findsOneWidget);
      expect(find.textContaining('当前：'), findsNothing);
      expect(find.byTooltip('一键换临时ID'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('连接设置'), findsNothing);
      expect(controller.configured, isFalse);
      expect(controller.configureCalls, 0);
      expect(find.text('你的昵称'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Own and other messages use identical centered cards with historical temporary IDs',
    (tester) async {
      await mobileSize(tester);
      final controller = UiController()
        ..server = 'https://example.com'
        ..displayName = '临时·ABC234';
      controller.activeGroup = const Group(
        id: 'g',
        server: 'https://example.com',
        name: '匿名群',
        ownerId: 'device-a',
      );
      controller.messages = [
        const ChatMessage(
          envelope: Envelope(
            groupId: 'g',
            messageId: 'own',
            senderId: 'device-a',
            nonce: '',
            ciphertext: '',
            signature: '',
          ),
          text: '自己的消息',
          senderName: '临时·ABC234',
          createdAt: 1,
          state: 'stored',
        ),
        const ChatMessage(
          envelope: Envelope(
            groupId: 'g',
            messageId: 'other',
            senderId: 'device-b',
            nonce: '',
            ciphertext: '',
            signature: '',
          ),
          text: '别人的消息',
          senderName: '临时·DEF567',
          createdAt: 2,
          state: 'stored',
        ),
      ];
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: ChatPage(controller: controller)),
      );
      await tester.pump();
      final own = find.byKey(const ValueKey('message-card-own')),
          other = find.byKey(const ValueKey('message-card-other'));
      expect(tester.getCenter(own).dx, closeTo(180, 0.1));
      expect(tester.getCenter(other).dx, closeTo(180, 0.1));
      expect(
        tester.widget<Material>(own).shape,
        tester.widget<Material>(other).shape,
      );
      expect(find.text('ABC234'), findsNWidgets(2));
      expect(find.text('DEF567'), findsOneWidget);
      expect(find.textContaining('临时·'), findsNothing);
      expect(find.byTooltip('一键换临时ID'), findsNothing);
      expect(
        tester.widget<Text>(find.text('自己的消息')).textAlign,
        TextAlign.justify,
      );
      expect(
        tester.widget<Text>(find.text('别人的消息')).textAlign,
        TextAlign.justify,
      );
      expect(find.byTooltip('复制消息'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
}
