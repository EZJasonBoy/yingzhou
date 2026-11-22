import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../ui/yz_tokens.dart';
import 'player_dev.dart';

/// How playback is going, judged by how much is buffered ahead: the first thing to look at when it stutters.
enum PlayHealth {
  /// The player has stopped to fetch more.
  waiting,

  /// Ten seconds or more ahead.
  smooth,

  /// A few seconds ahead.
  enough,

  /// Next to nothing ahead: it may stop any moment.
  thin;

  static PlayHealth of({required double ahead, required bool buffering}) {
    if (buffering) return PlayHealth.waiting;
    if (ahead >= 10) return PlayHealth.smooth;
    if (ahead >= 3) return PlayHealth.enough;
    return PlayHealth.thin;
  }

  String get label => switch (this) {
    PlayHealth.waiting => '正在缓冲',
    PlayHealth.smooth => '很顺',
    PlayHealth.enough => '够用',
    PlayHealth.thin => '快见底了，可能会卡',
  };
}

/// 播放信息, in every mode: how the picture is doing and where it comes from, in plain words. Simple and standard
/// mode get no addresses and no milliseconds here; the developer mode's statistics and 链路 are one button away
/// ([onStats], [onChain]).
///
/// The numbers are read from the player once a second (libmpv's own account where there is one).
class PlayInfoPanel extends StatefulWidget {
  const PlayInfoPanel({
    super.key,
    required this.player,
    required this.source,
    required this.line,
    required this.lineCount,
    required this.how,
    this.switched = const [],
    this.showTitle = true,
    this.onLines,
    this.onStats,
    this.statsOn = false,
    this.onChain,
  });

  final Player player;

  /// The site the video comes from, by its name.
  final String source;

  /// The line playing, as the screen names it, and how many lines the title has.
  final String line;
  final int lineCount;

  /// How the address was found, in words (直链, 经站点解析 …).
  final String how;

  /// The lines given up on for this episode, each with why.
  final List<String> switched;

  /// False where the panel sits under a title of its own (upright on a phone).
  final bool showTitle;

  /// Opens the lines to choose another; null when there is only one.
  final VoidCallback? onLines;

  /// Developer mode: the statistics over the picture, and 链路.
  final VoidCallback? onStats;
  final bool statsOn;
  final VoidCallback? onChain;

  /// 1080p, 4K …: by the width, so a film cropped to 1920×800 still counts as 1080p.
  static String quality(int width, int height) {
    if (width >= 3840 || height >= 2160) return '4K';
    if (width >= 2560 || height >= 1440) return '2K';
    if (width >= 1920 || height >= 1080) return '1080p';
    if (width >= 1280 || height >= 720) return '720p';
    return '${height}p';
  }

  /// How many dropped frames it takes before 播放信息 mentions them.
  static const droppedWorthSaying = 30;

  /// 3.2 MB/s, 640 KB/s.
  static String speed(double bytesPerSecond) =>
      bytesPerSecond >= 1048576 ? '${(bytesPerSecond / 1048576).toStringAsFixed(1)} MB/s' : '${(bytesPerSecond / 1024).round()} KB/s';

  @override
  State<PlayInfoPanel> createState() => _PlayInfoPanelState();
}

class _PlayInfoPanelState extends State<PlayInfoPanel> {
  static const _properties = ['video-params/w', 'video-params/h', 'container-fps', 'estimated-vf-fps', 'hwdec-current', 'demuxer-cache-duration', 'cache-speed', 'frame-drop-count'];

  Timer? _timer;
  Map<String, String> _values = const {};
  bool _reading = false;

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
      final values = await readMpvProperties(widget.player, _properties);
      if (mounted) setState(() => _values = values);
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = YzTokens.of(context);
    final v = _values;
    final state = widget.player.state;

    final ahead = math.max(0.0, double.tryParse(v['demuxer-cache-duration'] ?? '') ?? (state.buffer - state.position).inMilliseconds / 1000);
    final health = PlayHealth.of(ahead: ahead, buffering: state.buffering);
    final (healthIcon, healthColor) = switch (health) {
      PlayHealth.waiting => (Icons.hourglass_top_rounded, tokens.warning),
      PlayHealth.smooth => (Icons.check_circle_rounded, tokens.success),
      PlayHealth.enough => (Icons.check_circle_outline_rounded, scheme.onSurface),
      PlayHealth.thin => (Icons.warning_amber_rounded, tokens.warning),
    };

