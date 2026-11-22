import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../ui/tv/tv_focus.dart';
import '../ui/yz_tokens.dart';
import 'player_dev.dart' show readMpvProperties;
import 'player_info.dart';
import 'seek_bar.dart';

/// What the TV player draws over the picture for the remote control: the info bar, the dial (拨盘) on the left with
/// one entry per thing to change, and the panels that open next to it (docs/design/ux-review.md 2.2, the prototypes
/// TV-Dial-*). These widgets only draw; which keys do what is the player's (player_tv.dart).
///
/// Sizes are the prototypes' (1280 × 720) scaled to the TV's 960 × 540 logical canvas.
abstract final class TvDialLayout {
  /// From the top of the safe area to the first entry of the dial, and to the top of a panel.
  static const top = 36.0;

  /// The dial's width, and where a panel starts from the left of the safe area (just right of the dial).
  static const dialWidth = 315.0;
  static const panelLeft = 330.0;
  static const panelWidth = 357.0;

  static const rowHeight = 52.0;
  static const rowGap = 4.0;

  /// The dial's height: seven entries and the gaps between them. A panel is as tall.
  static double get height => DialEntry.values.length * rowHeight + (DialEntry.values.length - 1) * rowGap;
}

/// The entries of the dial, top to bottom. Always all seven, in this order, so each stays where the hand expects it.
enum DialEntry {
  episodes('选集', Icons.playlist_play_rounded),
  lines('线路', Icons.swap_horiz_rounded),
  speed('倍速', Icons.speed_rounded),
  subtitles('字幕', Icons.subtitles_outlined),
  danmaku('弹幕', Icons.chat_bubble_outline_rounded),
  info('信息', Icons.info_outline_rounded),
  more('更多设置', Icons.tune_rounded);

  const DialEntry(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Whether ← / → change this entry's value right on the dial; 信息 and 更多设置 only have their panel.
  bool get adjustable => this != info && this != more;
}

/// The entry the dial was on when it was last put away, for as long as the app runs: ↑ or ↓ brings the dial back
/// on it, in the next video too, so doing the same thing again takes two presses.
abstract final class TvDialMemory {
  static DialEntry last = DialEntry.episodes;

  @visibleForTesting
  static void reset() => last = DialEntry.episodes;
}

/// A key the remote's hint line names, and what it does.
typedef TvHint = (List<String> keys, String label);

/// The dial: one row per [DialEntry], each with its current value on the right. It takes no focus of its own; the
/// player holds the focus on it as a whole and moves [selected] with the keys.
class TvDial extends StatelessWidget {
  const TvDial({super.key, required this.selected, required this.open, required this.value, this.onTap});

  final DialEntry selected;

  /// The panel of [selected] is open next to the dial: that entry stays lit, the others dim.
  final bool open;

  /// What each entry shows on its right.
  final Widget Function(DialEntry entry) value;

  /// A click or tap on an entry (a mouse on a computer in the TV layout).
  final ValueChanged<DialEntry>? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: TvDialLayout.rowGap,
      children: [
        for (final e in DialEntry.values)
          TvDialRow(
            key: Key('tv-dial-${e.name}'),
            entry: e,
            selected: e == selected,
            open: open,
            value: value(e),
            onTap: onTap == null ? null : () => onTap!(e),
          ),
      ],
    );
  }
}

/// One entry of the [TvDial].
class TvDialRow extends StatelessWidget {
  const TvDialRow({super.key, required this.entry, required this.selected, required this.open, required this.value, this.onTap});

  final DialEntry entry;
  final bool selected;

