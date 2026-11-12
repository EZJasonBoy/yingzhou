import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/main.dart';

import 'fake_engine.dart';

void main() {
  testWidgets('connects, imports a subscription and lists its sites', (tester) async {
    final engine = fakeEngine();
    await tester.pumpWidget(TvboxApp(clientFactory: (url) => EngineClient(url, httpClient: engine)));
    await tester.pumpAndSettle();

    expect(find.textContaining('已连接：tvbox-engine 0.1.0'), findsOneWidget);
    expect(find.text('采集站'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, '订阅地址'), 'http://example.test/tv.json');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('2 个站点 · 0 个解析 · 0 组直播'), findsOneWidget);
    expect(find.text('采集站'), findsOneWidget);
    expect(find.text('脚本站'), findsOneWidget);
  });
}
