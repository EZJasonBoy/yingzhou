import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/app_state.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/settings.dart';

import 'fake_engine.dart';

void main() {
  test('restores the saved engine and site, and remembers changes', () async {
    final settings = MemorySettings();
    await settings.setString('engineUrl', 'http://192.168.1.20:9978');
    await settings.setString('siteKey', 'cms');
    final urls = <Uri>[];
    final engine = fakeEngine(hasConfig: true);
    final state = AppState(
      clientFactory: (url) {
        urls.add(url);
        return EngineClient(url, httpClient: engine);
      },
      settings: settings,
    );

    await state.start();
    expect(urls.single.toString(), 'http://192.168.1.20:9978');
    expect(state.currentSiteKey, 'cms');

    await state.connect('http://10.0.0.5:9978');
    expect(settings.getString('engineUrl'), 'http://10.0.0.5:9978');
  });

  test('a saved site that no longer exists falls back to the first browsable one', () async {
    final settings = MemorySettings();
    await settings.setString('siteKey', 'gone');
    final engine = fakeEngine(hasConfig: true);
    final state = AppState(clientFactory: (url) => EngineClient(url, httpClient: engine), settings: settings);
    await state.start();
    expect(state.currentSiteKey, 'cms');
  });
}
