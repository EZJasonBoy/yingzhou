import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/drives.dart';
import 'browse_page.dart' show errorText;

/// Adds a drive, or changes [drive]. The password and token go to the engine and stay there: when changing a drive
/// the fields start empty, and left empty they keep what the engine has.
Future<DriveInfo?> showDriveForm(BuildContext context, {DriveInfo? drive}) =>
    showDialog<DriveInfo>(context: context, builder: (_) => DriveFormDialog(drive: drive));

class DriveFormDialog extends StatefulWidget {
  const DriveFormDialog({super.key, this.drive});

  final DriveInfo? drive;

  @override
  State<DriveFormDialog> createState() => _DriveFormDialogState();
}

class _DriveFormDialogState extends State<DriveFormDialog> {
  late DriveKind _kind = widget.drive?.kind ?? DriveKind.alist;
  late final _name = TextEditingController(text: widget.drive?.name ?? '');
  late final _url = TextEditingController(text: widget.drive?.url ?? '');
  late final _username = TextEditingController(text: widget.drive?.username ?? '');
  final _password = TextEditingController();
  final _token = TextEditingController();
  late final _root = TextEditingController(text: widget.drive?.root ?? '/');
  late bool _proxy = widget.drive?.proxy ?? false;

  /// The saved password / token is to be removed.
  bool _clearPassword = false;
  bool _clearToken = false;

  bool _busy = false;
  DriveTestResult? _test;
  String? _error;

  bool get _editing => widget.drive != null;

  @override
  void dispose() {
    for (final c in [_name, _url, _username, _password, _token, _root]) {
      c.dispose();
    }
    super.dispose();
  }

  /// What is sent: everything shown, and the password and token only when typed in (or to be removed).
  Map<String, Object?> _fields() {
    final local = _kind == DriveKind.local;
    return {
      'kind': _kind.wire,
      'name': _name.text.trim(),
      'url': _url.text.trim(),
      if (!local) 'username': _username.text.trim(),
      if (!local && (_password.text.isNotEmpty || _clearPassword)) 'password': _password.text,
      if (_kind == DriveKind.alist && (_token.text.isNotEmpty || _clearToken)) 'token': _token.text.trim(),
      if (!local) 'root': _root.text.trim().isEmpty ? '/' : _root.text.trim(),
      if (!local) 'proxy': _proxy,
    };
  }

  Future<void> _runTest() async {
    setState(() {
      _busy = true;
      _test = null;
      _error = null;
    });
    try {
      final result = await AppScope.read(context).client.testDrive({..._fields(), if (_editing) 'id': widget.drive!.id});
      if (mounted) setState(() => _test = result);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_url.text.trim().isEmpty) {
      setState(() => _error = _kind == DriveKind.local ? '请填写文件夹路径' : '请填写地址');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final client = AppScope.read(context).client;
      final saved = _editing ? await client.updateDrive(widget.drive!.id, _fields()) : await client.addDrive(_fields());
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final local = _kind == DriveKind.local;
    final (urlLabel, urlHint, urlHelp) = switch (_kind) {
      DriveKind.alist => ('地址', 'http://192.168.1.2:5244', 'AList / OpenList 网页的地址'),
      DriveKind.webdav => ('WebDAV 地址', 'https://example.com/dav', 'AList / OpenList 的 WebDAV 在 /dav；Nextcloud 在 /remote.php/dav/files/<用户名>'),
      DriveKind.local => ('文件夹路径', r'D:\Videos', '引擎所在电脑上的文件夹，比如 D:\\Videos；只能在那台电脑上的映舟里添加'),
    };
    final saved = widget.drive;
    return AlertDialog(
      title: Text(_editing ? '编辑网盘' : '添加网盘'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<DriveKind>(
                segments: [for (final k in DriveKind.values) ButtonSegment(value: k, label: Text(k.label, key: Key('drive-kind-${k.wire}')))],
                selected: {_kind},
                showSelectedIcon: false,
                onSelectionChanged: _editing && saved!.kind == DriveKind.local ? null : (s) => setState(() {
                  _kind = s.first;
                  _test = null;
                }),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('drive-url'),
                controller: _url,
                decoration: InputDecoration(labelText: urlLabel, hintText: urlHint, helperText: urlHelp, helperMaxLines: 2, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('drive-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: '名称（可不填）', border: OutlineInputBorder()),
              ),
              if (!local) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('drive-username'),
                        controller: _username,
                        decoration: InputDecoration(labelText: _kind == DriveKind.alist ? '用户名（可不填，用访客）' : '用户名', border: const OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('drive-password'),
                        controller: _password,
                        obscureText: true,
                        enabled: !_clearPassword,
                        decoration: InputDecoration(
                          labelText: '密码',
                          hintText: saved?.hasPassword == true ? '已保存，不改就留空' : null,
                          border: const OutlineInputBorder(),
                          suffixIcon: saved?.hasPassword == true
                              ? IconButton(
                                  tooltip: _clearPassword ? '保留已保存的密码' : '清除已保存的密码',
                                  icon: Icon(_clearPassword ? Icons.undo : Icons.backspace_outlined),
                                  onPressed: () => setState(() {
                                    _clearPassword = !_clearPassword;
                                    _password.clear();
                                  }),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_kind == DriveKind.alist) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('drive-token'),
                  controller: _token,
                  obscureText: true,
                  enabled: !_clearToken,
                  decoration: InputDecoration(
                    labelText: '令牌（可不填）',
                    helperText: 'AList 设置 → 其他 里的令牌；填了就不用用户名和密码',
                    hintText: saved?.hasToken == true ? '已保存，不改就留空' : null,
                    border: const OutlineInputBorder(),
                    suffixIcon: saved?.hasToken == true
                        ? IconButton(
                            tooltip: _clearToken ? '保留已保存的令牌' : '清除已保存的令牌',
                            icon: Icon(_clearToken ? Icons.undo : Icons.backspace_outlined),
                            onPressed: () => setState(() {
                              _clearToken = !_clearToken;
                              _token.clear();
                            }),
                          )
                        : null,
                  ),
                ),
              ],
              if (!local) ...[
                const SizedBox(height: 12),
                TextField(
                  key: const Key('drive-root'),
                  controller: _root,
                  decoration: const InputDecoration(labelText: '起始文件夹', hintText: '/', helperText: '只看网盘里的这个文件夹，比如 /电影', border: OutlineInputBorder()),
                ),
                SwitchListTile(
                  key: const Key('drive-proxy'),
                  contentPadding: EdgeInsets.zero,
                  value: _proxy,
                  onChanged: (v) => setState(() => _proxy = v),
                  title: const Text('经引擎转发'),
                  subtitle: const Text('播放器不直接连网盘，由引擎取来再给播放器。网盘只有引擎那台机器连得上时打开；带账号的 WebDAV 总是经引擎。'),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                local ? '文件夹里的视频由引擎提供给播放器，局域网里配对过的设备也能看。' : '密码和令牌只保存在引擎里，不会发给播放器或其他设备。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              if (_test != null) ...[
                const SizedBox(height: 12),
                Row(
                  key: const Key('drive-test-result'),
                  children: [
                    Icon(_test!.ok ? Icons.check_circle : Icons.error_outline, color: _test!.ok ? Colors.green : scheme.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_test!.message, style: TextStyle(color: _test!.ok ? null : scheme.error))),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, key: const Key('drive-form-error'), style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(key: const Key('drive-test'), onPressed: _busy ? null : _runTest, child: const Text('测试连接')),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(key: const Key('drive-save'), onPressed: _busy ? null : _save, child: Text(_editing ? '保存' : '添加')),
      ],
    );
  }
}
