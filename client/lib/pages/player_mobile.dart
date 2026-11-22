import 'dart:async';

import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../engine/episode_names.dart';
import '../engine/vod_models.dart';
import '../mobile/playback_host.dart';
import '../ui/episode_buttons.dart';
import 'touch_gestures.dart';

/// The phone and tablet side of a player page: full screen and the turn to landscape, the lock, the screen kept on
/// while playing, picture-in-picture when the user leaves the app, and stopping when the app goes to the background
/// some other way. Desktop and TV pages never create one.
///
/// Orientation, as in phone video apps: on a phone [rotateToFullScreen] makes landscape the full-screen picture —
/// turning the phone sideways goes full screen, the full-screen button turns the screen to landscape and the way out
/// turns it back to portrait (which then stays until the page closes, so a phone held sideways does not throw the
/// user straight back in). On a tablet, and on the live tab, full screen only hides the system bars (turning a
/// portrait tablet to landscape for a landscape video); leaving it gives the rotation back.
class MobilePlayback with WidgetsBindingObserver {
  MobilePlayback({required this.onChanged, this.onBackground, this.onForeground, this.rotateToFullScreen = false, PlaybackHost? host}) : _hostOverride = host;

  /// Back from the background that [onBackground] reacted to (live: tune in again).
  final VoidCallback? onForeground;
  bool _wentBackground = false;

  /// Something here changed that the page shows (full screen, lock, picture-in-picture).
  final VoidCallback onChanged;

  /// The app went to the background without picture-in-picture: the page pauses (or stops a live channel).
  final VoidCallback? onBackground;

  /// A phone's video page: landscape is full screen (see the class). The page sets it once it knows its size.
  bool rotateToFullScreen;
  final PlaybackHost? _hostOverride;

  PlaybackHost get host => _hostOverride ?? PlaybackHost.instance;

  Player? _player;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _started = false;
  bool _disposed = false;
  bool _active = true;
  bool _brightnessTouched = false;

  /// The system bars are hidden for the picture.
  bool fullScreen = false;

  /// The screen is locked against touches (the lock button).
  bool locked = false;

  /// The device can show picture-in-picture (known once a player is attached).
  bool pipSupported = false;

  bool get inPip => host.inPip.value;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    host.inPip.addListener(_pipChanged);
  }

  /// The player whose playing keeps the screen on and arms picture-in-picture (the live page makes its own late).
  void attach(Player player) {
    if (identical(_player, player)) return;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player = player;
    _subs
      ..add(player.stream.playing.listen((_) => _sync()))
      ..add(player.stream.width.listen((_) => _sync()))
      ..add(player.stream.height.listen((_) => _sync()));
    _sync();
  }

  /// The page is (not) the one on screen: the live tab hidden behind another tab, say.
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    if (!active) {
      // The rest of the app: bars, every orientation and the system's brightness back.
      final wasFull = fullScreen;
      fullScreen = false;
      locked = false;
      host.restore();
      if (_brightnessTouched) host.setBrightness(null);
      if (wasFull) onChanged();
    }
    _sync();
  }

  bool get active => _active;

  /// The touch layer changed this window's brightness: it goes back to the system's when the page closes.
  void brightnessTouched() => _brightnessTouched = true;

  bool get _portraitVideo {
    final s = _player?.state;
    final w = s?.width ?? 0;
    final h = s?.height ?? 0;
    return w > 0 && h > w;
  }

  void _sync() {
    if (_disposed) return;
    final s = _player?.state;
    final playing = _active && (s?.playing ?? false);
    host.keepScreenOn(playing);
    host
        .setPip(
          this,
          enabled: _active && _player != null && (playing || inPip),
          width: s?.width ?? 0,
          height: s?.height ?? 0,
          playing: s?.playing ?? false,
          onAction: (_) => _player?.playOrPause(),
        )
        .then((supported) {
          if (!_disposed && supported && !pipSupported) {
            pipSupported = true;
            onChanged();
          }
        });
  }

  void setFullScreen(bool on) {
    if (fullScreen == on) return;
    fullScreen = on;
    if (on) {
      host.enterFullScreen(rotate: true, portraitVideo: _portraitVideo);
    } else {
      host.exitFullScreen(lockPortrait: rotateToFullScreen);
    }
    onChanged();
  }

  /// The window turned. On a phone's video page landscape is full screen; turning back to portrait leaves it.
  void orientationChanged(Orientation orientation) {
    if (!rotateToFullScreen || _disposed) return;
    final landscape = orientation == Orientation.landscape;
    if (landscape == fullScreen) return;
    fullScreen = landscape;
    // Already turned by the user: only the bars change, the rotation stays free.
    landscape ? host.enterFullScreen(rotate: false) : SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    onChanged();
  }

  void toggleLock() {
    locked = !locked;
    onChanged();
  }

  void _pipChanged() {
    if (_disposed) return;
    onChanged();
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // In picture-in-picture the app is paused but still on screen; when that window is closed the app is hidden.
    if ((state == AppLifecycleState.hidden || state == AppLifecycleState.paused) && _active && !inPip && !_wentBackground) {
      _wentBackground = true;
      onBackground?.call();
    } else if (state == AppLifecycleState.resumed && _wentBackground) {
      _wentBackground = false;
      if (_active) onForeground?.call();
    }
  }

  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      host.inPip.removeListener(_pipChanged);
    }
    host.setPip(this, enabled: false);
    if (_brightnessTouched) host.setBrightness(null);
    host.restore();
  }
}

