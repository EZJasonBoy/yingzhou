import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../settings.dart';
import '../ui/device_form.dart';

/// 设置 → 播放 → 打开详情时先测线路: whether the detail page probes the lines (线路体检) as soon as it opens, or only
/// when 播放 is pressed. Until it is chosen, phones wait for 播放 (the probe fetches a little of every line, which
/// counts on a mobile plan) and desktops, tablets and TVs probe at once.
class LineProbeSettings extends StatefulWidget {
  const LineProbeSettings({super.key});

  /// Kept as `'true'` / `'false'`; the web console reads and writes it the same way.
  static const settingKey = 'play.probeOnDetail';

  /// What the detail page does on this device.
  static bool onDetail(BuildContext context) => resolve(AppScope.read(context).settings, phone: isPhone(context));

  static bool resolve(SettingsStore settings, {required bool phone}) => switch (settings.getString(settingKey)) {
    'true' => true,
    'false' => false,
    _ => !phone,
  };

  @override
  State<LineProbeSettings> createState() => _LineProbeSettingsState();
}

class _LineProbeSettingsState extends State<LineProbeSettings> {
  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    final scheme = Theme.of(context).colorScheme;
    final on = LineProbeSettings.resolve(settings, phone: isPhone(context));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('线路体检', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SwitchListTile(
                key: const Key('probe-on-detail'),
                contentPadding: EdgeInsets.zero,
                title: const Text('打开详情时先测线路'),
                subtitle: Text(on ? '详情页一打开就测这一集的每条线路能不能播、快不快，按「播放」时直接用最好的那条' : '按下「播放」时才测，省流量；测完以前先从选中的线路播'),
                value: on,
                onChanged: (v) async {
                  await settings.setString(LineProbeSettings.settingKey, v ? 'true' : 'false');
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
