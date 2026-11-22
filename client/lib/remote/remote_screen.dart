import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../desktop/desktop_window.dart';
import '../engine/models.dart' show EngineException;
import '../ui/device_form.dart';
import '../ui/tv/tv_shell.dart';
import 'remote_agent.dart';
import 'remote_host.dart';
import 'remote_keys.dart';
import 'remote_socket.dart';
import 'remote_text.dart';

/// The part of the app a phone drives: sits around the navigator (in `TvAppFrame`), keeps the [RemoteAgent] for the
/// app's engine, puts the screen's state together and does what a remote asks:
///
/// - keys (`key`): real key events ([RemoteKeyboard]), so the D-pad of the phone moves the focus like a TV remote's;
///   BACK that nothing took goes back a page, as Android's own back does;
/// - `home`: out of whatever is open, to 首页;
/// - `text` / `submit`: into the text field that has the focus ([RemoteTextField]);
/// - `uiMode`: the TV layout on or off;
/// - everything else goes to the page that plays ([RemoteHost.player]): pause, seek, episode, line, subtitle…
///
/// Nothing here opens the device to anybody by itself: the agent connects only while 「允许手机遥控」 is on (the
/// setting is in `LanSection`, which finds the agent through [maybeAgentOf]).
class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key, required this.child, this.connector});

  final Widget child;

  /// Tests: how the agent reaches the engine's hub (default: a WebSocket).
  final RemoteConnector? connector;

  /// Tests of the whole app: how its agent reaches the hub, when [connector] is not given.
  static RemoteConnector? debugConnector;

  /// The agent of this app; null where there is none (a page pumped alone in a test).
  static RemoteAgent? maybeAgentOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_RemoteScope>()?.notifier;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScope extends InheritedNotifier<RemoteAgent> {
  const _RemoteScope({required RemoteAgent? agent, required super.child}) : super(notifier: agent);
}

class _RemoteScreenState extends State<RemoteScreen> {
  RemoteAgent? _agent;
  AppState? _app;
  DeviceFormController? _forms;
  final _text = RemoteTextField();
  String _form = 'desktop';

  @override
  void initState() {
    super.initState();
    _text.addListener(RemoteHost.instance.changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
    _forms = DeviceFormScope.maybeControllerOf(context);
    final form = DeviceFormScope.of(context).name;
    if (form != _form) {
      _form = form;
      // A change of layout drops what was held and is something to tell the remotes.
      RemoteKeyboard.instance.releaseAll();
      RemoteHost.instance.changed();
    }
    if (app == null) return;
    _app = app;
    final agent = _agent ??= RemoteAgent(
      settings: app.settings,
      connector: widget.connector ?? RemoteScreen.debugConnector,
      collect: _collect,
      perform: _perform,
      probe: _probe,
      platform: defaultTargetPlatform.name.toLowerCase(),
    )..onControllersGone = RemoteKeyboard.instance.releaseAll;
    agent.form = _form;
    agent.bind(engineUrl: app.engineUrl, connected: app.connected && !app.lightweightEngine, token: app.engineToken);
  }

  @override
  void dispose() {
    _text.removeListener(RemoteHost.instance.changed);
    _text.dispose();
    _agent?.dispose();
    RemoteKeyboard.instance.releaseAll();
    super.dispose();
  }

  /// Whether the engine has the remote control at all, when the socket would not open.
  Future<int> _probe() async {
    final app = _app;
    if (app == null || !app.connected) return 0;
    try {
      await app.client.send('GET', 'remote/screens');
      return 200;
    } on EngineException catch (e) {
      return e.statusCode ?? 0;
    } on StateError {
      return 0;
    }
  }

  // ---- the state ----

  Map<String, Object?> _collect() {
    Map<String, Object?>? player;
    try {
      player = RemoteHost.instance.player?.remoteState();
    } catch (_) {
      // A page on its way out: nothing plays as far as a remote is concerned.
    }
    return {
      'title': player == null ? '' : '${player['title'] ?? ''}',
      'page': player == null ? 'browse' : (player['kind'] == 'live' ? 'live' : 'player'),
      'form': _form,
      'canTv': _forms?.canOverride ?? false,
      'text': _text.state,
      'player': player,
    };
  }

  // ---- commands ----

  Future<String?> _perform(String name, Map<String, Object?> args) async {
    if (!mounted) return '屏幕正在关闭';
    switch (name) {
      case 'key':
        final key = args.string('key') ?? '';
        if (!RemoteKeyboard.instance.send(key, args.string('action') ?? 'press', unhandledBack: _systemBack)) return '不认识的按键：$key';
        return null;
      case 'home':
        _goHome();
        return null;
      case 'text':
        return _text.setText(args.string('value') ?? '') ? null : '屏幕上没有输入框';
      case 'submit':
        return _text.submit() ? null : '屏幕上没有输入框';
      case 'uiMode':
        final forms = _forms;
        if (forms == null || !forms.canOverride) return '这台设备不能切换界面模式';
        await forms.setOverride(args.string('mode') == 'tv' ? DeviceFormOverride.tv : DeviceFormOverride.auto);
        return null;
    }
    final player = RemoteHost.instance.player;
    if (player == null) return '屏幕上现在没有在播放';
    return await player.remoteCommand(name, args);
  }

  /// The navigator below (this widget is above it, in the app's builder).
  NavigatorState? _navigator() {
    NavigatorState? found;
    void visit(Element e) {
      if (found != null) return;
      if (e is StatefulElement && e.state is NavigatorState) {
        found = e.state as NavigatorState;
        return;
      }
      e.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  /// What the system's back does when no page took the key: the page on top decides (a panel, the shell's rail, a
  /// question before quitting), else it closes.
  void _systemBack() => unawaited(_navigator()?.maybePop());

  /// 主页 on the remote: every page that is open closes, and the shell shows 首页.
  void _goHome() {
    _navigator()?.popUntil((route) => route.isFirst);
    // The shell's own way to change tab, whichever layout it is in (it is found by what it is made of, so the
    // shell needs to know nothing of the remote).
    var done = false;
    void visit(Element e) {
      if (done) return;
      final w = e.widget;
      if (w is TvShell) {
        done = true;
        w.onSelect(0);
        final state = e is StatefulElement ? e.state : null;
        if (state is TvShellState) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (state.mounted) state.focusRail();
          });
        }
      } else if (w is NavigationRail) {
        done = true;
        w.onDestinationSelected?.call(0);
      } else if (w is NavigationBar) {
        done = true;
        w.onDestinationSelected?.call(0);
      } else {
        e.visitChildren(visit);
      }
    }

    context.visitChildElements(visit);
  }

  @override
  Widget build(BuildContext context) {
    return _RemoteScope(
      agent: _agent,
      child: RemoteKeyProbe(
        // A desktop in the TV layout has no system that goes back for it.
        systemBack: DesktopWindow.isDesktop && isTv(context),
        onBack: _systemBack,
        child: widget.child,
      ),
    );
  }
}
