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

  // ---- the player's own account, for `player.info` ----

  /// What [PlayInfoPanel] reads from libmpv.
  static const _mpvNames = ['video-params/w', 'video-params/h', 'container-fps', 'estimated-vf-fps', 'hwdec-current', 'demuxer-cache-duration', 'cache-speed', 'frame-drop-count'];

  /// How old the numbers may be before the state asks libmpv again: about once per refresh of the state.
  static const _mpvMaxAge = Duration(seconds: 4);

  /// The last answers (empty before the first, and where there is no libmpv to ask).
  Map<String, String> mpv = const {};
  DateTime _mpvAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _reading = false;

  /// Asks libmpv again when the numbers are old and a remote is connected (nobody else sees them here); the state
  /// goes out again once they are in.
  void refreshMpv(Player player) {
    if (!RemoteHost.instance.watched || _reading || DateTime.now().difference(_mpvAt) < _mpvMaxAge) return;
    _reading = true;
    unawaited(
      readMpvProperties(player, _mpvNames)
          .then((values) {
            _mpvAt = DateTime.now();
            mpv = values;
            if (_page.mounted) RemoteHost.instance.changed();
          })
          .whenComplete(() => _reading = false),
    );
  }
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
      // As the screen names them (simple mode numbers its lines).
      'lines': [for (var i = 0; i < lines.length; i++) _lineName(i)],
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
      'info': _remoteInfo(),
      // Developer mode: where the video comes from, step by step (the screen redacts it before it leaves).
      if (_dev) 'chain': _remoteChain(),
    };
  }

  /// 播放信息 as facts (player_info.dart's [PlayInfoPanel] shows the same in words): how it is going, the picture,
  /// the speed, the decoder, and where it comes from.
  Map<String, Object?> _remoteInfo() {
    _remote.refreshMpv(_player);
    final v = _remote.mpv;
    final state = _player.state;
    final measured = double.tryParse(v['demuxer-cache-duration'] ?? '') ?? (state.buffer - state.position).inMilliseconds / 1000;
    final ahead = measured > 0 ? measured : 0.0;
    final fps = double.tryParse(v['container-fps'] ?? v['estimated-vf-fps'] ?? '');
    final hwdec = v['hwdec-current'];
    final played = _played;
    return {
      'health': PlayHealth.of(ahead: ahead, buffering: state.buffering).name,
      'bufferSeconds': double.parse(ahead.toStringAsFixed(1)),
      'width': int.tryParse(v['video-params/w'] ?? '') ?? state.width,
      'height': int.tryParse(v['video-params/h'] ?? '') ?? state.height,
      'fps': fps == null || fps <= 0 ? null : double.parse(fps.toStringAsFixed(2)),
      'bytesPerSecond': double.tryParse(v['cache-speed'] ?? '')?.round(),
      'hwdec': hwdec == null ? null : hwdec != 'no',
      'droppedFrames': int.tryParse(v['frame-drop-count'] ?? ''),
      'source': AppScope.read(context).siteName(_detail.site),
      'line': _lineName(_line),
      'lineCount': _detail.lines.length,
      'how': [
        played == null ? '正在找播放地址' : (_parsedBy.isEmpty ? '直链' : _PlayerPageState._parserLabel(_parsedBy)),
        if (played?.relay.isNotEmpty == true) _onRelay ? '经引擎' : '直连片源',
      ].join(' · '),
      'switched': List.of(_failedNotes),
    };
  }

  /// 片源从哪来 ([PlayerChainPanel]) as steps, and as the text it copies.
  Map<String, Object?> _remoteChain() {
    final chain = _chain;
    final p = chain.played;
    Map<String, Object?> step(String title, String detail, {int? ms, bool ok = true, bool pending = false}) => {
      'title': title,
      'detail': detail,
      'ms': ?ms,
      'ok': ok && !pending,
      if (pending) 'pending': true,
    };
    return {
      'steps': [
        step('订阅', chain.subscription.isEmpty ? '（没有订阅：网盘或离线）' : chain.subscription),
        step('站点 · ${chain.siteName}', '${chain.siteKey}${chain.runtime.isEmpty ? '' : ' · ${chain.runtime}'} · vod_id ${chain.vodId}'),
        for (final f in chain.failed) step('线路 · 打不开', f, ok: false),
        step('线路 · ${chain.lineName.isEmpty ? '未命名' : chain.lineName}（共 ${chain.lineCount} 条）', '${chain.episodeName}\n${chain.episodeId}'),
        step('解析 · ${p == null ? '正在解析…' : chain.parser}', '', ms: chain.resolveMs, pending: p == null),
        if (p != null)
          step('播放地址${chain.onRelay ? ' · 经引擎' : (p.relay.isNotEmpty ? ' · 直连片源' : '')}', [
            chain.url,
            for (final h in p.headers.entries) '${h.key}: ${h.value}',
            if (p.cache.isNotEmpty) '引擎缓存：${p.cache}',
          ].join('\n')),
        step(chain.firstFrameMs == null ? '首帧 · 还没有画面' : '首帧', '', ms: chain.firstFrameMs, pending: chain.firstFrameMs == null),
      ],
      'text': chain.toText(),
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
