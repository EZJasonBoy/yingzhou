import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../engine/engine_client.dart';
import '../ui/theme.dart' show debugLegacyTheme;
import 'frames.dart';

const _engineDefault = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://127.0.0.1:19978');
const _framesDefine = String.fromEnvironment('LAB_FRAMES', defaultValue: 'desktop,phone,tablet,tv');
const _themeDefine = String.fromEnvironment('LAB_THEME');
const _zoomDefine = String.fromEnvironment('LAB_ZOOM');
const _shotDefine = String.fromEnvironment('LAB_SHOT');
const _exitDefine = bool.fromEnvironment('LAB_EXIT');
const _legacyDefine = bool.fromEnvironment('LAB_LEGACY');

// The lab's own colours: the brand's dusk, so its chrome never looks like part of the app it frames.
const _night = Color(0xFF17162E);
const _bar = Color(0xFF211F40);
const _coral = Color(0xFFF4A08A);
const _ink = Color(0xFFECE9FF);
const _muted = Color(0x99C9C6E8);

/// The lab: a toolbar (engine, frames, light / dark, zoom, reset, screenshot) over a canvas of [LabFrame]s.
class DesignLab extends StatefulWidget {
  const DesignLab({super.key});

  @override
  State<DesignLab> createState() => _DesignLabState();
}

class _DesignLabState extends State<DesignLab> {
  final _canvas = GlobalKey();
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  final _vertical = ScrollController();
  late final _engineField = TextEditingController(text: _engineDefault);
  String _engineUrl = _engineDefault;
  late Set<String> _frames = _framesDefine.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
  ThemeMode? _theme = ThemeMode.values.asNameMap()[_themeDefine];
  double _zoom = double.tryParse(_zoomDefine) ?? 0.5;
  int _generation = 0;
  String _engineInfo = '';

  @override
  void initState() {
    super.initState();
    debugLegacyTheme = _legacyDefine;
    _probe();
    if (_shotDefine.isNotEmpty) {
      // Give the frames time to load their pages and posters, then save the canvas.
      Timer(const Duration(seconds: 14), () async {
        final path = await _saveShot(File(_shotDefine));
        // ignore: avoid_print
        print('LAB_SHOT:$path');
        if (_exitDefine) exit(0);
      });
    }
  }

  @override
  void dispose() {
    _engineField.dispose();
    _vertical.dispose();
    super.dispose();
  }

  /// Says in the toolbar which engine answers at the address, or that none does.
  Future<void> _probe() async {
    setState(() => _engineInfo = '连接中…');
    try {
      final info = await EngineClient(Uri.parse(_engineUrl)).info();
      if (mounted) setState(() => _engineInfo = '${info.name} ${info.version}');
    } catch (_) {
      if (mounted) setState(() => _engineInfo = '连不上引擎');
    }
  }

  void _applyEngine() {
    final url = _engineField.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _engineUrl = url;
      _generation++;
    });
    _probe();
  }

  void _reset() => setState(() => _generation++);

  Future<String> _saveShot([File? target]) async {
    final boundary = _canvas.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ratio = (1 / _zoom).clamp(1.0, 2.5);
    final image = await boundary.toImage(pixelRatio: ratio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = target ??
        File('${(await getDownloadsDirectory() ?? Directory.systemTemp).path}${Platform.pathSeparator}'
            'yingzhou-design-lab-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
    return file.path;
  }

  Future<void> _shotButton() async {
    try {
      final path = await _saveShot();
      _messenger.currentState?.showSnackBar(SnackBar(content: Text('已保存：$path')));
    } catch (e) {
      _messenger.currentState?.showSnackBar(SnackBar(content: Text('截图失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: _coral, brightness: Brightness.dark).copyWith(primary: _coral, surface: _bar);
    return MaterialApp(
      title: '映舟 · 设计台',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messenger,
      theme: ThemeData(
        colorScheme: scheme,
        scaffoldBackgroundColor: _night,
        fontFamilyFallback: const ['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'Noto Sans SC'],
        visualDensity: VisualDensity.compact,
      ),
      home: Scaffold(
        body: Column(
          children: [
            _toolbar(),
            Expanded(child: _canvasView()),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    Widget group(String label, List<Widget> children) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: _muted, fontSize: 12)),
        const SizedBox(width: 8),
        ...children,
      ],
    );
    return Material(
      color: _bar,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Wrap(
          spacing: 22,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('映舟 · 设计台', style: TextStyle(color: _ink, fontWeight: FontWeight.w700, fontSize: 15)),
            group('引擎', [
              SizedBox(
                width: 230,
                child: TextField(
                  controller: _engineField,
                  style: const TextStyle(fontSize: 13, color: _ink),
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                  onSubmitted: (_) => _applyEngine(),
                ),
              ),
              const SizedBox(width: 6),
              TextButton(onPressed: _applyEngine, child: const Text('连接')),
              Text(_engineInfo, style: const TextStyle(color: _muted, fontSize: 12)),
            ]),
            group('设备', [
              for (final f in FrameSpec.all)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: FilterChip(
                    label: Text(f.label),
                    selected: _frames.contains(f.id),
                    onSelected: (on) => setState(() => _frames = on ? {..._frames, f.id} : ({..._frames}..remove(f.id))),
                  ),
                ),
            ]),
            group('明暗', [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'auto', label: Text('默认')),
                  ButtonSegment(value: 'light', label: Text('浅色')),
                  ButtonSegment(value: 'dark', label: Text('深色')),
                ],
                selected: {_theme?.name ?? 'auto'},
                onSelectionChanged: (s) => setState(() {
                  final mode = ThemeMode.values.asNameMap()[s.first];
                  // Back to each form's own default needs fresh copies; light and dark switch in place.
                  if (mode == null && _theme != null) _generation++;
                  _theme = mode;
                }),
              ),
            ]),
            group('主题', [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [ButtonSegment(value: false, label: Text('映舟')), ButtonSegment(value: true, label: Text('旧版'))],
                selected: {debugLegacyTheme},
                // The theme is built when a copy starts: switching makes fresh copies.
                onSelectionChanged: (s) => setState(() {
                  debugLegacyTheme = s.first;
                  _generation++;
                }),
              ),
            ]),
            group('缩放', [
              SizedBox(
                width: 150,
                child: Slider(value: _zoom, min: 0.25, max: 1, divisions: 15, label: '${(_zoom * 100).round()}%', onChanged: (v) => setState(() => _zoom = v)),
              ),
              Text('${(_zoom * 100).round()}%', style: const TextStyle(color: _muted, fontSize: 12)),
            ]),
            TextButton.icon(onPressed: _reset, icon: const Icon(Icons.restart_alt_rounded, size: 18), label: const Text('全部重置')),
            TextButton.icon(onPressed: _shotButton, icon: const Icon(Icons.photo_camera_outlined, size: 18), label: const Text('截图')),
          ],
        ),
      ),
    );
  }

  Widget _canvasView() {
    final specs = FrameSpec.all.where((f) => _frames.contains(f.id)).toList();
    if (specs.isEmpty) return const Center(child: Text('在上面选几种设备', style: TextStyle(color: _muted)));
    return Scrollbar(
      controller: _vertical,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: RepaintBoundary(
            key: _canvas,
            child: ColoredBox(
              color: _night,
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Wrap(
                  spacing: 36,
                  runSpacing: 36,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  children: [
                    for (final spec in specs)
                      LabFrame(
                        key: ValueKey('${spec.id}/$_generation/$_engineUrl'),
                        spec: spec,
                        engineUrl: _engineUrl,
                        zoom: _zoom,
                        themeMode: _theme,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
