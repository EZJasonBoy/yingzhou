import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/github_proxy.dart';
import '../engine/models.dart';

/// 网络 → GitHub 加速代理: off by default (GitHub directly); on, GitHub files go through the proxy picked from the
/// engine's list or typed in. 「测速」 has the engine fetch one small GitHub file straight and through each proxy,
/// and shows which answered and how fast.
class GithubProxySettings extends StatefulWidget {
  const GithubProxySettings({super.key});

  @override
  State<GithubProxySettings> createState() => _GithubProxySettingsState();
}

class _GithubProxySettingsState extends State<GithubProxySettings> {
  final _custom = TextEditingController();

  /// The engine's presets; empty for an engine from before them (only the address field then).
  List<GithubProxyPreset> _presets = const [];

  /// The last measurement, by prefix ('' is GitHub itself); null before the first.
  Map<String, GithubProxyProbeResult>? _probe;
  bool _probing = false;
  String? _probeError;

  /// Which engine [_presets] are from.
  Object? _askedOf;

  /// The prefix last put in the field from the engine's settings.
  String? _shownPrefix;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final engine = state.connected ? state.client : null;
    if (!identical(engine, _askedOf)) {
      _askedOf = engine;
      _presets = const [];
      _probe = null;
      if (engine != null) _load(state);
    }
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _load(AppState state) async {
    final asked = _askedOf;
    List<GithubProxyPreset> presets = const [];
    try {
      presets = await state.client.githubProxyPresets();
    } on EngineException {
      // An engine from before presets.
    } on StateError {
      return;
    }
    if (mounted && identical(asked, _askedOf)) {
      setState(() {
        _presets = presets;
        // The field is filled again knowing which prefixes are presets.
        _shownPrefix = null;
      });
    }
  }

  bool _isPreset(String prefix) => _presets.any((p) => p.prefix == prefix);

  Future<void> _measure(AppState state) async {
    final current = state.engineSettings?.githubProxyPrefix ?? '';
    final custom = _custom.text.trim();
    setState(() {
      _probing = true;
      _probeError = null;
    });
    try {
      final results = await state.client.probeGithubProxies([
        for (final p in _presets) p.prefix,
        if (current.isNotEmpty && !_isPreset(current)) current,
        if (custom.isNotEmpty) custom,
      ]);
      if (mounted) setState(() => _probe = {for (final r in results) r.prefix: r});
    } on EngineException catch (e) {
      if (mounted) setState(() => _probeError = e.message);
    } on StateError {
      // Disconnected meanwhile.
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.engineSettings;
    if (settings == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final chosen = settings.githubProxyPrefix;
    if (chosen != _shownPrefix) {
      _shownPrefix = chosen;
      // The field holds a prefix of the user's own; a preset is picked in the list (and one put in the field
      // before the presets were known comes out again).
      if (!_isPreset(chosen)) {
        _custom.text = chosen;
      } else if (_isPreset(_custom.text)) {
        _custom.text = '';
      }
    }
    final direct = _probe?[''];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('github-proxy-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('GitHub 加速代理'),
          subtitle: Text(settings.githubProxy ? 'GitHub 上的文件经下面选的代理获取，代理失败时再直连' : '已关闭：直连 GitHub，订阅里写的代理前缀（gh-proxy 等）会被去掉'),
          value: settings.githubProxy,
          onChanged: state.busy ? null : (on) => state.setGithubProxy(enabled: on, prefix: chosen),
        ),
        if (settings.githubProxy) ...[
          // An engine from before presets cannot measure either.
          if (_presets.isNotEmpty) Row(
            children: [
              Expanded(
                child: Text(
                  _probing
                      ? '正在测速：经每个代理取 GitHub 上的一个小文件…'
                      : direct == null
                      ? '这些代理由网友免费提供，随时可能失效；「测速」会经每个代理取一个小文件，看哪个能用'
                      : '直连 GitHub：${direct.ok ? '${direct.ms} ms' : '连不上'}',
                  key: const Key('github-proxy-probe-status'),
                  style: small,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                key: const Key('github-proxy-probe'),
                onPressed: _probing || state.busy ? null : () => _measure(state),
                child: Text(_probing ? '测速中…' : '测速'),
              ),
            ],
          ),
          if (_probeError != null) Text('测速失败：$_probeError', style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
          const SizedBox(height: 4),
          for (final p in _presets)
            _choice(
              context,
              key: Key('github-proxy-preset-${p.name}'),
              title: p.name,
              selected: p.prefix == chosen,
              result: _probe?[p.prefix],
              onTap: state.busy || p.prefix == chosen ? null : () => state.setGithubProxy(enabled: true, prefix: p.prefix),
            ),
          if (_presets.isNotEmpty)
            _choice(
              context,
              key: const Key('github-proxy-custom-choice'),
              title: '自定义',
              selected: !_isPreset(chosen),
              result: _isPreset(chosen) ? null : _probe?[chosen],
              onTap: null,
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('github-proxy-custom'),
                  controller: _custom,
                  enabled: !state.busy,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(labelText: _presets.isEmpty ? '代理地址' : '自定义代理地址', hintText: '如 https://gh.example.com/'),
                  onSubmitted: (v) => v.trim().isEmpty ? null : state.setGithubProxy(enabled: true, prefix: v),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.tonal(
                key: const Key('github-proxy-apply'),
                onPressed: state.busy ? null : () => _custom.text.trim().isEmpty ? null : state.setGithubProxy(enabled: true, prefix: _custom.text),
                child: const Text('应用'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _choice(BuildContext context, {required Key key, required String title, required bool selected, GithubProxyProbeResult? result, VoidCallback? onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: key,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: selected ? scheme.primary : scheme.onSurfaceVariant, size: 20),
      title: Text(title),
      trailing: result == null
          ? null
          : Tooltip(
              message: result.ok ? '取到了测试文件' : result.error,
              child: Text(
                result.ok ? '${result.ms} ms' : (result.error.contains('timeout') ? '超时' : '不可用'),
                style: TextStyle(color: result.ok ? (result.ms < 1500 ? scheme.primary : scheme.tertiary) : scheme.error, fontSize: 13),
              ),
            ),
      onTap: onTap,
    );
  }
}