  /// A panel is open next to the dial (see [TvDial.open]).
  final bool open;
  final Widget value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    // On the dial with the focus; the entry whose panel is open; an entry dimmed beside an open panel.
    final lit = selected && !open;
    final opened = selected && open;
    final fg = opened ? t.accentInk : t.ink;
    final Widget trailing;
    if (opened) {
      trailing = Icon(Icons.chevron_right_rounded, color: t.accentInk, size: 22);
    } else if (lit && entry.adjustable) {
      // ‹ value ›: ← / → change it here.
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 8,
        children: [
          Icon(Icons.chevron_left_rounded, color: t.accent, size: 20),
          Flexible(
            child: DefaultTextStyle.merge(
              style: TextStyle(color: t.ink, fontSize: 18, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: value,
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: t.accent, size: 20),
        ],
      );
    } else {
      trailing = DefaultTextStyle.merge(
        style: TextStyle(color: t.inkMuted, fontSize: 14, fontWeight: FontWeight.w400),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        child: value,
      );
    }
    return Opacity(
      opacity: open && !selected ? 0.45 : 1,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: TvDialLayout.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: lit ? t.surfaceRaised : (opened ? t.accent.withValues(alpha: 0.18) : null),
            borderRadius: BorderRadius.circular(12),
            border: lit ? Border.all(color: t.focus, width: 3, strokeAlign: BorderSide.strokeAlignOutside) : null,
          ),
          child: Row(
            children: [
              Icon(entry.icon, size: 21, color: fg),
              const SizedBox(width: 12),
              Text(entry.label, style: TextStyle(color: fg, fontSize: 18, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              const SizedBox(width: 12),
              Expanded(child: Align(alignment: Alignment.centerRight, child: trailing)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The frame of a panel that opens next to the dial. On a TV the remote's focus goes into it when it opens, and the
/// D-pad stays inside it ([TvFocusLayer]).
class TvDialPanel extends StatelessWidget {
  const TvDialPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    return Material(
      color: t.surface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: TvFocusLayer(child: child),
    );
  }
}

/// The title line of a panel next to the dial, with a note on its right.
class TvPanelHeading extends StatelessWidget {
  const TvPanelHeading(this.title, {super.key, this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title, style: TextStyle(color: t.ink, fontSize: 18, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (note != null) Text(note!, style: TextStyle(color: t.inkMuted, fontSize: 14)),
        ],
      ),
    );
  }
}

/// A choice in a panel: [label], or [child] in its place (an episode, laid out by [EpisodeButtons]).
class TvChip extends StatelessWidget {
  const TvChip({super.key, this.label = '', required this.onTap, this.selected = false, this.icon, this.child});

  final String label;
  final VoidCallback onTap;
  final bool selected;
  final IconData? icon;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return TvFocusable(
      onTap: onTap,
      scale: 1.06,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(color: selected ? scheme.primary : scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: child != null
            ? Align(alignment: Alignment.centerLeft, child: DefaultTextStyle.merge(style: TextStyle(fontSize: 15, color: fg), child: child!))
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, size: 19, color: fg), const SizedBox(width: 8)],
                  Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: fg))),
                ],
              ),
      ),
    );
  }
}

/// The 线路 panel: one row per line, the one playing marked and holding the focus; OK changes to the line in focus
/// (a choice by hand: that line is not switched away from).
class TvLinesPanel extends StatelessWidget {
  const TvLinesPanel({super.key, required this.names, required this.current, required this.onPick, this.quality = '', this.status});

  /// What each line is called on screen.
  final List<String> names;
  final int current;
  final ValueChanged<int> onPick;

  /// The picture of the line playing (1080p …), for its row; empty while unknown.
  final String quality;

  /// What is known of a line that is not playing, on its row: the seam for the line check that measures every line
  /// before playing (docs/design/line-probe.md: "1080p · 3.2 MB/s", "慢", "打不开"). Null, or null for a line, when
  /// nothing is known.
  final String? Function(int line)? status;

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    return ListView(
      key: const Key('tv-lines'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        TvPanelHeading('线路', note: '这一集 · 共 ${names.length} 条'),
        for (var i = 0; i < names.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: TvAutofocus(
              enabled: i == current,
              child: TvFocusable(
                key: Key('tv-panel-line-$i'),
                onTap: () => onPick(i),
                scale: 1.03,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 50),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(color: i == current ? t.surfaceRaised : null, borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    children: [
                      SizedBox(width: 22, child: i == current ? Icon(Icons.check_rounded, size: 20, color: t.success) : null),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          names[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.ink, fontSize: 16, fontWeight: i == current ? FontWeight.w600 : FontWeight.w400),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          i == current ? ['正在播', if (quality.isNotEmpty) quality].join(' · ') : (status?.call(i) ?? ''),
                          key: Key('tv-panel-line-$i-status'),
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: i == current ? t.ink : t.inkMuted, fontSize: 14, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 6),
        Text('自己选的线路放不了时只提示，不会被自动换走。', style: TextStyle(color: t.inkMuted, fontSize: 14, height: 1.5)),
      ],
    );
  }
}

/// The key caps and words of the hint line at the bottom of the screen.
class TvKeyHints extends StatelessWidget {
  const TvKeyHints(this.hints, {super.key});

  final List<TvHint> hints;

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    Widget cap(String k) => Container(
      constraints: const BoxConstraints(minWidth: 28),
      height: 25,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: t.lineStrong, width: 1.2), borderRadius: BorderRadius.circular(6)),
      child: Text(k, style: TextStyle(color: t.ink, fontSize: 13, fontWeight: FontWeight.w600)),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 20,
      children: [
        for (final (keys, label) in hints)
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 6,
            children: [
              ...keys.map(cap),
              Text(label, style: TextStyle(color: t.inkMuted, fontSize: 14)),
            ],
          ),
      ],
    );
  }
}

