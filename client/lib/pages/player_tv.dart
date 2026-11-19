part of 'player_page.dart';

/// What the player page keeps for the remote control on a TV.
class _TvPlayerUi {
  /// The play / pause button of the bar: ↓ puts the focus there.
  final playButton = FocusNode(debugLabel: 'tv-play');

  /// The 设置 panel of the remote (menu key): line, speed, subtitles, danmaku.
  bool settingsOpen = false;

  /// Holding ← / →: where the seek will land when the key is let go, and how long it has been held.
  Duration? slideTarget;
  int slideRepeats = 0;

  void dispose() => playButton.dispose();
}

/// The player with a remote control, the way TVBox users know it:
///
/// - OK (or play / pause) pauses and resumes, and shows the progress;
/// - ← / → seek 10 s; held, the target runs ahead faster and faster, and the player jumps once, when the key is
///   let go;
/// - ↑ opens the episode list, ↓ the control bar (then the D-pad walks its buttons), the menu key the settings
///   (line, speed, subtitles and audio, danmaku);
/// - channel up / down, page up / down and next / previous track change the episode; fast-forward / rewind seek 30 s;
/// - BACK closes what is open (a panel, then the bar) before it leaves the player.
extension _PlayerTv on _PlayerPageState {
  bool get _tvMode => isTv(context);

  bool get _tvPanelOpen => _anyPanelOpen || _tvUi.settingsOpen;

  KeyEventResult _onTvKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final primary = FocusManager.instance.primaryFocus;
    // A button of the bar, of an error or something in a panel has the focus (and the bar has not faded out under it).
    final inside = primary != _focus && (_tvPanelOpen || _controlsVisible || _error != null);

