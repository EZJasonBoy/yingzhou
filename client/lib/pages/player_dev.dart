import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/diagnostics.dart';
import '../engine/vod_models.dart';

/// A player whose libmpv properties can be read by name. The real one is media_kit's `NativePlayer`; a test's fake
/// player implements this to answer them.
abstract class MpvPropertyReader {
  Future<String?> getMpvProperty(String name);
}

/// A libmpv property of [player], or null where the player has none (the web, a fake without them) or does not
/// know this one.
Future<String?> readMpvProperty(Player player, String name) async {
  final platform = player.platform;
  try {
    if (platform is NativePlayer) {
      final value = await platform.getProperty(name);
      return value.isEmpty ? null : value;
    }
    if (platform is MpvPropertyReader) return await (platform as MpvPropertyReader).getMpvProperty(name);
  } catch (_) {
    // Not known to this libmpv, or the player is going away.
  }
  return null;
}

/// Developer mode: playback statistics over the picture (the I key), read from the player once a second. What the
/// decoder and the output are doing is libmpv's own account; where there is no libmpv to ask, the few things every
/// player knows are shown instead.
class PlayerStatsOverlay extends StatefulWidget {
  const PlayerStatsOverlay({super.key, required this.player});

  final Player player;

  static const _properties = [
    'video-format',
    'video-params/w',
    'video-params/h',
    'container-fps',
    'estimated-vf-fps',
    'hwdec-current',
    'current-vo',
    'osd-width',
    'osd-height',
    'display-fps',
    'frame-drop-count',
    'decoder-frame-drop-count',
    'audio-codec-name',
    'audio-params/samplerate',
    'audio-params/channel-count',
    'avsync',
    'video-bitrate',
    'demuxer-cache-duration',
    'cache-speed',
  ];

  @override
  State<PlayerStatsOverlay> createState() => _PlayerStatsOverlayState();
}

class _PlayerStatsOverlayState extends State<PlayerStatsOverlay> {
  Timer? _timer;
  Map<String, String> _values = const {};
  bool _reading = false;

  /// Seconds buffered ahead, one sample a second, the last minute.
  final _buffer = <double>[];

