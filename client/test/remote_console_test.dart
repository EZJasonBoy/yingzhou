import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/diagnostics/console_link.dart';
import 'package:tvbox_client/diagnostics/crash_record.dart';
import 'package:tvbox_client/diagnostics/dev_log.dart';
import 'package:tvbox_client/diagnostics/diagnostic_snapshot.dart';
import 'package:tvbox_client/diagnostics/diagnostics.dart';
import 'package:tvbox_client/diagnostics/diagnostics_page.dart';
import 'package:tvbox_client/diagnostics/diagnostics_store_memory.dart';
import 'package:tvbox_client/diagnostics/feedback.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';
import 'package:tvbox_client/pages/player_dev.dart' show MpvPropertyReader;
import 'package:tvbox_client/remote/remote_agent.dart';
import 'package:tvbox_client/remote/remote_app_settings.dart';
import 'package:tvbox_client/remote/remote_diagnostics.dart';
import 'package:tvbox_client/remote/remote_host.dart';
import 'package:tvbox_client/remote/remote_screen.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';
import 'package:tvbox_client/ui/phone_input.dart' show QrView;
import 'package:tvbox_client/ui/user_mode.dart';

import 'fake_engine.dart';
import 'fake_lan_engine.dart';
import 'fake_player.dart';
import 'fake_remote_hub.dart';

/// A player whose libmpv statistics the test sets (the plain fake has none).
class _MpvFakePlayer extends FakePlayer implements MpvPropertyReader {
  final values = <String, String>{};

  @override
  Future<String?> getMpvProperty(String name) async => values[name];
}

