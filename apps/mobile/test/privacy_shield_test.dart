import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nearlink/ui/privacy_shield.dart';

const _privateLabel = 'PRIVATE CHAT CONTENT';
const _draftKey = ValueKey('guard-test-draft');
const _actionKey = ValueKey('guard-test-action');
const _coverKey = ValueKey('privacy-cover');

class _DraftSurface extends StatefulWidget {
  const _DraftSurface({super.key});

  @override
  State<_DraftSurface> createState() => _DraftSurfaceState();
}

class _DraftSurfaceState extends State<_DraftSurface> {
  final draft = TextEditingController(text: 'original draft');
  final focus = FocusNode();
  int actions = 0, submissions = 0;

  @override
  void dispose() {
    draft.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const Text(_privateLabel),
        TextField(
          key: _draftKey,
          controller: draft,
          focusNode: focus,
          onSubmitted: (_) => setState(() => submissions++),
        ),
        TextButton(
          key: _actionKey,
          onPressed: () => setState(() => actions++),
          child: Text('Private action $actions'),
        ),
      ],
    ),
  );
}

Widget _host({Key? surfaceKey}) => MaterialApp(
  home: PrivacyShield(child: _DraftSurface(key: surfaceKey)),
);

Future<void> _flush(WidgetTester tester) async {
  // Allow lifecycle and focus changes to settle before inspecting semantics.
  await tester.pump();
  await tester.pump();
}

Future<void> _mount(WidgetTester tester, {Key? surfaceKey}) async {
  // Establish lifecycle after testWidgets has reset its binding, not in the
  // package:test setUp that precedes that reset.
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(_host(surfaceKey: surfaceKey));
  await _flush(tester);
}

void _expectCovered(WidgetTester tester) {
  expect(find.byKey(_coverKey), findsOneWidget);
  expect(find.text(_privateLabel).hitTestable(), findsNothing);
  expect(find.semantics.byLabel(_privateLabel), findsNothing);
  expect(find.byKey(_draftKey).hitTestable(), findsNothing);
  expect(find.byKey(_actionKey).hitTestable(), findsNothing);
  expect(tester.widget<Visibility>(find.byType(Visibility)).visible, isFalse);
}

void _expectReadable(WidgetTester tester) {
  expect(find.byKey(_coverKey), findsNothing);
  expect(find.text(_privateLabel).hitTestable(), findsOneWidget);
  expect(find.semantics.byLabel(_privateLabel), findsOneWidget);
  expect(tester.widget<Visibility>(find.byType(Visibility)).visible, isTrue);
}

void _guardTestWidgets(
  String description,
  Future<void> Function(WidgetTester) body,
) {
  testWidgets(description, (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.android]) {
    _guardTestWidgets(
      '$platform shows active content without a native presence feed',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        await _mount(tester);
        _expectReadable(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }

  _guardTestWidgets(
    'inactive cover preserves state and draft while removing focus, actions and semantics',
    (tester) async {
      final key = GlobalKey<_DraftSurfaceState>();
      await _mount(tester, surfaceKey: key);
      await _flush(tester);
      await tester.tap(find.byKey(_actionKey));
      await tester.enterText(find.byKey(_draftKey), 'unsent private draft');
      await _flush(tester);
      final state = key.currentState!;
      final actionPosition = tester.getCenter(find.byKey(_actionKey));
      expect(state.actions, 1);
      expect(state.focus.hasFocus, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      _expectCovered(tester);
      expect(key.currentState, same(state));
      expect(state.draft.text, 'unsent private draft');
      expect(state.focus.hasFocus, isFalse);
      state.focus.requestFocus();
      await _flush(tester);
      expect(state.focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tapAt(actionPosition);
      await _flush(tester);
      expect(state.actions, 1);
      expect(state.submissions, 0);
      expect(
        find.semantics.byValue(RegExp('unsent private draft')),
        findsNothing,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      _expectReadable(tester);
      expect(key.currentState, same(state));
      expect(state.draft.text, 'unsent private draft');
      await tester.tap(find.byKey(_actionKey));
      await tester.tap(find.byKey(_draftKey));
      await _flush(tester);
      expect(state.actions, 2);
      expect(state.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  _guardTestWidgets('an initially inactive app stays covered until resumed', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpWidget(_host());
    await _flush(tester);
    _expectCovered(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _flush(tester);
    _expectReadable(tester);
  });
}