/// Rebuilds once a minute, on the minute, for whatever shows the time of day.
class TvTimeOfDay extends StatefulWidget {
  const TvTimeOfDay({super.key, required this.builder});

  final Widget Function(BuildContext context, DateTime now) builder;

  /// 21:07.
  static String format(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  State<TvTimeOfDay> createState() => _TvTimeOfDayState();
}

class _TvTimeOfDayState extends State<TvTimeOfDay> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  void _schedule() {
    _timer = Timer(Duration(seconds: 60 - DateTime.now().second), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
}

/// The time of day in a corner, small and dim, while nothing else is over the picture (屏显时间: 一直显示).
class TvCornerClock extends StatelessWidget {
  const TvCornerClock({super.key});

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    return TvTimeOfDay(
      builder: (context, now) => Text(
        TvTimeOfDay.format(now),
        style: TextStyle(color: t.ink.withValues(alpha: 0.55), fontSize: 15, fontWeight: FontWeight.w500, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// 信息's value on the dial: how playback is going, in one word ([PlayHealth]), looked at once a second.
class TvHealthWord extends StatefulWidget {
  const TvHealthWord({super.key, required this.player});

  final Player player;

  /// The word on the dial; 播放信息 itself says the longer sentence.
  static String word(PlayHealth health) => switch (health) {
    PlayHealth.waiting => '正在缓冲',
    PlayHealth.smooth => '很顺',
    PlayHealth.enough => '够用',
    PlayHealth.thin => '快见底了',
  };

  @override
  State<TvHealthWord> createState() => _TvHealthWordState();
}

class _TvHealthWordState extends State<TvHealthWord> {
  Timer? _timer;
  double? _ahead;
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
      final values = await readMpvProperties(widget.player, const ['demuxer-cache-duration']);
      if (mounted) setState(() => _ahead = double.tryParse(values['demuxer-cache-duration'] ?? ''));
    } finally {
      _reading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    final state = widget.player.state;
    // Like 播放信息: libmpv's own account where there is one, else what the player says it has read ahead.
    final ahead = math.max(0.0, _ahead ?? (state.buffer - state.position).inMilliseconds / 1000);
    final health = PlayHealth.of(ahead: ahead, buffering: state.buffering);
    final (icon, color) = switch (health) {
      PlayHealth.smooth => (Icons.check_rounded, t.success),
      PlayHealth.enough => (null, null),
      PlayHealth.waiting || PlayHealth.thin => (Icons.warning_amber_rounded, t.warning),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        if (icon != null) Icon(icon, size: 17, color: color),
        Text(TvHealthWord.word(health), key: const Key('tv-health')),
      ],
    );
  }
}

/// What is over the picture whenever the remote brings something up: the title and what plays (line, picture,
/// subtitles, danmaku), the time of day with how long is left, the progress, and one line of keys. Nothing in it
/// takes the focus. Alone it is the info bar; under the dial it is the frame around it.
class TvOsd extends StatelessWidget {
  const TvOsd({
    super.key,
    required this.player,
    required this.buffered,
    required this.title,
    this.caption,
    required this.clock,
    required this.hints,
    this.progressBar = true,
    this.paused = false,
  });

  final Player player;
  final ValueListenable<List<BufferedRange>> buffered;
  final String title;

  /// Under the title: 线路 2 · 1080p · 中文字幕 · 弹幕开 (the info bar; the dial shows these as its values).
  final String? caption;

  /// Whether the time of day shows (屏显时间 is not 关). How long is left shows either way.
  final bool clock;
  final List<TvHint> hints;
  final bool progressBar;

  /// The pause sign in the middle of the picture.
  final bool paused;

  /// 还剩 12 分钟 · 约 21:19 看完: in real time, so at 1.25× it is sooner; [finish] leaves out the time of day.
  static String? remaining(Duration position, Duration duration, double rate, DateTime now, {bool finish = true}) {
    if (duration <= Duration.zero) return null;
    final left = duration - position;
    if (left.isNegative) return null;
    final ms = left.inMilliseconds / (rate > 0 ? rate : 1);
    final minutes = (ms / 60000).round();
    final head = minutes < 1 ? '还剩不到 1 分钟' : '还剩 $minutes 分钟';
    if (!finish) return head;
    return '$head · 约 ${TvTimeOfDay.format(now.add(Duration(milliseconds: ms.round())))} 看完';
  }

  @override
  Widget build(BuildContext context) {
    final t = YzTokens.of(context);
    final shade = t.scrim.withValues(alpha: 1);
    final muted = TextStyle(color: t.inkMuted, fontSize: 14);
    final clockStyle = TextStyle(
      color: t.ink,
      fontSize: 30,
      height: 1.1,
      fontWeight: FontWeight.w500,
      fontFamily: YzType.families[YzFamily.latin]!.first,
      fontFamilyFallback: YzType.families[YzFamily.latin],
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 135,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [shade.withValues(alpha: 0.82), shade.withValues(alpha: 0)]),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 165,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [shade.withValues(alpha: 0.94), shade.withValues(alpha: 0)]),
              ),
            ),
          ),
        ),
        if (paused)
          Center(
            child: Container(
              key: const Key('tv-paused'),
              width: 84,
              height: 84,
              decoration: BoxDecoration(color: t.surfaceSunk.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(21)),
              child: Icon(Icons.pause_rounded, size: 46, color: t.ink, semanticLabel: '已暂停'),
            ),
          ),
        SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 2,
                      children: [
                        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: t.ink, fontSize: 20, fontWeight: FontWeight.w600)),
                        if (caption != null && caption!.isNotEmpty) Text(caption!, key: const Key('tv-caption'), maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  TvTimeOfDay(
                    builder: (context, now) => StreamBuilder<Duration>(
                      stream: player.stream.position,
                      initialData: player.state.position,
                      builder: (context, snap) {
                        final left = remaining(snap.data ?? Duration.zero, player.state.duration, player.state.rate, now, finish: clock);
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          spacing: 14,
                          children: [
                            if (left != null) Text(left, key: const Key('tv-remaining'), style: muted),
                            if (clock) Text(TvTimeOfDay.format(now), key: const Key('tv-clock'), style: clockStyle),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              const Spacer(),
              if (progressBar)
                ExcludeFocus(
                  child: IgnorePointer(
                    child: ValueListenableBuilder<List<BufferedRange>>(
                      valueListenable: buffered,
                      builder: (context, ranges, _) => StreamBuilder<Duration>(
                        stream: player.stream.position,
                        initialData: player.state.position,
                        builder: (context, snap) => SeekBar(
                          key: const Key('seek-bar'),
                          position: snap.data ?? Duration.zero,
                          duration: player.state.duration,
                          buffered: ranges,
                          onSeek: (_) {},
                          height: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  StreamBuilder<Duration>(
                    stream: player.stream.position,
                    initialData: player.state.position,
                    builder: (context, snap) => Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: SeekBar.format(snap.data ?? Duration.zero)),
                          TextSpan(text: ' / ${SeekBar.format(player.state.duration)}', style: TextStyle(color: t.inkMuted)),
                        ],
                      ),
                      key: const Key('tv-time'),
                      style: TextStyle(color: t.ink, fontSize: 16, fontWeight: FontWeight.w500, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ),
                  const SizedBox(width: 20),
                  // Smaller rather than cut off where the words are long.
                  Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: TvKeyHints(hints))),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
