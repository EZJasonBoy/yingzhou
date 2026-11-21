import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/github_proxy.dart';
import '../engine/models.dart';
import '../update/update_models.dart' show normalizeMirror;

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
  bool _customChoice = false;
  String? _customError;

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
      _probing = false;
      _probeError = null;
      _shownPrefix = null;
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
    final asked = _askedOf;
    final current = state.engineSettings?.githubProxyPrefix ?? '';
    final custom = _custom.text.trim();
    setState(() {
      _probing = true;
      _probeError = null;
    });
    try {
      final results = await state.client.probeGithubProxies(
        {for (final p in _presets) p.prefix, if (current.isNotEmpty && !_isPreset(current)) current, if (custom.isNotEmpty) custom}.toList(),
      );
      if (mounted && identical(asked, _askedOf)) setState(() => _probe = {for (final r in results) r.prefix: r});
    } on EngineException catch (e) {
      if (mounted && identical(asked, _askedOf)) setState(() => _probeError = e.message);
    } on StateError {
      // Disconnected meanwhile.
    } finally {
      if (mounted && identical(asked, _askedOf)) setState(() => _probing = false);
    }
  }

  void _saveCustom(AppState state) {
    final prefix = normalizeMirror(_custom.text);
    final uri = Uri.tryParse(prefix);
    final valid =
        uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty && uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment;
    setState(() => _customError = valid ? null : '请输入完整的 HTTP 或 HTTPS 镜像地址');
    if (valid) state.setGithubProxy(enabled: true, prefix: prefix);
  }

  String _label(String name, String prefix) {
    final result = _probe?[prefix];
    return result == null
        ? name
        : '$name · ${result.ok
              ? '${result.ms} ms'
              : result.error.contains('timeout')
              ? '超时'
              : '不可用'}';
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.network.githubPending ? state.network.githubSettings : state.engineSettings ?? state.network.githubSettings;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final chosen = settings.githubProxyPrefix;
    if (chosen != _shownPrefix) {
      _shownPrefix = chosen;
      _customChoice = !_isPreset(chosen);
      _customError = null;
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
          subtitle: Text(state.engineSettings == null ? '引擎离线时先用于本机更新，连接后同步到引擎' : '用于 GitHub 上的配置源、组件和应用更新。开启后优先使用镜像，失败时尝试直连'),
          value: settings.githubProxy,
          onChanged: state.busy ? null : (on) => state.setGithubProxy(enabled: on, prefix: chosen),
        ),
        if (settings.githubProxy) ...[
          if (_presets.isNotEmpty)
            DropdownButton<String>(
              key: const Key('github-proxy-choice'),
              value: !_customChoice && _isPreset(chosen) ? chosen : '',
              isExpanded: true,
              menuMaxHeight: 360,
              items: [
                for (final preset in _presets)
                  DropdownMenuItem(
                    value: preset.prefix,
                    child: Text(_label(preset.name, preset.prefix), overflow: TextOverflow.ellipsis),
                  ),
                DropdownMenuItem(value: '', child: Text(_isPreset(chosen) ? '自定义地址…' : _label('自定义地址', chosen))),
              ],
              onChanged: state.busy
                  ? null
                  : (prefix) {
                      if (prefix == null) return;
                      setState(() {
                        _customChoice = prefix.isEmpty;
                        _customError = null;
                      });
                      if (prefix.isNotEmpty && prefix != chosen) state.setGithubProxy(enabled: true, prefix: prefix);
                    },
            ),
          // An engine from before presets cannot measure either.
          if (_presets.isNotEmpty)
            Row(
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
          if (_customChoice || _presets.isEmpty)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('github-proxy-custom'),
                    controller: _custom,
                    enabled: !state.busy,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: _presets.isEmpty ? '代理地址' : '自定义代理地址',
                      hintText: '如 https://gh.example.com/',
                      errorText: _customError,
                    ),
                    onSubmitted: (_) => _saveCustom(state),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonal(key: const Key('github-proxy-apply'), onPressed: state.busy ? null : () => _saveCustom(state), child: const Text('应用')),
              ],
            ),
        ],
      ],
    );
  }
}