/// What the web console needs of the app underneath its pages: answers that carry data, the `diag.*` commands
/// (redacted with the same samples as diagnostics_redact_test.dart), the settings a phone may change, 播放信息 and 链路
/// in the screen's state, and the QR code on 诊断与反馈 that opens the console's logs page.
void main() {
  // ---- the redaction samples (diagnostics_redact_test.dart) ----
  const subscription = 'https://sub.example.com/private/tv.json';
  const token = 'd7f3a9c2.Q2hhbmdlTWVQbGVhc2VUaGlzSXNOb3RBUmVhbFRva2V';
  const secrets = ['sub.example.com', 'private/tv.json', 'Q2hhbmdl', 's3cr3t', 'abc.m3u8', 'AbC_dEf', 'Alice', 'hunter2'];
  const dirty = 'loaded $subscription; GET https://cdn.example.com/live/abc.m3u8?token=s3cr3t&e=1700000000; '
      'play http://127.0.0.1:9978/hls/k1/index.m3u8?tvsig=l2x9k0.local.AbC_dEf-123456&t=1; '
      'data in C:\\Users\\Alice\\.tvbox-next\\engine; password=hunter2; paired with $token';

  void expectClean(Object? value) {
    final text = '$value';
    for (final s in secrets) {
      expect(text, isNot(contains(s)), reason: '"$s" is still in: $text');
    }
  }

  // ---------------------------------------------------------------- the agent

  testWidgets('an answer carries data when the command has some; the older answers stay as they were', (tester) async {
    final hub = FakeRemoteHub();
    final settings = MemorySettings();
    await settings.setString(RemoteAgent.enabledKey, '1');
    final agent = RemoteAgent(
      settings: settings,
      connector: hub.connect,
      collect: () => const {'title': ''},
      perform: (name, args) async => switch (name) {
        'with-data' => RemoteResult.ok({'entries': [1, 2], 'next': 2}),
        'failed-with-data' => const RemoteResult.failed('密码不对', {'locked': true}),
        'too-long' => RemoteResult.ok({'text': 'x' * RemoteAgent.maxMessage}),
        'not-json' => RemoteResult.ok({'when': DateTime(2026)}),
        'old-failed' => '不行',
        _ => null,
      },
    );
    agent.bind(engineUrl: 'http://127.0.0.1:9978', connected: true);
    await tester.pump();
    hub.screen.deliver({'type': 'welcome', 'id': 'x', 'controllers': 0});
    await tester.pump();

    final data = await hub.screen.command(tester, 'with-data');
    expect(data['ok'], isTrue);
    expect(data['data'], {'entries': [1, 2], 'next': 2});
    final failed = await hub.screen.command(tester, 'failed-with-data');
    expect(failed['ok'], isFalse);
    expect(failed['message'], '密码不对');
    expect(failed['data'], {'locked': true});

    // Older commands: no data at all.
    final ok = await hub.screen.command(tester, 'old-ok');
    expect(ok.keys.toSet(), {'type', 'to', 'id', 'ok', 'message'});
    expect(ok['ok'], isTrue);
    final no = await hub.screen.command(tester, 'old-failed');
    expect(no.keys.toSet(), {'type', 'to', 'id', 'ok', 'message'});
    expect(no['message'], '不行');

    // What would end the connection, or cannot be sent at all, becomes a plain failure.
    final long = await hub.screen.command(tester, 'too-long');
    expect(long['ok'], isFalse);
    expect(long['message'], '回答太长，发不过去');
    expect(long.containsKey('data'), isFalse);
    final odd = await hub.screen.command(tester, 'not-json');
    expect(odd['ok'], isFalse);
    expect(odd.containsKey('data'), isFalse);
    agent.dispose();
  });

  // ---------------------------------------------------------------- diag.*

  group('diag', () {
    late Diagnostics diagnostics;
    late MemoryDiagnosticsStore store;
    late DevLog log;
    late RemoteDiagnostics remote;
    var kind = EngineKind.local;

    DiagnosticSnapshot snapshot() => DiagnosticSnapshot(
      diagnostics,
      const DiagnosticEnvironment(appVersion: '0.4.0+5', platform: r'Windows 11 · C:\Users\Alice', form: 'tv', engine: 'tvbox-engine 0.4.1（jvm-windows，协议 v1）· 本机'),
      [subscription],
      engineKind: kind,
      engineVersion: '0.4.1',
    );

    Future<Map<String, dynamic>> ask(String name, [Map<String, Object?> args = const {}]) async {
      final result = (await remote.perform(name, args))!;
      expect(result.error, isNull, reason: '$name: ${result.error}');
      return result.data!.cast<String, dynamic>();
    }

    // Inside each test's own zone (futures made in setUp would never complete in fake async).
    Future<void> prepare() async {
      kind = EngineKind.local;
      store = MemoryDiagnosticsStore();
      diagnostics = Diagnostics(store: store, appVersion: '0.4.0+5', platform: 'Windows 11 · windows_x64', homes: [r'C:\Users\Alice']);
      var t = DateTime.utc(2026, 11, 22, 12, 0, 0);
      log = DevLog(now: () => t = t.add(const Duration(milliseconds: 5)));
      remote = RemoteDiagnostics(snapshot: snapshot, devLog: log);
      await store.save(
        CrashRecord(
          time: DateTime.utc(2026, 11, 20, 14, 31, 7),
          version: '0.4.0+5',
          platform: 'Windows 11',
          form: 'tv',
          source: CrashSource.engine,
          error: '引擎进程退出了（退出码 137）',
          stack: dirty,
        ),
        origin: 'engine',
      );
      await store.save(
        CrashRecord(
          time: DateTime.utc(2026, 11, 22, 12, 14, 31, 502),
          version: '0.4.0+5',
          platform: 'Windows 11',
          form: 'tv',
          source: CrashSource.flutter,
          error: 'FormatException: 订阅 $subscription 不是 JSON\n$dirty',
          stack: '#0 _PlayerPageState._readBuffered',
          repeated: 3,
        ),
      );
      store.engineOutput(r'tvbox-engine listening on http://127.0.0.1:9978, data in C:\Users\Alice\.tvbox-next\engine');
      store.engineOutput('loaded $subscription: 3 sites');
    }

    testWidgets('diag.summary: the app, the engine, the crash records, how much log there is', (tester) async {
      await prepare();
      log.info('引擎', '已连接');
      log.warn('播放器', dirty);
      final s = await ask('diag.summary');
      expect(s['app'], {'version': '0.4.0+5', 'platform': 'Windows 11 · ~', 'form': 'tv'});
      expect(s['engine'], {'version': '0.4.1', 'kind': 'local'});
      expect(s['logCount'], 2);
      expect(s['hasEngineLog'], isTrue, reason: 'the bundled engine on a desktop');
      final crashes = (s['crashes'] as List).cast<Map<String, Object?>>();
      expect(crashes, hasLength(2));
      expect(crashes[0]['time'], '2026-11-22T12:14:31.502Z', reason: 'newest first, ISO-8601');
      expect(crashes[0]['source'], 'flutter');
      expect(crashes[0]['label'], '界面错误');
      expect(crashes[0]['title'], 'FormatException: 订阅 <订阅地址> 不是 JSON');
      expect(crashes[0]['repeated'], 3);
      expect(crashes[1]['source'], 'engine');
      expect(crashes[1]['id'], isA<String>());
      expectClean(s);

      // With the engine on another device there is no output of it here.
      kind = EngineKind.remote;
      final elsewhere = await ask('diag.summary');
      expect(elsewhere['engine'], {'version': '0.4.1', 'kind': 'remote'});
      expect(elsewhere['hasEngineLog'], isFalse);
    });

    testWidgets('diag.log: pages of the log after a number, redacted, never more than asked or than fits', (tester) async {
      await prepare();
      for (var i = 1; i <= 650; i++) {
        log.add(i % 50 == 0 ? DevLevel.error : (i % 10 == 0 ? DevLevel.warn : DevLevel.info), '播放器', '第 $i 行 $dirty', detail: {'地址': subscription, '令牌': 'Bearer $token'});
      }
      // The log keeps its last 500 lines: 151 … 650.
      final first = await ask('diag.log');
      var entries = (first['entries'] as List).cast<Map<String, Object?>>();
      expect(entries, hasLength(RemoteDiagnostics.defaultLines));
      expect(entries.first['seq'], 151);
      expect(entries.first['time'], '2026-11-22T12:00:00.755Z');
      expect(entries.first['level'], 'info');
      expect(entries.first['module'], '播放器');
      expect(entries.first['message'], startsWith('第 151 行 loaded <订阅地址>; GET https://cdn.example.com/…'));
      expect(entries.first['detail'], {'地址': '<订阅地址>', '令牌': 'Bearer ***'});
      expect(entries.firstWhere((e) => e['seq'] == 200)['level'], 'error');
      expect(entries.firstWhere((e) => e['seq'] == 160)['level'], 'warn');
      expect(first['next'], 350);
      expect(first['more'], isTrue);
      expectClean(first);

      final second = await ask('diag.log', {'after': first['next'], 'limit': 10000});
      entries = (second['entries'] as List).cast<Map<String, Object?>>();
      expect(entries, hasLength(300), reason: 'what is left; at most ${RemoteDiagnostics.maxLines}');
      expect(entries.first['seq'], 351);
      expect(second['next'], 650);
      expect(second['more'], isFalse);

      // Nothing new: nothing, and `next` stays where it was.
      final none = await ask('diag.log', {'after': 650});
      expect(none['entries'], isEmpty);
      expect(none['next'], 650);
      log.info('应用', '新的一行');
      final fresh = await ask('diag.log', {'after': 650, 'limit': 5});
      expect([for (final e in fresh['entries'] as List) (e as Map)['message']], ['新的一行']);
      expect(fresh['next'], 651);

      // A number past the newest line: the app started again since, so from the start.
      final restarted = await ask('diag.log', {'after': 99999, 'limit': 3});
      expect([for (final e in restarted['entries'] as List) (e as Map)['seq']], [152, 153, 154]);

      // A page stops before it gets too long to send.
      log.clear();
      for (var i = 0; i < 400; i++) {
        log.info('引擎', 'x' * 2000);
      }
      final big = await ask('diag.log', {'after': 651, 'limit': 500});
      final bigEntries = big['entries'] as List;
      expect(bigEntries.length, lessThan(400));
      expect(big['more'], isTrue);
      expect(big['next'], (bigEntries.last as Map)['seq']);
    });

    testWidgets('diag.crash: one record in full by its id, redacted; diag.engineLog: the engine\'s last lines', (tester) async {
      await prepare();
      final crashes = ((await ask('diag.summary'))['crashes'] as List).cast<Map<String, Object?>>();
      final text = (await ask('diag.crash', {'id': crashes[1]['id']}))['text'] as String;
      expect(text, startsWith(CrashRecord.title));
      expect(text, contains('source: engine'));
      expect(text, contains('引擎进程退出了（退出码 137）'));
      expect(text, contains('<订阅地址>'));
      expectClean(text);
      expect((await remote.perform('diag.crash', {'id': 'nope'}))!.error, '没有这条崩溃记录，可能已经被新的记录替换了');
      expect((await remote.perform('diag.crash', {'id': '../../etc/passwd'}))!.error, isNotNull);
      expect((await remote.perform('diag.crash', const {}))!.error, '没有说是哪一条崩溃记录');

      final engineLog = await ask('diag.engineLog');
      expect(engineLog['title'], '引擎日志');
      expect(engineLog['text'], 'tvbox-engine listening on http://127.0.0.1:9978, data in ~\\.tvbox-next\\engine\nloaded <订阅地址>: 3 sites');
      expect((await ask('diag.engineLog', {'lines': 1}))['text'], 'loaded <订阅地址>: 3 sites');
      kind = EngineKind.remote;
      final elsewhere = await ask('diag.engineLog');
      expect(elsewhere['text'], '');
      expect(elsewhere['hasEngineLog'], isFalse);
    });

    testWidgets('diag.report: the same full text as 复制诊断信息, redacted', (tester) async {
      await prepare();
      String withoutTime(String s) => s.split('\n').where((l) => !l.startsWith('生成时间：')).join('\n');
      final text = (await ask('diag.report'))['text'] as String;
      expect(text, startsWith('映舟诊断信息\n应用版本：0.4.0+5'));
      expect(withoutTime(text), withoutTime(await snapshot().report()));
      expect(text, contains('== 最近的崩溃记录（2 条，新的在前）=='));
      expect(text, contains('loaded <订阅地址>: 3 sites'));
      expectClean(text);
      expect(await remote.perform('diag.nothing', const {}), isNull, reason: 'not one of them');
    });
  });

  // ---------------------------------------------------------------- setting.*

  group('settings', () {
    late MemorySettings store;
    late UserModeController mode;
    late RemoteAppSettings remote;

    void prepare({String form = 'tv'}) {
      store = MemorySettings();
      mode = UserModeController(store);
      remote = RemoteAppSettings(settings: store, userMode: mode, form: form);
    }

    Future<RemoteResult> set(String key, Object? value, [String? pin]) async => (await remote.perform('setting.set', {'key': key, 'value': value, 'pin': ?pin}))!;

    test('setting.get: the whole list, or the keys asked for (nothing outside the list)', () async {
      prepare();
      final all = (await remote.perform('setting.get', const {}))!;
      expect(all.data, {
        'values': {'ui.userMode': 'standard', 'ui.startPage': 'resume', 'danmaku.enabled': true, 'player.osdClock': 'osd', 'play.probeOnDetail': true},
        'locked': false,
      });
      await store.setString('engineUrl', 'http://127.0.0.1:9978');
      final some = (await remote.perform('setting.get', {
        'keys': ['ui.startPage', 'engineUrl', 'remote.screenId', 42],
      }))!;
      expect(some.data, {
        'values': {'ui.startPage': 'resume'},
        'locked': false,
      });
      prepare(form: 'phone');
      expect(remote.read('play.probeOnDetail'), isFalse, reason: 'phones test lines when 播放 is pressed, to save data');
    });

    test('setting.set: each key takes only its own values, and is kept where the app reads it', () async {
      prepare();
      expect((await set('ui.userMode', 'developer')).error, isNull);
      expect(mode.mode, UserMode.developer);
      expect(store.getString('ui.userMode'), 'developer');
      expect((await set('ui.startPage', 'library')).data, {
        'values': {'ui.startPage': 'library'},
        'locked': false,
      });
      expect(mode.startPage, StartPage.library);
      expect((await set('danmaku.enabled', false)).error, isNull);
      expect(store.getString('danmaku.enabled'), 'false', reason: 'as DanmakuPrefs keeps it');
      expect(remote.read('danmaku.enabled'), isFalse);
      expect((await set('player.osdClock', 'always')).error, isNull);
      expect(store.getString('player.osdClock'), 'always');
      expect((await set('play.probeOnDetail', false)).error, isNull);
      expect(store.getString('play.probeOnDetail'), 'false');

      for (final (key, value) in [
        ('ui.userMode', 'expert'),
        ('ui.startPage', 3),
        ('danmaku.enabled', 'yes'),
        ('player.osdClock', 'sometimes'),
        ('play.probeOnDetail', null),
      ]) {
        final r = await set(key, value);
        expect(r.error, isNotNull, reason: '$key = $value');
        expect(r.error, isNot(contains('Exception')));
      }
      expect(mode.mode, UserMode.developer, reason: 'unchanged by the refused ones');
      expect((await set('engineUrl', 'http://evil.example')).error, '这一项不能从手机上改：engineUrl');
      expect(store.getString('engineUrl'), isNull);
      expect((await remote.perform('setting.set', const {}))!.error, '没有说改哪一项');
    });

    test('in simple mode with the code on 设置, a change needs the same four digits', () async {
      prepare();
      await mode.setPin('2580');
      expect(remote.locked, isFalse, reason: 'only simple mode is locked');
      await mode.set(UserMode.simple);
      mode.lock();
      expect(((await remote.perform('setting.get', const {}))!.data!)['locked'], isTrue);

      final none = await set('ui.startPage', 'home');
      expect(none.error, '设置已经上锁，先输入 4 位密码');
      expect(none.data, {'locked': true});
      final wrong = await set('ui.startPage', 'home', '1234');
      expect(wrong.error, '密码不对');
      expect(mode.startPage, StartPage.resume);
      expect((await set('ui.startPage', 'home', '2580')).error, isNull);
      expect(mode.startPage, StartPage.home);
      // Out of simple mode with the code: then nothing is locked any more.
      final out = await set('ui.userMode', 'standard', '2580');
      expect(out.data, {
        'values': {'ui.userMode': 'standard'},
        'locked': false,
      });
      expect((await set('danmaku.enabled', false)).error, isNull);
    });
  });

  // ---------------------------------------------------------------- in the app

  late FakePlayer player;
  late Diagnostics before;

  Future<void> pass(WidgetTester tester, Duration time) async {
    for (var t = Duration.zero; t < time; t += const Duration(milliseconds: 100)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<FakeRemoteHub> pumpApp(WidgetTester tester, {DeviceForm form = DeviceForm.desktop, http.Client? engine, bool enabled = true, SettingsStore? settings, FakePlayer? with_}) async {
    tester.view.physicalSize = form == DeviceForm.tv ? const Size(1920, 1080) : const Size(1400, 1600);
    tester.view.devicePixelRatio = form == DeviceForm.tv ? 2 : 1;
    addTearDown(tester.view.reset);
    before = Diagnostics.instance;
    Diagnostics.instance = Diagnostics(store: MemoryDiagnosticsStore(), appVersion: '0.4.0+5', platform: 'Windows 11 · windows_x64', homes: [r'C:\Users\Alice']);
    addTearDown(() => Diagnostics.instance = before);
    final hub = FakeRemoteHub();
    RemoteScreen.debugConnector = hub.connect;
    addTearDown(() => RemoteScreen.debugConnector = null);
    final store = settings ?? MemorySettings();
    if (enabled) await store.setString(RemoteAgent.enabledKey, '1');
    player = with_ ?? FakePlayer();
    final client = engine ?? fakeEngine(hasConfig: true, lines: [fakeLine('线路一', 'a', count: 4), fakeLine('线路二', 'b', count: 4)]);
    await tester.pumpWidget(
      DeviceFormScope.fixed(
        form,
        child: TvboxApp(
          state: AppState(clientFactory: (url) => EngineClient(url, httpClient: client), settings: store, playerBackend: () => player.backend()),
        ),
      ),
    );
    await pass(tester, const Duration(seconds: 1));
    if (enabled) {
      hub.screen.deliver({'type': 'welcome', 'id': hub.screen.hello['id'], 'controllers': 0});
      await tester.pump();
    }
    return hub;
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  testWidgets('diag and setting commands are answered on any page; the player reports 播放信息, and 链路 in developer mode', (tester) async {
    final settings = MemorySettings();
    await settings.setString(UserModeController.key, 'developer');
    final mpv = _MpvFakePlayer();
    final hub = await pumpApp(tester, settings: settings, with_: mpv);
    DevLog.instance.warn('订阅', 'loaded http://example.test/tv.json');

    // On 首页, nothing playing.
    final summary = await hub.screen.command(tester, 'diag.summary');
    expect(summary['ok'], isTrue);
    final data = summary['data'] as Map<String, dynamic>;
    expect((data['app'] as Map)['version'], '0.4.0+5');
    expect((data['app'] as Map)['form'], 'desktop');
    expect(data['engine'], {'version': '0.1.0', 'kind': 'local'}, reason: 'the fake engine on 127.0.0.1');
    final logged = await hub.screen.command(tester, 'diag.log', {'limit': 500});
    final lines = ((logged['data'] as Map)['entries'] as List).cast<Map<String, dynamic>>();
    expect(lines.map((l) => l['message']), contains('loaded <订阅地址>'), reason: 'the subscription in use is a secret');
    expect('$lines', isNot(contains('example.test')));
    final got = await hub.screen.command(tester, 'setting.get', {
      'keys': ['ui.userMode'],
    });
    expect(got['data'], {
      'values': {'ui.userMode': 'developer'},
      'locked': false,
    });

    // Play, with a phone connected: the statistics are read for it.
    await tester.tap(find.text('推荐片').first);
    await pass(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('detail-play')));
    await pass(tester, const Duration(seconds: 1));
    mpv.values.addAll({
      'video-params/w': '1920',
      'video-params/h': '1080',
      'container-fps': '25.000000',
      'hwdec-current': 'd3d11va',
      'demuxer-cache-duration': '12.43',
      'cache-speed': '3355443',
      'frame-drop-count': '2',
    });
    player.playTo(const Duration(minutes: 1));
    hub.screen.deliver({'type': 'controllers', 'count': 1, 'names': ['我的手机']});
    await pass(tester, const Duration(milliseconds: 600));
    expect(RemoteHost.instance.watched, isTrue);
    final info = hub.screen.player!['info'] as Map<String, dynamic>;
    expect(info['health'], 'smooth');
    expect(info['bufferSeconds'], 12.4);
    expect(info['width'], 1920);
    expect(info['height'], 1080);
    expect(info['fps'], 25.0);
    expect(info['bytesPerSecond'], 3355443);
    expect(info['hwdec'], isTrue);
    expect(info['source'], '采集站');
    expect(info['line'], '线路一');
    expect(info['lineCount'], 2);
    expect(info['how'], '直链');
    expect(info['switched'], isEmpty);

    final chain = hub.screen.player!['chain'] as Map<String, dynamic>;
    final steps = (chain['steps'] as List).cast<Map<String, dynamic>>();
    expect(steps.first, {'title': '订阅', 'detail': '<订阅地址>', 'ok': true});
    expect(steps[1]['title'], '站点 · 采集站');
    expect(steps.map((s) => s['title']), contains('线路 · 线路一（共 2 条）'));
    final resolve = steps.firstWhere((s) => (s['title'] as String).startsWith('解析'));
    expect(resolve['ok'], isTrue);
    expect(resolve['ms'], isA<int>());
    final address = steps.firstWhere((s) => (s['title'] as String).startsWith('播放地址'));
    expect(address['detail'], startsWith('https://cdn.test/…'), reason: 'an address on the internet keeps only its host');
    expect(chain['text'], contains('订阅：<订阅地址>'));
    expect('$chain', isNot(contains('example.test')));
    expect('$chain', isNot(contains('/a/1.m3u8')));

    // The phone leaves: nothing reads the statistics any more.
    hub.screen.deliver({'type': 'controllers', 'count': 0, 'names': <String>[]});
    await tester.pump();
    expect(RemoteHost.instance.watched, isFalse);

    // From the phone, the mode back to standard: 链路 is the developer mode's.
    final changed = await hub.screen.command(tester, 'setting.set', {'key': 'ui.userMode', 'value': 'standard'});
    expect(changed['ok'], isTrue, reason: '${changed['message']}');
    await pass(tester, const Duration(milliseconds: 300));
    expect(settings.getString(UserModeController.key), 'standard');
    expect(hub.screen.player!.containsKey('chain'), isFalse);
    expect(hub.screen.player!['info'], isA<Map<String, dynamic>>(), reason: '播放信息 is in every mode');
    final refused = await hub.screen.command(tester, 'setting.set', {'key': 'remote.enabled', 'value': '0'});
    expect(refused['ok'], isFalse);
    expect(settings.getString(RemoteAgent.enabledKey), '1');
    await leave(tester);
  });

  testWidgets('诊断与反馈 offers 允许手机遥控 when it is off; on, a QR code opens the console\'s logs page with the pairing code', (tester) async {
    final engine = FakeLanEngine(fakeEngine(hasConfig: true), local: true, code: '654321');
    final settings = MemorySettings();
    final hub = await pumpApp(tester, engine: engine, enabled: false, settings: settings);
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()));
    await pass(tester, const Duration(seconds: 1));
    expect(find.text('用手机查看'), findsOneWidget);
    expect(find.byKey(const Key('diag-console-qr')), findsNothing);
    final toggle = find.byKey(const Key('diag-console-switch'));
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await pass(tester, const Duration(seconds: 1));
    expect(engine.sharing, isTrue, reason: 'a phone comes in through LAN sharing');
    expect(settings.getString(RemoteAgent.enabledKey), '1');
    expect(hub.connections, hasLength(1), reason: 'registered with the engine');
    expect(tester.widget<QrView>(find.byKey(const Key('diag-console-qr'))).data, 'http://192.168.1.5:9978/remote/#page=logs&code=654321');
    expect(find.text('用手机查看、下载和反馈'), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const Key('diag-console-url'))).data, 'http://192.168.1.5:9978/remote/');
    expect(find.byKey(const Key('diag-console-switch')), findsNothing);
    await leave(tester);
  });

  testWidgets('诊断与反馈 has no QR code where no phone can come in', (tester) async {
    // The fake engine on this machine cannot share (no LAN sharing): nothing to scan.
    await pumpApp(tester, enabled: true);
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()));
    await pass(tester, const Duration(seconds: 1));
    expect(find.byKey(const Key('diag-console')), findsNothing);
    expect(find.byKey(const Key('diag-version')), findsOneWidget);
    await leave(tester);
  });

  test('the console address carries the page, and the pairing code when there is one', () {
    expect(consoleUrl('http://192.168.1.5:9978'), 'http://192.168.1.5:9978/remote/#page=logs');
    expect(consoleUrl('http://192.168.1.5:9978', code: '123456'), 'http://192.168.1.5:9978/remote/#page=logs&code=123456');
    expect(consoleUrl('http://nas.lan:9978', page: 'playing'), 'http://nas.lan:9978/remote/#page=playing');
  });
}
