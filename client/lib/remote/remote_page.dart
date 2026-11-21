import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/discovery.dart';
import '../engine/engine_client.dart';
import '../engine/lan.dart';
import '../engine/models.dart' show EngineException;
import 'remote_controller.dart';
import 'remote_socket.dart';

/// 「遥控另一台映舟」 on a phone or tablet: find the engine the other 映舟 uses (the one this app uses, one found on
/// the LAN, or an address), pair with it once, pick one of its screens, and drive it ([RemoteControlPage]). The app
/// counterpart of the engine's web remote.
class RemoteFinderPage extends StatefulWidget {
  const RemoteFinderPage({super.key, this.discovery, this.connector});

  /// Tests pass their own; by default mDNS through the platform.
  final EngineDiscovery? discovery;

  /// Tests: how the control socket is opened.
  final RemoteConnector? connector;

  @override
  State<RemoteFinderPage> createState() => _RemoteFinderPageState();
}

class _RemoteFinderPageState extends State<RemoteFinderPage> {
  late final EngineDiscovery? _discovery = widget.discovery ?? createEngineDiscovery();
  List<DiscoveredEngine> _found = const [];
  final _address = TextEditingController();
  final _code = TextEditingController();

  /// The engine chosen, its screens, and what stands in the way.
  String? _engine;
  List<Map<String, Object?>>? _screens;
  bool _needsPairing = false;
  String? _problem;
  bool _working = false;
  Timer? _poll;

  static String _tokenKey(String url) {
    final u = Uri.tryParse(url);
    return 'remote.token|${u == null ? url : '${u.scheme}://${u.host}:${u.port}'}';
  }

  static bool _isLocal(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost';
  }

