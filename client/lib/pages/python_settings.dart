import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/models.dart';
import '../engine/python.dart';

/// Python 蜘蛛 on the 源 page: which Python the engine uses (or why there is none), a path to set, the 「下载 Python
/// 运行时」 button (Windows), the packages spiders commonly import and what spiders reported missing. Nothing is
/// downloaded or installed until the user confirms a dialog that says what, from where, how big and to where.
/// Shows nothing when the connected engine has no Python support (the Android app's engine).
class PythonSettings extends StatefulWidget {
  const PythonSettings({super.key});

  static String size(int bytes) => bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(bytes / 1024).round()} KB';

  @override
  State<PythonSettings> createState() => _PythonSettingsState();
}

class _PythonSettingsState extends State<PythonSettings> {
  static const indexPresets = {
    '': '跟随 pip 设置',
    'https://pypi.org/simple/': 'PyPI 官方',
    'https://pypi.tuna.tsinghua.edu.cn/simple/': '清华 TUNA',
    'https://mirrors.aliyun.com/pypi/simple/': '阿里云',
    'https://mirrors.cloud.tencent.com/pypi/simple/': '腾讯云',
  };
  static const runtimePresets = {
    '': 'Python 官方（python.org）',
    'https://mirrors.huaweicloud.com/python/': '华为云',
    'https://registry.npmmirror.com/-/binary/python/': 'npmmirror',
  };
  bool _customIndex = false;
  bool _customRuntime = false;
  PythonStatus? _status;

  /// Which engine [_status] is from.
  Object? _askedOf;
  final _path = TextEditingController();
  final _index = TextEditingController();
  final _mirror = TextEditingController();
  Timer? _poll;
  bool _working = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final engine = state.connected ? state.client : null;
    if (!identical(engine, _askedOf)) {
      _askedOf = engine;
      _status = null;
      _poll?.cancel();
      if (engine != null) _load();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _path.dispose();
    _index.dispose();
    _mirror.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    final state = AppScope.read(context);
    final asked = _askedOf;
    PythonStatus? status;
    try {
      status = await state.client.pythonStatus(refresh: refresh);
    } on EngineException {
      // An engine without Python spiders (or from before them): nothing to show.
      status = const PythonStatus(supported: false);
    } on StateError {
      return;
    }
    if (mounted && identical(asked, _askedOf)) _show(status);
  }