    final width = int.tryParse(v['video-params/w'] ?? '') ?? state.width;
    final height = int.tryParse(v['video-params/h'] ?? '') ?? state.height;
    final fps = double.tryParse(v['container-fps'] ?? v['estimated-vf-fps'] ?? '');
    final picture = [
      if (width != null && height != null && width > 0 && height > 0) '${PlayInfoPanel.quality(width, height)}（$width×$height）',
      if (fps != null && fps > 0) '${fps.round()} 帧',
    ].join(' · ');
    final bytes = double.tryParse(v['cache-speed'] ?? '');
    final hwdec = v['hwdec-current'];
    final dropped = int.tryParse(v['frame-drop-count'] ?? '') ?? 0;

    final rows = <(String, String, Color?)>[
      ('画面', picture.isEmpty ? '还没有画面' : picture, null),
      // With enough buffered the player stops fetching for a while: no speed is not a slow line then.
      if (bytes != null) ('网速', bytes > 0 ? PlayInfoPanel.speed(bytes) : (ahead >= 10 ? '缓冲够了，暂时没在下载' : '没有在下载'), null),
      if (hwdec != null) ('解码', hwdec == 'no' ? '软件解码（处理器）' : '硬件解码（显卡）', null),
      // A frame or two are lost when a video starts; it is worth a line once it adds up to what the eye notices.
      if (dropped >= PlayInfoPanel.droppedWorthSaying) ('掉帧', '丢了 $dropped 帧，画面可能不流畅', tokens.warning),
      ('来自', widget.source, null),
      ('线路', [widget.lineCount > 1 ? '${widget.line}（共 ${widget.lineCount} 条）' : widget.line, widget.how].where((s) => s.isNotEmpty).join(' · '), null),
    ];
    final label = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13, height: 1.7);
    const value = TextStyle(fontSize: 14, height: 1.6, fontFeatures: [FontFeature.tabularFigures()]);

    return ListView(
      key: const Key('play-info'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
      children: [
        if (widget.showTitle) ...[
          Text('播放信息', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(color: scheme.surface, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Icon(healthIcon, color: healthColor, size: 26),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(health.label, key: const Key('play-info-health'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: healthColor)),
                    Text('已缓冲 ${ahead.round()} 秒', key: const Key('play-info-buffer'), style: label),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final (name, text, color) in rows)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 48, child: Text(name, style: label)),
              Expanded(child: Text(text, style: color == null ? value : value.copyWith(color: color))),
            ],
          ),
        if (widget.switched.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('这一集换过的线路', style: label),
          for (final s in widget.switched)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 3, right: 8), child: Icon(Icons.swap_horiz_rounded, size: 16, color: tokens.warning)),
                  Expanded(child: Text(s, style: const TextStyle(fontSize: 13, height: 1.6))),
                ],
              ),
            ),
        ],
        const SizedBox(height: 14),
        Text(
          widget.lineCount > 1 ? '总是卡的时候先看缓冲：一直很少，就换一条线路；每条线路都这样，多半是这个站点慢或者网络慢。' : '总是卡的时候先看缓冲：一直很少，多半是这个站点慢或者网络慢。',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (widget.onLines != null)
              FilledButton.tonalIcon(key: const Key('play-info-lines'), onPressed: widget.onLines, icon: const Icon(Icons.swap_horiz_rounded, size: 18), label: const Text('换线路')),
            if (widget.onStats != null)
              OutlinedButton.icon(
                key: const Key('play-info-stats'),
                onPressed: widget.onStats,
                icon: const Icon(Icons.query_stats_rounded, size: 18),
                label: Text(widget.statsOn ? '收起完整统计' : '完整统计'),
              ),
            if (widget.onChain != null)
              OutlinedButton.icon(key: const Key('play-info-chain'), onPressed: widget.onChain, icon: const Icon(Icons.account_tree_outlined, size: 18), label: const Text('片源从哪来')),
          ],
        ),
      ],
    );
  }
}
