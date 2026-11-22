import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';

/// The fake engine with Python spiders: one Python site in the list, `/api/v1/python` and its actions. A download or
/// an installation finishes on the next status request after it started. Bodies of what the app sends are noted.
class _PythonEngine extends http.BaseClient {
  _PythonEngine({this.available = false, this.supported = true, List<String>? installed, this.missing = const []}) : installed = installed ?? [];

  bool available;
  bool supported;
  final List<String> installed;
  List<Map<String, Object>> missing;
  String pythonPath = '';
  String indexUrl = '';
  String downloadMirror = '';
  Map<String, Object>? task;
  final sent = <String>[];
  final http.Client _inner = fakeEngine(hasConfig: true);

  static const common = ['requests', 'lxml', 'pycryptodome', 'beautifulsoup4', 'pyquery', 'ujson', 'jsonpath', 'cachetools'];

  http.StreamedResponse _json(Object body, [int status = 200]) =>
      http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), status, headers: {'content-type': 'application/json; charset=utf-8'});

  Map<String, Object?> _status() {
    // A task that was started is over by the time the app asks again.
    final t = task;
    if (t != null && t['state'] == 'running' && t['seen'] == true) {
      if (t['kind'] == 'download') available = true;
      if (t['kind'] == 'install') installed.addAll((t['packages'] as List).cast<String>());
      if (t['kind'] == 'install') missing = [];
      task = {...t, 'state': 'done', 'message': t['kind'] == 'download' ? 'Python 已下载' : '安装完成', 'progress': 1.0};
    } else if (t != null && t['state'] == 'running') {
      task = {...t, 'seen': true};
    }
    return {
      'supported': true,
      'available': available,
      if (available) 'python': {'path': r'C:\data\python\runtime\python.exe', 'version': '3.14.10', 'source': 'downloaded', 'pip': false},
      'problem': available ? '' : '没有找到 Python 3.8 或更新的版本',
      'settings': {'path': pythonPath, 'indexUrl': indexUrl, 'downloadMirror': downloadMirror},
      'packagesDir': available ? r'C:\data\python\packages\cp314-win_amd64' : '',
      'packages': [
        for (final p in common) {'name': p, 'module': p, 'installed': installed.contains(p), 'where': installed.contains(p) ? 'engine' : ''},
      ],
      'missing': missing,
      'download': {
        'version': '3.14.10',
        'url': 'https://www.python.org/ftp/python/3.14.10/python-3.14.10-embed-amd64.zip',
        'sizeBytes': 12619664,
        'sha256': '90905e64',
        'dir': r'C:\data\python\runtime',
        'installed': available,
      },
      'task': ?task,
      'worker': {'running': false, 'pid': 0, 'starts': 0, 'spiders': 0},
    };
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request ? request.body : '';
    final path = request.url.path;
    if (path.startsWith('/api/v1/python')) {
      sent.add('${request.method} ${path.replaceFirst('/api/v1/', '')}${body.isEmpty ? '' : ' $body'}');
      if (!supported) {
        return _json({
          'error': {'code': 'NOT_FOUND', 'message': 'no route'},
        }, 404);
      }
    }
    switch ((request.method, path)) {
      case ('GET', '/api/v1/info'):
        return _json({
          'name': 'tvbox-engine',
          'version': '0.1.0',
          'protocol': 1,
          'platform': 'jvm-windows',
          'capabilities': {'jar': false, 'js': false, 'py': available, 'sniff': false},
        });
      case ('GET', '/api/v1/sites'):
        return _json([
          {'key': 'cms', 'name': '采集站', 'type': 1, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'cms'},
          {'key': 'pysite', 'name': 'Python站', 'type': 3, 'searchable': true, 'quickSearch': true, 'filterable': true, 'runtime': 'py'},
        ]);
      case ('GET', '/api/v1/python'):
        return _json(_status());
      case ('PUT', '/api/v1/python'):
        final settings = jsonDecode(body) as Map<String, dynamic>;
        pythonPath = settings['path'] as String? ?? pythonPath;
        indexUrl = settings['indexUrl'] as String? ?? indexUrl;
        downloadMirror = settings['downloadMirror'] as String? ?? downloadMirror;
        return _json(_status());
      case ('POST', '/api/v1/python/download'):
        task = {'kind': 'download', 'state': 'running', 'message': '正在下载 Python 3.14.10', 'progress': 0.4, 'log': <String>[]};
        return _json(_status());
      case ('POST', '/api/v1/python/packages'):
        final packages = ((jsonDecode(body) as Map<String, dynamic>)['packages'] as List).cast<String>();
        task = {
          'kind': 'install',
          'state': 'running',
          'message': '正在安装',
          'progress': -1,
          'log': ['\$ pip install ${packages.join(' ')}'],
          'packages': packages,
        };
        return _json(_status());
    }
    return _inner.send(request);
  }
}

