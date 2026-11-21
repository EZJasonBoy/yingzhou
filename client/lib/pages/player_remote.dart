part of 'player_page.dart';

/// The player as the LAN remote control sees it ([RemotePlayerTarget]; docs/protocol.md "遥控"): what a phone shows
/// of it, and what it can ask for whatever has the focus here. Everything goes through the page's own methods, so a
/// command from a phone does exactly what the button or the key on this screen does.
class _PlayerRemote implements RemotePlayerTarget {
  _PlayerRemote(this._page);

  final _PlayerPageState _page;

  @override
  bool get remoteActive => _page.mounted;

  @override
  Map<String, Object?> remoteState() => _page._remoteState();

  @override
  FutureOr<String?> remoteCommand(String name, Map<String, Object?> args) => _page._remoteCommand(name, args);
}

extension _PlayerRemoteGlue on _PlayerPageState {
  /// Registers with the remote control and tells it whenever what a phone shows may have changed. (What changes
  /// through `setState` is told from there.)
  void _remoteAttach() {
    final changed = RemoteHost.instance.changed;
    final p = _player.stream;
    for (final stream in <Stream<Object?>>[p.playing, p.buffering, p.rate, p.volume, p.duration, p.completed]) {
      _subs.add(stream.listen((_) => changed()));
    }
    // A jump of the position is a seek, wherever it came from; playing on is not news (remotes count on by themselves).
    var last = Duration.zero;
    _subs.add(
      p.position.listen((at) {
        if ((at - last).abs() > const Duration(seconds: 2)) changed();
        last = at;
      }),
    );
    _tracks.addListener(changed);
    RemoteHost.instance.attach(_remote);
  }

  void _remoteDetach() {
    _tracks.removeListener(RemoteHost.instance.changed);
    RemoteHost.instance.detach(_remote);
  }

  Map<String, Object?> _remoteState() {
    final state = _player.state;
    final lines = _detail.lines;
    return {
      'kind': 'vod',
      'title': _detail.name,
      'subtitle': [_currentEpisode.name, _currentLine.name].where((s) => s.isNotEmpty).join(' · '),
      'position': (_seekingTo ?? state.position).inMilliseconds,
      'duration': state.duration.inMilliseconds,
      'seekable': state.duration > Duration.zero,
      'paused': !state.playing,
      'buffering': _error == null && (_opening || state.buffering || !_started),
      'error': _error ?? '',
      'speed': state.rate,
      'speeds': _PlayerPageState._speeds,
      'volume': state.volume.round(),
      'muted': state.volume <= 0,
      'fullscreen': _window.isFullScreen,
      // The TV layout on a desktop is always full screen.
      'canFullscreen': _window.supported && !_window.pinnedFullScreen,
      'lines': [for (final l in lines) l.name],
      'line': _line,
      'episodes': [for (final e in _currentLine.episodes) e.name],
      'episode': _episode,
      'subtitles': _tracks.hasSubtitles
          ? [
              {'id': 'off', 'name': '关闭'},
              for (final t in _tracks.internalSubtitles) {'id': 'int:${t.id}', 'name': _tracks.subtitleLabel(t)},
              for (final s in _tracks.external) {'id': 'ext:${s.url}', 'name': s.name},
              for (final s in _tracks.local) {'id': s.url, 'name': s.name},
            ]
          : const <Object?>[],
      'subtitleId': _tracks.selected,
      'audios': [
        for (final t in _tracks.audioTracks) {'id': t.id, 'name': _tracks.audioLabel(t)},
      ],
      'audioId': _tracks.audioSelected,
      'danmaku': _danmakuPrefs.enabled,
    };
  }

  Future<String?> _remoteCommand(String name, Map<String, Object?> args) async {
    if (!mounted) return '播放已经结束';
    final duration = _player.state.duration;
    switch (name) {
      case 'toggle':
        await _player.playOrPause();
      case 'play':
        await _player.play();
      case 'pause':
        await _player.pause();
      case 'seek':
        final position = args.number('position');
        if (position == null) return '没有说跳到哪里';
        if (duration <= Duration.zero) return '还不能跳转';
        var target = Duration(milliseconds: position.round());
        if (target < Duration.zero) target = Duration.zero;
        if (target > duration) target = duration;
        _seekTo(target);
        _showOsd('${_TimeLabel.format(target)} / ${_TimeLabel.format(duration)}');
      case 'seekBy':
        final delta = args.number('delta');
        if (delta == null || delta == 0) return '没有说跳多远';
        _seekBy(Duration(milliseconds: delta.round()));
      case 'speed':
        final value = args.number('value')?.toDouble();
        if (value == null || !_PlayerPageState._speeds.contains(value)) return '没有这个倍速';
        await _player.setRate(value);
        _showOsd('倍速 ${value}x');
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
        if (!_window.supported || _window.pinnedFullScreen) return '这里不能切换全屏';
        final on = args.flag('on');
        if (on == null || on != _window.isFullScreen) _toggleFullScreen();
      case 'line':
        final index = args.integer('index');
        final lines = _detail.lines;
        if (index == null || index < 0 || index >= lines.length) return '没有这条线路';
        if (lines[index].episodes.isEmpty) return '这条线路没有可以播放的集';
        if (index != _line) _pickLine(index);
      case 'episode':
        final index = args.integer('index');
        if (index == null || index < 0 || index >= _currentLine.episodes.length) return '没有这一集';
        if (index != _episode || _error != null) _playEpisode(index);
      case 'next':
        if (!_hasNext) return '已经是最后一集';
        _playEpisode(_episode + 1);
      case 'previous':
        if (!_hasPrevious) return '已经是第一集';
        _playEpisode(_episode - 1);
      case 'subtitle':
        if (!await _tracks.selectById(args.string('id') ?? '')) return '没有这条字幕';
      case 'audio':
        if (!await _tracks.selectAudioById(args.string('id') ?? '')) return '没有这条音轨';
      case 'danmaku':
        final on = args.flag('on');
        if (on == null || on != _danmakuPrefs.enabled) _toggleDanmaku();
      case 'retry':
        if (_error == null) return '现在没有出错';
        _retry();
      case 'stop':
        // Out of the player, whatever is open in it.
        Navigator.of(context).pop();
      default:
        return '播放器不认识这个命令：$name';
    }
    if (mounted) _pokeControls();
    return null;
  }
}
