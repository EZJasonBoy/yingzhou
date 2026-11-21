import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/remote/remote_socket.dart';

/// Stands in for the engine's remote-control hub: what the app's agent connects to instead of a WebSocket. The test
/// plays the hub (and through it, the phone): it reads what the screen sent and delivers messages to it.
class FakeRemoteHub {
  final connections = <FakeRemoteChannel>[];

  /// Connecting fails (the engine is down, or too old to have the route).
  bool refuse = false;

  Future<RemoteChannel> connect(Uri url, {String? token}) async {
    if (refuse) throw const SocketException('refused');
    final channel = FakeRemoteChannel(url, token);
    connections.add(channel);
    return channel;
  }

  /// The screen's connection now (the last one made).
  FakeRemoteChannel get screen => connections.last;
}

class FakeRemoteChannel implements RemoteChannel {
  FakeRemoteChannel(this.url, this.token);

  final Uri url;
  final String? token;
  final _toScreen = StreamController<String>();

  /// Everything the screen sent, decoded.
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  int _commands = 0;

  @override
  int? closeCode;

  @override
  Stream<String> get messages => _toScreen.stream;

  @override
  void send(String text) => sent.add(jsonDecode(text) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    if (!_toScreen.isClosed) unawaited(_toScreen.close());
  }

  // ---- the hub's side ----

  void deliver(Map<String, Object?> message) => _toScreen.add(jsonEncode(message));

  /// The connection ends from the hub's side (the engine went away).
  void drop([int code = 1006]) {
    closeCode = code;
    unawaited(_toScreen.close());
  }

  Map<String, dynamic> get hello => sent.firstWhere((m) => m['type'] == 'hello');

  /// The last state the screen published.
  Map<String, dynamic> get state => sent.lastWhere((m) => m['type'] == 'state')['state'] as Map<String, dynamic>;

  int get states => sent.where((m) => m['type'] == 'state').length;

  /// What the screen reports of what is playing; null when nothing is.
  Map<String, dynamic>? get player => state['player'] as Map<String, dynamic>?;

  /// A command as the hub passes it on from a phone; answers what the screen said to it.
  Future<Map<String, dynamic>> command(WidgetTester tester, String name, [Map<String, Object?> args = const {}]) async {
    final id = '${++_commands}';
    deliver({'type': 'command', 'from': 'c1', 'id': id, 'name': name, 'args': args});
    // The message, the command and whatever it sets off (a seek, a frame, the state that follows).
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return sent.lastWhere((m) => m['type'] == 'result' && m['id'] == id, orElse: () => fail('no answer to $name'));
  }
}
