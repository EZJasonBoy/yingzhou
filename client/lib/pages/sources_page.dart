import 'package:material_ui/material_ui.dart';

import '../engine/engine_client.dart';
import '../engine/models.dart';

typedef EngineClientFactory = EngineClient Function(Uri baseUrl);

/// First slice of the client: connect to an engine, import a subscription, see its sites.
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key, required this.clientFactory, this.defaultEngineUrl = 'http://127.0.0.1:9978'});

  final EngineClientFactory clientFactory;
  final String defaultEngineUrl;

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  late final _engineField = TextEditingController(text: widget.defaultEngineUrl);
  final _subscriptionField = TextEditingController();

  EngineClient? _client;
  EngineInfo? _info;
  ConfigSummary? _summary;
  List<SiteInfo> _sites = const [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _client?.close();
    _engineField.dispose();
    _subscriptionField.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
        _client?.close();
        final client = widget.clientFactory(Uri.parse(_engineField.text.trim()));
        _client = client;
        _info = null;
        _summary = null;
        _sites = const [];
        _info = await client.info();
        try {
          _summary = await client.config();
          _sites = await client.sites();
        } on EngineException catch (e) {
          if (e.code != 'NO_CONFIG') rethrow;
        }
      });

  Future<void> _import() => _run(() async {
        final client = _client;
        final url = _subscriptionField.text.trim();
        if (client == null || url.isEmpty) return;
        final sub = await client.addSubscription(url);
        _summary = await client.activate(sub.id);
        _sites = await client.sites();
      });

  Future<void> _switchRepo(String repoUrl) => _run(() async {
        final client = _client!;
        _summary = await client.activate(_summary!.subscriptionId, repo: repoUrl);
        _sites = await client.sites();
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('源管理')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _EngineCard(
                controller: _engineField,
                info: _info,
                busy: _busy,
                onConnect: _connect,
              ),
              const SizedBox(height: 12),
              _SubscriptionCard(
                controller: _subscriptionField,
                enabled: _info != null && !_busy,
                onImport: _import,
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              if (_summary != null) ...[
                const SizedBox(height: 12),
                _SummaryCard(summary: _summary!, onSwitchRepo: _busy ? null : _switchRepo),
                const SizedBox(height: 12),
                _SiteList(sites: _sites),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.controller, required this.info, required this.busy, required this.onConnect});

  final TextEditingController controller;
  final EngineInfo? info;
  final bool busy;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: const InputDecoration(labelText: '引擎地址'),
                    onSubmitted: (_) => onConnect(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(onPressed: busy ? null : onConnect, child: const Text('连接')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              info == null ? '未连接' : '已连接：${info.name} ${info.version}（${info.platform}，协议 v${info.protocol}）',
              key: const Key('engine-status'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.controller, required this.enabled, required this.onImport});

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: '订阅地址',
                  hintText: '支持 http(s)、clan://、;pk; 密钥后缀',
                ),
                onSubmitted: (_) => onImport(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(onPressed: enabled ? onImport : null, child: const Text('导入')),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.onSwitchRepo});

  final ConfigSummary summary;
  final ValueChanged<String>? onSwitchRepo;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${summary.sites} 个站点 · ${summary.parses} 个解析 · ${summary.lives} 组直播', style: textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(summary.url, style: textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (summary.repos.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: summary.repos.any((r) => r.url == summary.url) ? summary.url : null,
                isExpanded: true,
                hint: const Text('选择仓库'),
                items: [
                  for (final r in summary.repos) DropdownMenuItem(value: r.url, child: Text(r.name)),
                ],
                onChanged: onSwitchRepo == null ? null : (url) => url == null ? null : onSwitchRepo!(url),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SiteList extends StatelessWidget {
  const _SiteList({required this.sites});

  final List<SiteInfo> sites;

  static const _runtimeLabels = {
    SiteRuntime.cms: '采集',
    SiteRuntime.js: 'JS',
    SiteRuntime.jar: 'JAR',
    SiteRuntime.py: 'PY',
    SiteRuntime.remote: '远程',
    SiteRuntime.unknown: '未知',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final site in sites)
            ListTile(
              dense: true,
              title: Text(site.name),
              subtitle: Text(site.key),
              leading: Container(
                width: 44,
                padding: const EdgeInsets.symmetric(vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  _runtimeLabels[site.runtime]!,
                  style: TextStyle(fontSize: 12, color: scheme.onSecondaryContainer),
                ),
              ),
              trailing: site.searchable ? const Icon(Icons.search, size: 18) : null,
            ),
        ],
      ),
    );
  }
}
