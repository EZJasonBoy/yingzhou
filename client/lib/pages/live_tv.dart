part of 'live_page.dart';

/// What the live page keeps for the remote control on a TV.
class _TvLiveUi {
  /// The channel list over the picture (OK), and the guide / catch-up (menu key).
  bool listOpen = false;
  bool guideOpen = false;

  /// The group shown in the list while browsing it (focus follows), before a channel is picked.
  int? browsingGroup;

  /// Number keys typed so far, and when the channel is tuned to.
  String digits = '';
  Timer? digitTimer;

  /// Closes the list or the guide when nothing is pressed for a while.
  Timer? idleTimer;

  void dispose() {
    digitTimer?.cancel();
    idleTimer?.cancel();
  }
}

/// Live TV with a remote control, the way TVBox users know it. Opening 直播 goes straight to the picture, full
/// screen. Then:
///
/// - ↑ / ↓ and channel up / down change channel; number keys type a channel number (its place in the list);
/// - OK opens the channel list (groups on the left; the focus follows the group);
/// - ← / → change line when the channel has several, else ← opens the list and → the guide; during catch-up they
///   seek;
/// - the menu key opens the guide, where an ended programme plays back (回看) and the one on air goes back to live;
/// - BACK closes what is open, then leaves full screen for the lists, then goes back to the main menu.
extension _LiveTv on _LivePageState {
  bool get _tvMode => isTv(context);

  static const _rowHeight = 56.0;

  void _tvSetState(VoidCallback f) => _tvSet(f);

  /// Every channel in list order, for numbers and stepping.
  List<(int, int)> get _tvFlat {
    final list = _list;
    if (list == null) return const [];
    return [
      for (var g = 0; g < list.groups.length; g++)
        for (var c = 0; c < list.groups[g].channels.length; c++) (g, c),
    ];
  }

