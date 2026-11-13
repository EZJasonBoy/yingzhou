import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app_state.dart';
import '../desktop/desktop_window.dart';
import '../engine/engine_client.dart';
import '../engine/live_models.dart';
import '../settings.dart';
import 'browse_page.dart' show errorText;

/// Live TV: the config's `lives` as sources, channel groups, a player and the programme guide.
///
/// Wide windows show groups | channels | player + guide side by side; narrow ones stack them. Keys: ↑/↓ change
/// channel, ←/→ change line, PageUp/PageDown change group, F or double-click toggles fullscreen (the channel list
/// becomes an overlay), M mutes, the wheel changes the volume. A line that fails, or shows nothing for 15 seconds,
/// is replaced by the channel's next line. The last channel is remembered.
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
  VideoController? _video;
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

  bool _immersive = false;
  bool _overlay = true;
  Timer? _overlayTimer;
  String? _osd;
  Timer? _osdTimer;

  static const _lastKey = 'live.last';
  static const _volumeKey = 'player.volume';

  AppState get _state => AppScope.read(context);
  EngineClient get _client => _state.client;
  SettingsStore get _settings => _state.settings;
  DesktopWindow get _window => DesktopWindow.instance;

  Player get _player {
    final existing = _playerOrNull;
    if (existing != null) return existing;
    final player = Player();
    _playerOrNull = player;
    _video = VideoController(player);
    final v = double.tryParse(_settings.getString(_volumeKey) ?? '');
    if (v != null) player.setVolume(v.clamp(0, 100));
    _subs.add(
      player.stream.error.listen((e) {
        // Errors while a line is playing (a lost segment) are mpv's business; one that keeps the picture from
        // starting means the line is dead.
        if (!_opening && mounted && (_watchdog != null || !(_playerOrNull?.state.playing ?? false))) _nextLine('线路 ${_line + 1} 无法播放');
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
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      _epg.clear();
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
      _line = line.clamp(0, ch.urls.length - 1);
      _status = ch.urls.length > 1 ? '正在打开 线路 ${_line + 1}/${ch.urls.length}…' : '正在打开…';
    });
    _settings.setString(_lastKey, '$_source\t${list.groups[group].name}\t${ch.name}');
    _window.title = '${ch.name} - TVBox Next';
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
    // Nothing on screen after a while: this line is dead.
    _watchdog = Timer(const Duration(seconds: 15), () => _nextLine('线路 ${_line + 1} 没有画面'));
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
    setState(() => _immersive = !_immersive);
    widget.onImmersiveChanged?.call(_immersive);
    if (_window.supported) _window.fullScreen = _immersive;
    if (_immersive) _showOverlay();
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
      _switchLine(-1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _switchLine(1);
    } else if (key == LogicalKeyboardKey.pageUp) {
      _stepGroup(-1);
    } else if (key == LogicalKeyboardKey.pageDown) {
      _stepGroup(1);
    } else if (key == LogicalKeyboardKey.keyF) {
      _toggleImmersive();
    } else if (key == LogicalKeyboardKey.escape && _immersive) {
      _toggleImmersive();
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
    if (!state.hasConfig) {
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
    return Focus(
      focusNode: _focus,
      autofocus: widget.visible,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: _immersive ? Colors.black : null,
        body: SafeArea(child: body),
      ),
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
    if (!wide) {
      return Column(
        children: [
          AspectRatio(aspectRatio: 16 / 9, child: player),
          _buildNowBar(context),
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
              child: Text(s.supported ? s.name : '${s.name}（暂不支持）', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (i) {
          if (i == null || i == _source) return;
          setState(() {
            _source = i;
            _epg.clear();
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
    final line = ch.urls.length > 1 ? '线路 ${_line + 1}/${ch.urls.length}${ch.urls[_line].label.isEmpty ? '' : ' · ${ch.urls[_line].label}'}' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(ch.name, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                if (now != null || line.isNotEmpty)
                  Text([if (now != null) '正在播放：${now.title}', if (line.isNotEmpty) line].join('   '), style: TextStyle(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (ch.urls.length > 1) IconButton(tooltip: '换线路 (→)', onPressed: () => _switchLine(1), icon: const Icon(Icons.swap_horiz_rounded)),
          _VolumeButton(player: _player, onToggleMute: _toggleMute),
          if (_window.supported) IconButton(tooltip: '全屏 (F / 双击)', onPressed: _toggleImmersive, icon: const Icon(Icons.fullscreen_rounded)),
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
    final day = _epg[ch.name];
    if (day == null) return const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)));
    if (day.programs.isEmpty) {
      return Center(
        child: Text('暂无节目单', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    final current = day.programs.indexWhere((p) => p.isOnAt(_now));
    return _GuideList(programs: day.programs, current: current, now: _now);
  }

  Widget _buildPlayer(BuildContext context) {
    return MouseRegion(
      onHover: _immersive ? (_) => _showOverlay() : null,
      cursor: _immersive && !_overlay ? SystemMouseCursors.none : SystemMouseCursors.basic,
      child: Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) _changeVolume(e.scrollDelta.dy < 0 ? 5 : -5);
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _window.supported ? _toggleImmersive : null,
          onTap: () {
            _focus.requestFocus();
            if (_immersive) _showOverlay();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_video != null) Video(controller: _video!, controls: NoVideoControls, fill: Colors.black) else const ColoredBox(color: Colors.black),
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
            ],
          ),
        ),
      ),
    );
  }

  /// Fullscreen: the picture alone; moving the mouse or a key shows the channel list and what is on.
  Widget _buildImmersive(BuildContext context) {
    final ch = _channel;
    final now = ch == null ? null : _epg[ch.name]?.current(_now);
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildPlayer(context),
        IgnorePointer(
          ignoring: !_overlay,
          child: AnimatedOpacity(
            opacity: _overlay ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: Row(
              children: [
                SizedBox(
                  width: 320,
                  // A Material, so the list tiles can paint their selection and ink.
                  child: Material(color: Colors.black.withValues(alpha: 0.72), child: _buildChannels(context)),
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
        if (ch != null)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _overlay ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(352, 24, 32, 28),
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
                      if (now != null) ...[
                        const SizedBox(height: 4),
                        Text('正在播放：${now.title}  ${_hm(now.start)}–${_hm(now.end)}', style: const TextStyle(color: Colors.white70, fontSize: 15)),
                        const SizedBox(height: 8),
                        SizedBox(width: 360, child: LinearProgressIndicator(value: now.progressAt(_now), minHeight: 3)),
                      ],
                      const SizedBox(height: 8),
                      const Text('↑/↓ 换台   ←/→ 换线路   Esc 退出全屏', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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
      child: url.isEmpty ? fallback : Image.network(url, fit: BoxFit.contain, errorBuilder: (_, _, _) => fallback),
    );
  }
}

/// Today's programmes, scrolled so the current one is in view.
class _GuideList extends StatefulWidget {
  const _GuideList({required this.programs, required this.current, required this.now});

  final List<EpgProgram> programs;
  final int current;
  final DateTime now;

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
        final color = current ? scheme.primary : (past ? scheme.onSurfaceVariant.withValues(alpha: 0.6) : scheme.onSurface);
        return Container(
          decoration: current ? BoxDecoration(color: scheme.primaryContainer.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(8)) : null,
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
              if (current) Text('直播中', style: TextStyle(color: scheme.primary, fontSize: 12)),
            ],
          ),
        );
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
