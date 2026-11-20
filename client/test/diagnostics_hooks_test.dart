import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/diagnostics/crash_record.dart';
import 'package:tvbox_client/diagnostics/diagnostics.dart';
import 'package:tvbox_client/diagnostics/diagnostics_store_memory.dart';

class _Throws extends StatelessWidget {
  const _Throws();

  @override
  Widget build(BuildContext context) => throw StateError(r'boom in build, file C:\Users\Alice\notes.txt');
}

Diagnostics _diagnostics() => Diagnostics(store: MemoryDiagnosticsStore(), appVersion: '0.4.0+5', platform: 'Testing OS', homes: [r'C:\Users\Alice']);

void main() {
  testWidgets('an error thrown while building a widget lands in a record', (tester) async {
    final d = _diagnostics();
    final testHandler = FlutterError.onError;
    final seenByPrevious = <FlutterErrorDetails>[];
    // What was there before still runs (here a stand-in for the console, instead of the test's own handler).
    FlutterError.onError = seenByPrevious.add;
    d.install();
    await tester.pumpWidget(const _Throws());
    d.uninstall();
    FlutterError.onError = testHandler;

    expect(seenByPrevious, hasLength(1));
    final records = (await tester.runAsync(() async {
      await d.flush();
      return d.store.list();
    }))!;
    final r = records.single.record;
    expect(r.source, CrashSource.flutter);
    expect(r.error, contains('boom in build'));
    expect(r.error, contains(r'~\notes.txt'), reason: 'the home folder is taken out as the record is written');
    expect(r.error, isNot(contains('Alice')));
    expect(r.error, contains('widgets library'));
    expect(r.stack, contains('_Throws.build'));
    expect(r.version, '0.4.0+5');
    expect(r.platform, 'Testing OS');
    expect(r.form, isNotEmpty);
  });

  test('an unhandled asynchronous error in the guarded zone lands in a record', () async {
    final d = _diagnostics();
    final before = Diagnostics.instance;
    final flutterHandler = FlutterError.onError;
    final platformHandler = PlatformDispatcher.instance.onError;
    try {
      await Diagnostics.runGuarded(() async {
        // Nobody awaits these.
        unawaited(Future<void>.delayed(const Duration(milliseconds: 10), () => throw StateError('lost in a timer')));
        scheduleMicrotask(() => throw const FormatException('lost in a microtask'));
      }, diagnostics: d);
      expect(Diagnostics.instance, same(d));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await d.flush();
      final errors = [for (final s in await d.store.list()) (s.record.source, s.record.summary)];
      expect(errors, containsAll([(CrashSource.zone, 'Bad state: lost in a timer'), (CrashSource.zone, 'FormatException: lost in a microtask')]));
    } finally {
      d.uninstall();
      Diagnostics.instance = before;
    }
    expect(FlutterError.onError, same(flutterHandler));
    expect(PlatformDispatcher.instance.onError, same(platformHandler));
  });

  test('an error outside the zone (PlatformDispatcher.onError) lands in a record and counts as handled', () async {
    final d = _diagnostics();
    final previous = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = null;
    d.install();
    try {
      final handled = PlatformDispatcher.instance.onError!(UnsupportedError('from a platform callback'), StackTrace.current);
      expect(handled, isTrue);
    } finally {
      d.uninstall();
      PlatformDispatcher.instance.onError = previous;
    }
    await d.flush();
    final r = (await d.store.list()).single.record;
    expect(r.source, CrashSource.platform);
    expect(r.summary, 'Unsupported operation: from a platform callback');
  });

  test('the same error again counts up; after maxPerRun new errors the rest are only counted', () async {
    final d = _diagnostics();
    final stack = StackTrace.current;
    for (var i = 0; i < 3; i++) {
      d.record(CrashSource.flutter, StateError('again'), stack);
    }
    for (var i = 0; i < Diagnostics.maxPerRun + 5; i++) {
      d.record(CrashSource.flutter, StateError('different $i'), stack);
    }
    await d.flush();
    final records = await d.store.list();
    expect(records, hasLength(Diagnostics.maxPerRun));
    expect(records.where((s) => s.record.summary == 'Bad state: again').single.record.repeated, 3);
    expect(d.dropped, 6);
  });

  test('a poster that fails to load is not a crash', () async {
    final d = _diagnostics();
    final previous = FlutterError.onError;
    FlutterError.onError = (_) {};
    d.install();
    FlutterError.reportError(FlutterErrorDetails(exception: Exception('HTTP 404 for a poster'), library: 'image resource service'));
    FlutterError.reportError(FlutterErrorDetails(exception: Exception('quiet'), silent: true));
    d.uninstall();
    FlutterError.onError = previous;
    await d.flush();
    expect(await d.store.list(), isEmpty);
  });

  test('the desktop engine dying leaves a record with its last lines', () async {
    final d = _diagnostics();
    d.recordEngineExit(1, ['tvbox-engine listening on http://127.0.0.1:19992', r'Exception in thread "main" java.lang.OutOfMemoryError at C:\Users\Alice\x']);
    await d.flush();
    final r = (await d.store.list()).single.record;
    expect(r.source, CrashSource.engine);
    expect(r.error, '引擎进程退出了（退出码 1）');
    expect(r.stack, contains('OutOfMemoryError at ~\\x'));
  });
}