void main() {
  Future<_PythonEngine> openSources(WidgetTester tester, _PythonEngine engine) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url, httpClient: engine)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    return engine;
  }

  /// Lets a started task finish: the poll a second later sees it done.
  Future<void> finishTask(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('without Python: says so, Python sites say what they need, and the download asks first', (tester) async {
    final engine = await openSources(tester, _PythonEngine());
    expect(find.text('Python 蜘蛛'), findsOneWidget);
    expect(find.byKey(const Key('python-missing')), findsOneWidget);
    expect(find.textContaining('没有找到 Python 3.8 或更新的版本'), findsOneWidget);
    // The site list is on 源, kept alive behind 设置.
    expect(find.textContaining('pysite · 需要 Python', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('下载 Python 运行时（12.0 MB）'), findsOneWidget);

    // The dialog says what, from where, how big and to where; cancelling sends nothing.
    await tester.tap(find.byKey(const Key('python-download')));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.textContaining('从 www.python.org 下载 CPython 3.14.10')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.textContaining('12.0 MB')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.textContaining(r'C:\data\python\runtime')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(engine.sent.where((s) => s.startsWith('POST')), isEmpty);

    await tester.tap(find.byKey(const Key('python-download')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('python-confirm')));
    await tester.pump();
    await tester.pump();
    expect(engine.sent, contains('POST python/download'));
    expect(find.textContaining('正在下载 Python 3.14.10'), findsOneWidget);

    await finishTask(tester);
    expect(find.text('Python 3.14.10 · 下载的运行时'), findsOneWidget);
    expect(find.textContaining('Python 已下载'), findsOneWidget);
    // The engine can run Python sites now: the site list follows.
    expect(find.textContaining('pysite · 需要 Python', skipOffstage: false), findsNothing);
    expect(find.text('pysite', skipOffstage: false), findsOneWidget);
    expect(find.byKey(const Key('python-remove')), findsOneWidget);
  });

  testWidgets('installing the common packages, and one a spider asked for', (tester) async {
    final engine = await openSources(
      tester,
      _PythonEngine(
        available: true,
        installed: ['pycryptodome', 'beautifulsoup4', 'pyquery', 'ujson', 'jsonpath', 'cachetools'],
        missing: [
          {'module': 'websocket', 'packageName': 'websocket-client', 'site': 'Python站', 'at': 1},
        ],
      ),
    );
    expect(find.text('Python 3.14.10 · 下载的运行时'), findsOneWidget);
    expect(find.text('安装常用依赖（2 个）'), findsOneWidget);
    expect(find.textContaining('「Python站」缺少 Python 包 websocket-client（模块 websocket）'), findsOneWidget);

    await tester.tap(find.byKey(const Key('python-install-common')));
    await tester.pumpAndSettle();
    expect(find.textContaining('requests、lxml'), findsOneWidget);
    expect(find.textContaining(r'C:\data\python\packages\cp314-win_amd64'), findsOneWidget);
    await tester.tap(find.byKey(const Key('python-confirm')));
    await tester.pump();
    await tester.pump();
    expect(engine.sent, contains('POST python/packages {"packages":["requests","lxml"]}'));
    await finishTask(tester);
    expect(find.textContaining('安装完成'), findsOneWidget);
    expect(find.byKey(const Key('python-install-common')), findsNothing);
    expect(find.textContaining('常用的包都有了'), findsOneWidget);
  });

  testWidgets('a package a spider is missing is installed by name', (tester) async {
    final engine = await openSources(
      tester,
      _PythonEngine(
        available: true,
        installed: [..._PythonEngine.common],
        missing: [
          {'module': 'websocket', 'packageName': 'websocket-client', 'site': 'Python站', 'at': 1},
        ],
      ),
    );
    await tester.tap(find.byKey(const Key('python-install-websocket-client')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('python-confirm')));
    await tester.pump();
    await tester.pump();
    expect(engine.sent, contains('POST python/packages {"packages":["websocket-client"]}'));
    await finishTask(tester);
    expect(find.textContaining('缺少 Python 包'), findsNothing);
  });

  testWidgets('the path the user sets is sent to the engine', (tester) async {
    final engine = await openSources(tester, _PythonEngine());
    await tester.enterText(find.byKey(const Key('python-path')), r'D:\Python312');
    await tester.tap(find.text('应用').last);
    await tester.pumpAndSettle();
    expect(engine.sent, contains(r'PUT python {"path":"D:\\Python312"}'));
  });

  testWidgets('an engine without Python spiders shows no such section', (tester) async {
    await openSources(tester, _PythonEngine(supported: false));
    expect(find.text('Python 蜘蛛'), findsNothing);
    expect(find.byKey(const Key('github-proxy-switch')), findsOneWidget);
  });

  testWidgets('Python mirrors include presets, custom addresses and a return to the default', (tester) async {
    final engine = await openSources(tester, _PythonEngine());
    await tester.ensureVisible(find.text('镜像'));
    await tester.tap(find.text('镜像'));
    await tester.pumpAndSettle();
    final index = find.byKey(const Key('python-index-choice'));
    final runtime = find.byKey(const Key('python-mirror-choice'));
    await tester.ensureVisible(index);
    await tester.tap(index);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清华 TUNA').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(runtime);
    await tester.tap(runtime);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义地址…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('python-mirror')), 'https://mirror.example/python/');
    final save = find.descendant(of: find.byKey(const Key('python-settings')), matching: find.text('保存'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(engine.indexUrl, 'https://pypi.tuna.tsinghua.edu.cn/simple/');
    expect(engine.downloadMirror, 'https://mirror.example/python/');
    await tester.ensureVisible(runtime);
    await tester.tap(runtime);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Python 官方（python.org）').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(engine.downloadMirror, '');
    expect(engine.indexUrl, 'https://pypi.tuna.tsinghua.edu.cn/simple/');
  });
}
