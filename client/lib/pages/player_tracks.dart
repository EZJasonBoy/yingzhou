import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import '../engine/engine_client.dart';
import '../engine/media_extras_api.dart';
import '../engine/vod_models.dart';
import '../settings.dart';
import '../ui/tv/tv_focus.dart';

/// A player that takes libmpv properties by name. The real one is media_kit's `NativePlayer`; a test's fake player
/// implements this to see what the page set.
abstract class MpvProperties {
  Future<void> setMpvProperty(String name, String value);
}

/// Sets a libmpv property, where the player has them (not on the web, quietly nothing in a fake without them).
Future<void> setMpvProperty(Player player, String name, String value) async {
  final platform = player.platform;
  try {
    if (platform is NativePlayer) {
      await platform.setProperty(name, value);
    } else if (platform is MpvProperties) {
      await (platform as MpvProperties).setMpvProperty(name, value);
    }
  } catch (_) {
    // A property this libmpv does not know, or a player that is going away: subtitles still play.
  }
}

/// A file the user picked: its name and contents.
typedef PickedFile = ({String name, Uint8List bytes});

/// Asks the user for a file with one of [extensions]; null when they cancel.
typedef FilePicker = Future<PickedFile?> Function(String label, List<String> extensions);

Future<PickedFile?> pickWithDialog(String label, List<String> extensions) async {
  final file = await openFile(acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)]);
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

/// How the player asks for a file: the system's open dialog; widget tests put a function of their own here.
FilePicker filePicker = pickWithDialog;

/// A language code as a reader would say it.
String languageName(String? code) {
  final c = (code ?? '').trim().toLowerCase();
  return switch (c) {
    '' || 'und' => '',
    'zh' || 'chi' || 'zho' || 'chs' || 'zh-cn' || 'zh-hans' || 'sc' => '中文',
    'cht' || 'zh-tw' || 'zh-hk' || 'zh-hant' || 'tc' => '繁体中文',
    'yue' => '粤语',
    'en' || 'eng' => '英语',
    'ja' || 'jpn' || 'jp' => '日语',
    'ko' || 'kor' => '韩语',
    'fr' || 'fre' || 'fra' => '法语',
    'de' || 'ger' || 'deu' => '德语',
    'es' || 'spa' => '西班牙语',
    'ru' || 'rus' => '俄语',
    _ => code!.trim(),
  };
}

/// Subtitles and audio tracks of the video playing: the stream's own, the site's (from the engine), files from disk;
/// the timing, size and position of subtitles. Size and position are remembered on this device; which subtitle and
/// audio track a title plays with goes into its history ([subtitleChoice], [audioChoice]).
///
/// Subtitles are drawn by libmpv (libass, so ASS styles show as written). The site's subtitles are added to the
/// player only when chosen; a file from disk is converted by the engine first (it finds GBK, Big5, UTF-16 …).
class PlayerTracks extends ChangeNotifier {
  PlayerTracks({required this.player, required this.client, required this.settings, this.onNotice, this.pickFile}) {
    scale = double.tryParse(settings.getString(_scaleKey) ?? '')?.clamp(minScale, maxScale) ?? 1.0;
    raise = int.tryParse(settings.getString(_raiseKey) ?? '')?.clamp(0, maxRaise) ?? 0;
    _subs.add(player.stream.tracks.listen((_) => _tracksChanged()));
    unawaited(_applyStyle());
  }

  final Player player;
  final EngineClient client;
  final SettingsStore settings;

  /// A short notice for the picture (timing changed, subtitle chosen, …).
  final void Function(String text)? onNotice;
  /// How to ask for a file; null for [filePicker].
  final FilePicker? pickFile;
  final _subs = <StreamSubscription<dynamic>>[];

  static const _scaleKey = 'player.subtitle.scale';
  static const _raiseKey = 'player.subtitle.raise';
  static const minScale = 0.5;
  static const maxScale = 2.5;
  static const maxRaise = 40;
  static const delayStep = 0.5;

  /// The site's subtitles for the video playing, and files the user loaded for it.
  List<ExternalSubtitle> external = const [];
  final local = <ExternalSubtitle>[];

  /// Seconds the subtitles are shown later (negative: earlier) than they say.
  double delay = 0;

  /// Size, as a factor of the subtitle's own (libmpv `sub-scale`).
  late double scale;

  /// How far up from the bottom, in percent of the picture (libmpv `sub-pos` = 100 − this).
  late int raise;

  /// What is showing: `off`, `int:<track id>`, `ext:<url>` or `local:<n>`; empty for the player's own choice.
  String selected = '';
  String _lastShown = '';
  String _audio = '';

