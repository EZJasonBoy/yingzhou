import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/settings.dart';
import 'package:tvbox_client/ui/device_form.dart';

void main() {
  test('desktop platforms are always desktop, whatever the override says', () async {
    final settings = MemorySettings();
    await settings.setString(DeviceFormController.overrideKey, 'tv');
    for (final p in [TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux]) {
      final c = DeviceFormController(info: const DeviceInfo(tvMode: true), settings: settings, platform: p);
      expect(c.isTv, isFalse);
      expect(c.canOverride, isFalse);
      expect(c.formFor(const Size(1920, 1080)), DeviceForm.desktop);
      expect(c.formFor(const Size(400, 800)), DeviceForm.desktop);
    }
  });

  test('Android: the system decides, phone and tablet by the shorter side', () {
    DeviceFormController make(DeviceInfo info) => DeviceFormController(info: info, platform: TargetPlatform.android);
    expect(make(const DeviceInfo()).formFor(const Size(400, 860)), DeviceForm.phone);
    expect(make(const DeviceInfo()).formFor(const Size(860, 400)), DeviceForm.phone);
    expect(make(const DeviceInfo()).formFor(const Size(1280, 800)), DeviceForm.tablet);
    expect(make(const DeviceInfo(tvMode: true)).formFor(const Size(960, 540)), DeviceForm.tv);
    // A box that does not report the TV mode: leanback and no touchscreen.
    expect(make(const DeviceInfo(leanback: true, touchscreen: false)).formFor(const Size(960, 540)), DeviceForm.tv);
    // A tablet that merely has leanback installed stays a tablet.
    expect(make(const DeviceInfo(leanback: true)).formFor(const Size(1280, 800)), DeviceForm.tablet);
  });

  test('the override is kept in the settings and wins over the system', () async {
    final settings = MemorySettings();
    final c = DeviceFormController(info: const DeviceInfo(), settings: settings, platform: TargetPlatform.android);
    expect(c.canOverride, isTrue);
    var notified = 0;
    c.addListener(() => notified++);
    await c.setOverride(DeviceFormOverride.tv);
    expect(c.isTv, isTrue);
    expect(notified, 1);
    expect(settings.getString(DeviceFormController.overrideKey), 'tv');
    // Read back on the next start.
    final again = DeviceFormController(info: const DeviceInfo(), settings: settings, platform: TargetPlatform.android);
    expect(again.override, DeviceFormOverride.tv);
    expect(again.formFor(const Size(400, 800)), DeviceForm.tv);
    await again.setOverride(DeviceFormOverride.touch);
    final tv = DeviceFormController(info: const DeviceInfo(tvMode: true), settings: settings, platform: TargetPlatform.android);
    expect(tv.isTv, isFalse);
  });

  testWidgets('the scope answers for its subtree; no scope is never TV', (tester) async {
    late DeviceForm inside;
    late DeviceForm outside;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            Builder(
              builder: (context) {
                outside = DeviceFormScope.of(context);
                return const SizedBox();
              },
            ),
            DeviceFormScope.fixed(
              DeviceForm.tv,
              child: Builder(
                builder: (context) {
                  inside = DeviceFormScope.of(context);
                  return const SizedBox();
                },
              ),
            ),
          ],
        ),
      ),
    );
    expect(inside, DeviceForm.tv);
    expect(outside, isNot(DeviceForm.tv));
  });

  test('without the Android side the info is the default', () async {
    expect((await DeviceInfo.load()).isTv, isFalse);
    expect(kIsWeb, isFalse);
  });
}
