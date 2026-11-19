import 'package:material_ui/material_ui.dart';

import 'engine/engine_client.dart';
import 'engine/local_engine.dart';
import 'engine/models.dart';
import 'player_backend.dart';
import 'settings.dart';

typedef EngineClientFactory = EngineClient Function(Uri baseUrl);

const defaultEngineUrl = 'http://127.0.0.1:9978';

/// App-wide state: which engine we talk to, its active config, and the site being browsed.
class AppState extends ChangeNotifier {
  AppState({
    required this.clientFactory,
    this.engineUrl = defaultEngineUrl,
    SettingsStore? settings,
    this._localEngine,
    this.waitStep = const Duration(milliseconds: 500),
    this.playerBackend = mediaKitBackend,
  }) : _settings = settings ?? MemorySettings();

  final EngineClientFactory clientFactory;

  /// The player the video-on-demand page plays with.
  final PlayerBackendFactory playerBackend;
  final SettingsStore _settings;

  /// Local preferences of this client (window, player volume...).
  SettingsStore get settings => _settings;
  final LocalEngine? _localEngine;
  final Duration waitStep;
  String engineUrl;

  /// True while the bundled engine (desktop) or the embedded one (Android) is coming up.
  bool startingEngine = false;

  static const _engineUrlKey = 'engineUrl';
  static const _siteKey = 'siteKey';

  /// Restores the last engine and site, then connects. When nothing answers on the local address, starts the
  /// bundled engine (desktop) or waits for the embedded one (Android) to come up.
  Future<void> start() async {
    engineUrl = _settings.getString(_engineUrlKey) ?? engineUrl;
    currentSiteKey = _settings.getString(_siteKey);
    await connect();
    if (connected || !_isLocal(engineUrl)) return;

    startingEngine = true;
    error = null;
    notifyListeners();
    final local = _localEngine;
    if (local != null && !await local.start(Uri.parse(engineUrl).port)) {
      startingEngine = false;
      error = '无法启动内置引擎：${local.recentOutput.isEmpty ? '未知原因' : local.recentOutput.last}';
      notifyListeners();
      return;
    }
    // The JVM needs a moment; the Android engine starts with the process and is usually there already.
    final attempts = local != null ? 60 : 16;
    for (var i = 0; i < attempts && !connected; i++) {
      await Future<void>.delayed(waitStep);
      try {
        await _connectOnce();
      } on EngineException {
        // not up yet
      }
    }
    startingEngine = false;
    if (!connected) {
      final tail = local?.recentOutput.reversed.take(3).toList().reversed.join('\n') ?? '';
      error = '内置引擎没有响应${tail.isEmpty ? '' : '\n$tail'}';
    }
    notifyListeners();
  }

  static bool _isLocal(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost';
  }

  @override
  void dispose() {
    _localEngine?.stop();
    _client?.close();
    super.dispose();
  }

  EngineClient? _client;
  EngineInfo? info;
  ConfigSummary? summary;
  List<SiteInfo> sites = const [];
  String? currentSiteKey;
  String? error;
  bool busy = false;

  EngineClient get client => _client ?? (throw StateError('not connected'));
  bool get connected => info != null;
  bool get hasConfig => summary != null;

  /// Sites the connected engine can actually run.
  List<SiteInfo> get browsableSites => [
    for (final s in sites)
      if (supports(s.runtime)) s,
  ];

  SiteInfo? get currentSite {
    for (final s in sites) {
      if (s.key == currentSiteKey) return s;
    }
    return null;
  }

  bool supports(SiteRuntime runtime) => switch (runtime) {
    SiteRuntime.cms || SiteRuntime.remote => true,
    SiteRuntime.js => info?.capabilities['js'] ?? false,
    SiteRuntime.jar => info?.capabilities['jar'] ?? false,
    SiteRuntime.py => info?.capabilities['py'] ?? false,
    SiteRuntime.unknown => false,
  };

  String siteName(String key) {
    for (final s in sites) {
      if (s.key == key) return s.name;
    }
    return key;
  }

  Future<void> connect([String? url]) => _run(() async {
    if (url != null) engineUrl = url.trim();
    await _connectOnce();
  });

  Future<void> _connectOnce() async {
    _client?.close();
    final client = clientFactory(Uri.parse(engineUrl));
    _client = client;
    info = null;
    summary = null;
    sites = const [];
    configError = null;
    info = await client.info();
    error = null;
    await _settings.setString(_engineUrlKey, engineUrl);
    try {
      engineSettings = await client.settings();
    } on EngineException {
      engineSettings = null;
    }
    await _loadConfig();
  }

  /// The engine's own settings; null when the engine is too old to have any.
  EngineSettings? engineSettings;

  /// Turns the GitHub proxy on or off (and names it), then loads the current subscription again the new way.
  Future<void> setGithubProxy({required bool enabled, String? prefix}) => _run(() async {
    final current = engineSettings ?? const EngineSettings();
    engineSettings = await client.updateSettings(
      EngineSettings(githubProxy: enabled, githubProxyPrefix: prefix ?? current.githubProxyPrefix),
    );
    final active = summary;
    if (active == null) {
      // Nothing loaded, perhaps because of the very address this setting changes: let the engine try again.
      await _loadConfig();
      return;
    }
    summary = await client.activate(active.subscriptionId, repo: active.repos.isEmpty ? null : active.url);
    await _loadSites();
  });

  /// Turns the engine's stream cache on or off, or changes how much disk it may take. Nothing is loaded again.
  Future<void> setStreamCache({bool? enabled, int? maxMB}) => _run(() async {
    engineSettings = await client.patchSettings({'streamCache': ?enabled, 'streamCacheMaxMB': ?maxMB});
  });

  /// True while the engine loads the active subscription (right after it starts, it loads the last one again).
  bool loadingConfig = false;

  /// Why the active subscription did not load (network, bad config); the engine is connected all the same.
  String? configError;

  /// Asks the engine for its config again; after a failed load, the engine tries loading the subscription again.
  Future<void> reloadConfig() => _loadConfig();

  Future<void> _loadConfig() async {
    loadingConfig = true;
    configError = null;
    notifyListeners();
    try {
      summary = await client.config();
      await _loadSites();
    } on EngineException catch (e) {
      if (e.code != 'NO_CONFIG') configError = e.message;
    } finally {
      loadingConfig = false;
      notifyListeners();
    }
  }

  Future<void> importSubscription(String url) => _run(() async {
    final sub = await client.addSubscription(url.trim());
    summary = await client.activate(sub.id);
    await _loadSites();
  });

  Future<void> switchRepo(String repoUrl) => _run(() async {
    try {
      summary = await client.activate(summary!.subscriptionId, repo: repoUrl);
    } catch (_) {
      // The current config stays; a list that was opened on the way now shows its entries.
      summary = await client.config().catchError((_) => summary!);
      rethrow;
    }
    await _loadSites();
  });

  void selectSite(String key) {
    if (key == currentSiteKey) return;
    currentSiteKey = key;
    _settings.setString(_siteKey, key);
    notifyListeners();
  }

  Future<void> _loadSites() async {
    sites = await client.sites();
    final browsable = browsableSites;
    if (browsable.every((s) => s.key != currentSiteKey)) {
      currentSiteKey = browsable.isEmpty ? null : browsable.first.key;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await action();
    } on EngineException catch (e) {
      error = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Reads without subscribing to changes (for callbacks).
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