  @override
  void initState() {
    super.initState();
    _read();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _read());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final answers = await Future.wait([for (final p in PlayerStatsOverlay._properties) readMpvProperty(widget.player, p)]);
      if (!mounted) return;
      final values = <String, String>{};
      for (var i = 0; i < answers.length; i++) {
        final a = answers[i];
        if (a != null) values[PlayerStatsOverlay._properties[i]] = a;
      }
      final state = widget.player.state;
      final ahead = double.tryParse(values['demuxer-cache-duration'] ?? '') ?? (state.buffer - state.position).inMilliseconds / 1000;
      _buffer.add(ahead < 0 ? 0 : ahead);
      if (_buffer.length > 60) _buffer.removeAt(0);
      setState(() => _values = values);
    } finally {
      _reading = false;
    }
  }

  static String _number(String? text, {int digits = 0}) {
    final n = double.tryParse(text ?? '');
    return n == null ? '—' : n.toStringAsFixed(digits);
  }

  @override
  Widget build(BuildContext context) {
    final v = _values;
    final state = widget.player.state;
    final width = v['video-params/w'] ?? (state.width == null ? null : '${state.width}');
    final height = v['video-params/h'] ?? (state.height == null ? null : '${state.height}');
    final fps = double.tryParse(v['container-fps'] ?? v['estimated-vf-fps'] ?? '');
    final hwdec = v['hwdec-current'];
    final bitrate = double.tryParse(v['video-bitrate'] ?? '');
    final speed = double.tryParse(v['cache-speed'] ?? '');
    final sampleRate = double.tryParse(v['audio-params/samplerate'] ?? '');
    final ahead = _buffer.isEmpty ? 0.0 : _buffer.last;
    final rows = <(String, String, Color?)>[
      (
        '视频',
        [
          if (v['video-format'] != null) v['video-format']!.toUpperCase(),
          if (width != null && height != null) '$width×$height',
          if (fps != null) '${fps.toStringAsFixed(fps == fps.roundToDouble() ? 0 : 3)} fps',
        ].join(' · '),
        null,
      ),
      if (hwdec != null) ('解码', hwdec == 'no' ? '软解' : '$hwdec 硬解', hwdec == 'no' ? null : const Color(0xFF84CFAE)),
      if (v['current-vo'] != null)
        (
          '输出',
          [
            v['current-vo']!,
            if (v['osd-width'] != null && v['osd-height'] != null) '${v['osd-width']}×${v['osd-height']}',
            if (v['display-fps'] != null) '${_number(v['display-fps'])} Hz',
          ].join(' · '),
          null,
        ),
      if (v['frame-drop-count'] != null) ('掉帧', '${v['frame-drop-count']} · 解码丢 ${v['decoder-frame-drop-count'] ?? '0'}', v['frame-drop-count'] == '0' ? null : const Color(0xFFF0C670)),
      if (v['audio-codec-name'] != null)
        (
          '音频',
          [
            v['audio-codec-name']!.toUpperCase(),
            if (sampleRate != null) '${(sampleRate / 1000).toStringAsFixed(sampleRate % 1000 == 0 ? 0 : 1)} kHz',
            if (v['audio-params/channel-count'] != null) '${v['audio-params/channel-count']} 声道',
          ].join(' · '),
          null,
        ),
      if (v['avsync'] != null) ('音画', '${(double.tryParse(v['avsync']!) ?? 0) >= 0 ? '+' : ''}${_number(v['avsync'], digits: 3)} s', null),
      if (bitrate != null) ('码率', '${(bitrate / 1000000).toStringAsFixed(1)} Mbps', null),
      ('倍速', '${state.rate}×', null),
    ];
    const label = TextStyle(color: Color(0xFFAAA6D2), fontSize: 12, height: 1.6);
    const value = TextStyle(color: Color(0xFFECE9FF), fontSize: 12, height: 1.6, fontFeatures: [FontFeature.tabularFigures()]);
    return Container(
      key: const Key('player-stats'),
      width: 320,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xD10D0C20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x80726EAB)),
      ),
      child: DefaultTextStyle(
        style: value,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Expanded(child: Text('播放统计', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFFECE9FF)))),
                Text('按 i 开关', style: label),
              ],
            ),
            const SizedBox(height: 6),
            for (final (name, text, color) in rows)
              if (text.isNotEmpty)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 44, child: Text(name, style: label)),
                    Expanded(child: Text(text, style: color == null ? null : value.copyWith(color: color))),
                  ],
                ),
            if (v.isEmpty) const Text('这个播放器不提供解码和输出的统计', style: label),
            const SizedBox(height: 6),
            Row(
              children: [
                const SizedBox(width: 44, child: Text('缓冲', style: label)),
                Expanded(child: Text('${ahead.toStringAsFixed(1)} s${speed == null ? '' : ' · ${(speed / 1048576).toStringAsFixed(1)} MB/s'}', key: const Key('player-stats-buffer'))),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(height: 32, width: double.infinity, child: CustomPaint(painter: _Sparkline(List.of(_buffer)))),
          ],
        ),
      ),
    );
  }
}

/// The seconds buffered over the last minute.
class _Sparkline extends CustomPainter {
  _Sparkline(this.samples);

  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()
      ..color = const Color(0x80726EAB)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), base);
    if (samples.length < 2) return;
    final top = samples.fold<double>(10, (m, s) => s > m ? s : m);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = size.width * i / 59;
      final y = (size.height - 2) * (1 - samples[i] / top) + 1;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF84CFAE)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_Sparkline old) => true;
}

/// Where the video on the screen comes from, step by step: the subscription, the site, the line, how the address was
/// found, the address itself and how long each step took.
@immutable
class PlayChain {
  const PlayChain({
    required this.subscription,
    required this.siteName,
    required this.siteKey,
    required this.runtime,
    required this.title,
    required this.vodId,
    required this.lineName,
    required this.lineCount,
    required this.episodeName,
    required this.episodeId,
    required this.played,
    required this.onRelay,
    required this.parser,
    required this.resolveMs,
    required this.firstFrameMs,
    required this.failed,
  });

  final String subscription;
  final String siteName;
  final String siteKey;
  final String runtime;
  final String title;
  final String vodId;
  final String lineName;
  final int lineCount;
  final String episodeName;
  final String episodeId;

  /// The engine's answer for this episode; null while it is being asked.
  final PlayInfo? played;

  /// The player gave up fetching from the source and plays through the engine.
  final bool onRelay;

  /// How the address was found, in words (直链, 经站点解析 …).
  final String parser;
  final int? resolveMs;
  final int? firstFrameMs;

  /// The lines that failed for this episode before the one playing, each with why.
  final List<String> failed;

  /// The address the player was given.
  String get url => played == null ? '' : (onRelay && played!.relay.isNotEmpty ? played!.relay : played!.url);

