import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine_client.dart';
import 'models.dart' show EngineException;
import 'vod_models.dart';

/// What the line probe (线路体检, `POST /api/v1/play/probe`) found out about one line, for one episode.
///
/// The engine resolves the episode on the line the way 播放 would, fetches the playlist and the start of its first
/// segment, and reports whether that worked and how fast. [testing] is the client's own: asked, no answer yet.
enum LineProbeState {
  testing,

  /// Resolved, and the playlist and the start of a segment came.
  ok,

  /// Came, but slower than its picture needs, or after the time budget.
  slow,

  /// Did not resolve, or the address does not open ([LineProbe.reason] says why in a few words).
  dead,

  /// Needs a web page sniffed for its address: only playing it tells.
  sniff,

  /// Over the number of lines one probe measures: not measured.
  skipped;

  static LineProbeState parse(String? s) => switch (s) {
    'ok' => ok,
    'slow' => slow,
    'dead' => dead,
    'sniff' => sniff,
    // An answer a newer engine may give means nothing to this client: nothing is said about the line.
    _ => skipped,
  };

  /// Measured and alive: it is worth waiting for.
  bool get alive => this == ok || this == slow;
}

/// How much a label says: simple mode three plain words, standard mode the picture and the speed, developer mode
/// the milliseconds too (rule one: the modes change the wording, not what is there).
enum ProbeWording { simple, standard, developer }

/// One line's result. Numbers the engine did not measure are null.
@immutable
class LineProbe {
  const LineProbe({
    required this.index,
    required this.line,
    required this.state,
    this.kind = '',
    this.width,
    this.height,
    this.resolveMs,
    this.firstByteMs,
    this.bytesPerSecond,
    this.parsedBy = '',
    this.reason = '',
  });

  /// Asked of the engine, no answer yet.
  const LineProbe.testing(this.index, [this.line = ''])
    : state = LineProbeState.testing,
      kind = '',
      width = null,
      height = null,
      resolveMs = null,
      firstByteMs = null,
      bytesPerSecond = null,
      parsedBy = '',
      reason = '';

  factory LineProbe.fromJson(Map<String, dynamic> j) => LineProbe(
    index: (j['index'] as num?)?.toInt() ?? -1,
    line: j['line'] as String? ?? '',
    state: LineProbeState.parse(j['state'] as String?),
    kind: j['kind'] as String? ?? '',
    width: (j['width'] as num?)?.toInt(),
    height: (j['height'] as num?)?.toInt(),
    resolveMs: (j['resolveMs'] as num?)?.toInt(),
    firstByteMs: (j['firstByteMs'] as num?)?.toInt(),
    bytesPerSecond: (j['bytesPerSecond'] as num?)?.toDouble(),
    parsedBy: j['parsedBy'] as String? ?? '',
    reason: j['reason'] as String? ?? '',
  );

  /// In an answer of the engine, the line's place in the request; in a [LineProbeRun], the line's place in the
  /// title's lines.
  final int index;

  /// The line's name as the site gives it.
  final String line;
  final LineProbeState state;

  /// `hls`, `file`, or empty when unknown.
  final String kind;
  final int? width;
  final int? height;
  final int? resolveMs;
  final int? firstByteMs;
  final double? bytesPerSecond;
  final String parsedBy;

  /// Why a [LineProbeState.dead] line does not open, in a few words (超时, 404, 被拒绝).
  final String reason;

  LineProbe withIndex(int i) => LineProbe(
    index: i,
    line: line,
    state: state,
    kind: kind,
    width: width,
    height: height,
    resolveMs: resolveMs,
    firstByteMs: firstByteMs,
    bytesPerSecond: bytesPerSecond,
    parsedBy: parsedBy,
    reason: reason,
  );

  /// The picture's height as a TV would name it (a film cropped to 1920×800 is still 1080), 0 when unknown.
  int get resolution {
    final w = width, h = height;
    if (w == null || h == null || w <= 0 || h <= 0) return 0;
    return h > w * 9 ~/ 16 ? h : w * 9 ~/ 16;
  }

