import 'dart:convert';

import '../diagnostics/dev_log.dart';
import '../diagnostics/diagnostic_snapshot.dart';
import 'remote_agent.dart';
import 'remote_host.dart' show RemoteArgs;

/// The remote's `diag.*` commands (docs/protocol.md, "遥控"): what the web console's 日志与崩溃 page shows of this
/// device, which lives in the app and not in the engine: the log ([DevLog]), the crash records, the built-in engine's
/// output and the full diagnostic text. Answered whatever page is open.
///
/// Everything goes through [DiagnosticSnapshot.redact] (`Diagnostics.redact` with the subscription addresses the app
/// knows of) before it leaves the device: what the phone gets can be posted as it is.
class RemoteDiagnostics {
  RemoteDiagnostics({required this.snapshot, this.devLog});

  /// The device and its engine as they are now.
  final DiagnosticSnapshot Function() snapshot;

  /// The log to read; [DevLog.instance] when null (tests put their own there).
  final DevLog? devLog;

  DevLog get log => devLog ?? DevLog.instance;

  /// Lines of the log in one answer: [defaultLines] unless asked otherwise, never more than [maxLines].
  static const defaultLines = 200;
  static const maxLines = 500;

  /// The engine's output: lines asked for by default, and at most.
  static const defaultEngineLines = 300;
  static const maxEngineLines = 2000;

  /// About how much text one answer carries (the engine takes at most [RemoteAgent.maxMessage] from a screen); a
  /// page of the log that would be longer stops early, and `next` says where to go on.
  static const budget = 384 * 1024;

  static bool handles(String name) => name.startsWith('diag.');

  /// The answer to [name]; null when it is not one of these commands.
  Future<RemoteResult?> perform(String name, Map<String, Object?> args) async => switch (name) {
    'diag.summary' => _summary(),
    'diag.log' => _page(args),
    'diag.crash' => _crash(args),
    'diag.engineLog' => _engineLog(args),
    'diag.report' => _report(),
    _ => null,
  };

  /// ISO-8601 in UTC (`2026-11-22T12:34:56.789Z`), which every browser reads.
  static String _time(DateTime t) => t.toUtc().toIso8601String();

  Future<RemoteResult> _summary() async {
    final s = snapshot();
    await s.diagnostics.flush();
    final records = await s.diagnostics.store.list();
    return RemoteResult.ok({
      'app': {'version': s.env.appVersion, 'platform': s.redact(s.env.platform), 'form': s.env.form},
      'engine': {'version': s.engineVersion, 'kind': s.engineKind.name},
      'crashes': [
        for (final r in records)
          {
            'id': r.id,
            'time': _time(r.record.time),
            'source': r.record.source.name,
            // What the app calls it (界面错误, 引擎退出 …), for a page that wants the same words.
            'label': r.record.source.label,
            'title': s.redact(r.record.summary),
            'repeated': r.record.repeated,
          },
      ],
      'logCount': log.length,
      'hasEngineLog': s.hasEngineLog,
    });
  }

  /// The lines after `after` (all of them without it), oldest first, at most `limit`.
  Future<RemoteResult> _page(Map<String, Object?> args) async {
    final s = snapshot();
    final limit = (args.integer('limit') ?? defaultLines).clamp(1, maxLines);
    final entries = log.entries;
    var after = args.integer('after') ?? 0;
    // Past the newest line: the app started again since (its log counts from 1 again), so from the start.
    if (after > log.lastSeq || after < 0) after = 0;
    final out = <Map<String, Object?>>[];
    var next = after;
    var size = 0;
    var more = false;
    for (final e in entries) {
      if (e.seq <= after) continue;
      if (out.length >= limit) {
        more = true;
        break;
      }
      final line = {
        'seq': e.seq,
        'time': _time(e.time),
        'level': e.level.name,
        'module': s.redact(e.module),
        'message': s.redact(e.message),
        'detail': {for (final d in e.detail.entries) s.redact(d.key): s.redact(d.value)},
      };
      size += jsonEncode(line).length;
      if (out.isNotEmpty && size > budget) {
        more = true;
        break;
      }
      out.add(line);
      next = e.seq;
    }
    return RemoteResult.ok({'entries': out, 'next': next, 'more': more});
  }

  Future<RemoteResult> _crash(Map<String, Object?> args) async {
    final id = args.string('id') ?? '';
    if (id.isEmpty) return const RemoteResult.failed('没有说是哪一条崩溃记录');
    final s = snapshot();
    await s.diagnostics.flush();
    // Only a record the list names: an id is not a path to read whatever it points at.
    final record = (await s.diagnostics.store.list()).where((r) => r.id == id).firstOrNull;
    if (record == null) return const RemoteResult.failed('没有这条崩溃记录，可能已经被新的记录替换了');
    final text = await s.diagnostics.store.read(id) ?? record.record.format();
    return RemoteResult.ok({'text': _head(s.redact(text))});
  }

  Future<RemoteResult> _engineLog(Map<String, Object?> args) async {
    final s = snapshot();
    final lines = (args.integer('lines') ?? defaultEngineLines).clamp(1, maxEngineLines);
    final (title, text) = await s.engineLog(lines: lines);
    return RemoteResult.ok({'text': _tail(text), 'title': title, 'hasEngineLog': s.hasEngineLog});
  }

  Future<RemoteResult> _report() async => RemoteResult.ok({'text': _head(await snapshot().report())});

  /// A text that would not fit: its beginning, and a word that the rest is missing.
  static String _head(String text) =>
      text.length <= budget ? text : '${text.substring(0, budget)}\n…（太长，后面的部分没有发过来）';

  /// A log that would not fit: its last lines.
  static String _tail(String text) {
    if (text.length <= budget) return text;
    final cut = text.substring(text.length - budget);
    final start = cut.indexOf('\n');
    return start < 0 ? cut : cut.substring(start + 1);
  }
}
