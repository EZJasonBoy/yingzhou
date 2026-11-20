import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../engine/lan.dart';
import '../ui/device_form.dart';
import '../ui/phone_input.dart' show QrView;
import '../ui/phone_input_server.dart';
import 'remote_agent.dart';
import 'remote_screen.dart';

/// 「允许手机遥控」 in the 局域网 card: off until the user switches it on.
///
/// On, this app registers with its engine as a screen ([RemoteAgent]) and a QR code leads a phone to the engine's
/// web remote (`/remote/`). With the engine on this machine the phone comes in through LAN sharing, so switching
/// this on switches that on too, and says so; the QR code then carries the pairing code, and scanning it is all a
/// phone has to do. With the engine on another device the phone pairs with that engine instead.
///
/// It shows nothing where there is no agent (a page pumped alone in a test, the web build).
class RemoteControlSettings extends StatefulWidget {
  const RemoteControlSettings({super.key, required this.engineUrl, this.lan, this.onEnableSharing, this.busy = false, this.findAddresses});

  /// The engine this app uses (`http://host:port`).
  final String engineUrl;

  /// LAN sharing of the engine on this machine; null when the engine is on another device.
  final LanStatus? lan;

  /// Switches LAN sharing on; answers whether it is on now.
  final Future<bool> Function()? onEnableSharing;
  final bool busy;

  /// Tests: this device's addresses (default [PhoneInputServer.lanAddresses]).
  final Future<List<String>> Function()? findAddresses;

  @override
  State<RemoteControlSettings> createState() => _RemoteControlSettingsState();
}

class _RemoteControlSettingsState extends State<RemoteControlSettings> {
  List<String>? _ranked;
  String? _host;
  bool _working = false;

  /// LAN sharing was off and went on with this switch (said next to it until the page is left).
  bool _sharingCameAlong = false;

  bool get _local => widget.lan != null;

  bool _on(RemoteAgent agent) => agent.enabled && (!_local || widget.lan!.enabled);

  Future<void> _loadAddresses() async {
    if (_ranked != null) return;
    _ranked = const [];
    final found = await (widget.findAddresses ?? PhoneInputServer.lanAddresses)();
    if (mounted) setState(() => _ranked = found);
  }

  /// Where a phone reaches the engine: the addresses the engine listens on, the likeliest home network first.
  List<String> _hosts() {
    final lan = widget.lan;
    if (lan == null) {
      final host = Uri.tryParse(widget.engineUrl)?.host ?? '';
      return host.isEmpty ? const [] : [host];
    }
    final listening = [for (final a in lan.addresses) Uri.tryParse(a)?.host ?? ''].where((h) => h.isNotEmpty).toList();
    final ranked = [for (final h in _ranked ?? const <String>[]) if (listening.contains(h)) h];
    return [...ranked, for (final h in listening) if (!ranked.contains(h)) h];
  }

  int get _port => widget.lan?.port ?? (Uri.tryParse(widget.engineUrl)?.port ?? 9978);

  Future<void> _toggle(RemoteAgent agent, bool on) async {
    setState(() => _working = true);
    try {
      if (on && _local && !widget.lan!.enabled) {
        if (!(await widget.onEnableSharing?.call() ?? false)) return;
        _sharingCameAlong = true;
      }
      if (!on) _sharingCameAlong = false;
      await agent.setEnabled(on);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _rename(RemoteAgent agent) async {
    final field = TextEditingController(text: agent.screenName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('这块屏幕叫什么'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '比如 客厅电视'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(context).pop(field.text), child: const Text('确定')),
        ],
      ),
    );
    if (name != null) await agent.setScreenName(name);
  }