  /// 1080p, 4K …; null when the engine could not tell.
  String? get quality {
    final w = width, h = height;
    return w == null || h == null || w <= 0 || h <= 0 ? null : videoQuality(w, h);
  }

  /// 3.2 MB/s; null when not measured.
  String? get speed => bytesPerSecond == null || bytesPerSecond! <= 0 ? null : speedLabel(bytesPerSecond!);

  /// About how fast a line must be for its picture to play without stopping: 1080p about 0.6 MB/s, 4K about 2.5.
  double get neededBytesPerSecond {
    final p = resolution;
    const mb = 1048576.0;
    if (p >= 2160) return 2.5 * mb;
    if (p >= 1440) return 1.2 * mb;
    if (p >= 1080) return 0.6 * mb;
    if (p >= 720) return 0.3 * mb;
    return 0.15 * mb;
  }

  /// Measured fast enough for its own picture.
  bool get fastEnough => bytesPerSecond != null && bytesPerSecond! >= neededBytesPerSecond;

  /// The picture and the speed, as far as they are known: `1080p · 3.2 MB/s`.
  String get numbers => [?quality, ?speed].join(' · ');

  String _ms(ProbeWording w) =>
      w != ProbeWording.developer ? '' : [if (resolveMs != null) '解析 $resolveMs ms', if (firstByteMs != null) '首字节 $firstByteMs ms'].map((s) => ' · $s').join();

  /// The words next to a line, without the 慢 mark of a slow line ([slowMark] says whether it gets one); empty
  /// for a line being measured (it shows the wave) or one that was not measured.
  ///
  /// Simple mode: 快 / 慢 / 打不开 / 要试了才知道. Standard: `1080p · 3.2 MB/s`, `打不开 · 超时`. Developer: the same
  /// with the milliseconds.
  String label(ProbeWording w) {
    final simple = w == ProbeWording.simple;
    return switch (state) {
      LineProbeState.testing || LineProbeState.skipped => '',
      LineProbeState.ok => simple ? '快' : '${numbers.isEmpty ? '能播' : numbers}${_ms(w)}',
      LineProbeState.slow => simple ? '' : '$numbers${_ms(w)}',
      LineProbeState.dead => simple || reason.isEmpty ? '打不开${simple ? '' : _ms(w)}' : '打不开 · $reason${_ms(w)}',
      LineProbeState.sniff => '要试了才知道',
    };
  }

  /// A slow line carries a 慢 mark after its [label].
  bool get slowMark => state == LineProbeState.slow;

  /// [label] and the 慢 mark in one line of text, for places that show plain text.
  String text(ProbeWording w) {
    final l = label(w);
    if (state == LineProbeState.testing) return '测速中';
    if (!slowMark) return l;
    return l.isEmpty ? '慢' : '$l · 慢';
  }

  @override
  String toString() => 'LineProbe($index $line ${state.name} $numbers $reason)';
}

/// 1080p, 4K …: by the width, so a film cropped to 1920×800 still counts as 1080p.
String videoQuality(int width, int height) {
  if (width >= 3840 || height >= 2160) return '4K';
  if (width >= 2560 || height >= 1440) return '2K';
  if (width >= 1920 || height >= 1080) return '1080p';
  if (width >= 1280 || height >= 720) return '720p';
  return '${height}p';
}

/// 3.2 MB/s, 640 KB/s.
String speedLabel(double bytesPerSecond) =>
    bytesPerSecond >= 1048576 ? '${(bytesPerSecond / 1048576).toStringAsFixed(1)} MB/s' : '${(bytesPerSecond / 1024).round()} KB/s';