  @override
  void initState() {
    super.initState();
    final discovery = _discovery;
    if (discovery != null) {
      unawaited(
        discovery
            .start((engines) {
              if (mounted) setState(() => _found = engines);
            })
            .catchError((Object _) {}),
      );
    }
    // The engine this app uses, when it is on another device: most likely the one the screen uses too.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = AppScope.read(context);
      if (mounted && app.connected && !_isLocal(app.engineUrl)) _choose(app.engineUrl);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_discovery?.stop());
    _address.dispose();
    _code.dispose();
    super.dispose();
  }

  /// The token for [url]: one paired here, else the app's own when it uses that engine.
  String? _token(String url) {
    final app = AppScope.read(context);
    final saved = app.settings.getString(_tokenKey(url));
    if (saved != null && saved.isNotEmpty) return saved;
    return url == app.engineUrl ? app.engineToken : null;
  }

  EngineClient _client(String url) => AppScope.read(context).clientFactory(Uri.parse(url))..token = _token(url);

  void _choose(String url) {
    setState(() {
      _engine = url.trim().replaceAll(RegExp(r'/+$'), '');
      _screens = null;
      _needsPairing = false;
      _problem = null;
    });
    unawaited(_load());
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_engine != null && !_needsPairing && !_working) unawaited(_load());
    });
  }

  Future<void> _load() async {
    final url = _engine;
    if (url == null) return;
    final client = _client(url);
    try {
      final list = await client.send('GET', 'remote/screens') as List;
      if (!mounted || url != _engine) return;
      setState(() {
        _screens = [for (final s in list) (s as Map).cast<String, Object?>()];
        _needsPairing = false;
        _problem = null;
      });
    } on EngineException catch (e) {
      if (!mounted || url != _engine) return;
      setState(() {
        _needsPairing = e.statusCode == 401;
        _problem = switch (e.statusCode) {
          401 => null,
          403 => e.message,
          404 => '这台引擎的版本还没有遥控功能',
          _ => '连不上这台引擎：手机和它要在同一个 Wi-Fi 或路由器下',
        };
      });
      if (_needsPairing) unawaited(_askForCode(url));
    } finally {
      client.close();
    }
  }

  /// An engine without a screen prints a pairing code when asked for one (`PAIR_CODE_REQUIRED` is the answer).
  Future<void> _askForCode(String url) async {
    final client = AppScope.read(context).clientFactory(Uri.parse(url));
    try {
      await client.pair('', deviceName());
    } catch (_) {
      // Expected: the code is entered next.
    } finally {
      client.close();
    }
  }

  Future<void> _pair() async {
    final url = _engine;
    if (url == null) return;
    setState(() {
      _working = true;
      _problem = null;
    });
    final client = AppScope.read(context).clientFactory(Uri.parse(url));
    try {
      final token = await client.pair(_code.text.replaceAll(RegExp(r'\D'), ''), deviceName());
      if (!mounted) return;
      await AppScope.read(context).settings.setString(_tokenKey(url), token);
      _code.clear();
      setState(() => _needsPairing = false);
      await _load();
    } on EngineException catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      client.close();
      if (mounted) setState(() => _working = false);
    }
  }

  void _open(Map<String, Object?> screen) {
    final url = _engine!;
    _poll?.cancel();
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => RemoteControlPage(
              engineUrl: url,
              screenId: '${screen['id']}',
              screenName: '${screen['name'] ?? '映舟'}',
              token: _token(url),
              connector: widget.connector,
            ),
          ),
        )
        .then((_) {
          if (mounted && _engine == url) _choose(url);
        });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    final app = AppScope.of(context);
    final engines = <(String, String)>[
      if (app.connected && !_isLocal(app.engineUrl)) ('这台手机用的引擎', app.engineUrl),
      for (final e in _found)
        if (e.url != app.engineUrl) (e.name, e.url),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('遥控另一台映舟'),
        leading: _engine == null ? null : IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _engine = null)),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: _engine == null ? _engineList(engines, small) : _screenList(small, scheme),
        ),
      ),
    );
  }

  List<Widget> _engineList(List<(String, String)> engines, TextStyle small) => [
    Text('先选那台映舟用的引擎。电视或电脑上的映舟要打开「源 → 局域网 → 允许手机遥控」。', style: small),
    const SizedBox(height: 12),
    if (engines.isEmpty) Text('正在局域网里查找…', style: small),
    for (final (name, url) in engines)
      Card(
        child: ListTile(
          key: Key('remote-engine-$url'),
          leading: const Icon(Icons.dns_outlined),
          title: Text(name),
          subtitle: Text(url),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _choose(url),
        ),
      ),
    const SizedBox(height: 16),
    Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('remote-address'),
            controller: _address,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '或者填引擎地址', hintText: 'http://192.168.1.5:9978'),
            onSubmitted: (v) => v.trim().isEmpty ? null : _choose(v),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton.tonal(onPressed: () => _address.text.trim().isEmpty ? null : _choose(_address.text), child: const Text('连接')),
      ],
    ),
  ];

  List<Widget> _screenList(TextStyle small, ColorScheme scheme) {
    final screens = _screens;
    const forms = {'tv': '电视模式', 'desktop': '桌面', 'phone': '手机', 'tablet': '平板'};
    return [
      Text(_engine!, style: small),
      const SizedBox(height: 12),
      if (_needsPairing) ...[
        const Text('和这台引擎配对一次：输入那台映舟在「源 → 局域网」里显示的 6 位配对码。'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('remote-code'),
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 7,
          autofocus: true,
          style: const TextStyle(fontSize: 28, letterSpacing: 6),
          decoration: const InputDecoration(labelText: '配对码'),
          onSubmitted: (_) => _pair(),
        ),
        FilledButton(key: const Key('remote-pair'), onPressed: _working ? null : _pair, child: const Text('配对')),
      ],
      if (_problem != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_problem!, style: TextStyle(color: scheme.error))),
      if (!_needsPairing && _problem == null && screens == null) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      if (screens != null && screens.isEmpty) Text('这台引擎上还没有可以遥控的屏幕。在电视或电脑上的映舟里打开「源 → 局域网 → 允许手机遥控」，它会出现在这里。', style: small),
      for (final s in screens ?? const <Map<String, Object?>>[])
        Card(
          child: ListTile(
            key: Key('remote-screen-${s['id']}'),
            leading: Icon(s['form'] == 'tv' ? Icons.tv_rounded : Icons.desktop_windows_outlined),
            title: Text('${s['name'] ?? '映舟'}'),
            subtitle: Text([forms[s['form']] ?? '', '${s['title'] ?? ''}'].where((t) => t.isNotEmpty).join(' · ')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(s),
          ),
        ),
    ];
  }
}

/// A phone as the remote control of one screen: D-pad, back / home / menu, transport, volume, what plays with its
/// seek bar, the choices of the player (lines, episodes, speed, subtitles…) and typing into the screen's text field.
/// Every press gives a light haptic tick.
class RemoteControlPage extends StatefulWidget {
  const RemoteControlPage({super.key, required this.engineUrl, required this.screenId, this.screenName = '映舟', this.token, this.connector});

  final String engineUrl;
  final String screenId;
  final String screenName;
  final String? token;
  final RemoteConnector? connector;

