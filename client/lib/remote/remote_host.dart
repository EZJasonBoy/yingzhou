import 'dart:async';

import 'package:flutter/foundation.dart';

/// A page that plays something, as the remote control sees it: what is playing, and the things a remote can ask of
/// it whatever has the focus (pause, seek, pick an episode…). The video-on-demand player and the live page each have
/// one; see docs/protocol.md "遥控" for the fields of the state and the commands.
abstract class RemotePlayerTarget {
  /// False while the page is there but not in front (the live page under another tab).
  bool get remoteActive;

  /// `player` in the screen's state.
  Map<String, Object?> remoteState();

  /// Does [name] with [args]. Null when it is done, else why it was not, in words for the person holding the remote.
  FutureOr<String?> remoteCommand(String name, Map<String, Object?> args);
}

/// Where the pages that play register with the remote control, and tell it that what they would report changed.
///
/// Pages know nothing else of the remote: whether one is connected, or allowed at all, is the agent's business
/// (remote_agent.dart), which listens here.
class RemoteHost extends ChangeNotifier {
  RemoteHost._();

  static final instance = RemoteHost._();

  final _players = <RemotePlayerTarget>[];

  /// The player in front: the last one that registered and is active.
  RemotePlayerTarget? get player {
    for (final p in _players.reversed) {
      if (p.remoteActive) return p;
    }
    return null;
  }

  void attach(RemotePlayerTarget target) {
    _players
      ..remove(target)
      ..add(target);
    notifyListeners();
  }

  void detach(RemotePlayerTarget target) {
    if (_players.remove(target)) notifyListeners();
  }

  /// Something a remote shows may have changed (cheap: the agent collects the state a little later, once).
  void changed() => notifyListeners();
}

/// Reads command arguments leniently: they come from another device.
extension RemoteArgs on Map<String, Object?> {
  num? number(String name) {
    final v = this[name];
    return v is num && v.isFinite ? v : null;
  }

  int? integer(String name) => number(name)?.round();

  String? string(String name) {
    final v = this[name];
    return v is String ? v : null;
  }

  bool? flag(String name) {
    final v = this[name];
    return v is bool ? v : null;
  }
}
