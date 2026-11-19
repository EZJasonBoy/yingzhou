import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../app_state.dart';
import '../desktop/desktop_window.dart';
import '../engine/engine_client.dart';
import '../engine/live_models.dart';
import '../player_backend.dart';
import '../settings.dart';
import '../ui/engine_image.dart';
import '../ui/form_factor.dart';
import '../ui/theme.dart';
import 'browse_page.dart' show errorText;
import 'player_mobile.dart';
import 'touch_gestures.dart';

/// Live TV: the config's `lives` as sources, channel groups, a player and the programme guide.
///
/// Wide windows show groups | channels | player + guide side by side; narrow ones stack them. Keys: ↑/↓ change
/// channel, ←/→ change line, PageUp/PageDown change group, F or double-click toggles fullscreen (the channel list
/// becomes an overlay), M mutes, the wheel changes the volume. A line that fails, or shows nothing for 15 seconds,
/// is replaced by the channel's next line. The last channel is remembered.
///
/// Catch-up (回看): on a channel that has it, the guide offers the days back the channel allows, and a programme
/// that has ended plays from the engine's catch-up address with a seek bar; 「回到直播」, Esc or another channel goes
/// back to live.
class LivePage extends StatefulWidget {
  const LivePage({super.key, required this.visible, this.onImmersiveChanged});

  /// The tab is showing; playback stops while it is hidden.
  final bool visible;

  /// Fullscreen on/off, so the shell can hide its navigation.
  final ValueChanged<bool>? onImmersiveChanged;

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  // Created the first time the tab is shown, so a user who never opens live TV never starts a second player.
  Player? _playerOrNull;
  PlayerBackend? _backend;
  final _focus = FocusNode();
  final _subs = <StreamSubscription<dynamic>>[];

  String _configKey = '';
  String _loadedKey = '';
  List<LiveSourceInfo> _sources = const [];
  int _source = 0;
  LiveList? _list;
  String? _error;
  bool _loading = false;

  int _group = 0; // the group being browsed
  (int, int)? _playing; // group, channel
  int _line = 0;
  String? _status;
  bool _opening = false;
  Timer? _watchdog;

  final _epg = <String, EpgDay>{};
  final _epgLoading = <String>{};
  Timer? _clock;
  DateTime _now = DateTime.now();

  // Catch-up: the programme being played back (null while live), its addresses and the one being tried; the guide
  // day shown (days before today) and the guides of earlier days by "channel|date".
  EpgProgram? _catchup;
  List<LiveUrl> _catchupUrls = const [];
  int _catchupTry = 0;
  int _guideDay = 0;
  final _pastEpg = <String, EpgDay>{};

  bool _immersive = false;
  bool _overlay = true;
  Timer? _overlayTimer;
  String? _osd;
  Timer? _osdTimer;

  /// Phones and tablets ([MobilePlayback]): gestures on the picture, full screen with the turn to landscape,
  /// picture-in-picture, keeping the screen on; null on desktops and TVs.
  MobilePlayback? _mobile;
  Orientation? _orientation;

  /// Keeps the picture (and its video surface) alive when it moves between the upright layout, full screen and
  /// picture-in-picture; a new video widget there would show black on Android.
  final _playerKey = GlobalKey();

  static const _lastKey = 'live.last';
  static const _volumeKey = 'player.volume';

  AppState get _state => AppScope.read(context);
  EngineClient get _client => _state.client;
  SettingsStore get _settings => _state.settings;
  DesktopWindow get _window => DesktopWindow.instance;

  Player get _player {
    final existing = _playerOrNull;
    if (existing != null) return existing;
    final backend = _state.playerBackend();
    final player = backend.player;
    _playerOrNull = player;
    _backend = backend;
    final v = double.tryParse(_settings.getString(_volumeKey) ?? '');
    if (v != null) player.setVolume(v.clamp(0, 100));
    _subs.add(
      player.stream.error.listen((e) {
        // Errors while a line is playing (a lost segment) are mpv's business; one that keeps the picture from
        // starting means the line is dead.
        if (!_opening && mounted && (_watchdog != null || !(_playerOrNull?.state.playing ?? false))) {
          _catchup != null ? _catchupFailed('无法播放') : _nextLine('线路 ${_line + 1} 无法播放');
        }
      }),
    );
    _subs.add(
      player.stream.position.listen((p) {
        if (p > Duration.zero && _watchdog != null) {
          _watchdog?.cancel();
          _watchdog = null;
          if (mounted && _status != null) setState(() => _status = null);
        }
      }),
    );
    _subs.add(player.stream.volume.listen((v) => _settings.setString(_volumeKey, v.toStringAsFixed(0))));
    _mobile?.attach(player);
    return player;
  }

