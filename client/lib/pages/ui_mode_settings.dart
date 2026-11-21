import 'package:material_ui/material_ui.dart';

import '../ui/device_form.dart';

/// 界面模式 on the 源 page. Android: let the system say whether this is a TV, or force the remote-control layout or
/// the touch layout — for a box that does not say it is a TV, or a TV with a touch screen. Desktops: the desktop
/// layout, or the TV layout in full screen for a computer on the television (the mouse and keyboard keep working).
class UiModeSettings extends StatelessWidget {
  const UiModeSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = DeviceFormScope.maybeControllerOf(context);
    if (controller == null || !controller.canOverride) return const SizedBox.shrink();
    if (controller.isDesktopPlatform) return _desktop(context, controller);
    final scheme = Theme.of(context).colorScheme;
    final system = controller.info.isTv ? '系统报告这是电视' : '系统报告这不是电视';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('界面模式', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SegmentedButton<DeviceFormOverride>(
                key: const Key('ui-mode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: DeviceFormOverride.auto, icon: Icon(Icons.auto_mode_rounded), label: Text('自动')),
                  ButtonSegment(value: DeviceFormOverride.tv, icon: Icon(Icons.tv_rounded), label: Text('电视遥控')),
                  ButtonSegment(value: DeviceFormOverride.touch, icon: Icon(Icons.touch_app_rounded), label: Text('触屏')),
                ],
                selected: {controller.override},
                onSelectionChanged: (s) => controller.setOverride(s.first),
              ),
              const SizedBox(height: 8),
              Text(
                '自动：$system，用${controller.info.isTv ? '电视遥控' : '触屏'}界面。电视遥控界面字和海报更大、四周留出边距，'
                '全部用方向键和确定键操作；电视盒子没有被认出来时选「电视遥控」。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A computer: the desktop layout or the TV layout.
  Widget _desktop(BuildContext context, DeviceFormController controller) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('界面模式', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                key: const Key('ui-mode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.desktop_windows_outlined), label: Text('桌面')),
                  ButtonSegment(value: true, icon: Icon(Icons.tv_rounded), label: Text('电视模式')),
                ],
                selected: {controller.isTv},
                onSelectionChanged: (s) => controller.setOverride(s.first ? DeviceFormOverride.tv : DeviceFormOverride.auto),
              ),
              const SizedBox(height: 8),
              Text(
                '电视模式：电脑接在电视上、坐在沙发上看的时候用。全屏显示，字和海报更大，全部可以用方向键、回车（确定）和 Esc（返回）操作，'
                '也可以用手机遥控（「局域网 → 允许手机遥控」）；鼠标照常可用。回到这里选「桌面」退出。',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
