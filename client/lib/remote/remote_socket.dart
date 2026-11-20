import 'dart:async';
import 'dart:io';

/// The WebSocket subprotocol of the remote control's routes (docs/protocol.md, "遥控").
const remoteProtocol = 'yingzhou.remote.v1';

/// Close codes of the engine's hub this client acts on.
abstract final class RemoteClose {
  static const notAllowed = 4401;
  static const noScreen = 4404;
  static const replaced = 4409;
  static const gone = 4410;
}

/// One connection to the engine's hub, as text messages. Tests put a pair of queues here instead of a socket.
abstract class RemoteChannel {
  /// The messages of the other end; done when the connection ended.
  Stream<String> get messages;

  void send(String text);

  Future<void> close();

  /// Why the other end closed it, once it did.
  int? get closeCode;
}

/// Opens a [RemoteChannel] to [url] (`ws://…/api/v1/remote/…`), with the paired [token] for an engine on another device.
typedef RemoteConnector = Future<RemoteChannel> Function(Uri url, {String? token});

/// The route [path] (`screen`, `control?screen=…`) of the engine at [engineUrl] (`http://host:port`).
Uri remoteSocketUri(String engineUrl, String path) {
  final base = Uri.parse(engineUrl);
  return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws').resolve('/api/v1/remote/$path');
}

/// The real thing: a `dart:io` WebSocket. Programs can set headers, so the token goes where it always does.
Future<RemoteChannel> connectRemoteSocket(Uri url, {String? token}) async {
  final socket = await WebSocket.connect(
    url.toString(),
    protocols: const [remoteProtocol],
    headers: {if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token'},
  ).timeout(const Duration(seconds: 10));
  // An engine that vanished (its machine went to sleep) is noticed without waiting for the next thing to send.
  socket.pingInterval = const Duration(seconds: 20);
  return _SocketChannel(socket);
}

class _SocketChannel implements RemoteChannel {
  _SocketChannel(this._socket);

  final WebSocket _socket;

  @override
  late final Stream<String> messages = _socket.where((m) => m is String).cast<String>().handleError((Object _) {});

  @override
  void send(String text) {
    if (_socket.readyState == WebSocket.open) _socket.add(text);
  }

  @override
  Future<void> close() async {
    try {
      await _socket.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Already gone, or the other end does not answer: nothing to wait for.
    }
  }

  @override
  int? get closeCode => _socket.closeCode;
}
