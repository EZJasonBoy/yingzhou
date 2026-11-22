import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../engine/discovery.dart' show deviceName;
import '../settings.dart';
import 'remote_host.dart';
import 'remote_socket.dart';

/// Where the agent stands.
enum RemoteAgentStatus {
  /// 「允许手机遥控」 is off, or there is no engine to register with.
  off,
  connecting,

  /// Registered: remotes paired with the engine can see and drive this screen.
  online,

  /// The engine answers but is from before the remote control.
  unsupported,

  /// The engine does not answer; trying again.
  offline,
}

/// What a command came to, when it answers with more than done or not: the log page, the crash record, the settings
/// asked for ([data], a JSON object the engine passes on to the remote that asked), and why not when it failed.
///
/// A command may also answer with null (done) or a sentence (why not), as all the older ones do.
class RemoteResult {
  const RemoteResult.ok([this.data]) : error = null;
  const RemoteResult.failed(String this.error, [this.data]);

  /// Why it was not done, for the person holding the remote; null when it was.
  final String? error;
  final Map<String, Object?>? data;
}

/// This app as a *screen* of the LAN remote control (docs/protocol.md, "遥控"; the engine's `RemoteHub`).
///
/// While 「允许手机遥控」 is on and the app has an engine, the agent keeps a WebSocket to that engine's
/// `/api/v1/remote/screen`, says who it is (a stable id and a name kept in the settings), reports the screen's state
/// whenever it changes, and does what the remotes ask. While it is off the agent is not connected: the engine does
/// not know this screen, and nothing can drive it.
///
/// What the state is and how a command is done comes from outside ([collect], [perform]: remote_screen.dart), so
/// this class is only the connection: connect, hello, publish, answer, come back after a drop.
class RemoteAgent extends ChangeNotifier {
  RemoteAgent({
    required this.settings,
    required this.collect,
    required this.perform,
    RemoteConnector? connector,
    this.probe,
    this.platform = '',
    this.version = '',
    this.retryBase = const Duration(seconds: 1),
  }) : _connector = connector ?? connectRemoteSocket {
    RemoteHost.instance.addListener(_changed);
  }

  final SettingsStore settings;

  /// The screen's state now (remote_screen.dart puts it together).
  final Map<String, Object?> Function() collect;

  /// Does a remote's command: null when done, else why not, in a sentence; or a [RemoteResult] that carries data.
  final Future<Object?> Function(String name, Map<String, Object?> args) perform;
  final RemoteConnector _connector;

  /// After a failed connection: the HTTP status of the engine's `GET /api/v1/remote/screens` (0 when it does not
  /// answer), to tell an engine without the remote control (404) from one that is not there.
  final Future<int> Function()? probe;
  final String platform;
  final String version;
  final Duration retryBase;

  static const enabledKey = 'remote.enabled';
  static const idKey = 'remote.screenId';
  static const nameKey = 'remote.screenName';

  /// With several remotes or a film that plays, how often the state is sent again without anything else changing
  /// (remotes move the position on by themselves in between).
  static const refresh = Duration(seconds: 5);

  /// The longest message the engine takes from a screen (`RemoteHub.MAX_SCREEN_MESSAGE`, in UTF-16 units as Dart
  /// counts a string's length too); a longer one would end the connection. Answers stay a little below it.
  static const maxMessage = 512 * 1024;
  static const maxAnswer = maxMessage - 4096;

  // ---- settings ----

  /// 「允许手机遥控」: off until the user switches it on.
  bool get enabled => settings.getString(enabledKey) == '1';

  Future<void> setEnabled(bool on) async {
    if (on == enabled) return;
    await settings.setString(enabledKey, on ? '1' : '0');
    _update();
    notifyListeners();
  }

  /// This screen's id on every engine it registers with: made once, kept for good, so a remote finds "its" screen again.
  String get screenId {
    final saved = settings.getString(idKey);
    if (saved != null && RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(saved)) return saved;
    final random = Random.secure();
    final id = 'scr-${List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join()}';
    settings.setString(idKey, id);
    return id;
  }

  /// What remotes call this screen: the user's name for it, else the device's.
  String get screenName {
    final saved = settings.getString(nameKey)?.trim() ?? '';
    return saved.isNotEmpty ? saved : deviceName();
  }

  Future<void> setScreenName(String name) async {
    await settings.setString(nameKey, name.trim());
    notifyListeners();
    _reconnect();
  }

  // ---- what it is connected to ----

  String _engineUrl = '';
  String? _token;
  bool _engineUp = false;
  String _form = 'desktop';

  /// The app's engine changed, came up or went away ([AppState]).
  void bind({required String engineUrl, required bool connected, String? token}) {
    final same = engineUrl == _engineUrl && token == _token;
    _engineUrl = engineUrl;
    _token = token;
    _engineUp = connected;
    if (!same) {
      _reconnect();
    } else {
      _update();
    }
  }

  /// The layout this screen is in (`tv`, `desktop`, `phone`, `tablet`), told to the engine with the hello.
  set form(String value) {
    if (value == _form) return;
    _form = value;
    _reconnect();
  }

  RemoteAgentStatus _status = RemoteAgentStatus.off;
  RemoteAgentStatus get status => _status;

  /// The remotes connected to this screen now, by their device names.
  List<String> controllers = const [];

  RemoteChannel? _channel;
  StreamSubscription<String>? _messages;
  bool _welcomed = false;
  bool _connecting = false;
  int _generation = 0;
  int _failures = 0;
  Timer? _retry;
  Timer? _debounce;
  Timer? _refresh;
  String _lastSent = '';
  bool _disposed = false;

  bool get _wanted => !_disposed && !kIsWeb && enabled && _engineUp && _engineUrl.isNotEmpty;