  LiveChannel? get _channel {
    final p = _playing;
    final list = _list;
    if (p == null || list == null || p.$1 >= list.groups.length || p.$2 >= list.groups[p.$1].channels.length) return null;
    return list.groups[p.$1].channels[p.$2];
  }

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    if (FormFactors.isMobile) {
      _mobile = MobilePlayback(
        onChanged: _mobileChanged,
        // In the background without picture-in-picture the channel stops; back in the app it tunes in again.
        onBackground: () => _playerOrNull?.stop(),
        onForeground: () {
          final p = _playing;
          if (p != null && _list != null && _catchup == null) _play(p.$1, p.$2, line: _line);
        },
      )..start();
      _mobile!.setActive(widget.visible);
      // The small controls over the picture come with a tap.
      _overlay = false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mobileOrientation();
    final state = AppScope.of(context);
    final key = state.hasConfig ? '${state.engineUrl}|${state.summary!.subscriptionId}|${state.summary!.url}' : '';
    _configKey = key;
    if (widget.visible) _loadIfNeeded();
  }

  /// Sources are loaded when the tab is first shown, and again after the subscription changes.
  void _loadIfNeeded() {
    if (_configKey == _loadedKey) return;
    _loadedKey = _configKey;
    if (_configKey.isNotEmpty) Future.microtask(_loadSources);
  }

