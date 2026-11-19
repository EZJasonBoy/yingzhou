import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/danmaku_models.dart';
import '../engine/media_extras_api.dart';
import '../engine/models.dart';

/// 弹幕 on the 源 page: which services the engine may ask for danmaku besides the site itself. Both are off until the
/// user turns them on: they are told the title and episode of everything played.
class DanmakuServiceSettings extends StatefulWidget {
  const DanmakuServiceSettings({super.key});

  @override
  State<DanmakuServiceSettings> createState() => _DanmakuServiceSettingsState();
}

class _DanmakuServiceSettingsState extends State<DanmakuServiceSettings> {
  DanmakuServices? _services;
  final _custom = TextEditingController();

  /// What [_services] was read for: asked again when the engine or its config changes.
  (Object?, Object?)? _askedOf;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final key = (state.connected ? state.client : null, state.summary);
    if (_askedOf == null || !identical(key.$1, _askedOf!.$1) || !identical(key.$2, _askedOf!.$2)) {
      _askedOf = key;
      if (key.$1 != null) _load();
    }
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = AppScope.read(context);
    DanmakuServices? services;
    try {
      services = await state.client.danmakuServices();
    } on EngineException {
      services = null; // An engine from before danmaku: nothing to show.
    } on StateError {
      return;
    }
    if (!mounted) return;
    setState(() {
      _services = services;
      if (services != null) _custom.text = services.customApi;
    });
  }

  Future<void> _save(Map<String, Object?> fields) async {
    final state = AppScope.read(context);
    setState(() => _saving = true);
    try {
      await state.client.patchSettings(fields);
      await _load();
    } on EngineException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：${e.message}')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _host(String url) => Uri.tryParse(url.replaceAll('{', '').replaceAll('}', ''))?.host ?? url;

  @override
  Widget build(BuildContext context) {
    final services = _services;
    if (services == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final hasConfigApi = services.configApi.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('弹幕', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 4),
              Text('站点自己给的弹幕总会显示。下面两项会把正在看的片名和集数发给第三方服务，默认关闭。', style: muted),
              SwitchListTile(
                key: const Key('danmaku-config-api'),
                contentPadding: EdgeInsets.zero,
                title: const Text('使用订阅提供的弹幕接口'),
                subtitle: Text(hasConfigApi ? '接口：${_host(services.configApi)}' : '当前订阅没有提供弹幕接口'),
                value: services.configApiEnabled,
                onChanged: _saving || (!hasConfigApi && !services.configApiEnabled) ? null : (on) => _save({'danmakuConfigApi': on}),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('danmaku-custom-api'),
                      controller: _custom,
                      decoration: const InputDecoration(
                        labelText: '自己的弹幕接口（可不填）',
                        hintText: '弹弹play 兼容接口的地址，或带 {name}、{episode} 的地址',
                      ),
                      onSubmitted: (v) => _save({'danmakuApi': v.trim()}),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(onPressed: _saving ? null : () => _save({'danmakuApi': _custom.text.trim()}), child: const Text('保存')),
                ],
              ),
              const SizedBox(height: 6),
              Text(services.customApi.isEmpty ? '没有填写：不使用。' : '正在使用：${_host(services.customApi)}（站点和订阅接口都没有弹幕时才问它）', style: muted),
            ],
          ),
        ),
      ),
    );
  }
}
