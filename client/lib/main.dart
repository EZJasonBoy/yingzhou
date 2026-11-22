import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'app_state.dart';
import 'desktop/desktop_window.dart';
import 'diagnostics/diagnostics.dart';
import 'engine/engine_client.dart';
import 'engine/local_engine.dart';
import 'mobile/playback_host.dart';
import 'pages/mode_chooser.dart';
import 'settings.dart';
import 'ui/device_form.dart';
import 'ui/poster_cache.dart';
import 'ui/pairing_dialog.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/tv/tv_app.dart';
import 'update/update_watcher.dart';

// Crash records (diagnostics/diagnostics.dart): the error hooks, and a guarded zone around all of it.
Future<void> main() => Diagnostics.runGuarded(_main);

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // During development, point the client at another engine with --dart-define=ENGINE_URL=http://127.0.0.1:19978
  const engineUrl = String.fromEnvironment('ENGINE_URL', defaultValue: defaultEngineUrl);
  // Android: whether this is the emulator, which the player's video output depends on (player_backend.dart).
  await PlaybackHost.init();
  final settings = await SharedPreferencesSettings.load();
  DesktopWindow.instance.restoreAndTrack(settings);
  // Posters are kept on disk (see ui/poster_cache.dart).
  PosterCache.instance = await PosterCache.open();
  // Phone, tablet, TV or desktop (ui/device_form.dart): the system's answer and the user's override.
  final deviceForm = DeviceFormController(info: await DeviceInfo.load(), settings: settings);
  Diagnostics.instance.deviceForm = deviceForm;
  runApp(
    DeviceFormScope(
      controller: deviceForm,
      child: TvboxApp(
        askUserMode: true,
        state: AppState(clientFactory: (url) => EngineClient(url), engineUrl: engineUrl, settings: settings, localEngine: createLocalEngine()),
      ),
    ),
  );
}

class TvboxApp extends StatefulWidget {
  const TvboxApp({super.key, required this.state, this.askUserMode = false});

  final AppState state;

  /// On the very first start, ask which way the app is to be used (simple, standard, developer) before the main
  /// screen (pages/mode_chooser.dart). Off unless the real app turns it on.
  final bool askUserMode;

  @override
  State<TvboxApp> createState() => _TvboxAppState();
}

class _TvboxAppState extends State<TvboxApp> {
  final _navigator = GlobalKey<NavigatorState>();

  void _back() => _navigator.currentState?.maybePop();
  @override
  void initState() {
    super.initState();
    widget.state.themeChoice.addListener(_themeChanged);
    widget.state.start();
  }

  @override
  void dispose() {
    widget.state.themeChoice.removeListener(_themeChanged);
    super.dispose();
  }

  void _themeChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: MaterialApp(
        title: '映舟',
        debugShowCheckedModeBanner: false,
        // Until the user chooses in 设置 → 外观: phones and tablets follow the system, desktops and TVs are dark.
        themeMode: widget.state.themeChoice.resolve(touch: isTouch(context)),
        theme: tvTheme(context, buildLightTheme()),
        darkTheme: tvTheme(context, buildDarkTheme()),
        navigatorKey: _navigator,
        // Desktop habits: the mouse's back button and Alt+Left go back a page.
        builder: (context, child) => Listener(
          onPointerDown: (e) {
            if (e.kind == PointerDeviceKind.mouse && e.buttons & kBackMouseButton != 0) _back();
          },
          child: CallbackShortcuts(bindings: {const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _back}, child: TvAppFrame(child: child ?? const SizedBox.shrink())),
        ),
        home: PairingGate(child: UpdateWatcher(child: ModeGate(ask: widget.askUserMode, child: const AppShell()))),
      ),
    );
  }
}