  @override
  Widget build(BuildContext context) {
    final agent = RemoteScreen.maybeAgentOf(context);
    if (agent == null || kIsWeb) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final on = _on(agent);
    final device = !kIsWeb && defaultTargetPlatform == TargetPlatform.android ? '这台设备' : '这台电脑';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('remote-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('允许手机遥控'),
          subtitle: Text(
            on
                ? (_sharingCameAlong ? '已开启。局域网共享也随它一起开启了：手机就是经它连进来的。' : '已开启：配对过的手机可以遥控$device上的映舟。')
                : _local
                ? '用手机当遥控器：方向键、播放和进度、选集、输入文字。打开后会同时开启上面的「局域网共享」，手机经它连进来。'
                : '用手机当遥控器。手机要先和那台引擎配对，再在它的地址后面加 /remote/ 打开遥控网页。',
          ),
          value: on,
          onChanged: _working || widget.busy ? null : (v) => _toggle(agent, v),
        ),
        if (on) _details(context, agent, small),
      ],
    );
  }

  Widget _details(BuildContext context, RemoteAgent agent, TextStyle small) {
    unawaited(_loadAddresses());
    final scheme = Theme.of(context).colorScheme;
    final tv = isTv(context);
    final hosts = _hosts();
    final host = hosts.contains(_host) ? _host! : hosts.firstOrNull;
    final lan = widget.lan;
    final locked = lan != null && lan.lockedUntil > DateTime.now().millisecondsSinceEpoch;
    final code = lan == null || locked ? '' : lan.code;
    final page = host == null ? null : 'http://$host:$_port/remote/';
    final status = switch (agent.status) {
      RemoteAgentStatus.online => agent.controllers.isEmpty ? '等手机连接…' : '正在遥控的手机：${agent.controllers.join('、')}',
      RemoteAgentStatus.connecting => '正在向引擎登记这块屏幕…',
      RemoteAgentStatus.unsupported => '这台引擎的版本还没有遥控功能，更新引擎后再试。',
      RemoteAgentStatus.offline => '引擎没有回应，正在重试…',
      RemoteAgentStatus.off => '还没有连上引擎。',
    };
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          code.isEmpty ? '用手机扫码打开遥控网页，再输入配对码（只需要一次）。' : '用手机扫码（相机、微信都可以）就能遥控：二维码里带着配对码，不用再输入。',
          style: TextStyle(fontSize: tv ? 17 : 14),
        ),
        const SizedBox(height: 6),
        Text('手机要和$_whereLabel连在同一个 Wi-Fi 或路由器下。遥控网页可以加到手机的主屏幕。', style: small),
        const SizedBox(height: 8),
        Text('也可以在手机浏览器里打开：', style: small),
        SelectableText(page ?? '', key: const Key('remote-url'), style: TextStyle(fontSize: tv ? 15 : 13, fontFamily: 'monospace')),
        if (hosts.length > 1) ...[
          const SizedBox(height: 8),
          Text('扫不开就换一个地址：', style: small),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final h in hosts) ChoiceChip(label: Text(h), selected: h == host, onSelected: (_) => setState(() => _host = h)),
            ],
          ),
        ],
        const SizedBox(height: 10),
        Text(status, key: const Key('remote-status'), style: small.copyWith(color: agent.status == RemoteAgentStatus.online ? scheme.primary : null)),
        Row(
          children: [
            Flexible(child: Text('手机上显示为「${agent.screenName}」', style: small, overflow: TextOverflow.ellipsis)),
            TextButton(key: const Key('remote-rename'), onPressed: () => _rename(agent), child: const Text('改名')),
            if (page != null && !tv)
              IconButton(tooltip: '复制地址', onPressed: () => Clipboard.setData(ClipboardData(text: page)), icon: const Icon(Icons.copy, size: 18)),
          ],
        ),
      ],
    );
    if (page == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('没有找到局域网地址：$_whereLabel没有连上 Wi-Fi 或网线，手机连不进来。', key: const Key('remote-no-address'), style: TextStyle(color: scheme.error, fontSize: 12)),
      );
    }
    final qr = QrView(key: const Key('remote-qr'), data: code.isEmpty ? page : '$page#code=$code', size: tv ? 220 : 190);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth >= 480
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [qr, const SizedBox(width: 20), Expanded(child: text)])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [qr, const SizedBox(height: 12), text]),
      ),
    );
  }

  String get _whereLabel => _local ? (!kIsWeb && defaultTargetPlatform == TargetPlatform.android ? '这台设备' : '这台电脑') : '那台引擎';
}