  /// What the history says to choose for this title, applied once the video's tracks are known.
  String _wantSubtitle = '';
  String _wantAudio = '';
  bool _pending = false;

  /// Titles of the tracks this page added to the player (the site's and local files), by what they show.
  final _added = <String, String>{};

  bool get hasSubtitles => internalSubtitles.isNotEmpty || external.isNotEmpty || local.isNotEmpty;

  /// The stream's own subtitles (not the ones added from outside).
  List<SubtitleTrack> get internalSubtitles => [
    for (final t in player.state.tracks.subtitle)
      if (t.id != 'auto' && t.id != 'no' && !_added.containsValue(t.title)) t,
  ];

  List<AudioTrack> get audioTracks => [
    for (final t in player.state.tracks.audio)
      if (t.id != 'auto' && t.id != 'no') t,
  ];

  /// The audio track playing: the one chosen, else the one libmpv picks by itself (the stream's default, or the first).
  String get audioSelected {
    if (_audio.isNotEmpty) return _audio;
    final current = player.state.track.audio.id;
    if (current != 'auto' && current != 'no') return current;
    final tracks = audioTracks;
    return (tracks.where((t) => t.isDefault == true).firstOrNull ?? tracks.firstOrNull)?.id ?? '';
  }

  /// For the history: `off`, `lang:<code>` or `name:<name>` of the subtitle chosen; empty when the user chose none.
  String get subtitleChoice {
    if (selected == 'off') return 'off';
    if (selected.startsWith('ext:')) {
      final e = external.where((s) => 'ext:${s.url}' == selected).firstOrNull;
      if (e != null) return e.lang.isNotEmpty ? 'lang:${e.lang}' : 'name:${e.name}';
    }
    if (selected.startsWith('int:')) {
      final t = internalSubtitles.where((s) => 'int:${s.id}' == selected).firstOrNull;
      if (t != null) return (t.language ?? '').isNotEmpty ? 'lang:${t.language}' : 'name:${t.title ?? ''}';
    }
    return '';
  }

  String get audioChoice {
    if (_audio.isEmpty) return '';
    final t = audioTracks.where((a) => a.id == _audio).firstOrNull;
    if (t == null) return '';
    return (t.language ?? '').isNotEmpty ? 'lang:${t.language}' : 'name:${t.title ?? ''}';
  }

  /// A new video is being opened: its own subtitles from [subtitles], what to choose from the history.
  void opened(List<ExternalSubtitle> subtitles, {String subtitle = '', String audio = ''}) {
    external = subtitles;
    local.clear();
    _added.clear();
    selected = '';
    _audio = '';
    _wantSubtitle = subtitle;
    _wantAudio = audio;
    _pending = true;
    delay = 0;
    unawaited(setMpvProperty(player, 'sub-delay', '0'));
    notifyListeners();
    _tracksChanged();
  }

  void _tracksChanged() {
    final tracks = player.state.tracks;
    // Applied once the media is in: it has a picture or a sound of its own.
    if (_pending && (tracks.video.length > 2 || tracks.audio.length > 2)) {
      _pending = false;
      unawaited(_applyRemembered());
    }
    notifyListeners();
  }

  Future<void> _applyRemembered() async {
    final want = _wantSubtitle;
    if (want == 'off') {
      await _select('off', SubtitleTrack.no());
    } else if (want.isNotEmpty) {
      final key = want.substring(want.indexOf(':') + 1);
      final byLang = want.startsWith('lang:');
      final internal = internalSubtitles.where((t) => byLang ? t.language == key : t.title == key).firstOrNull;
      final ext = external.where((s) => byLang ? s.lang == key : s.name == key).firstOrNull;
      if (internal != null) {
        await selectInternal(internal, announce: false);
      } else if (ext != null) {
        await selectExternal(ext, announce: false);
      }
    } else if (internalSubtitles.isEmpty && external.isNotEmpty) {
      // Like TVBox: the site's subtitle shows when the stream has none of its own.
      await selectExternal(external.first, announce: false);
    }
    final wantAudio = _wantAudio;
    if (wantAudio.isNotEmpty) {
      final key = wantAudio.substring(wantAudio.indexOf(':') + 1);
      final byLang = wantAudio.startsWith('lang:');
      final track = audioTracks.where((t) => byLang ? t.language == key : t.title == key).firstOrNull;
      if (track != null) await selectAudio(track, announce: false);
    }
  }

  Future<void> _select(String id, SubtitleTrack track) async {
    selected = id;
    if (id != 'off') _lastShown = id;
    notifyListeners();
    await player.setSubtitleTrack(track);
  }

