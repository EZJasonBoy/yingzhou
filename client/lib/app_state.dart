import 'package:material_ui/material_ui.dart';

import 'engine/engine_client.dart';
import 'engine/models.dart';

typedef EngineClientFactory = EngineClient Function(Uri baseUrl);

const defaultEngineUrl = 'http://127.0.0.1:9978';

/// App-wide state: which engine we talk to, its active config, and the site being browsed.
class AppState extends ChangeNotifier {
  AppState({required this.clientFactory, this.engineUrl = defaultEngineUrl});

  final EngineClientFactory clientFactory;
  String engineUrl;

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
  List<SiteInfo> get browsableSites => [for (final s in sites) if (supports(s.runtime)) s];

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
        _client?.close();
        final client = clientFactory(Uri.parse(engineUrl));
        _client = client;
        info = null;
        summary = null;
        sites = const [];
        info = await client.info();
        try {
          summary = await client.config();
          await _loadSites();
        } on EngineException catch (e) {
          if (e.code != 'NO_CONFIG') rethrow;
        }
      });

  Future<void> importSubscription(String url) => _run(() async {
        final sub = await client.addSubscription(url.trim());
        summary = await client.activate(sub.id);
        await _loadSites();
      });

  Future<void> switchRepo(String repoUrl) => _run(() async {
        summary = await client.activate(summary!.subscriptionId, repo: repoUrl);
        await _loadSites();
      });

  void selectSite(String key) {
    if (key == currentSiteKey) return;
    currentSiteKey = key;
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

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}

/// Makes [AppState] available to the widget tree.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Reads without subscribing to changes (for callbacks).
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