/// The controls over the picture on a touch screen. [compact]: the small picture above the episodes on a phone held
/// upright — back, title, play, the bar and full screen; otherwise the full set, with [actions] (speed, danmaku,
/// subtitles, episodes) at the end of the bottom row. Buttons are 48 dp.
class TouchPlayerBars extends StatelessWidget {
  const TouchPlayerBars({
    super.key,
    required this.title,
    required this.subtitle,
    required this.player,
    required this.seekBar,
    required this.compact,
    required this.fullScreen,
    required this.onBack,
    required this.onFullScreen,
    this.onPrevious,
    this.onNext,
    this.onPip,
    this.actions = const [],
  });

  final String title;
  final String subtitle;
  final Player player;
  final Widget seekBar;
  final bool compact;
  final bool fullScreen;
  final VoidCallback onBack;
  final VoidCallback onFullScreen;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onPip;
  final List<Widget> actions;

  static const _white = Colors.white;

  @override
  Widget build(BuildContext context) {
    final play = StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, snap) => IconButton(
        key: const Key('touch-play'),
        tooltip: snap.data == true ? '暂停' : '播放',
        iconSize: compact ? 28 : 34,
        onPressed: player.playOrPause,
        icon: Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded, color: _white),
      ),
    );
    final full = IconButton(
      key: const Key('touch-fullscreen'),
      tooltip: fullScreen ? '退出全屏' : '全屏',
      onPressed: onFullScreen,
      icon: Icon(fullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: _white),
    );
    final top = Row(
      children: [
        IconButton(tooltip: '返回', onPressed: onBack, icon: const Icon(Icons.arrow_back, color: _white)),
        Expanded(
          child: IgnorePointer(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _white, fontSize: compact ? 15 : 17, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        if (!compact && subtitle.isNotEmpty)
          Flexible(
            child: IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 13)),
              ),
            ),
          ),
        if (onPip != null) IconButton(key: const Key('touch-pip'), tooltip: '小窗播放', onPressed: onPip, icon: const Icon(Icons.picture_in_picture_alt_rounded, color: _white)),
      ],
    );
    if (compact) {
      return SafeArea(
        child: Column(
          children: [
            top,
            const Spacer(),
            Row(
              children: [
                play,
                IgnorePointer(child: TouchTimeLabel(player: player, small: true)),
                Expanded(child: seekBar),
                full,
              ],
            ),
          ],
        ),
      );
    }
    return SafeArea(
      child: Column(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(4, 4, 8, 0), child: top),
          const Spacer(),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: seekBar),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Row(
              children: [
                if (onPrevious != null) IconButton(tooltip: '上一集', onPressed: onPrevious, icon: const Icon(Icons.skip_previous_rounded, color: _white)),
                play,
                if (onNext != null) IconButton(tooltip: '下一集', onPressed: onNext, icon: const Icon(Icons.skip_next_rounded, color: _white)),
                const SizedBox(width: 4),
                IgnorePointer(child: TouchTimeLabel(player: player)),
                // A narrow screen scrolls the rest rather than cutting it off.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      reverse: true,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [...actions, full]),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Position / length, white over the picture.
class TouchTimeLabel extends StatelessWidget {
  const TouchTimeLabel({super.key, required this.player, this.small = false});

  final Player player;
  final bool small;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, snap) => Text(
        '${formatTouchTime(snap.data ?? Duration.zero)} / ${formatTouchTime(player.state.duration)}',
        style: TextStyle(color: Colors.white, fontSize: small ? 12 : 14, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// The lock at the left edge of the picture: while locked it is the only thing a tap brings up.
class PlayerLockButton extends StatelessWidget {
  const PlayerLockButton({super.key, required this.locked, required this.onPressed});

  final bool locked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: IconButton.filled(
            key: const Key('touch-lock'),
            tooltip: locked ? '解锁屏幕' : '锁定屏幕',
            style: IconButton.styleFrom(backgroundColor: Colors.black45, foregroundColor: Colors.white, minimumSize: const Size(48, 48)),
            onPressed: onPressed,
            icon: Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded),
          ),
        ),
      ),
    );
  }
}