  String subtitleLabel(SubtitleTrack t) {
    final title = (t.title ?? '').trim();
    final lang = languageName(t.language);
    if (title.isNotEmpty && lang.isNotEmpty && !title.contains(lang)) return '$title（$lang）';
    if (title.isNotEmpty) return title;
    if (lang.isNotEmpty) return '内嵌字幕 ${t.id}（$lang）';
    return '内嵌字幕 ${t.id}';
  }

  String audioLabel(AudioTrack t) {
    final parts = <String>[
      if ((t.title ?? '').trim().isNotEmpty) t.title!.trim(),
      if (languageName(t.language).isNotEmpty) languageName(t.language),
      if (t.channelscount != null) t.channelscount == 1 ? '单声道' : (t.channelscount == 2 ? '立体声' : '${t.channelscount} 声道'),
    ];
    return parts.isEmpty ? '音轨 ${t.id}' : '音轨 ${t.id} · ${parts.join(' · ')}';
  }

  Future<void> selectOff() async {
    await _select('off', SubtitleTrack.no());
    onNotice?.call('字幕已关闭');
  }

  Future<void> selectInternal(SubtitleTrack track, {bool announce = true}) async {
    await _select('int:${track.id}', track);
    if (announce) onNotice?.call('字幕：${subtitleLabel(track)}');
  }

  /// A subtitle from outside: added to the player the first time, chosen by its track afterwards.
  Future<void> selectExternal(ExternalSubtitle sub, {bool announce = true}) async {
    final id = 'ext:${sub.url}';
    await _select(id, _trackFor(id, sub.name, sub.lang) ?? SubtitleTrack.uri(sub.url, title: _titleFor(id, sub.name), language: sub.lang.isEmpty ? null : sub.lang));
    if (announce) onNotice?.call('字幕：${sub.name}');
  }

  /// The track of a subtitle added before, once the player lists it.
  SubtitleTrack? _trackFor(String id, String name, String lang) {
    final title = _added[id];
    if (title == null) return null;
    return player.state.tracks.subtitle.where((t) => t.title == title).firstOrNull;
  }

  /// A title for the player's track list that no other added subtitle has.
  String _titleFor(String id, String name) {
    final known = _added[id];
    if (known != null) return known;
    var title = name.isEmpty ? '字幕' : name;
    var n = 2;
    while (_added.values.contains(title)) {
      title = '${name.isEmpty ? '字幕' : name} ($n)';
      n++;
    }
    _added[id] = title;
    return title;
  }

  /// Asks for a subtitle file, has the engine turn it into UTF-8 text the player reads, and shows it.
  Future<void> loadFile() async {
    final PickedFile? file;
    try {
      file = await (pickFile ?? filePicker)('字幕', const ['srt', 'ass', 'ssa', 'vtt', 'lrc', 'ttml', 'dfxp', 'xml', 'json', 'sub', 'txt']);
    } catch (e) {
      onNotice?.call('打不开文件选择窗口：$e');
      return;
    }
    if (file == null) return;
    final ConvertedSubtitle converted;
    try {
      converted = await client.convertSubtitle(file.name, file.bytes);
    } catch (e) {
      onNotice?.call('字幕文件读不出来：$e');
      return;
    }
    final sub = ExternalSubtitle(name: file.name, format: converted.format, url: 'local:${local.length}');
    local.add(sub);
    final id = sub.url;
    await _select(id, SubtitleTrack.data(converted.text, title: _titleFor(id, sub.name)));
    onNotice?.call('字幕：${sub.name}');
  }

  Future<void> selectLocal(ExternalSubtitle sub) async {
    final track = _trackFor(sub.url, sub.name, '');
    if (track == null) return;
    await _select(sub.url, track);
    onNotice?.call('字幕：${sub.name}');
  }

  Future<void> selectAudio(AudioTrack track, {bool announce = true}) async {
    _audio = track.id;
    notifyListeners();
    await player.setAudioTrack(track);
    if (announce) onNotice?.call(audioLabel(track));
  }

  /// Chooses the subtitle named by an id as [selected] holds them (`off`, `int:…`, `ext:…`, `local:…`): for the
  /// remote control, which gets the list with these ids. False when there is no such subtitle.
  Future<bool> selectById(String id) async {
    if (id == 'off') {
      await selectOff();
      return true;
    }
    return id.isNotEmpty && await _reselect(id);
  }

  /// The audio track with this id (a track's own id); false when there is none.
  Future<bool> selectAudioById(String id) async {
    final track = audioTracks.where((t) => t.id == id).firstOrNull;
    if (track == null) return false;
    await selectAudio(track);
    return true;
  }

