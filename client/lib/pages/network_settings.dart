import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/models.dart';
import '../engine/network_models.dart';

/// 设置 → 网络: which DNS-over-HTTPS server the engine asks (off unless the user picks one), and what the active
/// subscription brings along: `hosts` redirects, per-host `headers`, `ads` hosts.
class NetworkSettings extends StatefulWidget {
  const NetworkSettings({super.key});

  @override
  State<NetworkSettings> createState() => _NetworkSettingsState();
}

class _NetworkSettingsState extends State<NetworkSettings> {
  NetworkInfo? _info;
  bool _showRules = false;

  /// What [_info] was asked for: it is asked again when the engine, the subscription or the choice changes.
  Object? _askedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final asking = (state.connected, state.engineUrl, state.summary?.subscriptionId, state.summary?.url, state.engineSettings?.doh);
    if (asking == _askedFor) return;
    _askedFor = asking;
    if (state.connected) _load(state);
  }

  Future<void> _load(AppState state) async {
    NetworkInfo? info;
    try {
      info = await state.client.network();
    } on EngineException {
      // An engine that does not have this yet: nothing to show.
    } on StateError {
      // Disconnected meanwhile.
    }
    if (mounted) setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final info = _info;
    final settings = state.engineSettings;
    if (info == null || settings == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final chosen = settings.doh;
    final options = [
      ...info.dohOptions,
      // The choice may be newer than the list.
      if (chosen.isNotEmpty && info.dohOptions.every((o) => o.url != chosen)) DohOption(name: _host(chosen), url: chosen, source: 'saved'),
    ];
    final failure = chosen.isNotEmpty && info.dohStatus.startsWith('failed') ? info.dohStatus.replaceFirst(RegExp(r'^failed:?\s*'), '') : null;
    final rules = [
      if (info.hosts.isNotEmpty) '${info.hosts.length} 条域名重定向',
      if (info.headerHosts.isNotEmpty) '${info.headerHosts.length} 条请求头',
      if (info.ads.isNotEmpty) '${info.ads.length} 个嗅探屏蔽域名',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Text('安全 DNS（DoH）', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 2),
        Text(
          chosen.isEmpty ? '已关闭：用系统的 DNS 查域名。打开后，引擎要访问的域名会发给你选的服务商去查' : '引擎要访问的域名交给所选的服务商查；它查不到或连不上时，退回系统的 DNS',
          key: const Key('doh-explain'),
          style: small,
        ),
        DropdownButton<String>(
          key: const Key('doh-choice'),
          value: chosen,
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('关闭（系统 DNS）')),
            for (final o in options) DropdownMenuItem(value: o.url, child: Text(_label(o), overflow: TextOverflow.ellipsis)),
          ],
          onChanged: state.busy ? null : (url) => url == null || url == chosen ? null : state.setDoh(url),
        ),
        if (failure != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '所选的服务商刚才没有应答${failure.isEmpty ? '' : '（$failure）'}，这段时间用的是系统的 DNS',
              key: const Key('doh-failed'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        if (rules.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: Text('当前订阅自带的网络规则：${rules.join(' · ')}', key: const Key('config-network-rules'), style: small)),
              TextButton(onPressed: () => setState(() => _showRules = !_showRules), child: Text(_showRules ? '收起' : '查看')),
            ],
          ),
          if (_showRules) ...[
            if (info.hosts.isNotEmpty) _ruleList(context, '域名重定向（hosts）：访问左边的域名时，实际连到右边', [for (final e in info.hosts.entries) '${e.key} → ${e.value}']),
            if (info.headerHosts.isNotEmpty) _ruleList(context, '请求头（headers）：访问这些域名时带上订阅指定的请求头', info.headerHosts),
            if (info.ads.isNotEmpty) _ruleList(context, '嗅探屏蔽（ads）：嗅探网页时不加载这些域名', info.ads),
          ],
        ],
      ],
    );
  }

  Widget _ruleList(BuildContext context, String title, List<String> lines) {
    final theme = Theme.of(context);
    const shown = 30;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodySmall),
          for (final line in lines.take(shown))
            Text(line, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontFamily: 'monospace')),
          if (lines.length > shown) Text('… 共 ${lines.length} 条', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;

  static String _label(DohOption o) {
    final host = _host(o.url);
    final from = switch (o.source) {
      'config' => '，订阅提供',
      'saved' => '，之前选的',
      _ => '',
    };
    return o.name == host ? '$host${from.isEmpty ? '' : '（${from.substring(1)}）'}' : '${o.name}（$host$from）';
  }
}
