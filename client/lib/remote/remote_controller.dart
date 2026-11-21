import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'remote_socket.dart';

/// Where a [RemoteController] stands.
enum RemoteLink { connecting, connected, reconnecting, screenGone, refused }

/// This device as a *remote* of another 映舟 (docs/protocol.md "遥控"): one control WebSocket to one screen through
/// the engine's hub. It keeps the screen's latest state, sends keys and commands, and connects again by itself
/// after a drop (a phone that slept, a screen that restarted). The same as the web remote does, for the app.
class RemoteController extends ChangeNotifier {
  RemoteController({
    required this.engineUrl,
    required this.screenId,
    this.token,
    RemoteConnector? connector,
    this.retryBase = const Duration(milliseconds: 500),
  }) : _connector = connector ?? connectRemoteSocket {
    unawaited(_connect());
  }

  final String engineUrl;
  final String screenId;
  final String? token;
  final RemoteConnector _connector;
  final Duration retryBase;

  RemoteLink _link = RemoteLink.connecting;
  RemoteLink get link => _link;

  /// The screen as the hub described it: `{id, name, platform, form, version}`.
  Map<String, Object?> screen = const {};

  /// The screen's last state; empty until the first comes.
  Map<String, Object?> state = const {};

  /// When [state] came, to move the position on while the film plays.
  final _stateClock = Stopwatch();

  /// The last thing the screen could not do, in its own words; cleared when read.
  String? notice;

  RemoteChannel? _channel;
  StreamSubscription<String>? _messages;
  Timer? _retry;
  Timer? _ping;
  int _failures = 0;
  int _seq = 0;
  bool _disposed = false;

  Map<String, Object?>? get player {
    final p = state['player'];
    return p is Map ? p.cast<String, Object?>() : null;
  }

  /// The text field that has the focus on the screen: `{value, hint, secret}`; null when none has.
  Map<String, Object?>? get text {
    final t = state['text'];
    return t is Map ? t.cast<String, Object?>() : null;
  }

  /// Where the film is now: the last position reported, moved on by the time since while it plays.
  Duration get position {
    final p = player;
    if (p == null) return Duration.zero;
    var ms = (p['position'] as num?)?.toDouble() ?? 0;
    if (p['paused'] != true && p['buffering'] != true && (p['error'] as String? ?? '').isEmpty) {
      ms += _stateClock.elapsedMilliseconds * ((p['speed'] as num?)?.toDouble() ?? 1);
    }
    final duration = (p['duration'] as num?)?.toDouble() ?? 0;
    if (duration > 0) ms = min(ms, duration);
    return Duration(milliseconds: ms.round());
  }

  Duration get duration => Duration(milliseconds: ((player?['duration'] as num?) ?? 0).round());

  void _set(RemoteLink link) {
    if (_link == link) return;
    _link = link;
    notifyListeners();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final RemoteChannel channel;
    try {
      channel = await _connector(remoteSocketUri(engineUrl, 'control?screen=${Uri.encodeQueryComponent(screenId)}'), token: token);
    } catch (_) {
      _again();
      return;
    }
    if (_disposed) {
      unawaited(channel.close());
      return;
    }
    _channel = channel;
    _failures = 0;
    _set(RemoteLink.connected);
    _messages = channel.messages.listen(_received, onDone: () => _closed(channel), onError: (Object _) {});
    _ping?.cancel();
    _ping = Timer.periodic(const Duration(seconds: 10), (_) => channel.send('{"type":"ping"}'));
  }

  void _closed(RemoteChannel channel) {
    if (!identical(channel, _channel)) return;
    _channel = null;
    _messages = null;
    _ping?.cancel();
    final code = channel.closeCode;
    if (code == RemoteClose.notAllowed) {
      // Revoked, or LAN sharing went off: trying again will not help until something changes over there.
      state = const {};
      _set(RemoteLink.refused);
      return;
    }
    _set(code == RemoteClose.noScreen || code == RemoteClose.gone ? RemoteLink.screenGone : RemoteLink.reconnecting);
    _again();
  }

  /// A while later, longer each time up to five seconds; a screen that went away may come back (it restarted).
  void _again() {
    if (_disposed) return;
    if (_link == RemoteLink.connecting || _link == RemoteLink.connected) _set(RemoteLink.reconnecting);
    _failures = min(_failures + 1, 4);
    _retry?.cancel();
    _retry = Timer(retryBase * (1 << _failures), () => unawaited(_connect()));
  }

  /// Tries again now (the app came back to the front, or the user asked).
  void retryNow() {
    if (_channel != null || _disposed) return;
    _retry?.cancel();
    _failures = 0;
    unawaited(_connect());
  }

  void _received(String text) {
    final Map<String, Object?> msg;
    try {
      msg = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'screen':
        final s = msg['screen'];
        if (s is Map) screen = s.cast<String, Object?>();
        notifyListeners();
      case 'state':
        final s = msg['state'];
        state = s is Map ? s.cast<String, Object?>() : const {};
        _stateClock
          ..reset()
          ..start();
        notifyListeners();
      case 'result':
        if (msg['ok'] == false && (msg['message'] as String? ?? '').isNotEmpty) {
          notice = msg['message'] as String;
          notifyListeners();
        }
      case 'gone':
        state = const {};
        _set(RemoteLink.screenGone);
    }
  }

  /// Sends a command; false when not connected.
  bool send(String name, [Map<String, Object?> args = const {}]) {
    final channel = _channel;
    if (channel == null) return false;
    channel.send(jsonEncode({'type': 'command', 'id': '${++_seq}', 'name': name, 'args': args}));
    return true;
  }

  /// One step of a key: `press`, or `down` / `repeat` / `up` while it is held.
  bool key(String key, [String action = 'press']) => send('key', {'key': key, 'action': action});

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ping?.cancel();
    _messages?.cancel();
    unawaited(_channel?.close());
    super.dispose();
  }
}