  /// C: subtitles off, or back on with the last one shown (the first there is when none was).
  Future<void> toggle() async {
    if (selected != 'off' && (selected.isNotEmpty || player.state.track.subtitle.id != 'no')) {
      await selectOff();
      return;
    }
    if (_lastShown.isNotEmpty && await _reselect(_lastShown)) return;
    final internal = internalSubtitles.firstOrNull;
    if (internal != null) {
      await selectInternal(internal);
    } else if (external.isNotEmpty) {
      await selectExternal(external.first);
    } else {
      onNotice?.call('这个视频没有字幕');
    }
  }

  Future<bool> _reselect(String id) async {
    if (id.startsWith('int:')) {
      final t = internalSubtitles.where((s) => 'int:${s.id}' == id).firstOrNull;
      if (t != null) await selectInternal(t);
      return t != null;
    }
    if (id.startsWith('ext:')) {
      final e = external.where((s) => 'ext:${s.url}' == id).firstOrNull;
      if (e != null) await selectExternal(e);
      return e != null;
    }
    final l = local.where((s) => s.url == id).firstOrNull;
    if (l != null) await selectLocal(l);
    return l != null;
  }

  /// J: the next subtitle in the list (after the last one, off).
  Future<void> cycle() async {
    final ids = <String>[
      for (final t in internalSubtitles) 'int:${t.id}',
      for (final e in external) 'ext:${e.url}',
      for (final l in local) l.url,
    ];
    if (ids.isEmpty) {
      onNotice?.call('这个视频没有字幕');
      return;
    }
    final i = ids.indexOf(selected);
    if (i == ids.length - 1) {
      await selectOff();
    } else {
      await _reselect(ids[i + 1]);
    }
  }

  /// A: the next audio track.
  Future<void> cycleAudio() async {
    final tracks = audioTracks;
    if (tracks.length < 2) {
      onNotice?.call(tracks.isEmpty ? '没有音轨' : '只有一条音轨');
      return;
    }
    final current = tracks.indexWhere((t) => t.id == audioSelected);
    await selectAudio(tracks[(current + 1) % tracks.length]);
  }

  static String delayLabel(double seconds) {
    if (seconds == 0) return '同步';
    final s = seconds.abs().toStringAsFixed(1);
    return seconds > 0 ? '延后 $s 秒' : '提前 $s 秒';
  }

  Future<void> stepDelay(double by) => setDelay(delay + by);

  Future<void> setDelay(double seconds) async {
    delay = (seconds * 10).round() / 10;
    notifyListeners();
    onNotice?.call('字幕${delay == 0 ? '同步（无偏移）' : delayLabel(delay)}');
    await setMpvProperty(player, 'sub-delay', delay.toStringAsFixed(2));
  }

  Future<void> stepScale(double by) async {
    scale = ((scale + by).clamp(minScale, maxScale) * 10).round() / 10;
    notifyListeners();
    await settings.setString(_scaleKey, scale.toStringAsFixed(1));
    onNotice?.call('字幕大小 ${(scale * 100).round()}%');
    await _applyStyle();
  }

  Future<void> stepRaise(int by) async {
    raise = (raise + by).clamp(0, maxRaise);
    notifyListeners();
    await settings.setString(_raiseKey, '$raise');
    onNotice?.call(raise == 0 ? '字幕在底部' : '字幕上移 $raise%');
    await _applyStyle();
  }

  Future<void> _applyStyle() async {
    await setMpvProperty(player, 'sub-scale', scale.toStringAsFixed(2));
    await setMpvProperty(player, 'sub-pos', '${100 - raise}');
  }