  /// Everything as text, for an issue.
  String toText() {
    final p = played;
    return [
      '片名：$title',
      '订阅：$subscription',
      '站点：$siteName（$siteKey${runtime.isEmpty ? '' : '，$runtime'}）',
      'vod_id：$vodId',
      '线路：$lineName（共 $lineCount 条）',
      '选集：$episodeName',
      '选集地址：$episodeId',
      for (final f in failed) '失败的线路：$f',
      '解析：$parser${resolveMs == null ? '' : ' · $resolveMs ms'}',
      if (p != null) '播放地址：$url',
      if (p != null && p.headers.isNotEmpty) '请求头：${p.headers.entries.map((e) => '${e.key}: ${e.value}').join('; ')}',
      if (p != null && p.cache.isNotEmpty) '引擎缓存：${p.cache}',
      if (firstFrameMs != null) '首帧：$firstFrameMs ms',
    ].join('\n');
  }
}

/// 片源从哪来 (developer mode): the [PlayChain] as a list of steps, and a button that copies it with addresses of
/// subscriptions and keys taken out.
class PlayerChainPanel extends StatelessWidget {
  const PlayerChainPanel({super.key, required this.chain});

  final PlayChain chain;

  static const _mono = TextStyle(fontFamilyFallback: ['Cascadia Mono', 'Consolas', 'Menlo', 'monospace'], fontSize: 12, height: 1.5);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = chain.played;
    const ok = Color(0xFF84CFAE);
    final steps = <_Step>[
      _Step(color: ok, title: '订阅', body: [SelectableText(chain.subscription.isEmpty ? '（没有订阅：网盘或离线）' : chain.subscription, minLines: 1, maxLines: 2, style: _mono)]),
      _Step(
        color: ok,
        title: '站点 · ${chain.siteName}',
        body: [Text('${chain.siteKey}${chain.runtime.isEmpty ? '' : ' · ${chain.runtime}'} · vod_id ${chain.vodId}', style: _mono)],
      ),
      for (final f in chain.failed) _Step(color: scheme.error, title: '线路 · 打不开', trailing: '已跳过', body: [Text(f, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.5))]),
      _Step(
        color: ok,
        title: '线路 · ${chain.lineName.isEmpty ? '未命名' : chain.lineName}',
        trailing: '共 ${chain.lineCount} 条',
        body: [Text(chain.episodeName, style: const TextStyle(fontSize: 12, height: 1.5)), SelectableText(chain.episodeId, minLines: 1, maxLines: 3, style: _mono.copyWith(color: scheme.onSurfaceVariant))],
      ),
      _Step(
        color: p == null ? scheme.outline : ok,
        title: '解析 · ${p == null ? '正在解析…' : chain.parser}',
        trailing: chain.resolveMs == null ? null : '${chain.resolveMs} ms',
        body: const [],
      ),
      if (p != null)
        _Step(
          color: ok,
          title: '播放地址${chain.onRelay ? ' · 经引擎' : (p.relay.isNotEmpty ? ' · 直连片源' : '')}',
          body: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(chain.url, key: const Key('chain-url'), style: _mono),
                  for (final h in p.headers.entries) Text('${h.key}: ${h.value}', style: _mono.copyWith(color: scheme.onSurfaceVariant)),
                  if (p.cache.isNotEmpty) Text('引擎缓存：${p.cache}', style: _mono.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      _Step(
        color: chain.firstFrameMs == null ? scheme.outline : scheme.primary,
        title: chain.firstFrameMs == null ? '首帧 · 还没有画面' : '首帧',
        trailing: chain.firstFrameMs == null ? null : '${chain.firstFrameMs} ms',
        body: const [],
        last: true,
      ),
    ];
    return ListView(
      key: const Key('player-chain'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      children: [
        Text('片源从哪来', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        ...steps,
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('chain-copy'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: Diagnostics.instance.redact(chain.toText())));
            if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('已复制诊断信息'), duration: Duration(seconds: 2)));
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('复制诊断信息'),
        ),
        const SizedBox(height: 8),
        Text('复制的内容会去掉订阅地址和密钥，可以直接贴到 issue。', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.color, required this.title, required this.body, this.trailing, this.last = false});

  final Color color;
  final String title;
  final String? trailing;
  final List<Widget> body;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(width: 10, height: 10, margin: const EdgeInsets.only(top: 6), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                if (!last) Expanded(child: Container(width: 2, color: scheme.outlineVariant)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(title, style: const TextStyle(fontSize: 14, height: 1.6))),
                      if (trailing != null) Text(trailing!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
                    ],
                  ),
                  ...body,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