  @override
  State<RemoteControlPage> createState() => _RemoteControlPageState();
}

class _RemoteControlPageState extends State<RemoteControlPage> with WidgetsBindingObserver {
  late final RemoteController _remote = RemoteController(
    engineUrl: widget.engineUrl,
    screenId: widget.screenId,
    token: widget.token,
    connector: widget.connector,
  )..addListener(_changed);
  final _text = TextEditingController();
  Timer? _tick;
  Timer? _textTimer;
  DateTime _typedAt = DateTime(0);
  double? _seeking;
  double? _volume;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The position moves on between states while the film plays.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final p = _remote.player;
      if (mounted && p != null && p['paused'] != true) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _textTimer?.cancel();
    _remote
      ..removeListener(_changed)
      ..dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _remote.retryNow();
  }

  void _changed() {
    if (!mounted) return;
    final notice = _remote.notice;
    if (notice != null) {
      _remote.notice = null;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(notice), duration: const Duration(seconds: 2)));
    }
    // What the screen's field holds, unless this phone is the one typing.
    final value = _remote.text?['value'];
    if (value is String && value != _text.text && DateTime.now().difference(_typedAt) > const Duration(milliseconds: 1200)) {
      _text.value = TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length));
    }
    setState(() {});
  }

  void _send(String name, [Map<String, Object?> args = const {}]) {
    unawaited(HapticFeedback.selectionClick());
    if (!_remote.send(name, args)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('还没有连上屏幕'), duration: Duration(seconds: 1)));
    }
  }

  void _typed(String value) {
    _typedAt = DateTime.now();
    _textTimer?.cancel();
    _textTimer = Timer(const Duration(milliseconds: 60), () => _remote.send('text', {'value': value}));
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String get _status => switch (_remote.link) {
    RemoteLink.connecting => '正在连接…',
    RemoteLink.connected => _remote.state.isEmpty ? '已连接' : (('${_remote.state['title'] ?? ''}').isEmpty ? '已连接' : '${_remote.state['title']}'),
    RemoteLink.reconnecting => '连接断开，正在重连…',
    RemoteLink.screenGone => '屏幕不在线，等它回来…',
    RemoteLink.refused => '这台手机不能再遥控了：配对被撤销，或局域网共享关了',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _remote.player;
    final text = _remote.text;
    final name = '${_remote.screen['name'] ?? widget.screenName}';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name),
            Text(
              _status,
              key: const Key('remote-link'),
              style: TextStyle(fontSize: 12, color: _remote.link == RemoteLink.connected ? scheme.primary : scheme.error),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          if (_remote.state['canTv'] == true)
            TextButton(
              onPressed: () => _send('uiMode', {'mode': _remote.state['form'] == 'tv' ? 'auto' : 'tv'}),
              child: Text(_remote.state['form'] == 'tv' ? '电视模式：开' : '电视模式：关'),
            ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              if (text != null) _textBar(text),
              if (p != null) _nowPlaying(p, scheme),
              const SizedBox(height: 12),
              Center(child: _dpad((c.maxWidth * 0.78).clamp(220, 320).toDouble(), scheme)),
              const SizedBox(height: 16),
              Row(
                children: [
                  _wide(Icons.undo_rounded, '返回', () => _remote.key('back') ? HapticFeedback.selectionClick() : null, const Key('remote-back')),
                  const SizedBox(width: 10),
                  _wide(Icons.home_outlined, '主页', () => _send('home'), const Key('remote-home')),
                  const SizedBox(width: 10),
                  _wide(Icons.menu_rounded, '菜单', () => _remote.key('menu') ? HapticFeedback.selectionClick() : null, const Key('remote-menu')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _round(Icons.skip_previous_rounded, '上一集', () => _send('previous')),
                  _round(Icons.replay_10_rounded, '后退 10 秒', () => _send('seekBy', {'delta': -10000})),
                  _round(
                    p != null && p['paused'] != true ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    '播放或暂停',
                    () => _send('toggle'),
                    key: const Key('remote-toggle'),
                    filled: true,
                  ),
                  _round(Icons.forward_10_rounded, '前进 10 秒', () => _send('seekBy', {'delta': 10000})),
                  _round(Icons.skip_next_rounded, '下一集', () => _send('next')),
                ],
              ),
              const SizedBox(height: 8),
              _volumeRow(p),
              if (p != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('remote-choices'),
                  onPressed: () => _choices(context),
                  icon: const Icon(Icons.tune_rounded),
                  label: Text(p['kind'] == 'live' ? '频道 · 线路' : '选集 · 线路 · 倍速 · 字幕'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _textBar(Map<String, Object?> field) {
    final hint = '${field['hint'] ?? ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: TextField(
          key: const Key('remote-text'),
          controller: _text,
          obscureText: field['secret'] == true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(labelText: hint.isEmpty ? '屏幕上的输入框' : hint, helperText: '在这里打字，屏幕上同步；回车确认'),
          onChanged: _typed,
          onSubmitted: (v) {
            _textTimer?.cancel();
            _remote.send('text', {'value': v});
            _send('submit');
          },
        ),
      ),
    );
  }

  Widget _nowPlaying(Map<String, Object?> p, ColorScheme scheme) {
    final duration = _remote.duration;
    final position = _remote.position;
    final seekable = p['seekable'] == true && duration > Duration.zero;
    final error = '${p['error'] ?? ''}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${p['title'] ?? ''}', key: const Key('remote-title'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(error.isNotEmpty ? error : '${p['subtitle'] ?? ''}', style: TextStyle(color: error.isNotEmpty ? scheme.error : scheme.onSurfaceVariant, fontSize: 13), maxLines: 2),
            if (error.isNotEmpty) TextButton(onPressed: () => _send('retry'), child: const Text('重试')),
            if (seekable)
              Row(
                children: [
                  Text(_clock(Duration(milliseconds: (_seeking ?? position.inMilliseconds.toDouble()).round())), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                  Expanded(
                    child: Slider(
                      key: const Key('remote-seek'),
                      max: duration.inMilliseconds.toDouble(),
                      value: (_seeking ?? position.inMilliseconds.toDouble()).clamp(0, duration.inMilliseconds.toDouble()),
                      onChanged: (v) => setState(() => _seeking = v),
                      // Once, when the finger is lifted.
                      onChangeEnd: (v) {
                        setState(() => _seeking = null);
                        _send('seek', {'position': v.round()});
                      },
                    ),
                  ),
                  Text(_clock(duration), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _dpad(double size, ColorScheme scheme) {
    Widget arrow(String key, IconData icon, Alignment at) => Align(
      alignment: at,
      child: _HoldButton(
        key: Key('remote-key-$key'),
        onDown: () => _remote.key(key, 'down'),
        onRepeat: () => _remote.key(key, 'repeat'),
        onUp: () => _remote.key(key, 'up'),
        child: SizedBox(width: size * 0.3, height: size * 0.3, child: Icon(icon, size: size * 0.16)),
      ),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.surfaceContainerHigh),
      child: Stack(
        children: [
          arrow('up', Icons.keyboard_arrow_up_rounded, Alignment.topCenter),
          arrow('down', Icons.keyboard_arrow_down_rounded, Alignment.bottomCenter),
          arrow('left', Icons.keyboard_arrow_left_rounded, Alignment.centerLeft),
          arrow('right', Icons.keyboard_arrow_right_rounded, Alignment.centerRight),
          Center(
            child: _HoldButton(
              key: const Key('remote-key-ok'),
              onDown: () => _remote.key('ok', 'down'),
              onRepeat: () => _remote.key('ok', 'repeat'),
              onUp: () => _remote.key('ok', 'up'),
              child: Container(
                width: size * 0.38,
                height: size * 0.38,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: scheme.primary),
                child: Text('OK', style: TextStyle(color: scheme.onPrimary, fontSize: 22, fontWeight: FontWeight.w800)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wide(IconData icon, String label, VoidCallback onTap, Key key) => Expanded(
    child: FilledButton.tonalIcon(
      key: key,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      onPressed: onTap,
      icon: Icon(icon),
      label: Text(label),
    ),
  );

  Widget _round(IconData icon, String label, VoidCallback onTap, {Key? key, bool filled = false}) => IconButton.filledTonal(
    key: key,
    tooltip: label,
    iconSize: 30,
    style: IconButton.styleFrom(minimumSize: const Size(56, 56), backgroundColor: filled ? Theme.of(context).colorScheme.primary : null, foregroundColor: filled ? Theme.of(context).colorScheme.onPrimary : null),
    onPressed: onTap,
    icon: Icon(icon),
  );

  Widget _volumeRow(Map<String, Object?>? p) {
    final muted = p != null && (p['muted'] == true || p['volume'] == 0);
    final volume = _volume ?? ((p?['volume'] as num?)?.toDouble() ?? 100);
    return Row(
      children: [
        IconButton(tooltip: '静音', onPressed: () => _send('mute'), icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded)),
        IconButton(tooltip: '音量减', onPressed: () => _send('volumeBy', {'delta': -5}), icon: const Icon(Icons.remove_rounded)),
        Expanded(
          child: Slider(
            key: const Key('remote-volume'),
            max: 100,
            value: volume.clamp(0, 100),
            onChanged: p == null ? null : (v) => setState(() => _volume = v),
            onChangeEnd: (v) {
              setState(() => _volume = null);
              _send('volume', {'value': v.round()});
            },
          ),
        ),
        IconButton(tooltip: '音量加', onPressed: () => _send('volumeBy', {'delta': 5}), icon: const Icon(Icons.add_rounded)),
      ],
    );
  }

  /// The player's choices, following the screen while open.
  void _choices(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => ListenableBuilder(
        listenable: _remote,
        builder: (context, _) {
          final p = _remote.player;
          if (p == null) return const SizedBox(height: 120, child: Center(child: Text('屏幕上现在没有在播放')));
          List<Object?> list(String name) => p[name] is List ? p[name] as List : const [];
          Widget section(String title, List<Object?> items, bool Function(int i, Object? item) chosen, String Function(int i, Object? item) label, void Function(int i, Object? item) pick) {
            if (items.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < items.length; i++)
                        ChoiceChip(label: Text(label(i, items[i])), selected: chosen(i, items[i]), onSelected: (_) => pick(i, items[i])),
                    ],
                  ),
                ],
              ),
            );
          }

          String nameOf(Object? t) => t is Map ? '${t['name'] ?? ''}' : '$t';
          String idOf(Object? t) => t is Map ? '${t['id'] ?? ''}' : '';
          final live = p['kind'] == 'live';
          return SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                section('倍速', list('speeds'), (_, v) => v == p['speed'], (_, v) => '${v}x', (_, v) => _send('speed', {'value': v})),
                section('分组', list('groups'), (i, _) => i == p['group'], (_, v) => '$v', (i, _) => _send('group', {'index': i})),
                section('线路', list('lines').length > 1 ? list('lines') : const [], (i, _) => i == p['line'], (_, v) => '$v', (i, _) => _send('line', {'index': i})),
                section(live ? '频道' : '选集', list('episodes'), (i, _) => i == p['episode'], (_, v) => '$v', (i, _) => _send('episode', {'index': i})),
                section('字幕', list('subtitles'), (_, t) => idOf(t) == p['subtitleId'], (_, t) => nameOf(t), (_, t) => _send('subtitle', {'id': idOf(t)})),
                section('音轨', list('audios').length > 1 ? list('audios') : const [], (_, t) => idOf(t) == p['audioId'], (_, t) => nameOf(t), (_, t) => _send('audio', {'id': idOf(t)})),
                Wrap(
                  spacing: 8,
                  children: [
                    if (p['danmaku'] is bool) FilterChip(label: const Text('弹幕'), selected: p['danmaku'] == true, onSelected: (_) => _send('danmaku')),
                    if (p['canFullscreen'] == true) FilterChip(label: const Text('全屏'), selected: p['fullscreen'] == true, onSelected: (_) => _send('fullscreen')),
                    ActionChip(label: const Text('退出播放'), onPressed: () => _send('stop')),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A button that can be held, like a remote's key: [onDown] at once (with a haptic tick), [onRepeat] while it is
/// held, [onUp] when it is let go.
class _HoldButton extends StatefulWidget {
  const _HoldButton({super.key, required this.child, required this.onDown, this.onRepeat, this.onUp});

  final Widget child;
  final VoidCallback onDown;
  final VoidCallback? onRepeat;
  final VoidCallback? onUp;

  @override
  State<_HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<_HoldButton> {
  Timer? _delay;
  Timer? _repeat;
  bool _held = false;

  void _down() {
    if (_held) _up();
    setState(() => _held = true);
    unawaited(HapticFeedback.selectionClick());
    widget.onDown();
    final repeat = widget.onRepeat;
    if (repeat != null) _delay = Timer(const Duration(milliseconds: 380), () => _repeat = Timer.periodic(const Duration(milliseconds: 110), (_) => repeat()));
  }

  void _up() {
    if (!_held) return;
    _delay?.cancel();
    _repeat?.cancel();
    if (mounted) setState(() => _held = false);
    widget.onUp?.call();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _up(),
        child: AnimatedScale(scale: _held ? 0.92 : 1, duration: const Duration(milliseconds: 80), child: widget.child),
      ),
    );
  }
}
