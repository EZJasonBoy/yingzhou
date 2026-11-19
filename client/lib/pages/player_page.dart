import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../app_state.dart';
import '../desktop/desktop_window.dart';
import '../engine/engine_client.dart';
import '../engine/library_models.dart';
import '../engine/models.dart' show EngineException;
import '../engine/vod_models.dart';
import '../player_backend.dart';
import '../player_cache.dart';
import '../settings.dart';
import 'browse_page.dart' show errorText;
import 'seek_bar.dart';

/// Full-window player: resolves the episode through the engine, plays it with media_kit (libmpv on desktop),
/// and draws its own controls so they work the same with mouse, touch and keyboard.
///
/// Desktop conventions: click pauses, double-click / F toggles fullscreen, Esc leaves fullscreen, the wheel and
/// ↑/↓ change the volume (M mutes), ←/→ seek 10 s (with Shift 60 s), [ / ] change speed, N / P next / previous
/// episode. The volume is remembered between sessions.
///
/// A line that cannot play the episode (its address does not resolve, the player cannot open it, no picture for 15
/// seconds, or the stream breaks off long before the end) is replaced by the next line that has the episode, carrying
/// on from the position reached. Every line gets one turn; a line the user picked by hand is not switched away from.
///
/// Seeking: the bar seeks once, when it is let go ([SeekBar]), and shows what is buffered — what the player holds
/// and, for streams the engine caches, what the engine has on disk. The player's own cache is set up for where the
/// video comes from ([PlayerCache]).
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
  late final PlayerBackend _backend = AppScope.read(context).playerBackend();
  late final EngineClient _client;
  final _focus = FocusNode();
  final _subs = <StreamSubscription<dynamic>>[];

  late int _line = widget.line;
  late int _episode = widget.episode;

  /// Where the episode being opened carries on from: the history's position on the way in, later the position
  /// reached on the line before. [_pendingSeek] is the same until the player has been sent there.
  Duration? _resumeAt;
  Duration? _pendingSeek;
  String? _status;
  String? _error;
  String _parsedBy = '';
  bool _controlsVisible = true;
  bool _panelOpen = false;
  bool _opening = false;
  Timer? _hideTimer;
  Timer? _saveTimer;
  int _requestSeq = 0;
  late final SettingsStore _settings;
  Timer? _volumeSave;
  double _volumeBeforeMute = 100;
  String? _osd;
  Timer? _osdTimer;

  // Changing line without being asked. A round starts where the user (or the end of an episode) chose to play,
  // [_originLine] / [_originEpisode]; from there every other line gets one turn before the page gives up.
  late int _originLine = widget.line;
  late int _originEpisode = widget.episode;
  final _failedLines = <int>{};

  /// False once the user picked the line by hand: the page does not switch away from that choice.
  bool _autoLine = true;

  /// How often the position has moved forward since the media was opened; above zero there is a picture.
  int _advances = 0;
  Duration _lastPosition = Duration.zero;
  Timer? _watchdog;
  Timer? _errorCheck;

  /// Where the player was last sent, until it reports a position from there: further steps start from this place,
  /// not from where the picture still is.
  Duration? _seekingTo;
  Timer? _seekingTimeout;

  /// What is buffered, for the seek bar: looked at once a second. [_cacheKey] names the film in the engine's stream
  /// cache when the engine serves it from there.
  final _buffered = ValueNotifier<List<BufferedRange>>(const []);
  Timer? _bufferWatch;
  bool _readingBuffer = false;
  int _bufferTicks = 0;
  String _cacheKey = '';
  List<BufferedRange> _engineRanges = const [];

  static const _volumeKey = 'player.volume';
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

  /// No picture this long after the player got the address: the line is dead.
  static const _startTimeout = Duration(seconds: 15);

  /// After the player reports an error, how long a line gets to show it is alive: one that has not loaded, and one
  /// that was playing.
  static const _loadGrace = Duration(seconds: 2);
  static const _stallGrace = Duration(seconds: 10);

  /// A stream that ends with more than this left did not finish, it broke off.
  static const _earlyEnd = Duration(seconds: 30);

  Player get _player => _backend.player;
  PlayLine get _currentLine => widget.detail.lines[_line];
  Episode get _currentEpisode => _currentLine.episodes[_episode];
  bool get _hasNext => _episode + 1 < _currentLine.episodes.length;
  bool get _hasPrevious => _episode > 0;
  bool get _started => _advances > 0;
  bool get _desktop => DesktopWindow.isDesktop;
  DesktopWindow get _window => DesktopWindow.instance;

  @override
  void initState() {
    super.initState();
    final app = AppScope.read(context);
    _client = app.client;
    _settings = app.settings;
    final savedVolume = double.tryParse(_settings.getString(_volumeKey) ?? '');
    if (savedVolume != null) _player.setVolume(savedVolume.clamp(0, 100));
    _subs.add(
      _player.stream.volume.listen((v) {
        _volumeSave?.cancel();
        _volumeSave = Timer(const Duration(milliseconds: 500), () => _settings.setString(_volumeKey, v.toStringAsFixed(0)));
      }),
    );
    _subs.add(
      _player.stream.completed.listen((done) {
        if (!done || !mounted || _opening || _error != null) return;
        final state = _player.state;
        // A stream that breaks off reports the end like any other; what is left tells the two apart. One that ends
        // before it showed anything never played at all.
        if (!_started) {
          _lineFailed('无法播放', '还没有画面就结束了');
        } else if (state.duration > Duration.zero && state.duration - state.position > _earlyEnd) {
          _lineFailed('播放中断', '播放中途断开（${_TimeLabel.format(state.position)} / ${_TimeLabel.format(state.duration)}）');
        } else if (_hasNext) {
          _playEpisode(_episode + 1);
        }
      }),
    );
    // Resume once the media knows its length (seeking earlier is ignored by some backends).
    _subs.add(
      _player.stream.duration.listen((d) {
        final seek = _pendingSeek;
        if (seek != null && d > Duration.zero && seek < d - const Duration(seconds: 5)) {
          _pendingSeek = null;
          _player.seek(seek);
        }
      }),
    );
    _subs.add(
      _player.stream.position.listen((p) {
        // Stopping the media before the next one resets the position.
        if (_opening) return;
        // The player has taken up the seek: its position is the place to step from again.
        if (_seekingTo != null && (p - _seekingTo!).abs() < const Duration(seconds: 2)) _clearSeekingTo();
        // Moving on from somewhere past zero: frames are coming (a jump to the resume point alone is not that).
        if (_lastPosition > Duration.zero && p > _lastPosition) {
          _advances++;
          _watchdog?.cancel();
          _watchdog = null;
        }
        _lastPosition = p;
      }),
    );
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());
    _subs.add(
      _player.stream.error.listen((e) {
        // Stopping or replacing the media emits errors (e.g. "empty src" on web), and so does a stream that carries
        // on regardless (a bad frame, a lost segment). The line is given up only if nothing moves afterwards.
        if (!mounted || _opening || _error != null || _errorCheck != null) return;
        final seq = _requestSeq;
        final seen = _advances;
        _errorCheck = Timer(seen > 0 ? _stallGrace : _loadGrace, () {
          _errorCheck = null;
          if (!mounted || seq != _requestSeq || _error != null || _advances != seen) return;
          final state = _player.state;
          // Never loaded; or was playing and is neither paused nor finished, yet stands still.
          if (seen == 0 ? state.duration <= Duration.zero : state.playing && !state.completed) {
            _lineFailed(seen == 0 ? '无法播放' : '播放中断', '播放出错：$e');
          }
        });
      }),
    );
    _bufferWatch = Timer.periodic(const Duration(seconds: 1), (_) => _readBuffered());
    _open(_line, _episode, resume: widget.startPosition);
    _pokeControls();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _osdTimer?.cancel();
    _volumeSave?.cancel();
    _watchdog?.cancel();
    _errorCheck?.cancel();
    _seekingTimeout?.cancel();
    _bufferWatch?.cancel();
    _buffered.dispose();
    _settings.setString(_volumeKey, _player.state.volume.toStringAsFixed(0));
    if (_window.isFullScreen) _window.fullScreen = false;
    _window.title = '映舟';
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
        .putHistory(
          HistoryEntry(
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
          ),
        )
        .catchError((Object _) {});
  }

  /// The user, or the end of the episode before, chose an episode: it starts from the beginning, and a new round of
  /// lines starts with it.
  void _playEpisode(int episode) {
    _originLine = _line;
    _originEpisode = episode;
    _failedLines.clear();
    _autoLine = true;
    _open(_line, episode);
  }

  /// The user chose a line: the same episode there, carrying on from where it was. The choice is theirs: if this
  /// line fails, the page says so and stays on it.
  void _pickLine(int line) {
    final lines = widget.detail.lines;
    if (lines[line].episodes.isEmpty) return;
    final same = lines[line].findEpisode(index: _originEpisode, name: lines[_originLine].episodes[_originEpisode].name);
    final resume = same == null ? null : _reached();
    _originLine = line;
    _originEpisode = same ?? _originEpisode.clamp(0, lines[line].episodes.length - 1);
    _failedLines.clear();
    _autoLine = false;
    _open(line, _originEpisode, resume: resume);
  }

  /// After an error: the same round again, from the line it began on and the position playback got to.
  void _retry() {
    _failedLines.clear();
    _open(_originLine, _originEpisode, resume: _resumeAt);
  }

  /// Where to carry on after a change of line: the position reached, else the one that was still to be sought.
  Duration? _reached() {
    final position = _player.state.position;
    return _started && position > Duration.zero ? position : _resumeAt;
  }

  String _lineLabel(int line) {
    final name = widget.detail.lines[line].name;
    return name.isEmpty ? '线路 ${line + 1}' : '「$name」';
  }

  /// The next line, going round from the current one, that has the episode and has not failed in this round.
  (int, int)? _nextLine() {
    final lines = widget.detail.lines;
    final wanted = lines[_originLine].episodes[_originEpisode].name;
    for (var step = 1; step < lines.length; step++) {
      final line = (_line + step) % lines.length;
      if (_failedLines.contains(line)) continue;
      final episode = lines[line].findEpisode(index: _originEpisode, name: wanted);
      if (episode != null) return (line, episode);
    }
    return null;
  }

  /// The current line cannot play the episode ([why] in two words for the notice, [reason] in full for the error).
  /// Moves on to the next line, unless the user chose this one by hand or every line has had its turn: then the
  /// error is shown and the page is back on the line the round began on, ready to go again.
  void _lineFailed(String why, String reason) {
    _watchdog?.cancel();
    _watchdog = null;
    _errorCheck?.cancel();
    _errorCheck = null;
    final lines = widget.detail.lines;
    final resume = _reached();
    final failed = _lineLabel(_line);
    _failedLines.add(_line);
    final next = _autoLine ? _nextLine() : null;
    if (next != null) {
      _showOsd('$failed$why，已切到${_lineLabel(next.$1)}', const Duration(seconds: 4));
      _open(next.$1, next.$2, resume: resume, automatic: true);
      return;
    }
    final tried = _failedLines.length;
    final String text;
    if (lines.length < 2) {
      text = reason;
    } else if (!_autoLine) {
      text = '$reason\n$failed是手动选的，不会自动换线路';
    } else if (tried < 2) {
      text = '$reason\n其他线路没有这一集';
    } else {
      text = '${tried == lines.length ? '所有 $tried 条线路都试过了' : '有这一集的 $tried 条线路都试过了'}，都没能播放\n最后一条$failed：$reason';
    }
    _saveProgress();
    // Nothing that was under way counts any more, and nothing keeps loading behind the error.
    ++_requestSeq;
    _player.stop().catchError((Object _) {});
    setState(() {
      _line = _originLine;
      _episode = _originEpisode;
      _resumeAt = resume;
      _status = null;
      _parsedBy = '';
      _error = text;
    });
  }

  /// No picture a while after the player got the address: the line is dead.
  void _armWatchdog(int seq) {
    _watchdog?.cancel();
    _watchdog = Timer(_startTimeout, () {
      _watchdog = null;
      if (!mounted || seq != _requestSeq || _started || _error != null || _player.state.completed) return;
      if (_player.state.playing) {
        _lineFailed('没有画面', '等了 ${_startTimeout.inSeconds} 秒还没有画面');
      } else {
        // Paused before anything showed: that is the user's doing. Look again later.
        _armWatchdog(seq);
      }
    });
  }

  /// Resolves the episode on that line and hands the address to the player. [resume] carries a position over;
  /// [automatic] marks a line the page turned to by itself.
  Future<void> _open(int line, int episode, {Duration? resume, bool automatic = false}) async {
    final seq = ++_requestSeq;
    final client = _client;
    if (seq > 1) _saveProgress();
    _watchdog?.cancel();
    _watchdog = null;
    _errorCheck?.cancel();
    _errorCheck = null;
    _advances = 0;
    _lastPosition = Duration.zero;
    _resumeAt = _pendingSeek = resume;
    _opening = true;
    _clearSeekingTo();
    _cacheKey = '';
    _engineRanges = const [];
    _buffered.value = const [];
    setState(() {
      _line = line;
      _episode = episode;
      _status = '正在解析播放地址…';
      _error = null;
      _parsedBy = '';
    });
    // An episode from its beginning goes into the history at once; a line the page turned to, only when it plays.
    if (resume == null && !automatic) _saveProgress(episodeStart: true);
    _window.title = '${widget.detail.name} · ${_currentEpisode.name} - 映舟';
    await _player.stop();
    final PlayInfo info;
    try {
      info = await client.resolvePlay(widget.detail.site, _currentLine.name, _currentEpisode.id);
    } catch (e) {
      if (mounted && seq == _requestSeq) _lineFailed('解析失败', '解析失败：${errorText(e)}');
      return;
    }
    if (!mounted || seq != _requestSeq) return;
    if (!info.isDirect) {
      _lineFailed('需要网页嗅探', '这条线路需要网页嗅探，但引擎没有可用的浏览器内核（桌面需安装 Edge 或 Chrome）');
      return;
    }
    setState(() {
      _status = '正在缓冲…';
      _parsedBy = info.parsedBy;
    });
    _cacheKey = info.cache;
    try {
      // What the player keeps of the video depends on whether the engine keeps it too.
      await PlayerCache.prepare(_player, engineCached: info.cache.isNotEmpty);
      if (!mounted || seq != _requestSeq) return;
      await _player.open(Media(info.url, httpHeaders: info.headers));
    } catch (e) {
      if (mounted && seq == _requestSeq) _lineFailed('无法播放', '播放出错：$e');
      return;
    }
    if (!mounted || seq != _requestSeq) return;
    _opening = false;
    _armWatchdog(seq);
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

  /// A short notice in the middle of the picture (seek, volume, speed, a change of line).
  void _showOsd(String text, [Duration duration = const Duration(milliseconds: 900)]) {
    _osdTimer?.cancel();
    setState(() => _osd = text);
    _osdTimer = Timer(duration, () {
      if (mounted) setState(() => _osd = null);
    });
  }

  void _clearSeekingTo() {
    _seekingTimeout?.cancel();
    _seekingTimeout = null;
    _seekingTo = null;
  }

  /// Sends the player to [target]. Until it reports a position from there, [_seekingTo] stands for where it is.
  void _seekTo(Duration target) {
    _seekingTimeout?.cancel();
    _seekingTo = target;
    _seekingTimeout = Timer(const Duration(seconds: 3), _clearSeekingTo);
    _player.seek(target);
    _pokeControls();
  }

  void _seekBy(Duration delta) {
    final duration = _player.state.duration;
    // Steps add up: the second press of a key starts from where the first one sent the player.
    var target = (_seekingTo ?? _player.state.position) + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    _seekTo(target);
    final seconds = delta.inSeconds.abs();
    _showOsd('${delta.isNegative ? '⏪' : '⏩'} $seconds 秒   ${_TimeLabel.format(target)} / ${_TimeLabel.format(duration)}');
  }

  /// Looks at what is buffered: what the player holds, and what the engine's stream cache has of this film.
  Future<void> _readBuffered() async {
    if (_readingBuffer || _opening || !mounted) return;
    _readingBuffer = true;
    final seq = _requestSeq;
    try {
      final own = await PlayerCache.read(_player);
      final key = _cacheKey;
      // The engine is asked every other time: it is a request over the network when the engine is another machine.
      if (key.isNotEmpty && _bufferTicks++ % 2 == 0) {
        try {
          final coverage = await _client.streamCoverage(key);
          if (seq == _requestSeq) _engineRanges = coverage.ranges;
        } on EngineException {
          // An engine without a stream cache, or one that is busy: the bar shows what it knew.
        }
      }
      if (!mounted || seq != _requestSeq) return;
      _buffered.value = PlayerCache.merge([...own.ranges, ..._engineRanges]);
      // The player's cache file only grows while the video is open; when it has grown too big, the video is opened
      // again where it is, which starts a new file.
      if (own.diskBytes > PlayerCache.diskLimit && _started && _error == null) {
        _showOsd('播放器缓存已满，正在重新载入…', const Duration(seconds: 3));
        _open(_line, _episode, resume: _player.state.position, automatic: true);
      }
    } finally {
      _readingBuffer = false;
    }
  }

  void _changeVolume(double delta) {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    _player.setVolume(v);
    _showOsd(v == 0 ? '🔇 静音' : '🔊 音量 ${v.round()}%');
  }

  void _toggleMute() {
    final v = _player.state.volume;
    if (v > 0) {
      _volumeBeforeMute = v;
      _player.setVolume(0);
      _showOsd('🔇 静音');
    } else {
      _player.setVolume(_volumeBeforeMute <= 0 ? 60 : _volumeBeforeMute);
      _showOsd('🔊 音量 ${_volumeBeforeMute.round()}%');
    }
  }

  void _stepSpeed(int step) {
    final i = _speeds.indexOf(_player.state.rate);
    final next = _speeds[((i < 0 ? _speeds.indexOf(1.0) : i) + step).clamp(0, _speeds.length - 1)];
    _player.setRate(next);
    _showOsd('倍速 ${next}x');
  }

  void _toggleFullScreen() {
    if (!_window.supported) return;
    _window.toggleFullScreen();
    setState(() {});
  }

  void _back() {
    if (_window.isFullScreen) {
      _window.fullScreen = false;
      setState(() {});
    } else if (_panelOpen) {
      setState(() => _panelOpen = false);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final step = Duration(seconds: shift ? 60 : 10);
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      _player.playOrPause();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _seekBy(step);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-step);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _changeVolume(-5);
    } else if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
    } else if (key == LogicalKeyboardKey.keyF) {
      _toggleFullScreen();
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      _stepSpeed(-1);
    } else if (key == LogicalKeyboardKey.bracketRight) {
      _stepSpeed(1);
    } else if ((key == LogicalKeyboardKey.keyN || key == LogicalKeyboardKey.pageDown) && _hasNext) {
      _playEpisode(_episode + 1);
    } else if ((key == LogicalKeyboardKey.keyP || key == LogicalKeyboardKey.pageUp) && _hasPrevious) {
      _playEpisode(_episode - 1);
    } else if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack) {
      _back();
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
          child: Listener(
            // The mouse wheel changes the volume, like desktop players.
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) _changeVolume(e.scrollDelta.dy < 0 ? 5 : -5);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The picture alone listens for clicks and double clicks. A button inside this detector would have to
                // wait until a click can no longer become a double click (0.3 s) before it reacts, so the layers
                // above are its siblings, and whatever in them is only for show lets clicks through to it.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Desktop: click pauses, double-click goes fullscreen. Touch: tap shows/hides the controls.
                  onTap: _desktop
                      ? () {
                          _player.playOrPause();
                          _pokeControls();
                        }
                      : () => _controlsVisible ? setState(() => _controlsVisible = false) : _pokeControls(),
                  onDoubleTap: _desktop ? _toggleFullScreen : _player.playOrPause,
                  child: _backend.view,
                ),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(ignoring: !_controlsVisible, child: _buildControls(context)),
                ),
                _buildStatus(),
                if (_osd != null)
                  IgnorePointer(
                    child: Align(
                      alignment: const Alignment(0, -0.55),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
                        child: Text(
                          _osd!,
                          style: const TextStyle(color: Colors.white, fontSize: 16, fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                      ),
                    ),
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
              // The spinner and the text are for reading; only the buttons under an error take clicks.
              IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_error == null) const CircularProgressIndicator(color: Colors.white70),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.tonal(onPressed: _retry, child: const Text('重试')),
                    // The lines stay the user's to choose from when the page has run out of them.
                    if (widget.detail.lines.length > 1) OutlinedButton(onPressed: () => setState(() => _panelOpen = true), child: const Text('换线路')),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildControls(BuildContext context) {
    final title = '${widget.detail.name} · ${_currentEpisode.name}';
    return Stack(
      fit: StackFit.expand,
      children: [
        // Shading behind the two bars. A decorated box takes every click inside it, so it must not get any: clicks
        // between the buttons belong to the picture underneath.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB0000000), Color(0x00000000), Color(0x00000000), Color(0xC0000000)],
                stops: [0, 0.22, 0.7, 1],
              ),
            ),
          ),
        ),
        _buildBars(context, title),
      ],
    );
  }

  Widget _buildBars(BuildContext context, String title) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回 (Esc)',
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: IgnorePointer(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: Text(
                    _parsedBy.isEmpty ? _currentLine.name : '${_currentLine.name} · ${_parserLabel(_parsedBy)}',
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          ValueListenableBuilder<List<BufferedRange>>(
            valueListenable: _buffered,
            builder: (context, buffered, _) => StreamBuilder<Duration>(
              stream: _player.stream.position,
              initialData: _player.state.position,
              builder: (context, snap) => SeekBar(
                key: const Key('seek-bar'),
                position: snap.data ?? Duration.zero,
                duration: _player.state.duration,
                buffered: buffered,
                onSeek: _seekTo,
                onInteraction: _pokeControls,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                if (_hasPrevious)
                  IconButton(
                    tooltip: '上一集 (P)',
                    onPressed: () => _playEpisode(_episode - 1),
                    icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
                  ),
                StreamBuilder<bool>(
                  stream: _player.stream.playing,
                  initialData: _player.state.playing,
                  builder: (context, snap) => IconButton(
                    tooltip: '播放 / 暂停 (空格)',
                    iconSize: 32,
                    onPressed: _player.playOrPause,
                    icon: Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                  ),
                ),
                if (_hasNext)
                  IconButton(
                    tooltip: '下一集 (N)',
                    onPressed: () => _playEpisode(_episode + 1),
                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
                  ),
                const SizedBox(width: 8),
                IgnorePointer(child: _TimeLabel(player: _player)),
                const Spacer(),
                if (_desktop) _VolumeControl(player: _player, onToggleMute: _toggleMute),
                _SpeedButton(player: _player, speeds: _speeds),
                TextButton.icon(
                  onPressed: () => setState(() => _panelOpen = true),
                  icon: const Icon(Icons.playlist_play_rounded, color: Colors.white),
                  label: const Text('选集', style: TextStyle(color: Colors.white)),
                ),
                if (_window.supported)
                  IconButton(
                    tooltip: _window.isFullScreen ? '退出全屏 (Esc)' : '全屏 (F / 双击)',
                    onPressed: _toggleFullScreen,
                    icon: Icon(_window.isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, color: Colors.white),
                  ),
              ],
            ),
          ),
        ],
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
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < widget.detail.lines.length; i++)
                            ChoiceChip(
                              label: Text(widget.detail.lines[i].name),
                              selected: i == _line,
                              onSelected: (_) {
                                setState(() => _panelOpen = false);
                                _pickLine(i);
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Text('选集', style: TextStyle(color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (var i = 0; i < _currentLine.episodes.length; i++)
                            SizedBox(
                              width: 98,
                              child: i == _episode
                                  ? FilledButton(onPressed: null, child: Text(_currentLine.episodes[i].name, maxLines: 1, overflow: TextOverflow.ellipsis))
                                  : OutlinedButton(
                                      onPressed: () {
                                        setState(() => _panelOpen = false);
                                        _playEpisode(i);
                                      },
                                      child: Text(_currentLine.episodes[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                    ),
                            ),
                        ],
                      ),
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

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.player});

  final Player player;

  static String format(Duration d) {
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
        '${format(snap.data ?? Duration.zero)} / ${format(player.state.duration)}',
        style: const TextStyle(color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
      ),
    );
  }
}

/// Mute button plus a volume slider (desktop).
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({required this.player, required this.onToggleMute});

  final Player player;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snap) {
        final v = (snap.data ?? 100).clamp(0.0, 100.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: v == 0 ? '取消静音 (M)' : '静音 (M)',
              onPressed: onToggleMute,
              icon: Icon(v == 0 ? Icons.volume_off_rounded : (v < 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded), color: Colors.white),
            ),
            SizedBox(
              width: 110,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                ),
                child: Slider(value: v, max: 100, onChanged: player.setVolume),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.player, required this.speeds});

  final Player player;
  final List<double> speeds;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.rate,
      initialData: player.state.rate,
      builder: (context, snap) => MenuAnchor(
        menuChildren: [
          for (final s in speeds)
            MenuItemButton(leadingIcon: Icon(s == snap.data ? Icons.check : null, size: 18), onPressed: () => player.setRate(s), child: Text('${s}x')),
        ],
        builder: (context, controller, _) => TextButton(
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          child: Text(snap.data == 1.0 ? '倍速' : '${snap.data}x', style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }
}
