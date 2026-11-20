import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/discovery.dart';
import '../engine/lan.dart';
import '../engine/models.dart';

/// Which half of [LanSection] a page shows.
enum LanPart {
  /// Both, in one card.
  all,

  /// Using an engine on another device (源): the engines found on the LAN, the pairing with the one in use, and where
  /// players fetch the video from.
  connect,

  /// Letting other devices use this machine's engine (设置): the sharing switch, addresses, pairing code, devices.
  share,
}

/// 「局域网」: the LAN sharing switch of the engine on this machine (addresses, pairing code, paired devices), the
/// engines found on the LAN, and the pairing with the engine in use when it is on another device. 源 shows the
/// [LanPart.connect] half and 设置 the [LanPart.share] half.
class LanSection extends StatefulWidget {
  const LanSection({super.key, this.discovery, this.part = LanPart.all});

  final LanPart part;

  /// Tests pass their own; by default mDNS through the platform.
  final EngineDiscovery? discovery;

  @override
  State<LanSection> createState() => _LanSectionState();
}

class _LanSectionState extends State<LanSection> {
  LanStatus? _status;
  String? _error;
  bool _working = false;
  Timer? _poll;
  String _loadedFor = '';

  late final EngineDiscovery? _discovery = widget.discovery ?? createEngineDiscovery();
  bool _searching = false;
  List<DiscoveredEngine> _found = const [];
  String? _searchError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final key = state.connected && _isLocal(state.engineUrl) ? state.engineUrl : '';
    if (key != _loadedFor) {
      _loadedFor = key;
      _status = null;
      _poll?.cancel();
      // The sharing status is only shown by the half that has the switch.
      if (key.isNotEmpty && widget.part != LanPart.connect) _refresh();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _discovery?.stop();
    super.dispose();
  }

  static bool _isLocal(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost';
  }

  Future<void> _refresh() async {
    final state = AppScope.read(context);
    try {
      final status = await state.client.lanStatus();
      if (!mounted) return;
      setState(() {
        _status = status;
        _error = null;
      });
      _schedulePoll(status);
    } on EngineException catch (e) {
      // An engine from before LAN sharing (404) or one that cannot share: no switch.
      if (mounted) setState(() => _status = e.statusCode == 404 ? const LanStatus(supported: false, enabled: false) : null);
    } on StateError {
      // Not connected any more.
    }
  }

  /// While sharing is on, new devices and the next code show up without leaving the page.
  void _schedulePoll(LanStatus status) {
    _poll?.cancel();
    if (status.enabled) _poll = Timer(const Duration(seconds: 5), () => mounted ? _refresh() : null);
  }

