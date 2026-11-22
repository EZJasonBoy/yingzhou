import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../network_preferences.dart';

class HttpProxySettings extends StatefulWidget {
  const HttpProxySettings({super.key});

  @override
  State<HttpProxySettings> createState() => _HttpProxySettingsState();
}

class _HttpProxySettingsState extends State<HttpProxySettings> {
  static const scopes = {'updates': '本机更新', 'modules': '模块 / 组件下载', 'config': '源配置获取', 'playback': '播放链接解析'};
  final _address = TextEditingController();
  Set<String> _selected = {};
  Object? _snapshot;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save(AppState state) async {
    final address = normalizeProxy(_address.text);
    if (address == null || (address.isEmpty && _selected.isNotEmpty)) {
      setState(() => _error = '请输入 HTTP 代理地址，例如 127.0.0.1:7890');
      return;
    }
    setState(() {
      _error = null;
      _address.text = address;
    });
    await state.setNetworkProxy(address, updates: _selected.contains('updates'), scopes: {..._selected}..remove('updates'));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state.error ?? '网络代理设置已保存')));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final engine = state.connected ? state.engineSettings : null;
    final local = state.network.http;
    final engineScopes = engine?.proxyScopes ?? const <String>{};
    final snapshot = (state.engineUrl, local, engine?.httpProxy, engineScopes.join(','));
    final active = {if (local.updates) 'updates', ...engineScopes};
    if (snapshot != _snapshot) {
      _snapshot = snapshot;
      _address.text = engineScopes.isNotEmpty
          ? engine!.httpProxy
          : local.address.isNotEmpty
          ? local.address
          : engine?.httpProxy ?? '';
      _selected = {...active};
      _error = null;
    }
    final description = [
      for (final item in scopes.entries)
        if (active.contains(item.key)) item.value,
    ].join('、');
    final small = Theme.of(context).textTheme.bodySmall;
    return ExpansionTile(
      key: const Key('network-proxy-settings'),
      tilePadding: EdgeInsets.zero,
      title: const Text('网络代理（HTTP）'),
      subtitle: Text(description.isEmpty ? '未启用' : description),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('network-proxy-address'),
          controller: _address,
          enabled: !state.busy,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(labelText: '代理地址', hintText: '主机:端口，例如 127.0.0.1:7890', errorText: _error),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final item in scopes.entries)
              FilterChip(
                key: Key('network-proxy-${item.key}'),
                label: Text(item.value),
                selected: _selected.contains(item.key),
                onSelected: state.busy || (item.key != 'updates' && engine?.supportsProxyScopes != true)
                    ? null
                    : (on) => setState(() {
                        if (on) {
                          _selected.add(item.key);
                        } else {
                          _selected.remove(item.key);
                        }
                      }),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(engine?.supportsProxyScopes != true ? '本机可单独代理更新。连接支持分用途代理的引擎后，可选择其余用途。' : '本机更新由这台设备连接代理，其余用途由引擎连接。使用远程引擎时，请填写相应设备可访问的地址。', style: small),
        if (local.updates && engineScopes.isNotEmpty && local.address != engine!.httpProxy) Text('本机更新当前使用 ${local.address}。保存后，所选用途都会使用上方地址。', style: small),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(key: const Key('network-proxy-save'), onPressed: state.busy ? null : () => _save(state), child: const Text('保存网络代理')),
        ),
      ],
    );
  }
}