  /// Called when a channel starts on a TV: the picture goes full screen (after the frame: this can happen while the
  /// shell builds, and going full screen tells the shell).
  void _tvOnPlay() {
    if (!_tvMode) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.visible || _immersive) return;
      _toggleImmersive();
      _focus.requestFocus();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _tvKeepOpen() {
    _tvUi.idleTimer?.cancel();
    _tvUi.idleTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || (!_tvUi.listOpen && !_tvUi.guideOpen)) return;
      _tvCloseOverlays();
    });
  }

  void _tvCloseOverlays() {
    _tvUi.idleTimer?.cancel();
    _tvSetState(() {
      _tvUi.listOpen = false;
      _tvUi.guideOpen = false;
      _tvUi.browsingGroup = null;
    });
    _focus.requestFocus();
  }

  void _tvOpenList() {
    _tvSetState(() {
      _tvUi.guideOpen = false;
      _tvUi.listOpen = true;
      _tvUi.browsingGroup = _playing?.$1 ?? _group;
    });
    _tvKeepOpen();
  }

  void _tvOpenGuide() {
    final ch = _channel;
    if (ch != null) _loadEpg(ch.name);
    _tvSetState(() {
      _tvUi.listOpen = false;
      _tvUi.guideOpen = true;
    });
    _tvKeepOpen();
  }

  KeyEventResult _onTvKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    final repeat = event is KeyRepeatEvent;
    final overlay = _tvUi.listOpen || _tvUi.guideOpen;
    final primary = FocusManager.instance.primaryFocus;

    if (TvKeys.isBack(key)) {
      if (down) _tvBack();
      return KeyEventResult.handled;
    }
    if (overlay || (primary != _focus && !_immersive)) {
      // The D-pad walks the list or the guide; OK picks.
      if (overlay) _tvKeepOpen();
      if (down && TvKeys.isMenu(key) && _immersive) {
        _tvUi.guideOpen ? _tvCloseOverlays() : _tvOpenGuide();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (!_immersive) return KeyEventResult.ignored;
    if (primary != _focus) _focus.requestFocus();

    final digit = TvKeys.digit(key);
    if (digit != null) {
      if (down) _tvDigit(digit);
      return KeyEventResult.handled;
    }
    if (!down && !repeat) return KeyEventResult.ignored;
    if (TvKeys.isUp(key) || TvKeys.isChannelUp(key)) {
      _stepChannel(-1);
      _showOverlay();
    } else if (TvKeys.isDown(key) || TvKeys.isChannelDown(key)) {
      _stepChannel(1);
      _showOverlay();
    } else if (TvKeys.isLeft(key) || TvKeys.isRight(key) || TvKeys.isRewind(key) || TvKeys.isFastForward(key)) {
      final forward = TvKeys.isRight(key) || TvKeys.isFastForward(key);
      final ch = _channel;
      if (_catchup != null) {
        _seekBy(Duration(seconds: forward ? 30 : -30));
        _showOverlay();
      } else if (!down) {
        // Held: nothing more (changing line on every repeat would never settle).
      } else if (ch != null && ch.urls.length > 1 && !TvKeys.isRewind(key) && !TvKeys.isFastForward(key)) {
        _switchLine(forward ? 1 : -1);
        _showOverlay();
      } else {
        forward ? _tvOpenGuide() : _tvOpenList();
      }
    } else if (!down) {
      return KeyEventResult.handled;
    } else if (TvKeys.isActivate(key)) {
      _tvOpenList();
    } else if (TvKeys.isMenu(key)) {
      _tvOpenGuide();
    } else if (TvKeys.isPlayPause(key)) {
      _player.playOrPause();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// BACK: an open list or guide, then full screen, then the main menu (the shell takes it from there).
  void _tvBack() {
    if (_tvUi.listOpen || _tvUi.guideOpen) {
      _tvCloseOverlays();
    } else if (_tvUi.digits.isNotEmpty) {
      _tvUi.digitTimer?.cancel();
      _tvSetState(() => _tvUi.digits = '');
    } else if (_immersive) {
      _toggleImmersive();
      // The lists: the playing channel has the focus (see _tvChannels).
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _tvDigit(int d) {
    _tvUi.digitTimer?.cancel();
    final typed = '${_tvUi.digits}$d';
    _tvSetState(() => _tvUi.digits = typed.length > 4 ? '$d' : typed);
    _tvUi.digitTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      final n = int.tryParse(_tvUi.digits) ?? 0;
      _tvSetState(() => _tvUi.digits = '');
      final flat = _tvFlat;
      if (n < 1 || n > flat.length) {
        _showOsd('没有第 $n 个频道（共 ${flat.length} 个）');
        return;
      }
      final (g, c) = flat[n - 1];
      _tvSetState(() => _group = g);
      _play(g, c);
      _showOverlay();
    });
  }

  /// The channel's number: its place in the whole list, from 1.
  int _tvNumber(int group, int channel) {
    final list = _list;
    if (list == null) return 0;
    var n = channel + 1;
    for (var g = 0; g < group && g < list.groups.length; g++) {
      n += list.groups[g].channels.length;
    }
    return n;
  }

  // ---------------------------------------------------------------- the lists (not full screen)

  Widget _buildTvLayout(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 170, child: _tvGroups(context, follow: true)),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        SizedBox(width: 260, child: _tvChannels(context, group: _group)),
        VerticalDivider(width: 1, color: scheme.outlineVariant),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(aspectRatio: 16 / 9, child: _buildPlayer(context)),
                ),
              ),
              _buildNowBar(context),
              Expanded(child: _tvGuideList(context)),
            ],
          ),
        ),
      ],
    );
  }

  /// The groups; with [follow] the channel column shows the group that has the focus.
  Widget _tvGroups(BuildContext context, {required bool follow}) {
    final list = _list;
    final scheme = Theme.of(context).colorScheme;
    if (list == null) return const SizedBox.shrink();
    final shown = _tvUi.browsingGroup ?? _group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Text(
            _sources.length > 1 ? _sources[_source].name : (list.name.isEmpty ? '直播' : list.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 15),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: ScrollController(initialScrollOffset: ((shown - 3).clamp(0, 1 << 20)) * _rowHeight),
            itemExtent: _rowHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: list.groups.length + (_sources.length > 1 ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == list.groups.length) {
                return _tvRow(context, key: const Key('tv-live-source'), title: '直播源…', icon: Icons.swap_vert_rounded, onTap: _tvPickSource);
              }
              final playingHere = _playing?.$1 == i;
              return _tvRow(
                context,
                key: Key('tv-group-$i'),
                title: list.groups[i].name,
                trailing: '${list.groups[i].channels.length}',
                selected: i == shown,
                playing: playingHere,
                onFocus: follow ? () => _tvSetState(() => _tvUi.listOpen ? _tvUi.browsingGroup = i : _group = i) : null,
                onTap: () => _tvSetState(() => _tvUi.listOpen ? _tvUi.browsingGroup = i : _group = i),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tvChannels(BuildContext context, {required int group}) {
    final list = _list;
    if (list == null || list.groups.isEmpty) return const SizedBox.shrink();
    final g = group.clamp(0, list.groups.length - 1);
    final channels = list.groups[g].channels;
    final playing = _playing?.$1 == g ? _playing!.$2 : -1;
    return ListView.builder(
      key: PageStorageKey('tv-channels-$g'),
      controller: ScrollController(initialScrollOffset: ((playing - 3).clamp(0, 1 << 20)) * _rowHeight),
      itemExtent: _rowHeight,
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      itemCount: channels.length,
      itemBuilder: (context, i) {
        final ch = channels[i];
        _loadEpg(ch.name);
        final now = _epg[ch.name]?.current(_now);
        return TvAutofocus(
          enabled: i == playing,
          child: _tvRow(
            context,
            key: Key('tv-channel-$g-$i'),
            leading: '${_tvNumber(g, i)}',
            title: ch.name,
            subtitle: now?.title,
            selected: i == playing,
            playing: i == playing,
            onTap: () {
              final wasOpen = _tvUi.listOpen;
              _tvSetState(() {
                _group = g;
                _tvUi.listOpen = false;
                _tvUi.browsingGroup = null;
              });
              if (_playing != (g, i)) {
                _play(g, i);
              } else if (!_immersive) {
                _tvOnPlay();
              }
              if (wasOpen || _immersive) _focus.requestFocus();
            },
          ),
        );
      },
    );
  }

  Future<void> _tvPickSource() async {
    final picked = await showTvChoiceDialog<int>(
      context,
      title: '直播源',
      items: [for (final s in _sources) (s.index, s.supported ? s.name : '${s.name}（${s.spider == 'py' ? '需要 Python' : '暂不支持'}）')],
      selected: _source,
      enabled: (i) => i < _sources.length && _sources[i].supported,
    );
    if (picked == null || picked == _source || !mounted) return;
    _tvSetState(() {
      _source = picked;
      _epg.clear();
      _pastEpg.clear();
      _tvUi.browsingGroup = null;
    });
    _loadList(refresh: false);
  }

  Widget _tvRow(
    BuildContext context, {
    required String title,
    required VoidCallback onTap,
    Key? key,
    String? leading,
    String? subtitle,
    String? trailing,
    IconData? icon,
    bool selected = false,
    bool playing = false,
    VoidCallback? onFocus,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: TvFocusable(
        key: key,
        onTap: onTap,
        scale: 1.04,
        center: false,
        onFocusChange: onFocus == null ? null : (f) => f ? onFocus() : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: selected ? scheme.primaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              if (leading != null)
                SizedBox(
                  width: 40,
                  child: Text(
                    leading,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
              if (icon != null) ...[Icon(icon, size: 20, color: fg), const SizedBox(width: 8)],
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 17, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: fg),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
              if (playing) Icon(Icons.graphic_eq_rounded, size: 18, color: scheme.primary),
              if (trailing != null && !playing) Text(trailing, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  /// The guide of the channel playing, for the remote: the days back it allows (catch-up), then its programmes;
  /// OK on an ended one plays it back, on the one on air goes back to live.
  Widget _tvGuideList(BuildContext context) {
    final ch = _channel;
    final scheme = Theme.of(context).colorScheme;
    if (ch == null) return const SizedBox.shrink();
    if (_source < _sources.length && !_sources[_source].hasEpg) {
      return Center(
        child: Text('这个直播源没有节目单', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    final daysBack = ch.hasCatchup ? ch.catchupDays : 0;
    final dayIndex = _guideDay.clamp(0, daysBack);
    final date = chinaDate(_now, daysAgo: dayIndex);
    final EpgDay? day;
    if (dayIndex == 0) {
      day = _epg[ch.name];
    } else {
      day = _pastEpg['${ch.name}|$date'];
      if (day == null) _loadPastEpg(ch.name, date);
    }
    final Widget list;
    if (day == null) {
      list = const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)));
    } else if (day.programs.isEmpty) {
      list = Center(
        child: Text('暂无节目单', style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    } else {
      final programs = day.programs;
      final current = programs.indexWhere((p) => p.isOnAt(_now));
      final back = _catchup;
      final focusAt = back != null ? programs.indexWhere((p) => p.start == back.start && p.end == back.end) : current;
      list = ListView.builder(
        key: ValueKey('tv-guide-${ch.name}|$date'),
        controller: ScrollController(initialScrollOffset: ((focusAt < 0 ? 0 : focusAt) - 2).clamp(0, 1 << 20) * _rowHeight),
        itemExtent: _rowHeight,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        itemCount: programs.length,
        itemBuilder: (context, i) {
          final p = programs[i];
          final past = p.end.isBefore(_now);
          final onAir = i == current;
          final playingBack = back != null && back.start == p.start && back.end == p.end;
          final canBack = ch.hasCatchup && past;
          final label = playingBack ? '回看中' : (onAir ? '直播中' : (canBack ? '回看' : ''));
          final row = Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(_hm(p.start), style: const TextStyle(fontSize: 15, fontFeatures: [FontFeature.tabularFigures()])),
              ),
              Expanded(
                child: Text(
                  p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: onAir ? FontWeight.w700 : FontWeight.w400),
                ),
              ),
              if (label.isNotEmpty) Text(label, style: TextStyle(fontSize: 13, color: playingBack || onAir ? scheme.primary : scheme.onSurfaceVariant)),
            ],
          );
          final highlighted = playingBack || (onAir && back == null);
          final VoidCallback? action = canBack && !playingBack
              ? () {
                  if (_tvUi.guideOpen) _tvCloseOverlays();
                  _playCatchup(p);
                  _tvOnPlay();
                }
              : (onAir && back != null)
              ? () {
                  if (_tvUi.guideOpen) _tvCloseOverlays();
                  _backToLive();
                }
              : null;
          final tile = Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: highlighted ? scheme.primaryContainer.withValues(alpha: 0.45) : null, borderRadius: BorderRadius.circular(10)),
            child: Opacity(opacity: past && !canBack ? 0.55 : 1, child: row),
          );
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: TvAutofocus(
              enabled: _tvUi.guideOpen && i == focusAt,
              // Rows without an action can still take the focus, so the D-pad scrolls through the whole day.
              child: TvFocusable(onTap: action ?? () {}, scale: 1.03, center: false, child: tile),
            ),
          );
        },
      );
    }
    if (daysBack == 0) return list;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            children: [
              for (var d = daysBack; d >= 0; d--)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TvFocusable(
                    key: Key('tv-guide-day-$d'),
                    onTap: () => _tvSetState(() => _guideDay = d),
                    onFocusChange: (f) {
                      if (f && _guideDay != d) _tvSetState(() => _guideDay = d);
                    },
                    scale: 1.06,
                    borderRadius: BorderRadius.circular(999),
                    center: false,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: d == dayIndex ? scheme.primaryContainer : scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(_dayLabel(d), style: const TextStyle(fontSize: 15)),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  // ---------------------------------------------------------------- full screen

  Widget _buildTvImmersive(BuildContext context) {
    final ch = _channel;
    final now = ch == null ? null : _epg[ch.name]?.current(_now);
    final next = ch == null ? null : _epg[ch.name]?.programs.where((p) => p.start.isAfter(_now)).firstOrNull;
    final p = _playing;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildPlayer(context),
        // What is on: shown on a change of channel or line, and with the list.
        if (ch != null && p != null)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _overlay && !_tvUi.listOpen && !_tvUi.guideOpen ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0xD0000000)]),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 40, 24, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${_tvNumber(p.$1, p.$2)}',
                            style: TextStyle(
                              color: TvColors.coral,
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        ch.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800),
                                      ),
                                    ),
                                    if (_catchup != null) ...[const SizedBox(width: 10), const _CatchupBadge()],
                                    if (ch.urls.length > 1) ...[
                                      const SizedBox(width: 12),
                                      Text('线路 ${_line + 1}/${ch.urls.length}', style: const TextStyle(color: Colors.white70, fontSize: 15)),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 4),
                                if (_catchup != null)
                                  Text(
                                    '回看：${_catchup!.title}  ${_md(_catchup!.start)} ${_hm(_catchup!.start)}–${_hm(_catchup!.end)}',
                                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                                  )
                                else if (now != null) ...[
                                  Text('正在播放：${now.title}  ${_hm(now.start)}–${_hm(now.end)}', style: const TextStyle(color: Colors.white, fontSize: 16)),
                                  const SizedBox(height: 6),
                                  SizedBox(width: 420, child: LinearProgressIndicator(value: now.progressAt(_now), minHeight: 4)),
                                  if (next != null) ...[
                                    const SizedBox(height: 6),
                                    Text('下一个：${_hm(next.start)} ${next.title}', style: const TextStyle(color: Colors.white60, fontSize: 14)),
                                  ],
                                ],
                                const SizedBox(height: 8),
                                Text(
                                  _catchup != null
                                      ? '←/→ 快退 / 快进   OK 频道列表   菜单键 节目单   返回 退出全屏'
                                      : '↑/↓ 换台   ${ch.urls.length > 1 ? '←/→ 换线路' : '← 频道列表  → 节目单'}   OK 频道列表   菜单键 节目单 / 回看   数字键 输入频道号',
                                  style: const TextStyle(color: Colors.white38, fontSize: 13),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (_catchup != null && _overlay)
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(child: _CatchupBar(player: _player)),
          ),
        if (_tvUi.digits.isNotEmpty)
          Align(
            alignment: Alignment.topRight,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(12)),
                child: Text(
                  _tvUi.digits,
                  style: TextStyle(color: TvColors.coral, fontSize: 48, fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ),
          ),
        if (_tvUi.listOpen)
          Align(
            alignment: Alignment.centerLeft,
            child: SafeArea(
              right: false,
              child: Container(
                width: 470,
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                decoration: BoxDecoration(color: scheme.surfaceContainer.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(16)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 175, child: _tvGroups(context, follow: true)),
                    VerticalDivider(width: 1, color: scheme.outlineVariant),
                    Expanded(child: _tvChannels(context, group: _tvUi.browsingGroup ?? _group)),
                  ],
                ),
              ),
            ),
          ),
        if (_tvUi.guideOpen)
          Align(
            alignment: Alignment.centerRight,
            child: SafeArea(
              left: false,
              child: Container(
                width: 460,
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                decoration: BoxDecoration(color: scheme.surfaceContainer.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(16)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                      child: Text(
                        ch == null ? '节目单' : '${ch.name} · 节目单${ch.hasCatchup ? ' / 回看' : ''}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(child: _tvGuideList(context)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