  Future<void> _do(Future<LanStatus?> Function() action) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final status = await action();
      if (!mounted) return;
      if (status != null) {
        setState(() => _status = status);
        _schedulePoll(status);
      } else {
        await _refresh();
      }
    } on EngineException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _toggleSearch() async {
    final discovery = _discovery;
    if (discovery == null) return;
    if (_searching) {
      await discovery.stop();
      if (mounted) setState(() => _searching = false);
      return;
    }
    setState(() {
      _searching = true;
      _found = const [];
      _searchError = null;
    });
    try {
      await discovery.start((engines) {
        if (mounted) setState(() => _found = engines);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _searchError = '无法搜索局域网：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);
    final status = _status;
    final remote = !_isLocal(state.engineUrl);
    final connectHalf = widget.part != LanPart.share;
    final shareHalf = widget.part != LanPart.connect;
    final showPairing = connectHalf && remote;
    final showSharing = shareHalf && !remote && status != null && status.supported;
    final showDiscovery = connectHalf && _discovery != null;
    // 设置 on a device that uses another device's engine: there is nothing to share from here.
    final elsewhere = widget.part == LanPart.share && remote;
    if (!showPairing && !showSharing && !showDiscovery && !elsewhere && _error == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(switch (widget.part) { LanPart.connect => '局域网里的引擎', LanPart.share => '共享这台设备的引擎', LanPart.all => '局域网' }, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            const SizedBox(height: 10),
            if (elsewhere) Text('正在使用另一台设备上的引擎。局域网共享在引擎所在的那台设备上设置。', style: small),
            // The engine in use is on another device: pairing.
            if (showPairing) ...[
              Row(
                children: [
                  Icon(state.engineToken != null && state.connected ? Icons.verified_user_outlined : Icons.lock_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.connected
                          ? (state.engineToken != null ? '已与这台引擎配对' : '这台引擎不需要配对')
                          : (state.needsPairing || state.error?.contains('配对') == true ? '这台引擎需要配对' : '未连接'),
                    ),
                  ),
                  if (!state.connected)
                    FilledButton.tonal(key: const Key('lan-pair'), onPressed: state.busy ? null : state.startPairing, child: const Text('输入配对码')),
                  if (state.connected && state.engineToken != null)
                    TextButton(onPressed: state.busy ? null : state.forgetPairing, child: const Text('取消配对')),
                ],
              ),
              const SizedBox(height: 16),
              _streamSource(state, small),
              const SizedBox(height: 12),
            ],
            // The engine on this machine: the sharing switch.
            if (showSharing) _sharing(context, state, status, small),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: scheme.error))),
            if (showDiscovery) ...[
              if (showPairing || showSharing) const Divider(height: 28),
              Row(
                children: [
                  const Expanded(child: Text('发现局域网里的引擎')),
                  if (_searching) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  TextButton(key: const Key('lan-search'), onPressed: _toggleSearch, child: Text(_searching ? '停止' : '搜索')),
                ],
              ),
              if (_searchError != null) Text(_searchError!, style: TextStyle(color: scheme.error, fontSize: 12)),
              if (_searching && _found.isEmpty) Text('正在查找…（对方要开启「局域网共享」，并在同一个网络里）', style: small),
              for (final engine in _found)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(engine.name),
                  subtitle: Text(engine.url),
                  trailing: engine.url == state.engineUrl ? const Text('使用中') : const Icon(Icons.chevron_right),
                  enabled: !state.busy && engine.url != state.engineUrl,
                  onTap: () => state.connect(engine.url),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Where players get the video while the engine is on another device ([AppState.fetchDirect]).
  Widget _streamSource(AppState state, TextStyle small) {
    final explain = switch (state.streamSource) {
      StreamSource.auto when state.engineOnLan => '自动：这台引擎在同一个局域网里，视频经引擎取（有引擎的播放缓存，拖动进度条快）。',
      StreamSource.auto => '自动：这台引擎不在这个局域网里（比如经 Tailscale 连回家），视频由这台设备直接从片源取，不占引擎那边的上传带宽；'
          '引擎只负责解析地址和去广告。直连播不了时自动改经引擎。',
      StreamSource.engine => '经引擎：视频由引擎取来再转给这台设备，有引擎的播放缓存，但要占引擎那边的上传带宽。',
      StreamSource.direct => '直连片源：引擎只负责解析地址和去广告，视频由这台设备直接从片源取；直连播不了时自动改经引擎。拖动进度条时用不上引擎的缓存。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('播放时视频从哪里取'),
        const SizedBox(height: 8),
        SegmentedButton<StreamSource>(
          key: const Key('stream-source'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: StreamSource.auto, label: Text('自动')),
            ButtonSegment(value: StreamSource.engine, label: Text('经引擎')),
            ButtonSegment(value: StreamSource.direct, label: Text('直连片源')),
          ],
          selected: {state.streamSource},
          onSelectionChanged: (s) => state.setStreamSource(s.first),
        ),
        const SizedBox(height: 6),
        Text(explain, key: const Key('stream-source-explain'), style: small),
      ],
    );
  }

  Widget _sharing(BuildContext context, AppState state, LanStatus status, TextStyle small) {
    final scheme = Theme.of(context).colorScheme;
    final locked = status.lockedUntil > DateTime.now().millisecondsSinceEpoch;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('lan-sharing-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('局域网共享'),
          subtitle: Text(
            status.forced
                ? '引擎以 --lan 启动，始终共享'
                : status.enabled
                ? '同一网络里的其他设备配对后可以使用$_thisDevice的引擎（订阅、历史、收藏都是同一份）'
                : '已关闭：只有$_thisDevice能用这个引擎',
          ),
          value: status.enabled,
          onChanged: _working || status.forced ? null : (on) => _do(() => state.client.setLanSharing(on)),
        ),
        if (status.enabled) ...[
          if (status.error.isNotEmpty) Text(status.error, style: TextStyle(color: scheme.error, fontSize: 12)),
          // Android: the engine runs in a foreground service while it shares (see EngineService).
          if (_android) Text('共享期间通知栏里有「局域网共享中」，设备不会休眠（更耗电）；不用时关掉。', style: small),
          Text(
            status.addresses.isEmpty ? '没有找到局域网地址' : '其他设备连接：${status.addresses.join('  ')}${status.discoverable ? '（可被自动发现）' : ''}',
            style: small,
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text('配对码', style: small),
              const SizedBox(width: 12),
              SelectableText(
                locked ? '——' : status.code,
                key: const Key('lan-code'),
                style: const TextStyle(fontSize: 28, letterSpacing: 6, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '复制',
                onPressed: status.code.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: status.code)),
                icon: const Icon(Icons.copy, size: 18),
              ),
              TextButton(onPressed: _working ? null : () => _do(() => state.client.newPairingCode()), child: const Text('换一个')),
            ],
          ),
          Text(
            locked
                ? '配对码输错次数太多，暂时锁定到 ${_hm(status.lockedUntil)}'
                : '在要连接的设备上输入它；${_hm(status.codeExpiresAt)} 前有效，用过一次就作废',
            style: small,
          ),
          const SizedBox(height: 12),
          Text('已配对的设备', style: small),
          if (status.devices.isEmpty) Text('还没有', style: small),
          for (final d in status.devices)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.devices_other_outlined),
              title: Text(d.name),
              subtitle: Text([
                '配对于 ${_date(d.createdAt)}',
                if (d.lastSeenAt > 0) '最近 ${_date(d.lastSeenAt)}',
                if (d.lastAddress.isNotEmpty) d.lastAddress,
              ].join(' · ')),
              trailing: TextButton(
                onPressed: _working ? null : () => _do(() async {
                  await state.client.revokeDevice(d.id);
                  return null;
                }),
                child: const Text('撤销'),
              ),
            ),
        ],
      ],
    );
  }

  /// The engine shares from a phone, tablet or TV box rather than a computer.
  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static String get _thisDevice => _android ? '这台设备' : '这台电脑';

  static String _hm(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  static String _date(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.month}月${t.day}日 ${_hm(ms)}';
  }
}
