import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../engine/line_probe.dart';
import '../ui/device_form.dart';
import '../ui/line_probe_view.dart';
import '../ui/tv/tv_focus.dart';
import '../ui/yz_tokens.dart';

/// What the player keeps for the 「正在换线路」 card (rule six of the design system: a wait of more than two seconds
/// says what it waits for and offers a way out). The card comes up when a line has shown no picture [delay] after
/// it was opened, or at once when the player changed line by itself; it goes when the picture comes.
class LineSwitching {
  LineSwitching({required this.onDue});

  /// The card became due by itself (the [delay] ran out): the page draws it.
  final VoidCallback onDue;

  static const delay = Duration(seconds: 2);

  /// The card's focus scope on a TV: the page puts the focus back into it if it has strayed.
  final scope = FocusScopeNode(debugLabel: 'line-switching');

  Timer? _timer;
  bool _due = false;
  bool _switched = false;
  bool _dismissed = false;

  /// 「停在这里」 was pressed: the player stays on the line it is on.
  bool held = false;

  /// Why each line of this round failed, in a word or two, for its row.
  final failed = <int, String>{};

  /// No picture yet [delay] after opening, or the line was changed by itself; and the card was not closed.
  bool get due => _due && !_dismissed;

  /// [line] failed: [why] goes in its row.
  void lineFailed(int line, String why) => failed[line] = why == '没有画面' ? '超时' : why;

  /// The player is changing line by itself: the card comes up as the next line opens, even if it was closed.
  void switching() {
    _switched = true;
    _dismissed = false;
  }

  /// A line is being opened: the card comes [delay] later if there is no picture by then, at once after
  /// [switching].
  void opening() {
    _timer?.cancel();
    _due = _switched;
    _switched = false;
    if (!_due) {
      _timer = Timer(delay, () {
        _due = true;
        if (!_dismissed) onDue();
      });
    }
  }

  /// The picture came. Returns whether the card was up.
  bool picture() {
    _timer?.cancel();
    final was = due;
    _due = false;
    return was;
  }

  /// BACK, 「选一条」 by hand, 「停在这里」: the card stays away until the player changes line by itself again.
  void dismiss() => _dismissed = true;

  /// The user chose an episode or a line, or asked to try again: a new round of lines.
  void newRound() {
    failed.clear();
    held = false;
    _dismissed = false;
  }

  void dispose() {
    _timer?.cancel();
    scope.dispose();
  }

  /// The card's title and sentence. [trying] and [failed] are the lines as a sentence names them, [failedWhy] why
  /// the last one failed (said only outside simple mode, which says 打不开), [from] where playback carries on.
  static (String, String) words({required String trying, String? failed, String failedWhy = '', String? from, required bool simple}) {
    final carry = from == null ? '' : '，接上以后从 $from 接着播';
    if (failed == null) return ('正在等画面', '正在试$trying$carry，还没有画面。打不开会自动换下一条，也可以自己选一条。');
    final broke = simple || failedWhy.isEmpty ? '$failed 打不开' : '$failed$failedWhy';
    return ('正在换线路', '$broke。正在试$trying$carry。');
  }

  /// A row per line, for the card: [failed] lines (this round), the one being [trying], what the probe found of
  /// the others; a line without the episode says so.
  static List<SwitchingRow> rows({
    required int count,
    required String Function(int line) name,
    required bool Function(int line) hasEpisode,
    required int trying,
    required Map<int, String> failed,
    required LineProbe? Function(int line) probe,
  }) => [
    for (var i = 0; i < count; i++)
      if (i == trying)
        SwitchingRow(line: i, name: name(i), kind: SwitchingRowKind.trying, probe: probe(i))
      else if (failed.containsKey(i))
        SwitchingRow(line: i, name: name(i), kind: SwitchingRowKind.failed, note: failed[i]!)
      else if (!hasEpisode(i))
        SwitchingRow(line: i, name: name(i), kind: SwitchingRowKind.missing)
      else
        SwitchingRow(line: i, name: name(i), kind: SwitchingRowKind.probed, probe: probe(i)),
  ];
}

enum SwitchingRowKind { failed, trying, probed, missing }

/// A line in the card.
class SwitchingRow {
  const SwitchingRow({required this.line, required this.name, required this.kind, this.probe, this.note = ''});

  /// Its place in the title's lines.
  final int line;

  /// As the screen names it (simple mode: 线路 1, 线路 2 …).
  final String name;
  final SwitchingRowKind kind;

  /// What the probe found, if anything.
  final LineProbe? probe;

  /// Why it failed ([SwitchingRowKind.failed]).
  final String note;
}