  /// The player's keys for subtitles and audio; false for any other key.
  bool handleKey(LogicalKeyboardKey key) {
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isAltPressed || keys.isMetaPressed) return false;
    if (key == LogicalKeyboardKey.keyC) {
      unawaited(toggle());
    } else if (key == LogicalKeyboardKey.keyJ) {
      unawaited(cycle());
    } else if (key == LogicalKeyboardKey.keyZ) {
      unawaited(stepDelay(-delayStep));
    } else if (key == LogicalKeyboardKey.keyX) {
      unawaited(stepDelay(delayStep));
    } else if (key == LogicalKeyboardKey.keyA) {
      unawaited(cycleAudio());
    } else {
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// The 字幕 / 音轨 side panel of the player.
class TracksPanel extends StatelessWidget {
  const TracksPanel({super.key, required this.tracks});

  final PlayerTracks tracks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
    );
    return ListenableBuilder(
      listenable: tracks,
      builder: (context, _) {
        final internal = tracks.internalSubtitles;
        final audio = tracks.audioTracks;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('字幕', style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(label: const Text('关闭'), selected: tracks.selected == 'off', onSelected: (_) => tracks.selectOff()),
                for (final t in internal)
                  ChoiceChip(
                    label: Text(tracks.subtitleLabel(t)),
                    selected: tracks.selected == 'int:${t.id}',
                    onSelected: (_) => tracks.selectInternal(t),
                  ),
                for (final e in tracks.external)
                  ChoiceChip(
                    avatar: const Icon(Icons.cloud_outlined, size: 16),
                    label: Text(e.name),
                    tooltip: '站点给出的字幕${e.lang.isEmpty ? '' : '（${languageName(e.lang)}）'}',
                    selected: tracks.selected == 'ext:${e.url}',
                    onSelected: (_) => tracks.selectExternal(e),
                  ),
                for (final l in tracks.local)
                  ChoiceChip(
                    avatar: const Icon(Icons.folder_open_outlined, size: 16),
                    label: Text(l.name),
                    selected: tracks.selected == l.url,
                    onSelected: (_) => tracks.selectLocal(l),
                  ),
              ],
            ),
            if (!tracks.hasSubtitles)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('这个视频没有字幕，可以从本地加载。', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(onPressed: tracks.loadFile, icon: const Icon(Icons.file_open_outlined), label: const Text('从本地文件加载…')),
            ),
            heading('字幕时间（Z 提前 / X 延后）'),
            _Stepper(
              label: PlayerTracks.delayLabel(tracks.delay),
              minusTooltip: '提前 0.5 秒 (Z)',
              plusTooltip: '延后 0.5 秒 (X)',
              onMinus: () => tracks.stepDelay(-PlayerTracks.delayStep),
              onPlus: () => tracks.stepDelay(PlayerTracks.delayStep),
              trailing: TextButton(onPressed: tracks.delay == 0 ? null : () => tracks.setDelay(0), child: const Text('归零')),
            ),
            heading('字幕大小'),
            _Stepper(
              label: '${(tracks.scale * 100).round()}%',
              minusTooltip: '小一点',
              plusTooltip: '大一点',
              onMinus: tracks.scale <= PlayerTracks.minScale ? null : () => tracks.stepScale(-0.1),
              onPlus: tracks.scale >= PlayerTracks.maxScale ? null : () => tracks.stepScale(0.1),
            ),
            heading('字幕位置'),
            _Stepper(
              label: tracks.raise == 0 ? '底部' : '上移 ${tracks.raise}%',
              minusTooltip: '往下',
              plusTooltip: '往上',
              minusIcon: Icons.arrow_downward_rounded,
              plusIcon: Icons.arrow_upward_rounded,
              onMinus: tracks.raise <= 0 ? null : () => tracks.stepRaise(-5),
              onPlus: tracks.raise >= PlayerTracks.maxRaise ? null : () => tracks.stepRaise(5),
            ),
            heading('音轨（A 切换）'),
            if (audio.isEmpty)
              Text('没有可选的音轨', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13))
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in audio)
                    ChoiceChip(label: Text(tracks.audioLabel(a)), selected: tracks.audioSelected == a.id, onSelected: (_) => tracks.selectAudio(a)),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// A panel on the right of the player, over a dimmed picture; a click beside it closes it.
class PlayerSidePanel extends StatelessWidget {
  const PlayerSidePanel({super.key, required this.onClose, required this.child, this.width = 380});

  final VoidCallback onClose;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: ColoredBox(
          color: Colors.black38,
          child: Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: () {},
              // A Material of its own: list tiles and switches in the panel draw their ink on it.
              child: Material(
                color: scheme.surfaceContainer.withValues(alpha: 0.96),
                // On a TV the remote's focus goes into the panel when it opens.
                child: SizedBox(width: width, child: SafeArea(child: TvAutofocus(child: child))),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.onMinus,
    required this.onPlus,
    required this.minusTooltip,
    required this.plusTooltip,
    this.minusIcon = Icons.remove_rounded,
    this.plusIcon = Icons.add_rounded,
    this.trailing,
  });

  final String label;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final String minusTooltip;
  final String plusTooltip;
  final IconData minusIcon;
  final IconData plusIcon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton.outlined(tooltip: minusTooltip, onPressed: onMinus, icon: Icon(minusIcon)),
        SizedBox(
          width: 120,
          child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
        ),
        IconButton.outlined(tooltip: plusTooltip, onPressed: onPlus, icon: Icon(plusIcon)),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    );
  }
}