  @override
  void didUpdateWidget(LivePage old) {
    super.didUpdateWidget(old);
    if (old.visible == widget.visible) return;
    _mobile?.setActive(widget.visible);
    if (widget.visible && _mobile != null) {
      // A phone already on its side when the tab comes up: full screen at once.
      _orientation = null;
      _mobileOrientation();
    }
    if (widget.visible) {
      _loadIfNeeded();
      // Live streams go stale while paused: tune in again.
      final p = _playing;
      if (p != null && _list != null) _play(p.$1, p.$2, line: _line);
      _focus.requestFocus();
    } else {
      _watchdog?.cancel();
      _playerOrNull?.stop();
      if (_immersive) {
        // Called while the shell builds: tell it after the frame.
        _immersive = false;
        if (_window.supported) _window.fullScreen = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => widget.onImmersiveChanged?.call(false));
      }
    }
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _clock?.cancel();
    _overlayTimer?.cancel();
    _osdTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _mobile?.dispose();
    _playerOrNull?.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- loading

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
      _list = null;
      _sources = const [];
      _playing = null;
      _catchup = null;
      _epg.clear();
      _pastEpg.clear();
    });
    try {
      final sources = await _client.liveSources();
      if (!mounted) return;
      final last = _settings.getString(_lastKey)?.split('\t');
      final wanted = int.tryParse(last?.first ?? '') ?? 0;
      setState(() {
        _sources = sources;
        _source = wanted < sources.length && sources[wanted].supported ? wanted : sources.indexWhere((s) => s.supported).clamp(0, sources.length);
      });
      if (sources.isNotEmpty) await _loadList(refresh: false);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadList({required bool refresh}) async {
    if (_source >= _sources.length) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _client.liveList(_source, refresh: refresh);
      if (!mounted) return;
      // Back to the channel watched last time, else the first one.
      final last = _settings.getString(_lastKey)?.split('\t');
      var target = (0, 0);
      if (last != null && last.length == 3 && last[0] == '$_source') {
        for (var g = 0; g < list.groups.length; g++) {
          if (list.groups[g].name != last[1]) continue;
          final c = list.groups[g].channels.indexWhere((ch) => ch.name == last[2]);
          if (c >= 0) target = (g, c);
        }
      }
      setState(() {
        _list = list;
        _group = target.$1;
      });
      if (list.groups.isNotEmpty && list.groups.first.channels.isNotEmpty) {
        if (widget.visible) {
          _play(target.$1, target.$2);
        } else {
          setState(() => _playing = target);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _loadEpg(String channel) {
    if (_source >= _sources.length || !_sources[_source].hasEpg) return;
    if (_epg.containsKey(channel) || _epgLoading.contains(channel) || _epgLoading.length >= 4) return;
    _epgLoading.add(channel);
    _client
        .epg(_source, channel)
        .then((day) {
          if (mounted) setState(() => _epg[channel] = day);
        })
        .catchError((Object _) {
          if (mounted) _epg[channel] = EpgDay(channel: channel, date: '');
        })
        .whenComplete(() => _epgLoading.remove(channel));
  }

  // ---------------------------------------------------------------- playback

  Future<void> _play(int group, int channel, {int line = 0}) async {
    final list = _list;
    if (list == null) return;
    final ch = list.groups[group].channels[channel];
    if (ch.urls.isEmpty) return;
    final changed = _playing != (group, channel);
    setState(() {
      _playing = (group, channel);
      // Live again: whatever was being played back stops, and a new channel's guide starts at today.
      _catchup = null;
      _catchupUrls = const [];
      if (changed) _guideDay = 0;
      _line = line.clamp(0, ch.urls.length - 1);
      _status = ch.urls.length > 1 ? '正在打开 线路 ${_line + 1}/${ch.urls.length}…' : '正在打开…';
    });
    _settings.setString(_lastKey, '$_source\t${list.groups[group].name}\t${ch.name}');
    _window.title = '${ch.name} - 映舟';
    _loadEpg(ch.name);
    if (changed && _immersive) _showOverlay();
    final url = ch.urls[_line];
    _opening = true;
    _watchdog?.cancel();
    try {
      await _player.open(Media(url.url, httpHeaders: url.headers));
    } catch (_) {
      // Reported through the error stream.
    } finally {
      _opening = false;
    }
    // A programme was picked for catch-up while this was opening: that is what plays now.
    if (_catchup != null) return;
    // Nothing on screen after a while: this line is dead.
    _watchdog = Timer(const Duration(seconds: 15), () => _nextLine('线路 ${_line + 1} 没有画面'));
  }

  /// Plays a programme that has ended (or the part of the current one so far) from the channel's catch-up address.
  Future<void> _playCatchup(EpgProgram program) async {
    final ch = _channel;
    final p = _playing;
    final list = _list;
    if (ch == null || p == null || list == null || !ch.hasCatchup) return;
    _watchdog?.cancel();
    _watchdog = null;
    setState(() {
      _catchup = program;
      _catchupUrls = const [];
      _status = '正在打开回看…';
    });
    _showOsd('回看 ${_hm(program.start)} ${program.title}');
    final LiveCatchup found;
    try {
      found = await _client.liveCatchup(_source, ch.name, group: list.groups[p.$1].name, line: _line, start: program.start, end: program.end);
    } catch (e) {
      if (mounted && _catchup == program) setState(() => _status = '取不到回看地址：${errorText(e)}');
      return;
    }
    if (!mounted || _catchup != program) return;
    _catchupUrls = found.all;
    _catchupTry = 0;
    await _openCatchup(program);
  }

  Future<void> _openCatchup(EpgProgram program) async {
    final url = _catchupUrls[_catchupTry];
    setState(() => _status = '正在打开回看…');
    _opening = true;
    _watchdog?.cancel();
    try {
      await _player.open(Media(url.url, httpHeaders: url.headers));
    } catch (_) {
      // Reported through the error stream.
    } finally {
      _opening = false;
    }
    if (!mounted || _catchup != program) return;
    _watchdog = Timer(const Duration(seconds: 15), () => _catchupFailed('没有画面'));
  }

  /// The catch-up address does not play: the next one the engine offered, else say so (the page stays in 回看).
  void _catchupFailed(String why) {
    final program = _catchup;
    if (program == null) return;
    _watchdog?.cancel();
    _watchdog = null;
    if (_catchupTry + 1 < _catchupUrls.length) {
      _catchupTry++;
      _openCatchup(program);
    } else {
      setState(() => _status = '回看$why，这个节目可能已经不能回看了');
    }
  }

  /// From catch-up back to the channel's live picture.
  void _backToLive() {
    final p = _playing;
    if (_catchup == null || p == null) return;
    _showOsd('回到直播');
    _play(p.$1, p.$2, line: _line);
  }

  void _seekBy(Duration delta) {
    final duration = _player.state.duration;
    var target = _player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    _player.seek(target);
    _showOsd('${delta.isNegative ? '⏪' : '⏩'} ${delta.inSeconds.abs()} 秒   ${_clockText(target)} / ${_clockText(duration)}');
  }

  /// The guide of [channel] on an earlier day.
  void _loadPastEpg(String channel, String date) {
    final key = '$channel|$date';
    if (_pastEpg.containsKey(key) || _epgLoading.contains(key)) return;
    _epgLoading.add(key);
    _client
        .epg(_source, channel, date: date)
        .then((day) {
          if (mounted) setState(() => _pastEpg[key] = day);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _pastEpg[key] = EpgDay(channel: channel, date: date));
        })
        .whenComplete(() => _epgLoading.remove(key));
  }

  void _nextLine(String why) {
    final ch = _channel;
    final p = _playing;
    if (ch == null || p == null) return;
    _watchdog?.cancel();
    _watchdog = null;
    if (_line + 1 < ch.urls.length) {
      _showOsd('$why，换到线路 ${_line + 2}');
      _play(p.$1, p.$2, line: _line + 1);
    } else {
      setState(() => _status = ch.urls.length > 1 ? '$why，所有 ${ch.urls.length} 条线路都试过了' : why);
    }
  }

  void _switchLine(int delta) {
    final ch = _channel;
    final p = _playing;
    if (ch == null || p == null || ch.urls.length < 2) return;
    final line = (_line + delta + ch.urls.length) % ch.urls.length;
    final label = ch.urls[line].label;
    _showOsd('线路 ${line + 1}/${ch.urls.length}${label.isEmpty ? '' : ' · $label'}');
    _play(p.$1, p.$2, line: line);
  }

  /// Next/previous channel, running across groups.
  void _stepChannel(int delta) {
    final list = _list;
    final p = _playing ?? (0, -delta.sign);
    if (list == null) return;
    final flat = <(int, int)>[
      for (var g = 0; g < list.groups.length; g++)
        for (var c = 0; c < list.groups[g].channels.length; c++) (g, c),
    ];
    if (flat.isEmpty) return;
    final i = flat.indexOf(p);
    final next = flat[((i < 0 ? 0 : i) + delta) % flat.length];
    setState(() => _group = next.$1);
    _play(next.$1, next.$2);
  }

  void _stepGroup(int delta) {
    final list = _list;
    if (list == null || list.groups.isEmpty) return;
    setState(() => _group = (_group + delta) % list.groups.length);
  }

  void _changeVolume(double delta) {
    final v = (_player.state.volume + delta).clamp(0.0, 100.0);
    _player.setVolume(v);
    _showOsd(v == 0 ? '🔇 静音' : '🔊 音量 ${v.round()}%');
  }

  void _toggleMute() {
    if (_player.state.volume > 0) {
      _settings.setString('live.unmute', _player.state.volume.toStringAsFixed(0));
      _player.setVolume(0);
      _showOsd('🔇 静音');
    } else {
      final v = double.tryParse(_settings.getString('live.unmute') ?? '') ?? 60;
      _player.setVolume(v);
      _showOsd('🔊 音量 ${v.round()}%');
    }
  }

  void _toggleImmersive() {
    final mobile = _mobile;
    if (mobile != null) {
      // Phones and tablets: through MobilePlayback (system bars, landscape), which reports back to _mobileChanged.
      mobile.setFullScreen(!mobile.fullScreen);
      return;
    }
    setState(() => _immersive = !_immersive);
    widget.onImmersiveChanged?.call(_immersive);
    if (_window.supported) _window.fullScreen = _immersive;
    if (_immersive) _showOverlay();
  }

  /// Full screen or picture-in-picture changed on a phone or tablet: the page shows the picture alone, and the shell
  /// hides its navigation (told after the frame: this can come while the shell builds).
  void _mobileChanged() {
    final mobile = _mobile;
    if (mobile == null || !mounted) return;
    final full = mobile.active && (mobile.fullScreen || mobile.inPip);
    if (full != _immersive) {
      _immersive = full;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onImmersiveChanged?.call(_immersive);
      });
      if (full && !mobile.inPip) _showOverlay();
    }
    setState(() {});
  }

  /// A phone's live picture goes full screen when the phone is turned on its side, and back when turned upright.
  void _mobileOrientation() {
    final mobile = _mobile;
    if (mobile == null) return;
    mobile.rotateToFullScreen = FormFactors.isPhone(context);
    final orientation = MediaQuery.orientationOf(context);
    if (orientation == _orientation || !widget.visible) return;
    _orientation = orientation;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.visible) mobile.orientationChanged(orientation);
    });
  }

  void _toggleOverlay() {
    if (_overlay) {
      _overlayTimer?.cancel();
      setState(() => _overlay = false);
    } else {
      _showOverlay();
    }
  }

  void _showOverlay() {
    _overlayTimer?.cancel();
    setState(() => _overlay = true);
    _overlayTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _overlay = false);
    });
  }

  void _showOsd(String text) {
    _osdTimer?.cancel();
    setState(() => _osd = text);
    _osdTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _osd = null);
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _stepChannel(-1);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _stepChannel(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      // Playing back: ←/→ seek (Shift: a minute); live: change line.
      _catchup != null ? _seekBy(Duration(seconds: HardwareKeyboard.instance.isShiftPressed ? -60 : -10)) : _switchLine(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _catchup != null ? _seekBy(Duration(seconds: HardwareKeyboard.instance.isShiftPressed ? 60 : 10)) : _switchLine(1);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _stepGroup(-1);
    } else if (key == LogicalKeyboardKey.pageDown) {
      _stepGroup(1);
    } else if (key == LogicalKeyboardKey.keyF) {
      _toggleImmersive();
    } else if (key == LogicalKeyboardKey.escape && _immersive) {
      _toggleImmersive();
    } else if (key == LogicalKeyboardKey.escape && _catchup != null) {
      _backToLive();
    } else if (key == LogicalKeyboardKey.keyM) {
      _toggleMute();
    } else if (key == LogicalKeyboardKey.space) {
      _player.playOrPause();
    } else {
      return KeyEventResult.ignored;
    }
    if (_immersive) _showOverlay();
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final Widget body;
    if (!state.hasConfig && state.loadingConfig) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!state.hasConfig && state.configError != null) {
      body = _message(Icons.cloud_off_rounded, '订阅加载失败\n${state.configError}', retry: state.reloadConfig);
    } else if (!state.hasConfig) {
      body = _message(Icons.live_tv_rounded, '先在"源"里导入订阅');
    } else if (_loading && _list == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null && _list == null) {
      body = _message(Icons.error_outline_rounded, _error!, retry: _sources.isEmpty ? _loadSources : () => _loadList(refresh: true));
    } else if (_sources.isEmpty) {
      body = _message(Icons.live_tv_rounded, '当前订阅没有直播源');
    } else {
      body = _immersive ? _buildImmersive(context) : _buildLayout(context);
    }
    return _touchBack(Focus(
      focusNode: _focus,
      autofocus: widget.visible,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: _immersive ? Colors.black : null,
        body: SafeArea(child: body),
      ),
    ));
  }

  /// Phones and tablets: the system's back leaves full screen first (the shell leaves this tab after that).
  Widget _touchBack(Widget child) {
    final mobile = _mobile;
    if (mobile == null) return child;
    return PopScope(
      canPop: !(widget.visible && mobile.fullScreen),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && widget.visible && mobile.fullScreen) mobile.setFullScreen(false);
      },
      child: child,
    );
  }

  Widget _message(IconData icon, String text, {VoidCallback? retry}) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          if (retry != null) ...[const SizedBox(height: 16), FilledButton.tonal(onPressed: retry, child: const Text('重试'))],
        ],
      ),
    );
  }

  Widget _buildLayout(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final player = _buildPlayer(context);
    if (!wide && _mobile != null) return _buildPhoneLayout(context, player);
    if (!wide) {
      return Column(
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: player),
          _buildNowBar(context),
          if (_catchup != null) _CatchupBar(player: _player),
          SizedBox(height: 48, child: _buildGroupChips(context)),
          Expanded(child: _buildChannels(context)),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 200, child: _buildGroups(context)),
        const VerticalDivider(width: 1),
        SizedBox(width: 300, child: _buildChannels(context)),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(aspectRatio: 16 / 9, child: player),
                ),
              ),
              _buildNowBar(context),
              if (_catchup != null) _CatchupBar(player: _player),
              Expanded(child: _buildGuide(context)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSourcePicker(BuildContext context) {
    if (_sources.length < 2) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
        child: Text(_list?.name ?? '直播', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
      child: DropdownButton<int>(
        isExpanded: true,
        value: _source,
        underline: const SizedBox.shrink(),
        items: [
          for (final s in _sources)
            DropdownMenuItem(
              value: s.index,
              enabled: s.supported,
              child: Text(s.supported ? s.name : '${s.name}（${s.spider == 'py' ? '需要 Python' : '暂不支持'}）', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (i) {
          if (i == null || i == _source) return;
          setState(() {
            _source = i;
            _epg.clear();
            _pastEpg.clear();
          });
          _loadList(refresh: false);
        },
      ),
    );
  }

  Widget _buildGroups(BuildContext context) {
    final list = _list;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSourcePicker(context),
        Expanded(
          child: list == null
              ? const SizedBox.shrink()
              : ListView.builder(
                  itemCount: list.groups.length,
                  itemBuilder: (context, i) {
                    final selected = i == _group;
                    final playingHere = _playing?.$1 == i;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.5),
                      title: Text(list.groups[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: playingHere
                          ? Icon(Icons.graphic_eq_rounded, size: 16, color: scheme.primary)
                          : Text('${list.groups[i].channels.length}', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                      onTap: () => setState(() => _group = i),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextButton.icon(
            onPressed: _loading ? null : () => _loadList(refresh: true),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('刷新频道'),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupChips(BuildContext context) {
    final list = _list;
    if (list == null) return const SizedBox.shrink();
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      children: [
        for (var i = 0; i < list.groups.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(label: Text(list.groups[i].name), selected: i == _group, onSelected: (_) => setState(() => _group = i)),
          ),
      ],
    );
  }

  Widget _buildChannels(BuildContext context) {
    final list = _list;
    if (list == null || list.groups.isEmpty) return const SizedBox.shrink();
    final group = list.groups[_group.clamp(0, list.groups.length - 1)];
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: group.channels.length,
      itemBuilder: (context, i) {
        final ch = group.channels[i];
        final playing = _playing == (_group, i);
        _loadEpg(ch.name);
        final now = _epg[ch.name]?.current(_now);
        return ListTile(
          selected: playing,
          selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
          leading: _Logo(url: ch.logo),
          title: Text(
            ch.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: playing ? FontWeight.w700 : FontWeight.w500),
          ),
          subtitle: now == null
              ? (ch.urls.length > 1 ? Text('${ch.urls.length} 条线路', style: const TextStyle(fontSize: 12)) : null)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(value: now.progressAt(_now), minHeight: 2),
                  ],
                ),
          onTap: () => _play(_group, i),
        );
      },
    );
  }

  Widget _buildNowBar(BuildContext context) {
    final ch = _channel;
    final scheme = Theme.of(context).colorScheme;
    if (ch == null) return const SizedBox(height: 8);
    final now = _epg[ch.name]?.current(_now);
    final back = _catchup;
    final line = ch.urls.length > 1 ? '线路 ${_line + 1}/${ch.urls.length}${ch.urls[_line].label.isEmpty ? '' : ' · ${ch.urls[_line].label}'}' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(ch.name, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                    if (back != null) ...[const SizedBox(width: 10), const _CatchupBadge()],
                  ],
                ),
                if (back != null)
                  Text('${_md(back.start)} ${_hm(back.start)}–${_hm(back.end)}  ${back.title}', style: TextStyle(color: scheme.onSurfaceVariant))
                else if (now != null || line.isNotEmpty)
                  Text([if (now != null) '正在播放：${now.title}', if (line.isNotEmpty) line].join('   '), style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (back != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: FilledButton.tonalIcon(
                key: const Key('back-to-live'),
                onPressed: _backToLive,
                icon: const Icon(Icons.live_tv_rounded, size: 18),
                label: const Text('回到直播'),
              ),
            ),
          if (back == null && ch.urls.length > 1) IconButton(tooltip: '换线路 (→)', onPressed: () => _switchLine(1), icon: const Icon(Icons.swap_horiz_rounded)),
          _VolumeButton(player: _player, onToggleMute: _toggleMute),
          if (_window.supported) IconButton(tooltip: '全屏 (F / 双击)', onPressed: _toggleImmersive, icon: const Icon(Icons.fullscreen_rounded)),
          if (_mobile != null) IconButton(key: const Key('live-fullscreen'), tooltip: '全屏', onPressed: _toggleImmersive, icon: const Icon(Icons.fullscreen_rounded)),
        ],
      ),
    );
  }

  Widget _buildGuide(BuildContext context) {
    final ch = _channel;
    final scheme = Theme.of(context).colorScheme;
    if (ch == null) return const SizedBox.shrink();
    if (_source < _sources.length && !_sources[_source].hasEpg) {
      return Center(
        child: Text('这个直播源没有节目单', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    // A channel with catch-up offers the days back it allows; one without shows today, as it always did.
    final daysBack = ch.hasCatchup ? ch.catchupDays : 0;
    final dayIndex = _guideDay.clamp(0, daysBack);
    final date = chinaDate(_now, daysAgo: dayIndex);
    final EpgDay? day;
    if (dayIndex == 0) {
      day = _epg[ch.name];
    } else {
      day = _pastEpg['${ch.name}|$date'];
      if (day == null) _loadPastEpg(ch.name, date);
    }
    final Widget list;
    if (day == null) {
      list = const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (day.programs.isEmpty) {
      list = Center(
        child: Text('暂无节目单', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    } else {
      list = _GuideList(
        key: ValueKey('${ch.name}|$date'),
        programs: day.programs,
        current: day.programs.indexWhere((p) => p.isOnAt(_now)),
        now: _now,
        catchup: ch.hasCatchup,
        playingBack: _catchup,
        onPlayBack: _playCatchup,
        onLive: _backToLive,
      );
    }
    if (daysBack == 0) return list;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            children: [
              for (var d = 0; d <= daysBack; d++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_dayLabel(d)),
                    selected: d == dayIndex,
                    onSelected: (_) => setState(() => _guideDay = d),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  String _dayLabel(int daysAgo) => switch (daysAgo) {
    0 => '今天',
    1 => '昨天',
    2 => '前天',
    _ => () {
      final d = chinaDate(_now, daysAgo: daysAgo).split('-');
      return '${int.parse(d[1])}月${int.parse(d[2])}日';
    }(),
  };

  Widget _buildPlayer(BuildContext context) {
    return _keepPlayer(MouseRegion(
      onHover: _immersive ? (_) => _showOverlay() : null,
      cursor: _immersive && !_overlay ? SystemMouseCursors.none : SystemMouseCursors.basic,
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) _changeVolume(e.scrollDelta.dy < 0 ? 5 : -5);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _window.supported ? _toggleImmersive : null,
          // Phones and tablets: the touch layer below takes the taps.
          onTap: _mobile != null ? null : () {
            _focus.requestFocus();
            if (_immersive) _showOverlay();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_mobile != null && _backend != null) _buildTouchLayer() else
              _backend?.view ?? const ColoredBox(color: Colors.black),
              if (_catchup != null) const IgnorePointer(child: Align(alignment: Alignment(-0.95, -0.9), child: _CatchupBadge())),
              if (_status != null)
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_watchdog != null || _opening) const CircularProgressIndicator(color: Colors.white70),
                      const SizedBox(height: 12),
                      Text(
                        _status!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              if (_osd != null)
                Align(
                  alignment: const Alignment(0, -0.6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(10)),
                    child: Text(_osd!, style: const TextStyle(color: Colors.white, fontSize: 15)),
                  ),
                ),
              if (_mobile != null && !_immersive) _buildInlineControls(),
            ],
          ),
        ),
      ),
    ));
  }

  /// Phones and tablets: the picture keeps its element across layouts ([_playerKey]).
  Widget _keepPlayer(Widget player) => _mobile == null ? player : KeyedSubtree(key: _playerKey, child: player);

  // ------------------------------------------------------------------ phones and tablets

  Widget _buildTouchLayer() {
    final catchup = _catchup != null;
    return TouchGestureLayer(
      player: _player,
      // Live: a swipe to either side changes channel; playing back, it seeks like the video player.
      swipe: catchup ? TouchSwipe.seek : TouchSwipe.step,
      onSeek: catchup ? (target) => _player.seek(target) : null,
      onSwipe: (direction) => _stepChannel(direction),
      longPressSpeed: catchup,
      onTap: _toggleOverlay,
      onDoubleTap: (_) => _player.playOrPause(),
      onBrightness: _mobile!.brightnessTouched,
      child: _backend!.view,
    );
  }

  /// Over the small picture: play / pause and full screen, for a few seconds after a tap.
  Widget _buildInlineControls() {
    return IgnorePointer(
      ignoring: !_overlay,
      child: AnimatedOpacity(
        opacity: _overlay ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xA0000000)]),
            ),
            child: Row(
              children: [
                if (_playerOrNull != null)
                  StreamBuilder<bool>(
                    stream: _player.stream.playing,
                    initialData: _player.state.playing,
                    builder: (context, snap) => IconButton(
                      tooltip: snap.data == true ? '暂停' : '播放',
                      onPressed: _player.playOrPause,
                      icon: Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                    ),
                  ),
                const Spacer(),
                if (_mobile!.pipSupported)
                  IconButton(tooltip: '小窗播放', onPressed: _enterPip, icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white)),
                IconButton(tooltip: '全屏', onPressed: _toggleImmersive, icon: const Icon(Icons.fullscreen_rounded, color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _enterPip() async {
    _overlayTimer?.cancel();
    setState(() => _overlay = false);
    if (!await _mobile!.host.enterPip()) _showOsd('这台设备不能小窗播放');
  }

  /// A phone held upright (or a narrow tablet): the picture on top, what is on under it, then the channels and the
  /// guide as two tabs.
  Widget _buildPhoneLayout(BuildContext context, Widget player) {
    final hasGuide = _source < _sources.length && _sources[_source].hasEpg;
    final size = MediaQuery.sizeOf(context);
    final tabs = DefaultTabController(
      length: hasGuide ? 2 : 1,
      child: Column(
        children: [
          TabBar(
            tabAlignment: TabAlignment.fill,
            tabs: [const Tab(text: '频道', height: 44), if (hasGuide) const Tab(text: '节目单', height: 44)],
          ),
          Expanded(
            child: TabBarView(
              children: [
                Column(
                  children: [
                    if (_sources.length > 1) _buildSourcePicker(context),
                    SizedBox(height: 56, child: _buildGroupChips(context)),
                    Expanded(child: _buildChannels(context)),
                  ],
                ),
                if (hasGuide) _buildGuide(context),
              ],
            ),
          ),
        ],
      ),
    );
    // On its side without full screen (a tablet, or a phone for the moment before it goes full screen): the picture
    // and what is on at the left, the channels and the guide at the right.
    if (size.width > size.height) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              children: [
                Flexible(child: AspectRatio(aspectRatio: 16 / 9, child: player)),
                _buildNowBar(context),
                if (_catchup != null) _CatchupBar(player: _player),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(width: 320, child: tabs),
        ],
      );
    }
    return Column(
      children: [
        AspectRatio(aspectRatio: 16 / 9, child: player),
        _buildNowBar(context),
        if (_catchup != null) _CatchupBar(player: _player),
        Expanded(child: tabs),
      ],
    );
  }

  /// Fullscreen: the picture alone; moving the mouse or a key shows the channel list and what is on.
  Widget _buildImmersive(BuildContext context) {
    final ch = _channel;
    final now = ch == null ? null : _epg[ch.name]?.current(_now);
    // A picture-in-picture window shows the picture and nothing else.
    final shown = _overlay && !(_mobile?.inPip ?? false);
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildPlayer(context),
        IgnorePointer(
          ignoring: !shown,
          child: AnimatedOpacity(
            opacity: shown ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Row(
              children: [
                SizedBox(
                  width: 320,
                  // A Material, so the list tiles can paint their selection and ink.
                  child: Material(color: Colors.black.withValues(alpha: 0.72), child: _mobile != null ? _buildTouchChannels(context) : _buildChannels(context)),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        if (_mobile != null)
          IgnorePointer(
            ignoring: !shown,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: SafeArea(
                child: Align(
                  alignment: Alignment.topRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_mobile!.pipSupported)
                        IconButton(tooltip: '小窗播放', onPressed: _enterPip, icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white)),
                      IconButton(
                        key: const Key('live-exit-fullscreen'),
                        tooltip: '退出全屏',
                        onPressed: _toggleImmersive,
                        icon: const Icon(Icons.fullscreen_exit_rounded, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (ch != null)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  // A phone still upright for a moment after asking for landscape has no room beside the list.
                  padding: EdgeInsets.fromLTRB(_mobile != null && MediaQuery.sizeOf(context).width < 700 ? 24 : 352, 24, 32, 28),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xC0000000)]),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ch.name,
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
                      ),
                      if (_catchup != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          '回看：${_catchup!.title}  ${_md(_catchup!.start)} ${_hm(_catchup!.start)}–${_hm(_catchup!.end)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 15),
                        ),
                      ] else if (now != null) ...[
                        const SizedBox(height: 4),
                        Text('正在播放：${now.title}  ${_hm(now.start)}–${_hm(now.end)}', style: const TextStyle(color: Colors.white70, fontSize: 15)),
                        const SizedBox(height: 8),
                        SizedBox(width: 360, child: LinearProgressIndicator(value: now.progressAt(_now), minHeight: 3)),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        _mobile != null
                            ? (_catchup != null ? '左右拖动快退 / 快进   上下滑动调亮度 / 音量   返回退出全屏' : '左右滑动换台   上下滑动调亮度 / 音量   返回退出全屏')
                            : _catchup != null ? '↑/↓ 换台（回到直播）   ←/→ 快退 / 快进   Esc 退出全屏' : '↑/↓ 换台   ←/→ 换线路   Esc 退出全屏',
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// The channel list over the full-screen picture on a touch screen: the groups on top, and touching it keeps it up.
  Widget _buildTouchChannels(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _showOverlay(),
      // Over the dark picture the list is light on dark, whatever the phone's theme.
      child: Theme(
        data: buildDarkTheme(),
        child: Builder(builder: (context) => _touchChannelList(context)),
      ),
    );
  }

  Widget _touchChannelList(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            SizedBox(height: 56, child: _buildGroupChips(context)),
            Expanded(child: _buildChannels(context)),
          ],
        ),
      ),
    );
  }
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String _md(DateTime t) => '${t.month}月${t.day}日';

String _clockText(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// The 「回看」 mark: the picture is a programme played back, not live.
class _CatchupBadge extends StatelessWidget {
  const _CatchupBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.orange.shade700, borderRadius: BorderRadius.circular(6)),
      child: const Text(
        '回看',
        style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Seek bar and times of the programme being played back.
class _CatchupBar extends StatelessWidget {
  const _CatchupBar({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, snap) {
        final duration = player.state.duration;
        final max = duration.inMilliseconds.toDouble();
        final position = snap.data ?? Duration.zero;
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
          child: Row(
            children: [
              StreamBuilder<bool>(
                stream: player.stream.playing,
                initialData: player.state.playing,
                builder: (context, playing) => IconButton(
                  tooltip: '播放 / 暂停 (空格)',
                  onPressed: player.playOrPause,
                  icon: Icon(playing.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
              ),
              Expanded(
                child: Slider(
                  key: const Key('catchup-seek'),
                  value: max <= 0 ? 0 : position.inMilliseconds.toDouble().clamp(0, max),
                  max: max <= 0 ? 1 : max,
                  onChanged: max <= 0 ? null : (v) => player.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Text('${_clockText(position)} / ${_clockText(duration)}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
        );
      },
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Icon(Icons.tv_rounded, color: scheme.onSurfaceVariant);
    return SizedBox(
      width: 48,
      height: 32,
      child: url.isEmpty ? fallback : Image.network(url, fit: BoxFit.contain, headers: engineImageHeaders(context, url), errorBuilder: (_, _, _) => fallback),
    );
  }
}

/// A day's programmes, scrolled so the current one is in view. On a channel with [catchup], programmes that have
/// ended are marked 「回看」 and play back when clicked; the one on air goes back to live.
class _GuideList extends StatefulWidget {
  const _GuideList({
    super.key,
    required this.programs,
    required this.current,
    required this.now,
    this.catchup = false,
    this.playingBack,
    this.onPlayBack,
    this.onLive,
  });

  final List<EpgProgram> programs;
  final int current;
  final DateTime now;
  final bool catchup;
  final EpgProgram? playingBack;
  final ValueChanged<EpgProgram>? onPlayBack;
  final VoidCallback? onLive;

  @override
  State<_GuideList> createState() => _GuideListState();
}

class _GuideListState extends State<_GuideList> {
  static const _rowHeight = 44.0;
  late final _scroll = ScrollController(initialScrollOffset: (widget.current - 2).clamp(0, 1 << 20) * _rowHeight);

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      itemExtent: _rowHeight,
      itemCount: widget.programs.length,
      itemBuilder: (context, i) {
        final p = widget.programs[i];
        final current = i == widget.current;
        final past = p.end.isBefore(widget.now);
        final back = widget.playingBack;
        final playingBack = back != null && back.start == p.start && back.end == p.end;
        // Live again from the programme on air, but only once something is being played back.
        final canBack = widget.catchup && past;
        final canLive = widget.catchup && current && back != null;
        final highlighted = playingBack || (current && back == null);
        final color = highlighted ? scheme.primary : (past && !canBack ? scheme.onSurfaceVariant.withValues(alpha: 0.6) : scheme.onSurface);
        final row = Container(
          decoration: highlighted ? BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(8)) : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                child: Text(
                  _hm(p.start),
                  style: TextStyle(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
              Expanded(
                child: Text(
                  p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontWeight: current ? FontWeight.w700 : FontWeight.w400),
                ),
              ),
              if (playingBack)
                Text('回看中', style: TextStyle(color: scheme.primary, fontSize: 12))
              else if (canBack)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded, size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 2),
                    Text('回看', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
                  ],
                )
              else if (current)
                Text('直播中', style: TextStyle(color: current && back == null ? scheme.primary : scheme.onSurfaceVariant, fontSize: 12)),
            ],
          ),
        );
        if (canBack && !playingBack) return InkWell(borderRadius: BorderRadius.circular(8), onTap: () => widget.onPlayBack?.call(p), child: row);
        if (canLive) return InkWell(borderRadius: BorderRadius.circular(8), onTap: widget.onLive, child: row);
        return row;
      },
    );
  }
}

class _VolumeButton extends StatelessWidget {
  const _VolumeButton({required this.player, required this.onToggleMute});

  final Player player;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snap) {
        final v = snap.data ?? 100;
        return IconButton(
          tooltip: v == 0 ? '取消静音 (M)' : '静音 (M)，滚轮调音量',
          onPressed: onToggleMute,
          icon: Icon(v == 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded),
        );
      },
    );
  }
}