/// Under the picture on a phone held upright: the title, the actions ([actions]: speed, danmaku, subtitles, small
/// window), the lines and the episodes as touch-sized buttons. A [panel] (subtitles, danmaku settings) takes the place
/// of all that while it is open.
class PlayerPhoneInfo extends StatefulWidget {
  const PlayerPhoneInfo({
    super.key,
    required this.title,
    required this.caption,
    required this.lines,
    required this.line,
    required this.episode,
    required this.onLine,
    required this.onEpisode,
    this.numberedLines = false,
    this.actions = const [],
    this.panel,
    this.panelTitle = '',
    this.onClosePanel,
  });

  final String title;

  /// The episode, line and how it was parsed.
  final String caption;
  final List<PlayLine> lines;
  final int line;
  final int episode;
  final ValueChanged<int> onLine;
  final ValueChanged<int> onEpisode;

  /// The lines are offered (not in simple mode, where the player changes line by itself).
  /// Simple mode: the lines go by their numbers (线路 1, 线路 2 …), not by what the site calls them.
  final bool numberedLines;
  final List<Widget> actions;
  final Widget? panel;
  final String panelTitle;
  final VoidCallback? onClosePanel;

  /// The episode buttons: at least 48 dp tall, about four to a row on a phone.
  static const episodeExtent = 52.0;

  @override
  State<PlayerPhoneInfo> createState() => _PlayerPhoneInfoState();
}

class _PlayerPhoneInfoState extends State<PlayerPhoneInfo> {
  final _scroll = ScrollController();

  /// On the button of the episode playing, to bring it into view.
  final _currentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Long series: the episode playing is brought into view.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealEpisode());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _revealEpisode() {
    if (!mounted || !_scroll.hasClients) return;
    final box = _currentKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final top = RenderAbstractViewport.maybeOf(box)?.getOffsetToReveal(box, 0).offset;
    if (top == null) return;
    // Only when the episode is out of sight: the title stays in view for the first rows.
    final viewport = _scroll.position.viewportDimension;
    if (top + box.size.height <= viewport) return;
    _scroll.jumpTo((top - viewport / 3).clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final panel = widget.panel;
    if (panel != null) {
      return Material(
        color: scheme.surface,
        child: Column(
          children: [
            ListTile(
              title: Text(widget.panelTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: IconButton(key: const Key('phone-panel-close'), tooltip: '关闭', onPressed: widget.onClosePanel, icon: const Icon(Icons.close_rounded)),
            ),
            const Divider(height: 1),
            Expanded(child: panel),
          ],
        ),
      );
    }
    final lines = widget.lines;
    final episodes = lines.isEmpty ? const <Episode>[] : lines[widget.line].episodes;
    return Material(
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              sliver: SliverList.list(
                children: [
                  Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(widget.caption, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  if (widget.actions.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: widget.actions)),
                  ],
                  if (lines.length > 1) ...[
                    const SizedBox(height: 14),
                    Text('线路', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < lines.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                key: Key('phone-line-$i'),
                                label: Text(lineTitle(lines, i, numbered: widget.numberedLines)),
                                selected: i == widget.line,
                                onSelected: (_) => widget.onLine(i),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text('选集 · ${episodes.length}', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Short names: buttons of about 104 dp that fill the row, about four to a row on a phone.
                    final columns = ((constraints.maxWidth + 8) / 112).ceil().clamp(1, 100);
                    return EpisodeButtons(
                      naming: lines.isEmpty ? EpisodeNaming.empty : EpisodeNaming.of(lines, widget.line, title: widget.title),
                      buttonWidth: (constraints.maxWidth - 8 * (columns - 1)) / columns - 0.01,
                      maxColumns: 2,
                      button: (context, i, label, row) {
                        final current = i == widget.episode;
                        final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(10));
                        final padding = EdgeInsets.symmetric(horizontal: row ? 12 : 6);
                        final alignment = row ? Alignment.centerLeft : null;
                        final button = current
                            ? FilledButton(key: Key('phone-episode-$i'), onPressed: () {}, style: FilledButton.styleFrom(padding: padding, shape: shape, alignment: alignment), child: label)
                            : OutlinedButton(
                                key: Key('phone-episode-$i'),
                                onPressed: () => widget.onEpisode(i),
                                style: OutlinedButton.styleFrom(padding: padding, shape: shape, alignment: alignment, side: BorderSide(color: scheme.outlineVariant)),
                                child: label,
                              );
                        final sized = row ? button : SizedBox(height: PlayerPhoneInfo.episodeExtent, child: button);
                        return current ? KeyedSubtree(key: _currentKey, child: sized) : sized;
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A rounded action under the picture (倍速, 弹幕, 字幕, 小窗).
class PhoneAction extends StatelessWidget {
  const PhoneAction({super.key, required this.icon, required this.label, required this.onPressed, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        selected: selected,
        onSelected: onPressed == null ? null : (_) => onPressed!(),
      ),
    );
  }
}
