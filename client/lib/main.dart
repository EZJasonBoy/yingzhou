import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'app_state.dart';
import 'desktop/desktop_window.dart';
import 'engine/engine_client.dart';
import 'engine/local_engine.dart';
import 'settings.dart';
import 'ui/device_form.dart';
import 'ui/poster_cache.dart';
import 'ui/pairing_dialog.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // During development, point the client at another engine with --dart-define=ENGINE_URL=http://127.0.0.1:19978
  const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: defaultEngineUrl);
  final settings = await SharedPreferencesSettings.load();
  DesktopWindow.instance.restoreAndTrack(settings);
  // Posters are kept on disk (see ui/poster_cache.dart).
  PosterCache.instance = await PosterCache.open();
  // Phone, tablet, TV or desktop (ui/device_form.dart): the system's answer and the user's override.
  final deviceForm = DeviceFormController(info: await DeviceInfo.load(), settings: settings);
  runApp(
    DeviceFormScope(
      controller: deviceForm,
      child: TvboxApp(
        state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings, localEngine: createLocalEngine()),
      ),
    ),
  );
}

class TvboxApp extends StatefulWidget {
  const TvboxApp({super.key, required this.state});

  final AppState state;

  @override
  State<TvboxApp> createState() => _TvboxAppState();
}

class _TvboxAppState extends State<TvboxApp> {
  final _navigator = GlobalKey<NavigatorState>();

  void _back() => _navigator.currentState?.maybePop();
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
        title: '映舟',
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.dark,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        navigatorKey: _navigator,
        // Desktop habits: the mouse's back button and Alt+Left go back a page.
        builder: (context, child) => Listener(
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.mouse && e.buttons & kBackMouseButton != 0) _back();
          },
          child: CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back}, child: child ?? const SizedBox.shrink()),
        ),
        home: const PairingGate(child: AppShell()),
      ),
    );
  }
}
