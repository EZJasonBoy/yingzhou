import 'local_engine_stub.dart' if (dart.library.io) 'local_engine_io.dart' as impl;

/// Starts the engine that ships with the desktop app, when no engine is running yet.
abstract class LocalEngine {
  /// Starts the engine on [port]. False when this platform has no bundled engine or it could not be started.
  Future<bool> start(int port);

  /// Last lines the engine printed, for error messages.
  List<String> get recentOutput;

  void stop();
}

/// The bundled engine on Windows/macOS/Linux; null elsewhere (Android embeds the engine, web has none).
LocalEngine? createLocalEngine() => impl.createLocalEngine();
