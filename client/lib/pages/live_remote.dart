part of 'live_page.dart';

/// Live TV as the LAN remote control sees it ([RemotePlayerTarget]; docs/protocol.md "遥控"). A phone gets the
/// channel playing, the groups and the channels of the group being browsed (as `episodes`, so one list on the phone
/// serves films and channels alike), and can change channel, line and volume without the channel list being open
/// here. The page only counts while its tab is the one shown and something is tuned in.
class _LiveRemote implements RemotePlayerTarget {
  _LiveRemote(this._page);

  final _LivePageState _page;

  @override
  bool get remoteActive => _page.mounted && _page.widget.visible && _page._channel != null;

  @override
  Map<String, Object?> remoteState() => _page._remoteState();

  @override
  FutureOr<String?> remoteCommand(String name, Map<String, Object?> args) => _page._remoteCommand(name, args);
}

extension _LiveRemoteGlue on _LivePageState {
  /// The player was made (it is, the first time a channel is opened): what it reports is news for a remote.
  void _remoteWatch(Player player) {
    final changed = RemoteHost.instance.changed;
    final p = player.stream;
    for (final stream in <Stream<Object?>>[p.playing, p.buffering, p.volume, p.duration]) {
      _subs.add(stream.listen((_) => changed()));
    }
    var last = Duration.zero;
    _subs.add(
      p.position.listen((at) {
        if ((at - last).abs() > const Duration(seconds: 2)) changed();
        last = at;
      }),
    );
  }

  Map<String, Object?> _remoteState() {
    final list = _list!;
    final playing = _playing!;
    final channel = _channel!;
    final player = _playerOrNull?.state;
    final catchup = _catchup;
    final group = _group.clamp(0, list.groups.length - 1);
    final program = _epg[channel.name]?.current(_now);
    final failed = _status != null && _watchdog == null && !_opening;
    return {
      'kind': 'live',
      'title': channel.name,
      'subtitle': catchup != null
          ? '回看：${catchup.title}'
          : [list.groups[playing.$1].name, if (program != null) '正在播出：${program.title}'].where((s) => s.isNotEmpty).join(' · '),
      // Live has no length; a programme played back does.
      'position': catchup == null ? 0 : (player?.position.inMilliseconds ?? 0),
      'duration': catchup == null ? 0 : (player?.duration.inMilliseconds ?? 0),
      'seekable': catchup != null,
      'paused': !(player?.playing ?? false),
      'buffering': !failed && (_opening || _status != null || (player?.buffering ?? false)),
      'error': failed ? _status! : '',
      'speed': 1.0,
      'speeds': const <double>[],
      'volume': (player?.volume ?? 100).round(),
      'muted': (player?.volume ?? 100) <= 0,
      'fullscreen': _immersive,
      'canFullscreen': true,
      'groups': [for (final g in list.groups) g.name],
      'group': group,
      'lines': [
        for (var i = 0; i < channel.urls.length; i++) channel.urls[i].label.isEmpty ? '线路 ${i + 1}' : channel.urls[i].label,
      ],
      'line': _line,
      'episodes': [for (final c in list.groups[group].channels) c.name],
      'episode': playing.$1 == group ? playing.$2 : -1,
    };
  }

  Future<String?> _remoteCommand(String name, Map<String, Object?> args) async {
    final list = _list;
    final playing = _playing;
    if (!mounted || list == null || playing == null) return '现在没有在看直播';
    switch (name) {
      case 'toggle':
        await _player.playOrPause();
      case 'play':
        await _player.play();
      case 'pause':
        await _player.pause();
      case 'seek':
        if (_catchup == null) return '直播不能跳转（回看的节目可以）';
        final position = args.number('position');
        if (position == null) return '没有说跳到哪里';
        await _player.seek(Duration(milliseconds: position.round().clamp(0, _player.state.duration.inMilliseconds)));
      case 'seekBy':
        if (_catchup == null) return '直播不能跳转（回看的节目可以）';
        _seekBy(Duration(milliseconds: (args.number('delta') ?? 0).round()));
      case 'speed':
        return '直播不能调倍速';
      case 'volume':
        final value = args.number('value');
        if (value == null) return '没有说音量';
        _changeVolume(value.toDouble().clamp(0.0, 100.0) - _player.state.volume);
      case 'volumeBy':
        _changeVolume((args.number('delta') ?? 0).toDouble());
      case 'mute':
        final on = args.flag('on');
        if (on == null || on != (_player.state.volume <= 0)) _toggleMute();
      case 'fullscreen':
        final on = args.flag('on');
        if (on == null || on != _immersive) _toggleImmersive();
      case 'line':
        final index = args.integer('index');
        final urls = list.groups[playing.$1].channels[playing.$2].urls;
        if (index == null || index < 0 || index >= urls.length) return '没有这条线路';
        if (index != _line) unawaited(_play(playing.$1, playing.$2, line: index));
      case 'group':
        final index = args.integer('index');
        if (index == null || index < 0 || index >= list.groups.length) return '没有这个分组';
        _tvSet(() => _group = index);
      case 'episode' || 'channel':
        final group = args.integer('group') ?? _group;
        final index = args.integer('index');
        if (group < 0 || group >= list.groups.length || index == null || index < 0 || index >= list.groups[group].channels.length) return '没有这个频道';
        _tvSet(() => _group = group);
        unawaited(_play(group, index));
      case 'next':
        _stepChannel(1);
      case 'previous':
        _stepChannel(-1);
      case 'retry':
        unawaited(_play(playing.$1, playing.$2, line: _line));
      case 'stop':
        // Out of full screen; the page itself is a tab and stays.
        if (_immersive) _toggleImmersive();
      default:
        return '直播不认识这个命令：$name';
    }
    return null;
  }
}
