import 'package:material_ui/material_ui.dart';

import 'engine/engine_client.dart';
import 'pages/sources_page.dart';

void main() {
  runApp(TvboxApp(clientFactory: (url) => EngineClient(url)));
}

class TvboxApp extends StatelessWidget {
  const TvboxApp({super.key, required this.clientFactory});

  final EngineClientFactory clientFactory;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TVBox Next',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D7BFF), brightness: Brightness.dark),
      ),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3D7BFF)),
      ),
      home: SourcesPage(clientFactory: clientFactory),
    );
  }
}