  void _show(PythonStatus status) {
    final before = _status;
    setState(() {
      if (before == null || before.settings.path != status.settings.path) _path.text = status.settings.path;
      if (before == null || before.settings.indexUrl != status.settings.indexUrl) {
        _index.text = status.settings.indexUrl;
        _customIndex = !indexPresets.containsKey(_index.text);
      }
      if (before == null || before.settings.downloadMirror != status.settings.downloadMirror) {
        _mirror.text = status.settings.downloadMirror;
        _customRuntime = !runtimePresets.containsKey(_mirror.text);
      }
      _status = status;
    });
    final running = status.task?.running ?? false;
    if (running && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _load());
    } else if (!running && _poll != null) {
      _poll?.cancel();
      _poll = null;
    }
    // What the engine can run may have changed (a Python was found, packages arrived): the site list follows.
    final state = AppScope.read(context);
    final engineSays = state.info?.capabilities['py'] ?? false;
    if (engineSays != status.available || (before?.task?.running ?? false) && !running) state.refreshInfo();
  }

  Future<void> _act(Future<PythonStatus> Function() action) async {
    setState(() => _working = true);
    try {
      final status = await action();
      if (mounted) _show(status);
    } on EngineException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: SelectableText(body)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(key: const Key('python-confirm'), onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _download(PythonDownloadOffer offer) async {
    final ok = await _confirm(
      '下载 Python 运行时',
      '从 ${offer.host} 下载 CPython ${offer.version} 的 Windows 免安装版（${PythonSettings.size(offer.sizeBytes)}），'
          '校验后解压到：\n${offer.dir}\n\n只给映舟的引擎用，不会安装到系统、不改环境变量。之后可以在这里删除。',
      '下载',
    );
    if (ok && mounted) await _act(() => AppScope.read(context).client.downloadPython());
  }

  Future<void> _install(PythonStatus status, List<String> packages) async {
    final index = status.settings.indexUrl.isEmpty ? 'PyPI（pypi.org，或 pip 自己设置的镜像）' : status.settings.indexUrl;
    final ok = await _confirm(
      '安装 Python 包',
      '用 pip 从 $index 下载并安装：\n${packages.join('、')}\n（以及它们依赖的包）\n\n'
          '装到引擎自己的目录：\n${status.packagesDir}\n不会装进 ${status.python?.path ?? '系统'} 自己的环境。',
      '安装',
    );
    if (ok && mounted) await _act(() => AppScope.read(context).client.installPythonPackages(packages));
  }

  void _showLog(PythonTaskState task) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(task.kind == 'download' ? '下载输出' : 'pip 输出'),
        content: SizedBox(
          width: 640,
          height: 360,
          child: SingleChildScrollView(
            reverse: true,
            child: SelectableText(task.log.isEmpty ? task.message : task.log.join('\n'), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final status = _status;
    if (!state.connected || status == null || !status.supported) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final task = status.task;
    final busy = _working || (task?.running ?? false);
    final python = status.python;
    final offer = status.download;
    final missingCommon = status.notInstalled;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        key: const Key('python-settings'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Python 蜘蛛', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                  ),
                  IconButton(tooltip: '重新查找 Python', icon: const Icon(Icons.refresh, size: 18), onPressed: busy ? null : () => _load(refresh: true)),
                ],
              ),
              if (python != null) ...[
                Text('Python ${python.version} · ${python.sourceLabel}', key: const Key('python-found'), style: text.titleMedium),
                Text(python.path, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ] else ...[
                Text('还不能打开 Python 站点', key: const Key('python-missing'), style: text.titleMedium),
                Text(
                  '${status.problem.isEmpty ? '没有找到 Python' : status.problem}。订阅里 api 以 .py 结尾的站点和直播要用 Python 3.8 或更新的版本运行。',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
              if (python != null && status.problem.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(status.problem, style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('python-path'),
                      controller: _path,
                      enabled: !busy,
                      decoration: const InputDecoration(labelText: 'Python 位置', hintText: '留空自动查找；可填 python.exe 或它所在的文件夹'),
                      onSubmitted: (v) => _act(() => state.client.updatePython(path: v)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: busy ? null : () => _act(() => state.client.updatePython(path: _path.text)),
                    child: const Text('应用'),
                  ),
                ],
              ),
              if (offer != null && (python == null || offer.installed)) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!offer.installed)
                      FilledButton.icon(
                        key: const Key('python-download'),
                        icon: const Icon(Icons.download, size: 18),
                        onPressed: busy ? null : () => _download(offer),
                        label: Text('下载 Python 运行时（${PythonSettings.size(offer.sizeBytes)}）'),
                      )
                    else
                      OutlinedButton(
                        key: const Key('python-remove'),
                        onPressed: busy ? null : () => _act(() => state.client.removeDownloadedPython()),
                        child: const Text('删除下载的运行时'),
                      ),
                    Text(
                      offer.installed ? 'CPython ${offer.version}，在 ${offer.dir}' : 'CPython ${offer.version}，来自 ${offer.host}，下载前会再确认',
                      style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
              if (offer == null && python == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '请安装 Python 3（macOS 可用 python.org 的安装包或 Homebrew），装好后点右上角的刷新；装在别处就在上面填它的位置。',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              if (python != null) ...[
                const SizedBox(height: 16),
                Text('常用的包', style: text.labelLarge),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final p in status.packages)
                      Chip(
                        key: Key('python-package-${p.name}'),
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          p.installed ? Icons.check_circle : Icons.radio_button_unchecked,
                          size: 16,
                          color: p.installed ? scheme.primary : scheme.outline,
                        ),
                        label: Text(p.name),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  missingCommon.isEmpty ? 'TVBox 的 Python 蜘蛛常用的包都有了' : '多数 Python 蜘蛛至少要 requests，解析网页常用 lxml；没装的包在站点用到时会提示',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (missingCommon.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton.tonal(
                      key: const Key('python-install-common'),
                      onPressed: busy ? null : () => _install(status, [for (final p in missingCommon) p.name]),
                      child: Text('安装常用依赖（${missingCommon.length} 个）'),
                    ),
                  ),
              ],
              for (final m in status.missing)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, size: 18, color: scheme.error),
                      const SizedBox(width: 8),
                      Expanded(child: Text('「${m.site}」缺少 Python 包 ${m.packageName}${m.packageName == m.module ? '' : '（模块 ${m.module}）'}')),
                      if (python != null)
                        TextButton(
                          key: Key('python-install-${m.packageName}'),
                          onPressed: busy ? null : () => _install(status, [m.packageName]),
                          child: Text('安装 ${m.packageName}'),
                        ),
                    ],
                  ),
                ),
              if (task != null) ...[
                const SizedBox(height: 12),
                if (task.running) LinearProgressIndicator(value: task.progress >= 0 && task.progress <= 1 && task.kind == 'download' ? task.progress : null),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.running ? (task.log.isEmpty || task.kind == 'download' ? task.message : task.log.last) : task.message,
                        key: const Key('python-task'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: task.state == 'failed' ? scheme.error : scheme.onSurfaceVariant),
                      ),
                    ),
                    if (task.log.isNotEmpty) TextButton(onPressed: () => _showLog(task), child: const Text('查看输出')),
                  ],
                ),
              ],
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text('镜像', style: text.bodyMedium),
                  subtitle: Text('下载慢时可以换成国内镜像', style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  children: [
                    _mirrorPicker('python-index', 'PyPI 镜像（安装依赖）', indexPresets, _index, _customIndex, busy, (custom) => _customIndex = custom),
                    const SizedBox(height: 8),
                    if (offer != null)
                      _mirrorPicker('python-mirror', 'Python 运行时下载镜像', runtimePresets, _mirror, _customRuntime, busy, (custom) => _customRuntime = custom),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.tonal(
                        onPressed: busy ? null : () => _act(() => state.client.updatePython(indexUrl: _index.text, downloadMirror: _mirror.text)),
                        child: const Text('保存'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mirrorPicker(
    String name,
    String title,
    Map<String, String> presets,
    TextEditingController controller,
    bool custom,
    bool busy,
    ValueChanged<bool> chooseCustom,
  ) {
    const customValue = 'custom';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        DropdownButton<String>(
          key: Key('$name-choice'),
          value: custom ? customValue : controller.text,
          isExpanded: true,
          items: [
            for (final preset in presets.entries) DropdownMenuItem(value: preset.key, child: Text(preset.value)),
            const DropdownMenuItem(value: customValue, child: Text('自定义地址…')),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() {
                    chooseCustom(value == customValue);
                    if (value != customValue) {
                      controller.text = value;
                    } else if (presets.containsKey(controller.text)) {
                      controller.clear();
                    }
                  });
                },
        ),
        if (custom)
          TextField(
            key: Key(name),
            controller: controller,
            enabled: !busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: '自定义镜像地址', hintText: 'https://…'),
          ),
      ],
    );
  }
}
