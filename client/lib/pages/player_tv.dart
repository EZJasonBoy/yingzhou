part of 'player_page.dart';

/// What the player page keeps for the remote control on a TV.
class _TvPlayerUi {
  _TvPlayerUi() {
    // The dial lights its entry itself; the app's focus ring stays off it.
    tvOwnFocusLook(dial);
  }

  /// The dial holds the remote's focus as a whole while it is the layer on top; the keys move its lit entry.
  final dial = FocusNode(debugLabel: 'tv-dial');

  /// The dial is out. The panel next to it, if any, is the page's [_PlayerPageState._panel].
  bool dialOpen = false;

  /// Holding ← / →: where the seek will land when the key is let go, and how long it has been held.
  Duration? slideTarget;
  int slideRepeats = 0;

  /// OK went down on the picture or on the dial and is not let go yet: it acts when it is let go, unless it was held
  /// ([okLong]: 更多设置 opened instead). [okOnDial]: it went down on the dial.
  bool okDown = false;
  bool okLong = false;
  bool okOnDial = false;

  /// Runs for two seconds after BACK on the picture: a second BACK meanwhile leaves the player.
  Timer? exitTimer;

  /// 画面比例, as libmpv's `video-aspect-override` takes it; `-1` is the video's own.
  String aspect = '-1';

  void dispose() {
    dial.dispose();
    exitTimer?.cancel();
  }
}

/// The player with a remote control (docs/design/ux-review.md 2.2, the prototypes TV-Dial-*). Nothing over the
/// picture takes the keys until it is called up:
///
/// | layer   | ← / →                              | ↑ / ↓              | OK                         | menu / holding OK | BACK                  |
/// |---------|------------------------------------|--------------------|----------------------------|-------------------|-----------------------|
/// | picture | seek 10 s, held: faster, one seek  | the dial           | pause / play, the info bar | 更多设置           | twice within 2 s: out |
/// | dial    | change this entry's value          | another entry      | this entry's panel         | 更多设置           | dial away             |
/// | panel   | walk the panel; at its left: dial  | walk the panel     | choose                     | 更多设置           | back to the dial      |
///
/// The info bar ([TvOsd]) only shows: the title, line, picture, subtitles and danmaku, the time and how long is left,
/// the progress, the keys. Channel up / down, page up / down and next / previous track change the episode anywhere;
/// fast-forward / rewind seek 30 s on the picture; play / pause works anywhere.
///
/// One layer has the focus at a time: the picture, the dial or the panel next to it. The dial cannot take the focus
/// while a panel is open, the panel is a focus scope the D-pad cannot walk out of, and nothing under them can take
/// it; a key that finds the focus elsewhere only puts it back.
extension _PlayerTv on _PlayerPageState {
  bool get _tvMode => isTv(context);

  /// The dial is out, or a panel next to it (one opened from elsewhere brings the dial with it).
  bool get _tvLayerOpen => _tvUi.dialOpen || _panel != null;

  /// 屏显时间, read from the settings each time: the web console may change it while a video plays.
  OsdClock get _tvClock => OsdClock.read(_settings);

  /// The entry lit on the dial: the one whose panel is open, else the one used last.
  DialEntry get _tvEntry {
    final panel = _panel;
    return panel == null ? TvDialMemory.last : _tvEntryOf(panel);
  }

  static DialEntry _tvEntryOf(_PlayerPanel panel) => switch (panel) {
    _PlayerPanel.episodes => DialEntry.episodes,
    _PlayerPanel.lines => DialEntry.lines,
    _PlayerPanel.speed => DialEntry.speed,
    _PlayerPanel.tracks => DialEntry.subtitles,
    _PlayerPanel.danmaku => DialEntry.danmaku,
    _PlayerPanel.info => DialEntry.info,
    // 片源从哪来 is opened from 更多设置.
    _PlayerPanel.more || _PlayerPanel.chain => DialEntry.more,
  };

  static _PlayerPanel _tvPanelOf(DialEntry entry) => switch (entry) {
    DialEntry.episodes => _PlayerPanel.episodes,
    DialEntry.lines => _PlayerPanel.lines,
    DialEntry.speed => _PlayerPanel.speed,
    DialEntry.subtitles => _PlayerPanel.tracks,
    DialEntry.danmaku => _PlayerPanel.danmaku,
    DialEntry.info => _PlayerPanel.info,
    DialEntry.more => _PlayerPanel.more,
  };

