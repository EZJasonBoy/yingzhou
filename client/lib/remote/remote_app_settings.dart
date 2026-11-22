import 'package:flutter/widgets.dart' show StringCharacters;

import '../settings.dart';
import '../ui/user_mode.dart';
import 'remote_agent.dart';
import 'remote_host.dart' show RemoteArgs;

/// The app's own settings a remote may read and change (`setting.get` / `setting.set`, docs/protocol.md "遥控"): the
/// few that make sense to change from a phone, by name. Nothing else the app keeps can be read or written this way.
///
/// In simple mode with the code on 设置 set, a change needs the same four digits ([UserModeController.matches]).
class RemoteAppSettings {
  RemoteAppSettings({required this.settings, required this.userMode, this.form = '', this.screenName, this.onScreenName});

  final SettingsStore settings;
  final UserModeController userMode;

  /// What remotes call this screen now, and how to rename it ([RemoteAgent.setScreenName], which reconnects under
  /// the new name). Without them the name is only kept.
  final String Function()? screenName;
  final void Function(String name)? onScreenName;

  /// The layout of this screen (`phone`, `tv` …): what some defaults depend on.
  final String form;

  // The names are the keys the app keeps them under.
  static const userModeKey = UserModeController.key;
  static const startPageKey = UserModeController.startKey;

  /// Danmaku on or off when a video starts (`DanmakuPrefs`, which keeps it as `true` / `false`; on unless switched off).
  static const danmakuKey = 'danmaku.enabled';

  /// The clock in the player's on-screen display: `off`, `osd` (with the display, the default) or `always`.
  static const osdClockKey = 'player.osdClock';

  /// Test the lines when a detail page opens (`true` / `false`); off on phones unless switched on, to save data.
  static const probeOnDetailKey = 'play.probeOnDetail';

  /// What this screen is called on the LAN (`RemoteAgent.nameKey`), 1 to 40 characters.
  static const screenNameKey = RemoteAgent.nameKey;

  /// Every key a remote may use, in the order `setting.get` answers.
  static const keys = [userModeKey, startPageKey, danmakuKey, osdClockKey, probeOnDetailKey, screenNameKey];

  static const _osdClocks = ['off', 'osd', 'always'];

  static bool handles(String name) => name == 'setting.get' || name == 'setting.set';

  /// Changes need the code: simple mode with a code set.
  bool get locked => userMode.simple && userMode.hasPin;

  /// [key]'s value now, as a remote sees it (a string or a bool); null when it is not one of [keys].
  Object? read(String key) => switch (key) {
    userModeKey => userMode.mode.name,
    startPageKey => userMode.startPage.name,
    danmakuKey => settings.getString(danmakuKey) != 'false',
    osdClockKey => _osdClocks.contains(settings.getString(osdClockKey)) ? settings.getString(osdClockKey) : 'osd',
    probeOnDetailKey => _flag(settings.getString(probeOnDetailKey)) ?? form != 'phone',
    screenNameKey => screenName?.call() ?? settings.getString(screenNameKey) ?? '',
    _ => null,
  };

  static bool? _flag(String? text) => switch (text) {
    'true' || '1' => true,
    'false' || '0' => false,
    _ => null,
  };

  /// The answer to [name]; null when it is not one of these commands.
  Future<RemoteResult?> perform(String name, Map<String, Object?> args) async => switch (name) {
    'setting.get' => _get(args),
    'setting.set' => await _set(args),
    _ => null,
  };

  RemoteResult _get(Map<String, Object?> args) {
    final asked = args['keys'];
    final wanted = asked is List ? [for (final k in asked) if (k is String && keys.contains(k)) k] : keys;
    return RemoteResult.ok({
      'values': {for (final k in wanted) k: read(k)},
      'locked': locked,
    });
  }

  Future<RemoteResult> _set(Map<String, Object?> args) async {
    final key = args.string('key') ?? '';
    if (!keys.contains(key)) return RemoteResult.failed(key.isEmpty ? '没有说改哪一项' : '这一项不能从手机上改：$key');
    if (locked) {
      final pin = args['pin'];
      final entered = pin is String ? pin : (pin is int ? '$pin'.padLeft(4, '0') : '');
      if (entered.isEmpty) return RemoteResult.failed('设置已经上锁，先输入 4 位密码', {'locked': true});
      if (!userMode.matches(entered)) return RemoteResult.failed('密码不对', {'locked': true});
    }
    final value = args['value'];
    String? wrong;
    switch (key) {
      case userModeKey:
        final mode = value is String ? UserMode.values.asNameMap()[value] : null;
        if (mode == null) {
          wrong = '用法只能是 simple、standard 或 developer';
        } else {
          await userMode.set(mode);
        }
      case startPageKey:
        final page = value is String ? StartPage.values.asNameMap()[value] : null;
        if (page == null) {
          wrong = '起始页只能是 resume、home 或 library';
        } else {
          await userMode.setStartPage(page);
        }
      case danmakuKey || probeOnDetailKey:
        // A boolean; the strings 'true' / 'false' are taken too (how the app keeps them).
        final on = value is bool ? value : (value is String ? _flag(value) : null);
        if (on == null) {
          wrong = '这一项只能是开（true）或关（false）';
        } else {
          await settings.setString(key, '$on');
        }
      case screenNameKey:
        final name = value is String ? value.trim() : '';
        if (name.isEmpty || name.characters.length > 40) {
          wrong = '名字要有 1 到 40 个字';
        } else if (onScreenName != null) {
          onScreenName!(name);
        } else {
          await settings.setString(key, name);
        }
      case osdClockKey:
        if (value is! String || !_osdClocks.contains(value)) {
          wrong = '屏显时间只能是 off、osd 或 always';
        } else {
          await settings.setString(key, value);
        }
    }
    if (wrong != null) return RemoteResult.failed(wrong);
    return RemoteResult.ok({
      'values': {key: key == screenNameKey ? (value as String).trim() : read(key)},
      'locked': locked,
    });
  }
}
