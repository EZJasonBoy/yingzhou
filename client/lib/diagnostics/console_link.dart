import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/lan.dart';
import '../engine/models.dart' show EngineException;
import '../remote/remote_agent.dart';
import '../remote/remote_screen.dart';
import '../ui/device_form.dart';
import '../ui/phone_input.dart' show QrView;
import '../ui/phone_input_server.dart';

/// The web console's page [page] on the engine at [base] (`http://192.168.1.5:9978`), with the pairing code when a
/// phone still has to pair, like the pairing QR code: `http://192.168.1.5:9978/remote/#page=logs&code=123456`.
String consoleUrl(String base, {String page = 'logs', String code = ''}) => '$base/remote/#page=$page${code.isEmpty ? '' : '&code=$code'}';

/// 用手机查看 on the 诊断与反馈 page: a QR code that opens the web console's 日志与崩溃 page on a phone, where the log,
/// the crash records and the engine's output can be read, downloaded and sent as feedback (a TV has no browser and
/// no clipboard to paste into). The phone gets them through the remote control, so while 「允许手机遥控」 is off the
/// switch is offered here instead (with the engine on this device it switches LAN sharing on too, as in 设置).
///
/// Shows nothing where a phone cannot come in at all: no remote control in this app (a page pumped alone, the web
/// build), no engine, or an engine on this device that cannot share.
class PhoneConsoleCard extends StatefulWidget {
  const PhoneConsoleCard({super.key, this.findAddresses});

  /// Tests: this device's addresses (default [PhoneInputServer.lanAddresses]).
  final Future<List<String>> Function()? findAddresses;

  @override
  State<PhoneConsoleCard> createState() => _PhoneConsoleCardState();
}

class _PhoneConsoleCardState extends State<PhoneConsoleCard> {
  LanStatus? _lan;
  String _loadedFor = '';
  Timer? _poll;
  List<String>? _ranked;
  bool _working = false;
  String? _error;

  static bool _isLocal(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
    final key = state != null && state.connected && _isLocal(state.engineUrl) ? state.engineUrl : '';
    if (key == _loadedFor) return;
    _loadedFor = key;
    _lan = null;
    _poll?.cancel();
    if (key.isNotEmpty) unawaited(_refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// LAN sharing of the engine on this device; again every few seconds while it is on (the pairing code changes).
  Future<void> _refresh() async {
    final state = context.getInheritedWidgetOfExactType<AppScope>()?.notifier;
    if (state == null) return;
    LanStatus? status;
    try {
      status = await state.client.lanStatus();
    } on EngineException catch (e) {
      // An engine from before LAN sharing: a phone cannot come in.
      if (e.statusCode == 404) status = const LanStatus(supported: false, enabled: false);
    } on StateError {
      // Not connected any more.
    }
    if (!mounted || status == null) return;
    setState(() => _lan = status);
    _poll?.cancel();
    if (status.enabled) _poll = Timer(const Duration(seconds: 5), () => mounted ? _refresh() : null);
  }

  Future<void> _loadAddresses() async {
    if (_ranked != null) return;
    _ranked = const [];
    final found = await (widget.findAddresses ?? PhoneInputServer.lanAddresses)();
    if (mounted) setState(() => _ranked = found);
  }

  Future<void> _switchOn(AppState state, RemoteAgent agent, bool local) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final lan = _lan;
      if (local && lan != null && !lan.enabled) {
        final status = await state.client.setLanSharing(true);
        if (!mounted) return;
        setState(() => _lan = status);
        if (!status.enabled) return;
        unawaited(_refresh());
      }
      await agent.setEnabled(true);
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final agent = RemoteScreen.maybeAgentOf(context);
    final state = context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
    if (agent == null || kIsWeb || state == null || !state.connected) return const SizedBox.shrink();
    final local = _isLocal(state.engineUrl);
    final lan = _lan;
    if (local && (lan == null || !lan.supported)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tv = isTv(context);
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: tv ? 14 : 12, height: 1.5);
    final on = agent.enabled && (!local || lan!.enabled);

    Widget body;
    if (!on) {
      body = SwitchListTile(
        key: const Key('diag-console-switch'),
        title: const Text('允许手机遥控'),
        subtitle: Text(
          local
              ? '打开后用手机扫码，就能在手机上查看、下载日志和崩溃记录，再反馈问题。会同时开启「局域网共享」，手机经它连进来。'
              : '打开后用手机扫码，就能在手机上查看、下载日志和崩溃记录，再反馈问题。手机要先和这台设备用的引擎配对。',
        ),
        value: false,
        onChanged: _working || state.busy ? null : (_) => _switchOn(state, agent, local),
      );
    } else {
      final uri = Uri.parse(state.engineUrl);
      String? base;
      var code = '';
      if (local) {
        unawaited(_loadAddresses());
        final listening = [for (final a in lan!.addresses) Uri.tryParse(a)?.host ?? ''].where((h) => h.isNotEmpty).toList();
        final ranked = [for (final h in _ranked ?? const <String>[]) if (listening.contains(h)) h];
        final host = [...ranked, ...listening].firstOrNull;
        if (host != null) base = 'http://$host:${lan.port}';
        if (lan.lockedUntil <= DateTime.now().millisecondsSinceEpoch) code = lan.code;
      } else {
        base = '${uri.scheme}://${uri.authority}';
      }
      if (base == null) {
        body = Padding(
          padding: const EdgeInsets.all(16),
          child: Text('没有找到局域网地址：这台设备没有连上 Wi-Fi 或网线，手机连不进来。', key: const Key('diag-console-no-address'), style: TextStyle(color: scheme.error)),
        );
      } else {
        final qr = QrView(key: const Key('diag-console-qr'), data: consoleUrl(base, code: code), size: tv ? 220 : 180);
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('用手机查看、下载和反馈', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '扫码在手机上打开「日志与崩溃」：日志、崩溃记录和引擎输出都能看、能下载成文件；「生成反馈」把全部诊断信息带到手机上的 GitHub 新问题页，不用在${tv ? '电视' : '这台设备'}上复制粘贴。'
              '${code.isEmpty ? '' : '二维码里带着配对码，不用再输入。'}',
              style: TextStyle(fontSize: tv ? 16 : 14, height: 1.5),
            ),
            const SizedBox(height: 6),
            Text('离开这台设备之前，订阅地址、令牌、签名参数和用户目录都会被遮掉。手机要和这台设备连在同一个 Wi-Fi 或路由器下。', style: small),
            const SizedBox(height: 6),
            // On a TV a selectable text would keep the arrows for its caret.
            if (tv)
              Text('$base/remote/', key: const Key('diag-console-url'), style: small.copyWith(fontFamily: 'monospace'))
            else
              SelectableText('$base/remote/', key: const Key('diag-console-url'), style: small.copyWith(fontFamily: 'monospace')),
          ],
        );
        body = Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 480
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [qr, const SizedBox(width: 20), Expanded(child: text)])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [qr, const SizedBox(height: 12), text]),
          ),
        );
      }
    }
    return Column(
      key: const Key('diag-console'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
          child: Text('用手机查看', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        ),
        Card(clipBehavior: Clip.antiAlias, child: body),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(_error!, style: TextStyle(color: scheme.error))),
      ],
    );
  }
}
