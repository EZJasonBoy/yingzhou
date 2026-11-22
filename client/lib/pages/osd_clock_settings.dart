import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../settings.dart';
import '../ui/device_form.dart';

/// 屏显时间: whether the TV player shows the time of day, kept on this device as `off`, `osd` or `always` under
/// [key] (the web console reads and writes the same strings); `osd` when unset.
enum OsdClock {
  /// Never.
  off('关'),

  /// Top right with the info bar and the dial, next to how long is left (the default).
  withOsd('随屏显出现'),

  /// Also small and dim in a corner while nothing else is over the picture.
  always('一直显示');

  const OsdClock(this.label);

  final String label;

  static const key = 'player.osdClock';

  static OsdClock read(SettingsStore settings) => switch (settings.getString(key)) {
    'off' => off,
    'always' => always,
    _ => withOsd,
  };

  Future<void> save(SettingsStore settings) => settings.setString(key, switch (this) {
    off => 'off',
    withOsd => 'osd',
    always => 'always',
  });
}

/// 设置 → 播放 → 屏显时间, the same choice as in the player's 更多设置. Only in the TV layout, the one player that has it.
class OsdClockSettings extends StatefulWidget {
  const OsdClockSettings({super.key});

  @override
  State<OsdClockSettings> createState() => _OsdClockSettingsState();
}

class _OsdClockSettingsState extends State<OsdClockSettings> {
  @override
  Widget build(BuildContext context) {
    if (!isTv(context)) return const SizedBox.shrink();
    final settings = AppScope.of(context).settings;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('屏显时间', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SegmentedButton<OsdClock>(
                key: const Key('osd-clock'),
                showSelectedIcon: false,
                segments: [for (final c in OsdClock.values) ButtonSegment(value: c, label: Text(c.label))],
                selected: {OsdClock.read(settings)},
                onSelectionChanged: (s) async {
                  await s.first.save(settings);
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 8),
              Text(
                '播放时右上角显示现在几点、大约几点看完。选「一直显示」时，没有屏显也在角落里小字显示时间。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
