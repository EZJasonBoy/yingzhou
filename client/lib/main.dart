import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'app_state.dart';
import 'engine/engine_client.dart';
import 'engine/local_engine.dart';
import 'settings.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // During development, point the client at another engine with --dart-define=ENGINE_URL=http://127.0.0.1:19978
  const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: defaultEngineUrl);
  final settings = await SharedPreferencesSettings.load();
  runApp(TvboxApp(
    state: AppState(
      clientFactory: (url) => EngineClient(url),
      engineUrl: engineUrl,
      settings: settings,
      localEngine: createLocalEngine(),
    ),
  ));
}

class TvboxApp extends StatefulWidget {
  const TvboxApp({super.key, required this.state});

  final AppState state;

  @override
  State<TvboxApp> createState() => _TvboxAppState();
}

class _TvboxAppState extends State<TvboxApp> {
  @override
  void initState() {
    super.initState();
    widget.state.start();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: 'TVBox Next',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        home: const AppShell(),
      ),
    );
  }
}