/// The line 播放 starts on, from what the probe found ([results] by line index) — the rule of
/// docs/design/line-probe.md:
///
/// 1. the line watched last time ([lastWatched]), if it is `ok`: habits are not upset;
/// 2. else among the `ok` lines, the highest picture whose speed is enough for it (1080p about 0.6 MB/s, 4K about
///    2.5), the faster one of two alike;
/// 3. else the fastest `ok` line; with none, the fastest `slow` one;
/// 4. else [fallback] (what 播放 would play without a probe), or when the probe found that one dead, the next of
///    [candidates] (the lines that have the episode) it did not.
///
/// No results yet: [fallback], as before there was a probe.
int choosePlayLine(Map<int, LineProbe> results, {int? lastWatched, required int fallback, List<int> candidates = const []}) {
  if (results.isEmpty) return fallback;
  if (lastWatched != null && results[lastWatched]?.state == LineProbeState.ok) return lastWatched;
  int byIndex(LineProbe a, LineProbe b) => a.index.compareTo(b.index);
  double bps(LineProbe p) => p.bytesPerSecond ?? 0;
  final ok = results.values.where((p) => p.state == LineProbeState.ok).toList()..sort(byIndex);
  if (ok.isNotEmpty) {
    final enough = ok.where((p) => p.fastEnough).toList();
    if (enough.isNotEmpty) {
      enough.sort((a, b) {
        final c = b.resolution.compareTo(a.resolution);
        if (c != 0) return c;
        final s = bps(b).compareTo(bps(a));
        return s != 0 ? s : byIndex(a, b);
      });
      return enough.first.index;
    }
    return _fastest(ok);
  }
  final slow = results.values.where((p) => p.state == LineProbeState.slow).toList()..sort(byIndex);
  if (slow.isNotEmpty) return _fastest(slow);
  if (results[fallback]?.state != LineProbeState.dead) return fallback;
  final order = [...candidates.where((i) => i > fallback), ...candidates.where((i) => i < fallback)];
  for (final i in order) {
    if (results[i]?.state != LineProbeState.dead) return i;
  }
  return fallback;
}

int _fastest(List<LineProbe> probes) {
  var best = probes.first;
  for (final p in probes.skip(1)) {
    final a = p.bytesPerSecond ?? 0, b = best.bytesPerSecond ?? 0;
    if (a > b || (a == b && p.resolution > best.resolution)) best = p;
  }
  return best.index;
}

/// One probe of one episode on every line of a title that has it. It notifies as each line's answer comes.
class LineProbeRun extends ChangeNotifier {
  LineProbeRun._({required this.key, required this.client, required this.lineNames, required this.asked});

  /// [LineProbes.episodeKey] of the episode.
  final String key;

  /// The engine asked: an answer from one engine says nothing about another's network.
  final EngineClient client;

  /// The title's lines when it was asked: a detail loaded again with other lines does not reuse it.
  final List<String> lineNames;

  /// The lines asked about, by their place in the title's lines, in the order of the request.
  final List<int> asked;

  final _results = <int, LineProbe>{};
  StreamSubscription<LineProbe>? _sub;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt;
  bool _running = true;

  /// The engine could not probe: it is from before the probe ([unsupported]), or the request failed.
  bool failed = false;
  bool unsupported = false;

  bool get running => _running;

  /// The answers so far, by the line's place in the title's lines.
  Map<int, LineProbe> get results => Map.unmodifiable(_results);

  /// What is known of [line]: its answer, [LineProbeState.testing] while it is being measured, null when it was not
  /// asked about (it does not have the episode) or no answer came.
  LineProbe? of(int line) => _results[line] ?? (_running && asked.contains(line) ? LineProbe.testing(line) : null);

  void _start(Stream<LineProbe> answers, VoidCallback onChanged) {
    _sub = answers.listen(
      (p) {
        if (p.index < 0 || p.index >= asked.length) return;
        final line = asked[p.index];
        _results[line] = p.withIndex(line);
        notifyListeners();
        onChanged();
      },
      onError: (Object e) {
        _running = false;
        finishedAt = DateTime.now();
        failed = _results.isEmpty;
        unsupported = e is EngineException && (e.statusCode == 404 || e.statusCode == 405);
        notifyListeners();
        onChanged();
      },
      onDone: () {
        _running = false;
        finishedAt = DateTime.now();
        notifyListeners();
        onChanged();
      },
      cancelOnError: true,
    );
  }