/// 「正在换线路」, over the middle of the picture (on a phone held upright, under it, [bare]): the title with the
/// wave, a plain sentence, a row per line, and 「选一条」 / 「停在这里」.
///
/// On a TV the focus goes to 「选一条」 when the card comes up and cannot leave the card: ← / → go between the two
/// buttons, ↑ / ↓ stay, OK presses, BACK closes the card ([onClose]); the menu and media keys still reach the player.
/// Desktops and phones get the same card for the mouse and touch.
class LineSwitchingCard extends StatefulWidget {
  const LineSwitchingCard({
    super.key,
    required this.title,
    required this.sentence,
    required this.rows,
    required this.wording,
    required this.onPick,
    required this.onStay,
    required this.onClose,
    this.scope,
    this.bare = false,
  });

  final String title;
  final String sentence;
  final List<SwitchingRow> rows;
  final ProbeWording wording;

  /// 「选一条」: the lines to choose from.
  final VoidCallback onPick;

  /// 「停在这里」: no more changing line by itself.
  final VoidCallback onStay;

  /// BACK on a TV.
  final VoidCallback onClose;

  /// The focus scope the card holds on a TV ([LineSwitching.scope]).
  final FocusScopeNode? scope;

  /// Inside the panel under the picture, which has the title and a close button of its own.
  final bool bare;

  @override
  State<LineSwitchingCard> createState() => _LineSwitchingCardState();
}

