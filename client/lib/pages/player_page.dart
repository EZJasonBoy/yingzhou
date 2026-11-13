import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app_state.dart';
import '../engine/engine_client.dart';
import '../engine/library_models.dart';
import '../engine/vod_models.dart';
import 'browse_page.dart' show errorText;

/// Full-window player: resolves the episode through the engine, plays it with media_kit (libmpv on desktop),
/// and draws its own controls so they work the same with mouse, touch and keyboard.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.detail, required this.line, required this.episode, this.startPosition});

  final VodDetail detail;
  final int line;
  final int episode;

  /// Resume point for the first episode played (from history).
  final Duration? startPosition;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final Player _player = Player();
  late final VideoController _video = VideoController(_player);
  late final EngineClient _client;
  final _focus = FocusNode();
  final _subs = <StreamSubscription<dynamic>>[];

  late int _line = widget.line;
  late int _episode = widget.episode;
  late Duration? _pendingSeek = widget.startPosition;
  String? _status;
  String? _error;
  String _parsedBy = '';
  bool _controlsVisible = true;
  bool _panelOpen = false;
  bool _opening = false;
  Timer? _hideTimer;
  Timer? _saveTimer;
  int _requestSeq = 0;

  PlayLine get _currentLine => widget.detail.lines[_line];
  Episode get _currentEpisode => _currentLine.episodes[_episode];
  bool get _hasNext => _episode + 1 < _currentLine.episodes.length;

  @override
  void initState() {
    super.initState();
    _client = AppScope.read(context).client;
    _subs.add(_player.stream.completed.listen((done) {
      if (done && _hasNext) _openEpisode(_line, _episode + 1);
    }));
    // Resume once the media knows its length (seeking earlier is ignored by some backends).
    _subs.add(_player.stream.duration.listen((d) {
      final seek = _pendingSeek;
      if (seek != null && d > Duration.zero && seek < d - const Duration(seconds: 5)) {
        _pendingSeek = null;
        _player.seek(seek);
      }
    }));
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());
    _subs.add(_player.stream.error.listen((e) {
      // Stopping/replacing the media emits errors (e.g. "empty src" on web); only report real playback errors.
      if (mounted && !_opening) setState(() => _error = '播放出错：$e');
    }));
    _subs.add(_player.stream.playing.listen((playing) {
      if (playing && _error != null && mounted) setState(() => _error = null);
    }));
    _openEpisode(_line, _episode);
    _pokeControls();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _saveProgress();
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Records where we are, so any client of this engine can resume. Failures are ignored (best effort).
  void _saveProgress({bool episodeStart = false}) {
    final d = widget.detail;
    final position = episodeStart ? Duration.zero : _player.state.position;
    final duration = episodeStart ? Duration.zero : _player.state.duration;
    if (!episodeStart && duration <= Duration.zero) return;
    _client
        .putHistory(HistoryEntry(
          site: d.site,
          vodId: d.id,
          name: d.name,
          pic: d.pic,
          line: _currentLine.name,
          episodeId: _currentEpisode.id,
          episodeName: _currentEpisode.name,
          episodeIndex: _episode,
          positionMs: position.inMilliseconds,
          durationMs: duration.inMilliseconds,
        ))
        .catchError((Object _) {});
  }

  Future<void> _openEpisode(int line, int episode) async {
    final seq = ++_requestSeq;
    final client = _client;
    final isFirst = seq == 1;
    if (!isFirst) _saveProgress();
    setState(() {
      _line = line;
      _episode = episode;
      _status = '正在解析播放地址…';
      _error = null;
      _parsedBy = '';
    });
    if (!isFirst) _pendingSeek = null;
    if (_pendingSeek == null) _saveProgress(episodeStart: true);
    _opening = true;
    await _player.stop();
    try {
      final info = await client.resolvePlay(widget.detail.site, _currentLine.name, _currentEpisode.id);
      if (!mounted || seq != _requestSeq) return;
      if (!info.isDirect) {
        setState(() {
          _status = null;
          _error = '这条线路需要网页嗅探，但引擎没有可用的浏览器内核（桌面需安装 Edge 或 Chrome），请换一条线路试试';
        });
        return;
      }
      setState(() {
        _status = '正在缓冲…';
        _parsedBy = info.parsedBy;
      });
      await _player.open(Media(info.url, httpHeaders: info.headers));
    } catch (e) {
      if (mounted && seq == _requestSeq) {
        setState(() {
          _status = null;
          _error = '解析失败：${errorText(e)}';
        });
      }
    } finally {
      if (seq == _requestSeq) _opening = false;
    }
  }

  /// The engine names parsers it made up from a site's `playUrl` "sniff" / "json".
  static String _parserLabel(String parsedBy) => switch (parsedBy) {
        'sniff' => '网页嗅探',
        'json' => '经站点解析',
        _ => '经 $parsedBy 解析',
      };

  void _pokeControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _player.state.playing && !_panelOpen) setState(() => _controlsVisible = false);
    });
  }

  void _seekBy(Duration delta) {
    final target = _player.state.position + delta;
    _player.seek(target < Duration.zero ? Duration.zero : target);
    _pokeControls();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      _player.playOrPause();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(const Duration(seconds: 10));
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(const Duration(seconds: -10));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _player.setVolume((_player.state.volume + 10).clamp(0, 100));
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _player.setVolume((_player.state.volume - 10).clamp(0, 100));
    } else if (key == LogicalKeyboardKey.keyN && _hasNext) {
      _openEpisode(_line, _episode + 1);
    } else if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      if (_panelOpen) {
        setState(() => _panelOpen = false);
      } else {
        Navigator.of(context).maybePop();
      }
    } else {
      return KeyEventResult.ignored;
    }
    _pokeControls();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _pokeControls(),
          cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _controlsVisible ? setState(() => _controlsVisible = false) : _pokeControls(),
            onDoubleTap: _player.playOrPause,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(controller: _video, controls: NoVideoControls, fill: Colors.black),
                _buildStatus(),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(ignoring: !_controlsVisible, child: _buildControls(context)),
                ),
                if (_panelOpen) _buildEpisodePanel(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatus() {
    return StreamBuilder<bool>(
      stream: _player.stream.buffering,
      initialData: false,
      builder: (context, snap) {
        final playingStarted = _player.state.duration > Duration.zero;
        final text = _error ?? (snap.data == true || !playingStarted ? _status : null);
        if (text == null) return const SizedBox.shrink();
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error == null) const CircularProgressIndicator(color: Colors.white70),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                FilledButton.tonal(onPressed: () => _openEpisode(_line, _episode), child: const Text('重试')),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls(BuildContext context) {
    final title = '${widget.detail.name} · ${_currentEpisode.name}';
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB0000000), Color(0x00000000), Color(0x00000000), Color(0xC0000000)],
          stops: [0, 0.22, 0.7, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back, color: Colors.white)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                  Text(
                    _parsedBy.isEmpty ? _currentLine.name : '${_currentLine.name} · ${_parserLabel(_parsedBy)}',
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ],
              ),
            ),
            const Spacer(),
            _ProgressBar(player: _player, onSeek: (_) => _pokeControls()),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    initialData: _player.state.playing,
                    builder: (context, snap) => IconButton(
                      iconSize: 32,
                      onPressed: _player.playOrPause,
                      icon: Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                    ),
                  ),
                  if (_hasNext)
                    IconButton(
                      tooltip: '下一集 (N)',
                      onPressed: () => _openEpisode(_line, _episode + 1),
                      icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                    ),
                  const SizedBox(width: 8),
                  _TimeLabel(player: _player),
                  const Spacer(),
                  _SpeedButton(player: _player),
                  TextButton.icon(
                    onPressed: () => setState(() => _panelOpen = true),
                    icon: const Icon(Icons.playlist_play_rounded, color: Colors.white),
                    label: const Text('选集', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEpisodePanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: GestureDetector(
        onTap: () => setState(() => _panelOpen = false),
        child: ColoredBox(
          color: Colors.black38,
          child: Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 360,
                color: scheme.surfaceContainer.withValues(alpha: 0.96),
                child: SafeArea(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text('线路', style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (var i = 0; i < widget.detail.lines.length; i++)
                          ChoiceChip(
                            label: Text(widget.detail.lines[i].name),
                            selected: i == _line,
                            onSelected: (_) {
                              final ep = _episode.clamp(0, widget.detail.lines[i].episodes.length - 1);
                              setState(() => _panelOpen = false);
                              _openEpisode(i, ep);
                            },
                          ),
                      ]),
                      const SizedBox(height: 18),
                      Text('选集', style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (var i = 0; i < _currentLine.episodes.length; i++)
                          SizedBox(
                            width: 98,
                            child: i == _episode
                                ? FilledButton(onPressed: null, child: Text(_currentLine.episodes[i].name, maxLines: 1, overflow: TextOverflow.ellipsis))
                                : OutlinedButton(
                                    onPressed: () {
                                      setState(() => _panelOpen = false);
                                      _openEpisode(_line, i);
                                    },
                                    child: Text(_currentLine.episodes[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
                          ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.player, required this.onSeek});

  final Player player;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, snap) {
        final duration = player.state.duration;
        final max = duration.inMilliseconds.toDouble();
        final value = (snap.data ?? Duration.zero).inMilliseconds.toDouble().clamp(0, max <= 0 ? 0 : max).toDouble();
        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            activeTrackColor: Colors.white,
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
          ),
          child: Slider(
            value: max <= 0 ? 0 : value,
            max: max <= 0 ? 1 : max,
            onChanged: max <= 0
                ? null
                : (v) {
                    final target = Duration(milliseconds: v.round());
                    player.seek(target);
                    onSeek(target);
                  },
          ),
        );
      },
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.player});

  final Player player;

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, snap) => Text(
        '${_fmt(snap.data ?? Duration.zero)} / ${_fmt(player.state.duration)}',
        style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.player});

  final Player player;
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.rate,
      initialData: player.state.rate,
      builder: (context, snap) => MenuAnchor(
        menuChildren: [
          for (final s in _speeds)
            MenuItemButton(
              leadingIcon: Icon(s == snap.data ? Icons.check : null, size: 18),
              onPressed: () => player.setRate(s),
              child: Text('${s}x'),
            ),
        ],
        builder: (context, controller, _) => TextButton(
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          child: Text(snap.data == 1.0 ? '倍速' : '${snap.data}x', style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }
}