    if (TvKeys.isBack(key)) {
      if (down) _tvBack();
      return KeyEventResult.handled;
    }
    if (TvKeys.isMenu(key)) {
      if (down) _tvToggleSettings();
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
        _seekBy(Duration(seconds: TvKeys.isRewind(key) ? -30 : 30));
        return KeyEventResult.handled;
      }
    }
    if (inside) {
      // The D-pad walks the bar or the panel, OK presses; every key keeps the bar up a little longer.
      if (!_tvPanelOpen) _pokeControls();
      return KeyEventResult.ignored;
    }
    if (primary != _focus) {
      // The bar faded out under a button: the picture takes the keys again.
      _focus.requestFocus();
    }

    if (TvKeys.isLeft(key) || TvKeys.isRight(key)) {
      _tvSlide(event, TvKeys.isRight(key) ? 1 : -1);
      return KeyEventResult.handled;
    }
    if (!down) return event is KeyRepeatEvent ? KeyEventResult.handled : KeyEventResult.ignored;
    if (TvKeys.isActivate(key)) {
      _tvPlayPause();
    } else if (TvKeys.isUp(key)) {
      _tvSet(() => _panelOpen = true);
    } else if (TvKeys.isDown(key)) {
      _pokeControls();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tvUi.playButton.requestFocus();
      });
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
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

  /// BACK: the settings, then a panel, then the bar, then out of the player.
  void _tvBack() {
    if (_tvUi.settingsOpen) {
      _tvSet(() => _tvUi.settingsOpen = false);
      _focus.requestFocus();
    } else if (_anyPanelOpen) {
      _tvSet(() {
        _panelOpen = false;
        _tracksOpen = false;
        _danmakuOpen = false;
      });
      _focus.requestFocus();
    } else if (_controlsVisible && _player.state.playing) {
      _hideTimer?.cancel();
      _tvSet(() => _controlsVisible = false);
      _focus.requestFocus();
    } else if (FocusManager.instance.primaryFocus != _focus) {
      _focus.requestFocus();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _tvToggleSettings() {
    final open = !_tvUi.settingsOpen;
    _tvSet(() {
      _panelOpen = false;
      _tracksOpen = false;
      _danmakuOpen = false;
      _tvUi.settingsOpen = open;
    });
    if (!open) _focus.requestFocus();
  }

  /// Opens one of the other panels from the settings.
  void _tvOpen({bool tracks = false, bool danmaku = false, bool episodes = false}) {
    _tvSet(() {
      _tvUi.settingsOpen = false;
      _tracksOpen = tracks;
      _danmakuOpen = danmaku;
      _panelOpen = episodes;
    });
  }

  /// The episode list for the remote: lines on top, then the episodes, the one playing has the focus.
  Widget _buildTvEpisodePanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = widget.detail.lines;
    final episodes = _currentLine.episodes;
    return PlayerSidePanel(
      width: 440,
      onClose: () {
        _tvSet(() => _panelOpen = false);
        _focus.requestFocus();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        children: [
          if (lines.length > 1) ...[
            Text('线路', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < lines.length; i++)
                  _tvChip(
                    context,
                    lines[i].name.isEmpty ? '线路 ${i + 1}' : lines[i].name,
                    selected: i == _line,
                    key: Key('tv-line-$i'),
                    onTap: () {
                      _tvSet(() => _panelOpen = false);
                      _focus.requestFocus();
                      if (i != _line) _pickLine(i);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 20),
          ],
          Text('选集（${episodes.length}）', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (var i = 0; i < episodes.length; i++)
                SizedBox(
                  width: 120,
                  child: TvAutofocus(
                    enabled: i == _episode,
                    child: _tvChip(
                      context,
                      episodes[i].name,
                      selected: i == _episode,
                      key: Key('tv-episode-$i'),
                      onTap: () {
                        _tvSet(() => _panelOpen = false);
                        _focus.requestFocus();
                        if (i != _episode) _playEpisode(i);
                      },
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The settings of the remote (menu key).
  Widget _buildTvSettings(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lines = widget.detail.lines;
    final rate = _player.state.rate;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15)),
    );
    return PlayerSidePanel(
      width: 440,
      onClose: _tvToggleSettings,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        children: [
          heading('倍速'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final s in _PlayerPageState._speeds)
                TvAutofocus(
                  enabled: s == rate,
                  child: _tvChip(
                    context,
                    '${s}x',
                    selected: s == rate,
                    key: Key('tv-speed-$s'),
                    onTap: () {
                      _player.setRate(s);
                      _tvSet(() {});
                    },
                  ),
                ),
            ],
          ),
          if (lines.length > 1) ...[
            heading('线路'),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (var i = 0; i < lines.length; i++)
                  _tvChip(
                    context,
                    lines[i].name.isEmpty ? '线路 ${i + 1}' : lines[i].name,
                    selected: i == _line,
                    key: Key('tv-set-line-$i'),
                    onTap: () {
                      _tvToggleSettings();
                      if (i != _line) _pickLine(i);
                    },
                  ),
              ],
            ),
          ],
          heading('字幕与弹幕'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _tvChip(context, '字幕与音轨', icon: Icons.subtitles_outlined, key: const Key('tv-set-tracks'), onTap: () => _tvOpen(tracks: true)),
              _tvChip(
                context,
                _danmakuPrefs.enabled ? '弹幕：开' : '弹幕：关',
                icon: _danmakuPrefs.enabled ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
                selected: _danmakuPrefs.enabled,
                key: const Key('tv-set-danmaku-toggle'),
                onTap: _toggleDanmaku,
              ),
              _tvChip(context, '弹幕设置', icon: Icons.tune_rounded, key: const Key('tv-set-danmaku'), onTap: () => _tvOpen(danmaku: true)),
            ],
          ),
          heading('选集'),
          _tvChip(
            context,
            '${_currentEpisode.name}  ·  共 ${_currentLine.episodes.length} 集',
            icon: Icons.playlist_play_rounded,
            key: const Key('tv-set-episodes'),
            onTap: () => _tvOpen(episodes: true),
          ),
          const SizedBox(height: 18),
          Text('遥控器：OK 暂停 / 继续，← → 快退快进（按住加速），↑ 选集，↓ 控制栏，菜单键 设置，返回键 收起 / 退出', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _tvChip(BuildContext context, String label, {required VoidCallback onTap, bool selected = false, IconData? icon, Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimary : scheme.onSurface;
    return TvFocusable(
      key: key,
      onTap: onTap,
      scale: 1.08,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(color: selected ? scheme.primary : scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