  void _setStatus(RemoteAgentStatus status) {
    if (status == _status) return;
    _status = status;
    notifyListeners();
  }

  void _update() {
    if (!_wanted) {
      _drop();
      _setStatus(RemoteAgentStatus.off);
      return;
    }
    if (_channel == null && !_connecting && _retry == null) unawaited(_connect());
  }

  void _reconnect() {
    _drop();
    _failures = 0;
    _update();
  }

  /// Ends the connection, if any, and whatever was on its way to one.
  void _drop() {
    _generation++;
    _retry?.cancel();
    _retry = null;
    _debounce?.cancel();
    _debounce = null;
    _refresh?.cancel();
    _refresh = null;
    _messages?.cancel();
    _messages = null;
    final channel = _channel;
    _channel = null;
    _welcomed = false;
    _connecting = false;
    _lastSent = '';
    if (controllers.isNotEmpty) {
      controllers = const [];
      RemoteHost.instance.watched = false;
      onControllersGone?.call();
      notifyListeners();
    }
    if (channel != null) unawaited(channel.close());
  }

  /// Called when the last remote left or the connection ended: whatever a remote was holding down is let go.
  VoidCallback? onControllersGone;

  Future<void> _connect() async {
    final generation = ++_generation;
    _connecting = true;
    if (_status != RemoteAgentStatus.unsupported && _status != RemoteAgentStatus.offline) _setStatus(RemoteAgentStatus.connecting);
    final RemoteChannel channel;
    try {
      channel = await _connector(remoteSocketUri(_engineUrl, 'screen'), token: _token);
    } catch (_) {
      if (generation != _generation) return;
      _connecting = false;
      final status = await probe?.call() ?? 0;
      if (generation != _generation) return;
      _failed(status == 404 ? RemoteAgentStatus.unsupported : RemoteAgentStatus.offline);
      return;
    }
    if (generation != _generation) {
      unawaited(channel.close());
      return;
    }
    _connecting = false;
    _channel = channel;
    _messages = channel.messages.listen(
      (text) => _received(generation, text),
      onDone: () {
        if (generation != _generation) return;
        _drop();
        _failed(RemoteAgentStatus.offline);
      },
      onError: (Object _) {},
    );
    channel.send(jsonEncode({'type': 'hello', 'id': screenId, 'name': screenName, 'platform': platform, 'form': _form, 'version': version}));
  }

  /// Not connected, though it should be: tries again, a little later each time (an engine without the remote
  /// control is asked once a minute, in case it is updated).
  void _failed(RemoteAgentStatus status) {
    _setStatus(status);
    if (!_wanted) return;
    _failures = min(_failures + 1, 5);
    final wait = status == RemoteAgentStatus.unsupported ? retryBase * 60 : retryBase * (1 << (_failures - 1));
    _retry?.cancel();
    _retry = Timer(wait, () {
      _retry = null;
      _update();
    });
  }

  void _received(int generation, String text) {
    if (generation != _generation) return;
    final Map<String, Object?> msg;
    try {
      msg = (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      return;
    }
    switch (msg['type']) {
      case 'welcome':
        _welcomed = true;
        _failures = 0;
        _setStatus(RemoteAgentStatus.online);
        _publish();
        _refresh = Timer.periodic(refresh, (_) {
          if (controllers.isNotEmpty) _publish();
        });
      case 'controllers':
        final before = controllers.length;
        final names = msg['names'];
        controllers = [
          if (names is List)
            for (final n in names)
              if (n is String) n,
        ];
        RemoteHost.instance.watched = controllers.isNotEmpty;
        if (controllers.isEmpty && before > 0) onControllersGone?.call();
        notifyListeners();
        // A remote that just came gets the position as it is now, not as it was at the last change.
        if (controllers.length > before) _publish();
      case 'command':
        unawaited(_command(generation, msg));
    }
  }

  Future<void> _command(int generation, Map<String, Object?> msg) async {
    final name = msg['name'];
    if (name is! String) return;
    final args = msg['args'];
    String? error;
    Map<String, Object?>? data;
    try {
      final answer = await perform(name, args is Map ? args.cast<String, Object?>() : const {});
      if (answer is RemoteResult) {
        error = answer.error;
        data = answer.data;
      } else if (answer is String) {
        error = answer;
      }
    } catch (e) {
      error = '没有做成：$e';
    }
    if (generation != _generation) return;
    Map<String, Object?> result(String? error, Map<String, Object?>? data) => {
      'type': 'result',
      'to': msg['from'],
      'id': msg['id'],
      'ok': error == null,
      'message': error ?? '',
      'data': ?data,
    };
    String text;
    try {
      text = jsonEncode(result(error, data));
    } catch (_) {
      text = jsonEncode(result('回答里有发不出去的内容', null));
    }
    // The engine would end the connection over a message this long: the remote hears why instead.
    if (text.length > maxAnswer) text = jsonEncode(result('回答太长，发不过去', null));
    _channel?.send(text);
    _changed();
  }

  /// Something the state is made of changed: send it soon, once, however many changes come together.
  void _changed() {
    if (_channel == null || !_welcomed || _debounce != null) return;
    _debounce = Timer(const Duration(milliseconds: 80), () {
      _debounce = null;
      _publish();
    });
  }

  void _publish() {
    final channel = _channel;
    if (channel == null || !_welcomed) return;
    final String text;
    try {
      text = jsonEncode({'type': 'state', 'state': collect()});
    } catch (_) {
      // A page that is being taken down: the next change sends what is true then.
      return;
    }
    if (text == _lastSent) return;
    _lastSent = text;
    channel.send(text);
  }

  @override
  void dispose() {
    _disposed = true;
    RemoteHost.instance.removeListener(_changed);
    _drop();
    super.dispose();
  }
}