  // ------------------------------------------------------------------ keys

  KeyEventResult _onTvKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final ui = _tvUi;

    if (TvKeys.isBack(key)) {
      if (down) _tvBack();
      return KeyEventResult.handled;
    }
    if (TvKeys.isMenu(key)) {
      if (down) _tvOpenPanel(DialEntry.more);
      return KeyEventResult.handled;
    }
    // Keys that mean the same wherever the focus is.
    if (down || event is KeyRepeatEvent) {
      if (TvKeys.isPlayPause(key)) {
        if (down) _tvPlayPause();
        return KeyEventResult.handled;
      }
      if (TvKeys.isChannelDown(key) || TvKeys.isNext(key)) {
        if (down && _hasNext) _playEpisode(_episode + 1);
        return KeyEventResult.handled;
      }
      if (TvKeys.isChannelUp(key) || TvKeys.isPrevious(key)) {
        if (down && _hasPrevious) _playEpisode(_episode - 1);
        return KeyEventResult.handled;
      }
      if (TvKeys.isFastForward(key) || TvKeys.isRewind(key)) {
        // Never a seek behind the dial or a panel.
        if (!_tvLayerOpen) _seekBy(Duration(seconds: TvKeys.isRewind(key) ? -30 : 30));
        return KeyEventResult.handled;
      }
    }
    // OK went down on the picture or the dial: held, it opens 更多设置 (for remotes without a menu key); let go, it
    // does what OK does there. Its repeats and its release are kept from whatever has the focus by then. A new press
    // starts afresh, should the release of the one before have gone astray.
    if (down && TvKeys.isActivate(key)) ui.okDown = false;
    if (ui.okDown && TvKeys.isActivate(key)) {
      if (event is KeyRepeatEvent && !ui.okLong) {
        ui.okLong = true;
        _tvOpenPanel(DialEntry.more);
      } else if (event is KeyUpEvent) {
        ui.okDown = false;
        if (!ui.okLong) {
          if (ui.okOnDial && ui.dialOpen && _panel == null) {
            _tvOpenPanel(TvDialMemory.last);
          } else if (!ui.okOnDial && !_tvLayerOpen) {
            _tvPlayPause();
          }
        }
      }
      return KeyEventResult.handled;
    }
    if (_panel != null) return _tvPanelKey(event);
    if (ui.dialOpen) return _tvDialKey(event);
    return _tvPictureKey(event);
  }

  /// A panel is open next to the dial: the D-pad walks it (the app's directional focus, which stops at the panel's
  /// edges) and OK chooses; ← at its left edge goes back to the dial.
  KeyEventResult _tvPanelKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (!_panelScope.hasFocus) {
      // The focus is not in the panel (it had nothing to take it yet, or it fell back to the page): the key puts it
      // back into the panel and does nothing else, never a seek or a second layer.
      if (down) _panelScope.requestFocus();
      return KeyEventResult.handled;
    }
    if (TvKeys.isLeft(key)) {
      if (event is KeyUpEvent) return KeyEventResult.handled;
      final primary = FocusManager.instance.primaryFocus;
      // A panel with nothing to walk to has the focus on itself: ← goes straight back.
      final moved = primary != null && primary is! FocusScopeNode && primary.focusInDirection(TraversalDirection.left);
      // Held, ← only walks: it does not run on out of the panel and into the dial's own ← (an episode back).
      if (!moved && down) _tvToDial();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// The dial is the layer on top: ↑ / ↓ light another entry, ← / → change its value, OK (when let go) opens its panel.
  KeyEventResult _tvDialKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final ui = _tvUi;
    if (!ui.dial.hasPrimaryFocus) {
      if (down) ui.dial.requestFocus();
      return KeyEventResult.handled;
    }
    if (TvKeys.isUp(key) || TvKeys.isDown(key)) {
      if (event is! KeyUpEvent) {
        final entries = DialEntry.values;
        // To the ends and no further: the hand learns where 选集 and 更多设置 are.
        final next = (TvDialMemory.last.index + (TvKeys.isUp(key) ? -1 : 1)).clamp(0, entries.length - 1);
        _tvSet(() => TvDialMemory.last = entries[next]);
      }
      return KeyEventResult.handled;
    }
    if (TvKeys.isLeft(key) || TvKeys.isRight(key)) {
      // One step per press: a held key does not run through episodes or lines.
      if (down) _tvAdjust(TvDialMemory.last, TvKeys.isRight(key) ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (TvKeys.isActivate(key)) {
      if (down) {
        ui.okDown = true;
        ui.okLong = false;
        ui.okOnDial = true;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Nothing over the picture has the keys: ← / → seek, OK (when let go) pauses, ↑ / ↓ call up the dial.
  KeyEventResult _tvPictureKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final ui = _tvUi;
    final primary = FocusManager.instance.primaryFocus;
    // The buttons under an error (重试, 换线路): the D-pad walks them and OK presses.
    if (_error != null && primary != null && primary != _focus) return KeyEventResult.ignored;
    if (primary != _focus) _focus.requestFocus();

    if (TvKeys.isLeft(key) || TvKeys.isRight(key)) {
      _tvSlide(event, TvKeys.isRight(key) ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (TvKeys.isActivate(key)) {
      if (down) {
        ui.okDown = true;
        ui.okLong = false;
        ui.okOnDial = false;
      }
      return KeyEventResult.handled;
    }
    if (!down) return event is KeyRepeatEvent ? KeyEventResult.handled : KeyEventResult.ignored;
    if (TvKeys.isUp(key) || TvKeys.isDown(key)) {
      _tvOpenDial();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _tvPlayPause() {
    _player.playOrPause();
    _pokeControls();
  }

  /// ← / →: a tap seeks 10 s; held, the target moves on 10 s, then 20 s, 30 s… per repeat, and the jump happens
  /// once, on release (the engine's stream cache and the player both prefer one seek to many).
  void _tvSlide(KeyEvent event, int dir) {
    final ui = _tvUi;
    final duration = _player.state.duration;
    if (event is KeyUpEvent) {
      final target = ui.slideTarget;
      ui.slideTarget = null;
      ui.slideRepeats = 0;
      if (target != null) _seekTo(target);
      return;
    }
    if (event is KeyDownEvent || ui.slideTarget == null) {
      ui.slideRepeats = 0;
      ui.slideTarget = _seekingTo ?? _player.state.position;
    } else {
      ui.slideRepeats++;
    }
    final step = Duration(seconds: 10 * (1 + ui.slideRepeats ~/ 3).clamp(1, 12));
    var target = ui.slideTarget! + step * dir;
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    ui.slideTarget = target;
    _pokeControls();
    final from = _player.state.position;
    final delta = target - from;
    _showOsd(
      '${delta.isNegative ? '⏪' : '⏩'} ${_TimeLabel.format(target)} / ${_TimeLabel.format(duration)}'
      '   ${delta.isNegative ? '-' : '+'}${_TimeLabel.format(delta.abs())}',
      const Duration(milliseconds: 1500),
    );
  }

  /// BACK, one layer at a time: the panel back to the dial, the dial away; on the picture the first press only says
  /// how to leave, a second one within two seconds leaves.
  void _tvBack() {
    final ui = _tvUi;
    if (_panel != null) {
      _tvToDial();
    } else if (ui.dialOpen) {
      _tvCloseDial();
    } else if (ui.exitTimer?.isActive ?? false) {
      ui.exitTimer!.cancel();
      Navigator.of(context).maybePop();
    } else {
      ui.exitTimer = Timer(const Duration(seconds: 2), () {});
      _showOsd('再按一次退出', const Duration(seconds: 2));
    }
  }

  /// A seek being held is dropped when a layer comes up: nothing seeks behind it.
  void _tvDropSlide() {
    _tvUi.slideTarget = null;
    _tvUi.slideRepeats = 0;
  }

  /// After the frame that puts the dial in (or lets it take the focus again once a panel is gone).
  void _tvFocusDialSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _tvUi.dialOpen && _panel == null) _tvUi.dial.requestFocus();
    });
  }

  /// ↑ / ↓ on the picture: the dial, on the entry used last.
  void _tvOpenDial() {
    _tvDropSlide();
    _tvSet(() => _tvUi.dialOpen = true);
    _tvFocusDialSoon();
  }

  /// The panel of [entry] next to the dial (from the dial, the menu key, holding OK, or a click on the entry). The
  /// panel takes the focus as it comes in ([TvDialPanel]).
  void _tvOpenPanel(DialEntry entry) {
    _tvDropSlide();
    _tvSet(() {
      _tvUi.dialOpen = true;
      TvDialMemory.last = entry;
      _panel = _tvPanelOf(entry);
    });
  }

  /// From a panel back to the dial, the focus on the entry that opened it.
  void _tvToDial() {
    _tvSet(() {
      final panel = _panel;
      if (panel != null) TvDialMemory.last = _tvEntryOf(panel);
      _panel = null;
      _tvUi.dialOpen = true;
    });
    _tvFocusDialSoon();
  }

  /// Everything away: the picture has the keys again. While it plays the picture is left clear (the info bar's timer
  /// may have run out while a panel was open, which keeps it up); paused, the info bar stays.
  void _tvCloseDial() {
    _tvSet(() {
      final panel = _panel;
      if (panel != null) TvDialMemory.last = _tvEntryOf(panel);
      _panel = null;
      _tvUi.dialOpen = false;
      if (_player.state.playing) {
        _hideTimer?.cancel();
        _controlsVisible = false;
      }
    });
    _focus.requestFocus();
  }

  /// ← / → on the dial: the lit entry's value one step down or up.
  void _tvAdjust(DialEntry entry, int dir) {
    switch (entry) {
      case DialEntry.episodes:
        final target = _episode + dir;
        if (target < 0 || target >= _currentLine.episodes.length) {
          _showOsd(dir < 0 ? '已经是第一集' : '已经是最后一集');
        } else {
          _playEpisode(target);
        }
      case DialEntry.lines:
        // The next line in that direction that has episodes; a choice by hand, like one made in the panel.
        final lines = _detail.lines;
        for (var i = _line + dir; i >= 0 && i < lines.length; i += dir) {
          if (lines[i].episodes.isNotEmpty) {
            _pickLine(i);
            return;
          }
        }
        _showOsd(lines.length < 2 ? '只有这一条线路' : (dir < 0 ? '已经是第一条线路' : '已经是最后一条线路'));
      case DialEntry.speed:
        _stepSpeed(dir);
        _tvSet(() {});
      case DialEntry.subtitles:
        unawaited(_tvCycleSubtitle(dir));
      case DialEntry.danmaku:
        _toggleDanmaku();
      case DialEntry.info || DialEntry.more:
        break;
    }
  }

  // ------------------------------------------------------------------ what the dial and the info bar say

  String get _tvTitle => '${_detail.name} · ${_currentEpisode.name}';

  /// 1080p, 4K … from the picture's size; until the player knows it, what the line probe measured of this line;
  /// empty when neither knows.
  String get _tvQuality {
    final w = _player.state.width, h = _player.state.height;
    if (w != null && h != null && w > 0 && h > 0) return PlayInfoPanel.quality(w, h);
    return _probeOf(_line)?.quality ?? '';
  }

  /// Under the title of the info bar: 线路 2 · 1080p · 中文字幕 · 弹幕开.
  String get _tvCaption => [
    if (_linesShown) _lineName(_line),
    if (_tvQuality.isNotEmpty) _tvQuality,
    if (_tracks.hasSubtitles) _tvSubtitleNow == 'off' ? '字幕关' : (_tvSubtitleName(_tvSubtitleNow) ?? '字幕关'),
    _danmakuPrefs.enabled ? '弹幕开' : '弹幕关',
  ].join(' · ');

  /// The subtitles ← / → go round on the dial, as [PlayerTracks.selected] names them (after `off`).
  List<String> get _tvSubtitleIds => [
    for (final t in _tracks.internalSubtitles) 'int:${t.id}',
    for (final e in _tracks.external) 'ext:${e.url}',
    for (final l in _tracks.local) l.url,
  ];

  /// The subtitle showing, one of [_tvSubtitleIds], or `off`.
  String get _tvSubtitleNow {
    final selected = _tracks.selected;
    if (selected.isNotEmpty) return selected;
    // Nothing chosen yet: whatever the player took by itself.
    final own = 'int:${_player.state.track.subtitle.id}';
    return _tvSubtitleIds.contains(own) ? own : 'off';
  }

  String? _tvSubtitleName(String id) {
    if (id.startsWith('int:')) {
      final track = _tracks.internalSubtitles.where((t) => 'int:${t.id}' == id).firstOrNull;
      return track == null ? null : _tracks.subtitleLabel(track);
    }
    if (id.startsWith('ext:')) return _tracks.external.where((e) => 'ext:${e.url}' == id).firstOrNull?.name;
    return _tracks.local.where((l) => l.url == id).firstOrNull?.name;
  }

  Future<void> _tvCycleSubtitle(int dir) async {
    final ids = ['off', ..._tvSubtitleIds];
    if (ids.length < 2) {
      _showOsd('这个视频没有字幕', const Duration(seconds: 2));
      return;
    }
    final i = ids.indexOf(_tvSubtitleNow);
    await _tracks.selectById(ids[((i < 0 ? 0 : i) + dir) % ids.length]);
  }

  /// What an entry of the dial shows on its right.
  Widget _tvDialValue(DialEntry entry) {
    final Widget value = switch (entry) {
      DialEntry.episodes => Text('第 ${_episode + 1} 集 · 共 ${_currentLine.episodes.length} 集'),
      DialEntry.lines => Text([_lineName(_line), if (_tvQuality.isNotEmpty) _tvQuality].join(' · ')),
      DialEntry.speed => Text('${_player.state.rate}×'),
      DialEntry.subtitles => Text(!_tracks.hasSubtitles ? '没有字幕' : (_tvSubtitleNow == 'off' ? '关' : (_tvSubtitleName(_tvSubtitleNow) ?? '关'))),
      DialEntry.danmaku => Text(_danmakuPrefs.enabled ? '开' : '关'),
      DialEntry.info => TvHealthWord(player: _player),
      DialEntry.more => Text(_tvAspectSupported ? '画面、音轨、屏显时间' : '音轨、屏显时间'),
    };
    return KeyedSubtree(key: Key('tv-dial-${entry.name}-value'), child: value);
  }

  /// What the 线路 panel says of a line that is not playing. For now what this round of lines found out (a line that
  /// failed for this episode); the line check (docs/design/line-probe.md) puts what it measured here.
  /// What the 线路 panel says beside a line: what the line probe found (快 / 慢 / 打不开 in simple mode, the picture and
  /// the speed otherwise), or that it failed in this round when the probe has nothing to say about it.
  String? _tvLineStatus(int line) {
    final words = _probeOf(line)?.text(probeWording(_userMode.mode)) ?? '';
    if (words.isNotEmpty && !(_failedLines.contains(line) && _probeOf(line)!.state.alive)) return words;
    return _failedLines.contains(line) ? '刚才打不开' : null;
  }

  List<TvHint> _tvHints(_PlayerPanel? panel) {
    const back = (['←', '返回'], '回到拨盘');
    return switch (panel) {
      null => const [(['↑', '↓'], '换一项'), (['←', '→'], '直接调'), (['OK'], '进去细调'), (['返回'], '收起')],
      _PlayerPanel.lines => const [(['↑', '↓'], '选一条'), (['OK'], '换到这条'), back],
      _PlayerPanel.episodes => const [(['OK'], '播放这一集'), back],
      _ => const [(['OK'], '选中'), back],
    };
  }

  // ------------------------------------------------------------------ 画面比例, 屏显时间

  /// Only libmpv can be told another shape for the picture.
  bool get _tvAspectSupported => _player.platform is NativePlayer || _player.platform is MpvProperties;

  static const _tvAspects = [('-1', '原始'), ('16:9', '16:9'), ('4:3', '4:3'), ('2.35:1', '2.35:1')];

  void _tvSetAspect(String value) {
    _tvSet(() => _tvUi.aspect = value);
    unawaited(setMpvProperty(_player, 'video-aspect-override', value));
  }

  void _tvSetClock(OsdClock clock) {
    unawaited(clock.save(_settings));
    _tvSet(() {});
  }

  // ------------------------------------------------------------------ what is drawn

  /// The info bar (TV-Dial-Info), which the page fades in and out like the other layouts' bars. Under the dial the
  /// dial's own frame takes its place.
  Widget _tvBars(BuildContext context) {
    if (_tvLayerOpen) return const SizedBox.shrink();
    return StreamBuilder<bool>(
      stream: _player.stream.playing,
      initialData: _player.state.playing,
      builder: (context, snap) {
        final playing = snap.data ?? false;
        return ListenableBuilder(
          listenable: Listenable.merge([_tracks, _danmakuPrefs]),
          builder: (context, _) => TvOsd(
            key: const Key('tv-info-bar'),
            player: _player,
            buffered: _buffered,
            title: _tvTitle,
            caption: _tvCaption,
            clock: _tvClock != OsdClock.off,
            paused: !playing && _started && _error == null,
            hints: [
              (['OK'], playing ? '暂停' : '继续'),
              (['←', '→'], '快退 / 快进'),
              (['↑', '↓'], '拨盘'),
              (['返回'], '按两次退出'),
            ],
          ),
        );
      },
    );
  }

  /// Over everything else on the picture: the dial with its panel, or the time in a corner (屏显时间: 一直显示)
  /// while nothing is up.
  Widget _buildTvLayer(BuildContext context) {
    final open = _tvLayerOpen;
    final pad = MediaQuery.paddingOf(context);
    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!open && !_barsVisible && _tvClock == OsdClock.always)
            Positioned(top: pad.top, right: pad.right, child: const IgnorePointer(child: TvCornerClock(key: Key('tv-corner-clock')))),
          if (open) _buildTvDial(context),
        ],
      ),
    );
  }

  /// The dial at the left (TV-Dial) and, when one is open, its entry's panel right next to it (TV-Dial-Lines,
  /// TV-Dial-PlayInfo): the eye does not have to cross the screen, and the dial stays in sight with that entry lit.
  Widget _buildTvDial(BuildContext context) {
    final t = YzTokens.of(context);
    final panel = _panel;
    final pad = MediaQuery.paddingOf(context);
    final shade = t.scrim.withValues(alpha: 1);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Shading from the left, as far as the panel reaches when there is one.
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: panel == null ? 525 : 840,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [shade.withValues(alpha: 0.95), shade.withValues(alpha: panel == null ? 0.82 : 0.86), shade.withValues(alpha: 0)],
                  stops: [0, panel == null ? 0.6 : 0.78, 1],
                ),
              ),
            ),
          ),
        ),
        TvOsd(player: _player, buffered: _buffered, title: _tvTitle, clock: _tvClock != OsdClock.off, progressBar: panel == null, hints: _tvHints(panel)),
        Positioned(
          left: pad.left,
          top: pad.top + TvDialLayout.top,
          width: TvDialLayout.dialWidth,
          // While a panel is open the dial cannot take the focus: one layer at a time.
          child: ExcludeFocus(
            excluding: panel != null,
            child: Focus(
              focusNode: _tvUi.dial,
              child: StreamBuilder<double>(
                stream: _player.stream.rate,
                initialData: _player.state.rate,
                builder: (context, _) => ListenableBuilder(
                  listenable: Listenable.merge([_tracks, _danmakuPrefs]),
                  builder: (context, _) => TvDial(key: const Key('tv-dial'), selected: _tvEntry, open: panel != null, value: _tvDialValue, onTap: _tvOpenPanel),
                ),
              ),
            ),
          ),
        ),
        if (panel != null)
          Positioned(
            left: pad.left + TvDialLayout.panelLeft,
            top: pad.top + TvDialLayout.top,
            width: TvDialLayout.panelWidth,
            height: TvDialLayout.height,
            // Keyed by which panel it is, so one that replaces another starts afresh and takes the focus.
            child: FocusScope(
              node: _panelScope,
              child: KeyedSubtree(
                key: ValueKey(panel),
                child: TvDialPanel(key: Key('tv-panel-${panel == _PlayerPanel.chain ? 'chain' : _tvEntryOf(panel).name}'), child: _buildTvPanel(context, panel)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTvPanel(BuildContext context, _PlayerPanel panel) => switch (panel) {
    _PlayerPanel.episodes => _buildTvEpisodePanel(context),
    _PlayerPanel.lines => TvLinesPanel(
      names: [for (var i = 0; i < _detail.lines.length; i++) _lineName(i)],
      current: _line,
      quality: _tvQuality,
      status: _tvLineStatus,
      onPick: (i) {
        _tvCloseDial();
        if (i != _line) _pickLine(i);
      },
    ),
    _PlayerPanel.speed => _buildTvSpeedPanel(context),
    _PlayerPanel.tracks => TracksPanel(tracks: _tracks),
    _PlayerPanel.danmaku => DanmakuPanel(
      prefs: _danmakuPrefs,
      list: _danmaku,
      loading: _danmakuLoading,
      error: _danmakuError,
      onReload: () => _loadDanmaku(refresh: true),
      onLoadFile: _loadDanmakuFile,
    ),
    _PlayerPanel.info => _buildInfo(),
    _PlayerPanel.more => _buildTvMorePanel(context),
    _PlayerPanel.chain => PlayerChainPanel(chain: _chain),
  };

  Widget _tvSection(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(left: 2, top: 14, bottom: 8),
    child: Text(text, style: TextStyle(color: YzTokens.of(context).inkMuted, fontSize: 14)),
  );

  /// 选集: the lines on top, then the episodes; the one playing has the focus. Choosing one plays it and puts the dial
  /// away.
  Widget _buildTvEpisodePanel(BuildContext context) {
    final lines = _detail.lines;
    final episodes = _currentLine.episodes;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TvPanelHeading('选集', note: '共 ${episodes.length} 集'),
        if (lines.length > 1) ...[
          _tvSection(context, '线路'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < lines.length; i++)
                TvChip(
                  key: Key('tv-line-$i'),
                  label: _lineName(i),
                  selected: i == _line,
                  onTap: () {
                    _tvCloseDial();
                    if (i != _line) _pickLine(i);
                  },
                ),
            ],
          ),
          _tvSection(context, '选集'),
        ],
        EpisodeButtons(
          naming: EpisodeNaming.of(lines, _line, title: _detail.name),
          buttonWidth: 100,
          spacing: 8,
          maxColumns: 1,
          button: (context, i, label, row) => TvAutofocus(
            enabled: i == _episode,
            child: TvChip(
              key: Key('tv-episode-$i'),
              selected: i == _episode,
              onTap: () {
                _tvCloseDial();
                if (i != _episode) _playEpisode(i);
              },
              child: label,
            ),
          ),
        ),
      ],
    );
  }

  /// 倍速: every speed, the current one has the focus; choosing one keeps the panel open on it.
  Widget _buildTvSpeedPanel(BuildContext context) {
    final rate = _player.state.rate;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const TvPanelHeading('倍速'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _PlayerPageState._speeds)
              TvAutofocus(
                enabled: s == rate,
                child: TvChip(
                  key: Key('tv-speed-$s'),
                  label: '$s×',
                  selected: s == rate,
                  onTap: () {
                    _player.setRate(s);
                    _tvSet(() {});
                  },
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 更多设置 (the menu key, holding OK, the dial's last entry): 画面比例 where the player can, 音轨, 屏显时间; in
  /// developer mode the statistics and 片源从哪来.
  Widget _buildTvMorePanel(BuildContext context) {
    final muted = TextStyle(color: YzTokens.of(context).inkMuted, fontSize: 14);
    Widget chips(List<Widget> children) => Wrap(spacing: 8, runSpacing: 8, children: children);
    return ListenableBuilder(
      listenable: _tracks,
      builder: (context, _) {
        final audio = _tracks.audioTracks;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const TvPanelHeading('更多设置'),
            if (_tvAspectSupported) ...[
              _tvSection(context, '画面比例'),
              chips([
                for (final (value, label) in _tvAspects)
                  TvChip(key: Key('tv-aspect-$value'), label: label, selected: _tvUi.aspect == value, onTap: () => _tvSetAspect(value)),
              ]),
            ],
            _tvSection(context, '音轨'),
            if (audio.isEmpty)
              Text('没有可选的音轨', style: muted)
            else
              chips([
                for (final a in audio)
                  TvChip(key: Key('tv-audio-${a.id}'), label: _tracks.audioLabel(a), selected: _tracks.audioSelected == a.id, onTap: () => _tracks.selectAudio(a)),
              ]),
            _tvSection(context, '屏显时间'),
            chips([
              for (final c in OsdClock.values) TvChip(key: Key('tv-clock-${c.name}'), label: c.label, selected: _tvClock == c, onTap: () => _tvSetClock(c)),
            ]),
            if (_dev) ...[
              _tvSection(context, '开发者'),
              chips([
                TvChip(
                  key: const Key('tv-more-stats'),
                  label: _statsOpen ? '播放统计：开' : '播放统计：关',
                  icon: Icons.query_stats_rounded,
                  selected: _statsOpen,
                  onTap: _toggleStats,
                ),
                TvChip(
                  key: const Key('tv-more-chain'),
                  label: '片源从哪来',
                  icon: Icons.account_tree_outlined,
                  onTap: () => _tvSet(() => _panel = _PlayerPanel.chain),
                ),
              ]),
            ],
          ],
        );
      },
    );
  }
}
