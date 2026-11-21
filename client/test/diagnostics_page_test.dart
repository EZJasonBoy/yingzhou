import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/diagnostics/crash_record.dart';
import 'package:tvbox_client/diagnostics/diagnostics.dart';
import 'package:tvbox_client/diagnostics/diagnostics_page.dart';
import 'package:tvbox_client/diagnostics/diagnostics_store_memory.dart';
import 'package:tvbox_client/diagnostics/feedback.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/settings_page.dart';
import 'package:tvbox_client/ui/device_form.dart';

import 'fake_engine.dart';

/// The 诊断与反馈 card at the end of 设置, its page, a record, the log and 反馈问题, on a desktop with the mouse and on a
/// TV with the remote. The fake engine's subscription is `http://example.test/tv.json`; the records and the log
/// mention it and the home folder, which must not show anywhere.
void main() {
  late Diagnostics before;
  late List<String> clipboard;
  late List<String> opened;
  late Future<bool> Function(String) opener;

  const subscription = 'http://example.test/tv.json';

  // Called at the start of each test, inside its fake-async zone (futures made in setUp would never complete there).
  Future<void> prepare() async {
    before = Diagnostics.instance;
    opener = Diagnostics.openUrl;
    final store = MemoryDiagnosticsStore();
    Diagnostics.instance = Diagnostics(store: store, appVersion: '0.4.0+5', platform: 'Windows 11 · windows_x64', homes: [r'C:\Users\Alice']);
    await store.save(
      CrashRecord(
        time: DateTime.now().subtract(const Duration(hours: 2)),
        version: '0.4.0+5',
        platform: 'Windows 11 · windows_x64',
        form: 'desktop',
        source: CrashSource.engine,
        error: '引擎进程退出了（退出码 1）',
        stack: 'java.net.BindException: Address already in use',
      ),
    );
    await store.save(
      CrashRecord(
        time: DateTime.now().subtract(const Duration(minutes: 5)),
        version: '0.4.0+5',
        platform: 'Windows 11 · windows_x64',
        form: 'desktop',
        source: CrashSource.flutter,
        error: 'FormatException: 订阅 $subscription 不是 JSON',
        stack: [for (var i = 0; i < 120; i++) '#$i      frame$i (package:tvbox_client/x.dart:$i)'].join('\n'),
        repeated: 3,
      ),
    );
    store.engineOutput(r'tvbox-engine listening on http://127.0.0.1:9978, data in C:\Users\Alice\.tvbox-next\engine');
    store.engineOutput('loaded $subscription: 3 sites, 0 parses, 1 live groups');
    clipboard = [];
    opened = [];
    Diagnostics.openUrl = (url) async {
      opened.add(url);
      return false;
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
      return null;
    });
  }

  tearDown(() {
    Diagnostics.instance = before;
    Diagnostics.openUrl = opener;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  void expectClean(String text) {
    expect(text, isNot(contains('example.test')));
    expect(text, isNot(contains('Alice')));
  }

  String shownText(WidgetTester tester) {
    final w = tester.widget(find.byKey(const Key('diag-text')));
    return w is SelectableText ? w.data! : (w as Text).data!;
  }

  group('desktop', () {
    Future<void> openSettings(WidgetTester tester) async {
      await prepare();
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TvboxApp(
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: fakeEngine(hasConfig: true))),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('diag-open')),
        400,
        scrollable: find.descendant(of: find.byType(SettingsPage), matching: find.byType(Scrollable)).first,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the card at the end of 设置: the records, copy, the page, a record, the log', (tester) async {
      await openSettings(tester);
      expect(find.textContaining('2 条崩溃记录，最近一次：'), findsOneWidget);
      expect(find.textContaining('不会自己上传任何东西'), findsOneWidget);

      await tester.tap(find.byKey(const Key('diag-copy')));
      await tester.pumpAndSettle();
      final copied = clipboard.single;
      expect(copied, startsWith('映舟诊断信息\n应用版本：0.4.0+5\n系统：Windows 11 · windows_x64\n设备形态：桌面（desktop）\n引擎：tvbox-engine'));
      expect(copied, contains('== 最近的崩溃记录（2 条，新的在前）=='));
      expect(copied, contains('FormatException: 订阅 <订阅地址> 不是 JSON'));
      expect(copied, contains('界面错误（flutter） · 重复 3 次'));
      expect(copied, contains('…（还有 80 行）'));
      expect(copied, contains(r'data in ~\.tvbox-next\engine'));
      expect(copied, contains('loaded <订阅地址>: 3 sites'));
      expectClean(copied);
      expect(find.textContaining('已复制诊断信息'), findsOneWidget);

      await tester.tap(find.byKey(const Key('diag-open')));
      await tester.pumpAndSettle();
      expect(find.text('诊断与反馈'), findsWidgets);
      expect(find.byKey(const Key('diag-version')), findsOneWidget);
      expect(find.textContaining('Windows 11 · windows_x64 · 桌面'), findsOneWidget);
      expect(find.textContaining('引擎：tvbox-engine'), findsOneWidget);
      expect(find.textContaining('界面错误 · '), findsOneWidget);
      expect(find.textContaining('引擎退出 · '), findsOneWidget);
      expect(find.text('FormatException: 订阅 <订阅地址> 不是 JSON'), findsOneWidget);

      await tester.tap(find.byKey(const Key('diag-record-0')));
      await tester.pumpAndSettle();
      final record = shownText(tester);
      expect(record, startsWith(CrashRecord.title));
      expect(record, contains('source: flutter'));
      expect(record, contains('repeated: 3'));
      expectClean(record);
      expect(find.byType(SelectableText), findsWidgets, reason: 'off TV the text can be selected');
      await tester.tap(find.byKey(const Key('diag-text-copy')));
      await tester.pumpAndSettle();
      expect(clipboard.last, record);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('diag-log')));
      await tester.pumpAndSettle();
      final log = shownText(tester);
      expect(log, contains('loaded <订阅地址>: 3 sites'));
      expectClean(log);
    });

    testWidgets('反馈问题 shows the full text first; the browser gets GitHub with the form filled in', (tester) async {
      await openSettings(tester);
      await tester.tap(find.byKey(const Key('diag-feedback')));
      await tester.pumpAndSettle();
      expect(find.text('反馈问题'), findsWidgets);
      final text = shownText(tester);
      expect(text, startsWith('映舟诊断信息'));
      expectClean(text);
      expect(find.byKey(const Key('feedback-qr')), findsNothing, reason: 'a desktop opens the browser');

      await tester.tap(find.byKey(const Key('feedback-open')));
      await tester.pumpAndSettle();
      final url = Uri.parse(opened.single);
      expect(opened.single, startsWith('$issueBaseUrl?'));
      expect(url.queryParameters['template'], issueTemplate);
      expect(url.queryParameters['version'], '0.4.0+5');
      expect(url.queryParameters['platform'], 'Windows 11 · windows_x64 · 桌面');
      expect(url.queryParameters['engine'], startsWith('tvbox-engine'));
      expect(url.queryParameters['logs'], text, reason: 'short enough to go in whole');
      expectClean(opened.single);
      expect(clipboard.last, text, reason: 'the full text is on the clipboard as well');
      // The opener said there is no browser: the QR code takes over.
      expect(find.byKey(const Key('feedback-qr')), findsOneWidget);
    });
  });

  group('TV', () {
    Future<void> key(WidgetTester tester, LogicalKeyboardKey k, {int times = 1}) async {
      for (var i = 0; i < times; i++) {
        await tester.sendKeyEvent(k);
        await tester.pumpAndSettle();
      }
    }

    bool focusIsIn(Finder finder) {
      final node = FocusManager.instance.primaryFocus!;
      final element = finder.evaluate().single;
      var inside = node.context == element;
      node.context!.visitAncestorElements((e) {
        if (e == element) inside = true;
        return !inside;
      });
      return inside;
    }

    /// ↓ until the focus is in [finder], at most [max] times.
    Future<void> downTo(WidgetTester tester, Finder finder, String what, {int max = 60}) async {
      for (var i = 0; i < max; i++) {
        if (finder.evaluate().isNotEmpty && focusIsIn(finder)) return;
        await key(tester, LogicalKeyboardKey.arrowDown);
      }
      fail('↓ did not reach $what; the focus is on ${FocusManager.instance.primaryFocus}');
    }

    /// [direction] until the focus is in [finder], at most three times.
    Future<void> sideTo(WidgetTester tester, Finder finder, LogicalKeyboardKey direction) async {
      for (var i = 0; i < 3 && !focusIsIn(finder); i++) {
        await key(tester, direction);
      }
      expect(focusIsIn(finder), isTrue, reason: '$direction reaches $finder');
    }

    testWidgets('the remote reaches the card, opens a record, scrolls it, comes back and sends feedback by QR code', (tester) async {
      await prepare();
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DeviceFormScope.fixed(
          DeviceForm.tv,
          child: TvboxApp(
            state: AppState(clientFactory: (url) => EngineClient(url, httpClient: fakeEngine(hasConfig: true))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await key(tester, LogicalKeyboardKey.arrowDown, times: 6);
      expect(focusIsIn(find.byKey(const Key('tv-rail-6'))), isTrue, reason: 'the rail entry of 设置');
      await key(tester, LogicalKeyboardKey.select);

      // ↓ goes down the page to the last card; ← / → along its buttons.
      await downTo(tester, find.byKey(const Key('diag-card')), 'the card');
      await sideTo(tester, find.byKey(const Key('diag-open')), LogicalKeyboardKey.arrowLeft);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(DiagnosticsPage), findsOneWidget);
      expect(focusIsIn(find.byKey(const Key('diag-record-0'))), isTrue, reason: 'the page starts on the newest record');
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(focusIsIn(find.byKey(const Key('diag-record-1'))), isTrue);
      await key(tester, LogicalKeyboardKey.arrowUp);
      await key(tester, LogicalKeyboardKey.select);

      // The record: the text has the focus; ↓ scrolls it instead of leaving it.
      expect(find.byType(DiagnosticTextPage), findsOneWidget);
      expect(find.byType(SelectableText), findsNothing, reason: 'a selectable text would keep the arrows for its caret');
      expect(focusIsIn(find.byType(ReadableText)), isTrue);
      final scroll = tester
          .widget<SingleChildScrollView>(find.descendant(of: find.byType(ReadableText), matching: find.byType(SingleChildScrollView)))
          .controller!;
      expect(scroll.offset, 0);
      await key(tester, LogicalKeyboardKey.arrowDown, times: 3);
      expect(scroll.offset, greaterThan(200));
      expect(focusIsIn(find.byType(ReadableText)), isTrue);
      await key(tester, LogicalKeyboardKey.arrowUp, times: 3);
      expect(scroll.offset, 0);
      // At the top, ↑ leaves the text for the bar above.
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(focusIsIn(find.byType(ReadableText)), isFalse);
      expect(focusIsIn(find.byType(AppBar)), isTrue, reason: 'the back and copy buttons');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticTextPage), findsNothing);
      expect(focusIsIn(find.byKey(const Key('diag-record-0'))), isTrue, reason: 'BACK returns to the record that was opened');

      await downTo(tester, find.byType(Wrap), 'the buttons on the page');
      await sideTo(tester, find.byKey(const Key('diag-page-feedback')), LogicalKeyboardKey.arrowRight);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(FeedbackPage), findsOneWidget);
      expect(find.byKey(const Key('feedback-qr')), findsOneWidget, reason: 'a TV shows the QR code right away');
      expect(focusIsIn(find.byKey(const Key('feedback-open'))), isTrue);
      await key(tester, LogicalKeyboardKey.select);
      expect(opened, hasLength(1));
      expect(Uri.parse(opened.single).queryParameters['platform'], 'Windows 11 · windows_x64 · 电视');
      expect(clipboard, isNotEmpty);
      expectClean(clipboard.last);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticsPage), findsNothing);
      expect(focusIsIn(find.byKey(const Key('diag-open'))), isTrue, reason: 'back on the card');
    });
  });
}
