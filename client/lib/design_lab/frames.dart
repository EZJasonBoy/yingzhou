import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/engine_client.dart';
import '../main.dart';
import '../settings.dart';
import '../ui/device_form.dart';

/// A device the lab shows: a form and a screen in logical pixels.
@immutable
class FrameSpec {
  const FrameSpec(this.id, this.label, this.form, this.size);

  final String id;
  final String label;
  final DeviceForm form;
  final Size size;

  static const all = [
    FrameSpec('desktop', '桌面', DeviceForm.desktop, Size(1440, 900)),
    FrameSpec('phone', '手机', DeviceForm.phone, Size(393, 852)),
    FrameSpec('phone-landscape', '手机横屏', DeviceForm.phone, Size(852, 393)),
    FrameSpec('tablet', '平板', DeviceForm.tablet, Size(1180, 820)),
    FrameSpec('tv', '电视', DeviceForm.tv, Size(960, 540)),
  ];

  static FrameSpec byId(String id) => all.firstWhere((f) => f.id == id, orElse: () => all.first);
}

/// One live copy of the app in a frame of [spec]'s size, drawn at [zoom]. It has its own [AppState] (settings in
/// memory, so nothing touches the real app's) and talks to the engine at [engineUrl].
class LabFrame extends StatefulWidget {
  const LabFrame({super.key, required this.spec, required this.engineUrl, required this.zoom, this.themeMode});

  final FrameSpec spec;
  final String engineUrl;
  final double zoom;

  /// Light or dark for this copy; null keeps the app's own default for the form.
  final ThemeMode? themeMode;

  @override
  State<LabFrame> createState() => _LabFrameState();
}

class _LabFrameState extends State<LabFrame> {
  late final AppState _state;
  late final DeviceFormController _form;

  @override
  void initState() {
    super.initState();
    final settings = MemorySettings();
    final mode = widget.themeMode;
    if (mode != null) settings.setString('ui.theme', mode.name);
    _state = AppState(clientFactory: (url) => EngineClient(url), engineUrl: widget.engineUrl, settings: settings);
    _form = DeviceFormController.fixed(widget.spec.form);
  }

  @override
  void didUpdateWidget(LabFrame old) {
    super.didUpdateWidget(old);
    final mode = widget.themeMode;
    if (mode != null && mode != old.themeMode) _state.themeChoice.set(mode);
  }

  @override
  void dispose() {
    _state.dispose();
    _form.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.spec.size;
    final z = widget.zoom;
    final base = MediaQuery.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: widget.spec.label, style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFFECE9FF))),
              TextSpan(text: '   ${size.width.toInt()} × ${size.height.toInt()}', style: const TextStyle(color: Color(0x99C9C6E8), fontSize: 12)),
            ]),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.spec.form == DeviceForm.phone ? 22 : 10),
            boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 28, offset: Offset(0, 14))],
            border: Border.all(color: const Color(0x33FFFFFF)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.spec.form == DeviceForm.phone ? 22 : 10),
            child: SizedBox(
              width: size.width * z,
              height: size.height * z,
              child: FittedBox(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: MediaQuery(
                    // The copy sees a screen of this size and nothing of the lab around it.
                    data: base.copyWith(size: size, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero, viewInsets: EdgeInsets.zero),
                    child: DeviceFormScope(controller: _form, child: TvboxApp(state: _state)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