class _LineSwitchingCardState extends State<LineSwitchingCard> {
  final _pick = FocusNode(debugLabel: 'switching-pick');
  final _stay = FocusNode(debugLabel: 'switching-stay');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && DeviceFormScope.readIsTv(context)) _pick.requestFocus();
    });
  }

  @override
  void dispose() {
    _pick.dispose();
    _stay.dispose();
    super.dispose();
  }

  /// The menu and media keys mean the same over the card as anywhere in the player.
  static bool _passes(LogicalKeyboardKey k) =>
      TvKeys.isMenu(k) ||
      TvKeys.isPlayPause(k) ||
      TvKeys.isChannelUp(k) ||
      TvKeys.isChannelDown(k) ||
      TvKeys.isNext(k) ||
      TvKeys.isPrevious(k) ||
      TvKeys.isFastForward(k) ||
      TvKeys.isRewind(k);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (TvKeys.isBack(key)) {
      if (down) widget.onClose();
      return KeyEventResult.handled;
    }
    if (_passes(key)) return KeyEventResult.ignored;
    if (down || event is KeyRepeatEvent) {
      if (TvKeys.isLeft(key)) {
        _pick.requestFocus();
      } else if (TvKeys.isRight(key)) {
        _stay.requestFocus();
      } else if (TvKeys.isActivate(key) && down) {
        if (_stay.hasPrimaryFocus) {
          widget.onStay();
        } else if (_pick.hasPrimaryFocus) {
          widget.onPick();
        } else {
          _pick.requestFocus();
        }
      } else if (!_pick.hasFocus && !_stay.hasFocus) {
        _pick.requestFocus();
      }
    }
    // Every other key stays here: nothing under the card seeks, opens a panel or takes the focus.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tv = isTv(context);
    final t = YzTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    // The prototype is drawn for a TV; a desktop window and a phone get the same card a little smaller.
    final k = tv ? 1.0 : 0.82;
    final rows = [for (final r in widget.rows) _row(context, r, k, t, scheme)];
    final buttons = Row(
      children: [
        Expanded(
          child: FilledButton(
            key: const Key('switching-pick'),
            focusNode: _pick,
            onPressed: widget.onPick,
            style: FilledButton.styleFrom(
              minimumSize: Size.fromHeight(52 * k),
              textStyle: TextStyle(fontSize: 18 * k, fontWeight: FontWeight.w600),
            ),
            child: const Text('选一条'),
          ),
        ),
        SizedBox(width: 16 * k),
        Expanded(
          child: OutlinedButton(
            key: const Key('switching-stay'),
            focusNode: _stay,
            onPressed: widget.onStay,
            style: OutlinedButton.styleFrom(
              minimumSize: Size.fromHeight(52 * k),
              foregroundColor: t.ink,
              side: BorderSide(color: t.lineStrong, width: 1.5),
              textStyle: TextStyle(fontSize: 18 * k),
            ),
            child: const Text('停在这里'),
          ),
        ),
      ],
    );
    final hint = Text(
      tv ? '出画面后这张卡片会自己收起 · 返回键关掉它' : '出画面后这张卡片会自己收起',
      style: TextStyle(color: t.inkFaint, fontSize: 13 * k),
    );
    final sentence = Text(
      widget.sentence,
      key: const Key('switching-sentence'),
      style: TextStyle(color: t.inkMuted, fontSize: 16 * k, height: 1.45),
    );

    if (widget.bare) {
      return ListView(
        key: const Key('switching-card'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
        children: [sentence, const SizedBox(height: 10), ...rows, const SizedBox(height: 14), buttons, const SizedBox(height: 10), hint],
      );
    }

    Widget card = Container(
      key: const Key('switching-card'),
      constraints: BoxConstraints(maxWidth: 560 * k),
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.all(22 * k),
      decoration: BoxDecoration(
        color: t.surfaceRaised,
        borderRadius: BorderRadius.circular(18 * k),
        boxShadow: const [BoxShadow(color: Color(0x8C050414), blurRadius: 28, offset: Offset(0, 12))],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ProbeWave(width: 40 * k, height: 11 * k, strokeWidth: 2.6 * k),
              SizedBox(width: 12 * k),
              Flexible(
                child: Text(
                  widget.title,
                  key: const Key('switching-title'),
                  style: TextStyle(fontSize: 22 * k, fontWeight: FontWeight.w600, color: t.ink),
                ),
              ),
            ],
          ),
          SizedBox(height: 6 * k),
          sentence,
          SizedBox(height: 10 * k),
          // Many lines: they scroll, the buttons stay in sight.
          Flexible(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: rows),
            ),
          ),
          SizedBox(height: 14 * k),
          buttons,
          SizedBox(height: 10 * k),
          hint,
        ],
      ),
    );
    if (tv) card = FocusScope(node: widget.scope, onKeyEvent: _onKey, child: card);
    // Only the card takes clicks: around it they reach the picture and the bars.
    return Center(child: card);
  }

  Widget _row(BuildContext context, SwitchingRow r, double k, YzTokens t, ColorScheme scheme) {
    final simple = widget.wording == ProbeWording.simple;
    final probe = r.probe;
    final size = 16 * k;
    final status = TextStyle(fontSize: 14.5 * k, color: t.inkMuted, fontFeatures: const [FontFeature.tabularFigures()]);
    final (Widget? mark, Widget right) = switch (r.kind) {
      SwitchingRowKind.failed => (
        Icon(Icons.close_rounded, size: size * 1.2, color: t.danger),
        Text(simple || r.note.isEmpty ? '打不开' : '打不开 · ${r.note}', style: status.copyWith(color: t.danger)),
      ),
      SwitchingRowKind.trying => (
        ProbeWave(width: size * 1.3, height: size * 0.5),
        Text(
          ['正在试', if (!simple && probe != null && probe.state.alive && probe.numbers.isNotEmpty) probe.numbers].join(' · '),
          style: status.copyWith(color: t.ink),
        ),
      ),
      SwitchingRowKind.missing => (null, Text('没有这一集', style: status.copyWith(color: t.inkFaint))),
      SwitchingRowKind.probed => switch (probe?.state) {
        LineProbeState.ok || LineProbeState.slow => (
          Icon(Icons.check_rounded, size: size * 1.2, color: t.success),
          LineProbeBadge(probe: probe!, wording: widget.wording, fontSize: 14.5 * k, prefix: '能播 · '),
        ),
        LineProbeState.dead => (
          Icon(Icons.close_rounded, size: size * 1.2, color: t.danger),
          LineProbeBadge(probe: probe!, wording: widget.wording, fontSize: 14.5 * k),
        ),
        LineProbeState.testing => (null, Text('测速中', style: status)),
        LineProbeState.sniff => (null, Text('要试了才知道', style: status)),
        _ => (null, const SizedBox.shrink()),
      },
    };
    final current = r.kind == SwitchingRowKind.trying;
    return Container(
      key: Key('switching-row-${r.line}'),
      height: 46 * k,
      padding: EdgeInsets.symmetric(horizontal: 14 * k),
      decoration: current ? BoxDecoration(color: t.surfaceHover, borderRadius: BorderRadius.circular(12 * k)) : null,
      child: Row(
        children: [
          SizedBox(
            width: size * 1.4,
            child: Center(child: mark),
          ),
          SizedBox(width: 10 * k),
          Text(
            r.name,
            style: TextStyle(
              fontSize: 17 * k,
              fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              color: r.kind == SwitchingRowKind.missing ? t.inkFaint : t.ink,
            ),
          ),
          SizedBox(width: 12 * k),
          Expanded(
            child: Align(alignment: Alignment.centerRight, child: right),
          ),
        ],
      ),
    );
  }
}