  /// Stops listening: the engine sees the connection close and stops measuring the rest.
  void cancel() {
    final sub = _sub;
    _sub = null;
    if (sub != null && _running) unawaited(sub.cancel());
    _running = false;
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

/// The probes made in this session, by title and episode, so the detail page and the player (and the remote's
/// view of the player) see the same answers. Notifies whenever any probe learns something.
///
/// Only what is asked for is probed: the detail page asks for the episode it would play, once the detail and its
/// history are in (or only when 播放 is pressed, with 「打开详情时先测线路」 off); never a whole series, never in the
/// background. Answers are kept [maxAge], as long as the engine keeps its own.
class LineProbes extends ChangeNotifier {
  LineProbes({this.maxAge = const Duration(minutes: 5)});

  final Duration maxAge;
  final _runs = <String, LineProbeRun>{};

  /// Site, title and episode. The episode goes by its name, which is what finds it on the other lines
  /// ([PlayLine.findEpisode]); by its place when it has none.
  static String episodeKey(VodDetail d, int line, int episode) {
    final name = d.lines[line].episodes[episode].name.trim();
    return '${d.site}|${d.id}|${name.isEmpty ? '#$episode' : name}';
  }

  /// The lines of [d] that have the episode at [line] / [episode], and where it is on each.
  static List<(int, int)> linesWith(VodDetail d, int line, int episode) {
    final name = d.lines[line].episodes[episode].name;
    return [
      for (var i = 0; i < d.lines.length; i++)
        if ((i == line ? episode : d.lines[i].findEpisode(index: episode, name: name)) case final at?) (i, at),
    ];
  }

  static bool _valid(VodDetail d, int line, int episode) => line >= 0 && line < d.lines.length && episode >= 0 && episode < d.lines[line].episodes.length;

  /// The probe of that episode made with [client], while it is under way or fresh; null when there is none.
  LineProbeRun? find(EngineClient client, VodDetail d, int line, int episode) {
    if (!_valid(d, line, episode)) return null;
    final run = _runs[episodeKey(d, line, episode)];
    if (run == null || !identical(run.client, client) || !listEquals(run.lineNames, [for (final l in d.lines) l.name])) return null;
    if (!run.running && DateTime.now().difference(run.startedAt) > maxAge) return null;
    return run;
  }

  /// Probes the episode at [line] / [episode] on every line of [d] that has it, unless a fresh probe of it is there
  /// already ([again] asks anew). Null when there is nothing to choose between: fewer than two lines have it, or
  /// the title is in a drive (the user's own files).
  LineProbeRun? probe(EngineClient client, VodDetail d, {required int line, required int episode, bool direct = false, bool again = false}) {
    if (!_valid(d, line, episode) || d.site.startsWith('drive:')) return null;
    if (!again) {
      final known = find(client, d, line, episode);
      if (known != null) return known;
    }
    final lines = linesWith(d, line, episode);
    if (lines.length < 2) return null;
    final key = episodeKey(d, line, episode);
    _runs.remove(key)?.cancel();
    final run = LineProbeRun._(key: key, client: client, lineNames: [for (final l in d.lines) l.name], asked: [for (final (i, _) in lines) i]);
    _runs[key] = run;
    run._start(
      client.probeLines(d.site, [for (final (i, at) in lines) (line: d.lines[i].name, episodeId: d.lines[i].episodes[at].id)], direct: direct),
      notifyListeners,
    );
    notifyListeners();
    return run;
  }

  /// Stops [run] when nobody needs it any more (the detail page that asked for it closed); what it had not
  /// measured yet is asked again next time. Nobody is told: it is called while a page is taken down, and the only
  /// page showing the probe is that one.
  void release(LineProbeRun? run) {
    if (run == null || !run.running) return;
    run.cancel();
    if (identical(_runs[run.key], run)) _runs.remove(run.key);
  }
}
