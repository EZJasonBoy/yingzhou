import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../ui/device_form.dart';

/// 设置 → 外观 → 明暗: follow the system, or always light, or always dark. Until one is chosen, phones and tablets
/// follow the system and desktops and TVs are dark (see [ThemeChoice]).
class ThemeModeSettings extends StatelessWidget {
  const ThemeModeSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final choice = AppScope.of(context).themeChoice;
    final scheme = Theme.of(context).colorScheme;
    final touch = isTouch(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: choice,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('明暗', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                const SizedBox(height: 10),
                SegmentedButton<ThemeMode>(
                  key: const Key('theme-mode'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_rounded), label: Text('跟随系统')),
                    ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded), label: Text('浅色')),
                    ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded), label: Text('深色')),
                  ],
                  selected: {choice.resolve(touch: touch)},
                  onSelectionChanged: (s) => choice.set(s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  '画面上的控制条和面板始终是深色的。',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
