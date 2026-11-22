import 'dart:async';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../engine/downloads.dart';
import '../engine/episode_names.dart';
import '../engine/library_models.dart';
import '../engine/line_probe.dart';
import '../engine/source_finder.dart';
import '../engine/vod_models.dart';
import '../ui/common.dart';
import '../ui/device_form.dart';
import '../ui/episode_buttons.dart';
import '../ui/line_probe_view.dart';
import '../ui/tv/tv_focus.dart';
import 'browse_page.dart' show FolderPage, errorText;
import 'download_sheet.dart';
import 'line_probe_settings.dart';
import 'player_page.dart';

void openDetail(BuildContext context, VodCard vod) {
  // A folder lists what is inside it, one level further down; back goes up again.
  if (vod.isFolder) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => FolderPage(folder: vod)));
    return;
  }
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DetailPage(preview: vod)));
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.preview, this.resume = false});

  /// What we already know from the poster wall; shown while the detail loads.
  final VodCard preview;

  /// Carry on where the title stopped as soon as it has loaded (继续播放 on simple mode's 首页); back from the player
  /// is this page, with its episodes.
  final bool resume;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  /// The source on screen: the card that was opened, or another site's copy of the same title found for it.
  late VodCard _shown = widget.preview;
  VodDetail? _d;
  Object? _error;
  bool _loading = true;

  /// Looking for the title on other sites; the message says why. Null when not.
  String? _searching;

  /// A card that stands for a title, and no other site has it.
  bool _notFound = false;

  /// Under the source line: why this source is the one on screen.
  String? _note;

  /// The user chose this source: it is never switched away from on its own (like a line chosen by hand).
  bool _picked = false;

  /// The search for this title on other sites, made when first needed; shared with the player.
  SourceFinder? _finder;

  /// Bumped by every load, so an answer that comes after another load began is dropped.
  int _gen = 0;

  int _line = 0;
  bool _expanded = false;

  /// [DetailPage.resume] has been acted on: playback starts by itself once only.
  bool _resumed = false;
  HistoryEntry? _history;
  bool _favorite = false;
  bool _lineFromHistory = false;

  /// The engine's downloads, for marking the episodes that are downloaded or under way.
  late final DownloadsWatcher _downloads = DownloadsWatcher(AppScope.read(context).client)..addListener(_downloadsChanged);

  /// The line probe (线路体检): what it finds is shared with the player through [LineProbes]. [_probing] is the
  /// probe this page started, stopped if the page closes before it is done; [_probedKey] the episode it was asked
  /// for on its own (「打开详情时先测线路」).
  late final LineProbes _probes;
  LineProbeRun? _probing;
  String? _probedKey;

  /// The history of what is on screen has been asked for (answered or not): the probe waits for it, since it says
  /// which episode 播放 will play.
  bool _libraryDone = false;

  /// The user picked a line on this page: 播放 uses it, whatever the probe says.
  bool _lineChosen = false;

  @override
  void initState() {
    super.initState();
    _probes = AppScope.read(context).lineProbes..addListener(_probesChanged);
    _start();
    _loadLibrary();
    _downloads.start();
  }

  @override
  void dispose() {
    _gen++;
    _finder?.dispose();
    _downloads.dispose();
    _probes
      ..removeListener(_probesChanged)
      ..release(_probing);
    super.dispose();
  }

  void _probesChanged() {
    if (mounted) setState(() {});
  }

  void _downloadsChanged() {
    if (mounted) setState(() {});
  }

  /// The title looked for on other sites.
  String get _title => widget.preview.name.trim().isNotEmpty ? widget.preview.name : (_d?.name ?? '');

  bool _changeable(String site) => AppScope.read(context).siteInfo(site)?.changeable ?? true;

  SourceFinder _ensureFinder() {
    final state = AppScope.read(context);
    return _finder ??= SourceFinder(client: state.client, title: _title, sites: state.titleSearchSites(exclude: widget.preview.site));
  }

  /// Loads what is on screen: a card that stands for a title is looked for on other sites instead (TVBox's
  /// `msearch:`), anything else is asked of its site. Callers that are not `initState` wrap it in setState.
  void _start({bool refresh = false}) {
    final gen = ++_gen;
    _loading = true;
    _error = null;
    _notFound = false;
    _searching = null;
    if (needsTitleSearch(_shown)) {
      unawaited(_autoFind(gen, why: '正在别的站点找《$_title》…'));
    } else {
      unawaited(_fetch(gen, _shown, refresh: refresh, fallback: !_picked));
    }
  }

  /// [card]'s detail. With [fallback], one that has no line to play, or does not load, sends the page looking for
  /// the title elsewhere, unless its site is not `changeable`.
  Future<void> _fetch(int gen, VodCard card, {bool refresh = false, bool fallback = true}) async {
    final state = AppScope.read(context);
    final VodDetail d;
    try {
      d = (await state.client.detail(card.site, card.id, refresh: refresh)).withId(card.id);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      if (fallback && _title.trim().isNotEmpty && _changeable(card.site)) {
        return _autoFind(gen, why: '「${state.siteName(card.site)}」上的《$_title》打不开，正在别的站点找…', failure: e);
      }
      setState(() {
        _loading = false;
        _error = e;
      });
      return;
    }
    if (!mounted || gen != _gen) return;
    if (fallback && d.lines.isEmpty && _title.trim().isNotEmpty && _changeable(d.site)) {
      return _autoFind(gen, why: '「${state.siteName(d.site)}」上的《$_title》没有播放线路，正在别的站点找…', from: d);
    }
    setState(() {
      _d = d;
      _loading = false;
    });
  }

  /// Looks for the title on other sites and shows the first copy of the same title that has lines (FongMi's way);
  /// a copy without lines, one that does not load, or one of another year than [from] is marked and skipped.
  /// Nothing found: [from] (the detail without lines) stays on screen with a note, a failed load shows its
  /// [failure], and a card that stands for a title says so.
  Future<void> _autoFind(int gen, {required String why, VodDetail? from, Object? failure}) async {
    final finder = _ensureFinder();
    setState(() {
      _searching = why;
      _loading = false;
    });
    final tried = <String>{};
    for (var i = 0; i < 8; i++) {
      final card = await finder.nextExact(skip: tried);
      if (!mounted || gen != _gen) return;
      if (card == null) break;
      tried.add(sourceKey(card.site, card.id));
      final VodDetail d;
      try {
        d = (await AppScope.read(context).client.detail(card.site, card.id)).withId(card.id);
      } catch (_) {
        finder.markBroken(card.site, card.id);
        continue;
      }
      if (!mounted || gen != _gen) return;
      if (d.lines.isEmpty || (from != null && yearsConflict(from.year, d.year))) {
        finder.markBroken(card.site, card.id);
        continue;
      }
      final origin = AppScope.read(context).siteName(widget.preview.site);
      setState(() {
        _show(card, d);
        _note = needsTitleSearch(widget.preview) ? null : '「$origin」上没有可播放的线路，已换到这里';
      });
      unawaited(_loadLibrary());
      return;
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _searching = null;
      if (from != null) {
        _d = from;
        _note = '其他站点也没有找到同名的片';
      } else if (failure != null) {
        _error = failure;
      } else {
        _notFound = true;
      }
    });
  }

  /// [card] and its detail are what the page shows from now on.
  void _show(VodCard card, VodDetail d) {
    _shown = card;
    _d = d;
    _searching = null;
    _loading = false;
    _error = null;
    _notFound = false;
    _line = 0;
    _lineFromHistory = false;
    _history = null;
    _favorite = false;
    _libraryDone = false;
    _probedKey = null;
    _lineChosen = false;
  }

  /// The user picked [card] in 换一个: it is loaded as it is, and stays even without lines.
  void _pick(VodCard card) {
    setState(() {
      _picked = true;
      _shown = card;
      _note = null;
      _d = null;
      _line = 0;
      _lineFromHistory = false;
      _lineChosen = false;
      _libraryDone = false;
      _probedKey = null;
      _history = null;
      _favorite = false;
      _loading = true;
      _error = null;
      _notFound = false;
      _searching = null;
    });
    unawaited(_fetch(++_gen, card, fallback: false));
    unawaited(_loadLibrary());
  }

  /// The player found no line of [_shown] that plays and moved on to [card]: the page follows it.
  void _switchedInPlayer(VodCard card, VodDetail d) {
    if (!mounted) return;
    final from = AppScope.read(context).siteName(_shown.site);
    setState(() {
      _show(card, d);
      _note = '「$from」的线路都不能播放，已换到这里';
    });
    unawaited(_loadLibrary());
  }

  Future<void> _loadLibrary() async {
    if (needsTitleSearch(_shown)) return;
    final client = AppScope.read(context).client;
    final site = _shown.site;
    final id = _shown.id;
    try {
      final results = await Future.wait([client.historyFor(site, id), client.isFavorite(site, id)]);
      if (!mounted || site != _shown.site || id != _shown.id) return;
      setState(() {
        _history = results[0] as HistoryEntry?;
        _favorite = results[1] as bool;
        _libraryDone = true;
      });
    } catch (_) {
      // Library is a nice-to-have on this page; browsing still works without it.
      if (mounted && site == _shown.site && id == _shown.id) setState(() => _libraryDone = true);
    }
  }

  Future<void> _toggleFavorite(VodDetail d) async {
    final client = AppScope.read(context).client;
    final next = !_favorite;
    setState(() => _favorite = next);
    try {
      if (next) {
        await client.putFavorite(FavoriteEntry(site: d.site, vodId: d.id, name: d.name, pic: d.pic, remarks: d.remarks));
      } else {
        await client.removeFavorite(d.site, d.id);
      }
    } catch (_) {
      if (mounted) setState(() => _favorite = !next);
    }
  }

  Future<void> _play(VodDetail detail, int line, int episode, {Duration? start}) async {
    // The line the probe found best, unless the user picked one here; then the probe of the episode played, if it
    // was not probed yet (「打开详情时先测线路」 off): the player takes its answers as they come.
    if (!_lineChosen) (line, episode) = _bestLine(detail, line, episode);
    _probeLines(detail, line, episode);
    // When every line fails, the player may look for the title on other sites (not for drives, and not for a source
    // the user chose or a site that is not `changeable`).
    final sources = detail.site.startsWith('drive:')
        ? null
        : PlayerSources(finder: _ensureFinder(), auto: !_picked && _changeable(detail.site), onSwitched: _switchedInPlayer);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlayerPage(detail: detail, line: line, episode: episode, startPosition: start, sources: sources),
    ));
    if (mounted) _loadLibrary();
  }

  /// 换一个: every copy found on other sites, the same title first, updated while the search goes on.
  Future<void> _showSourcePicker() async {
    final finder = _ensureFinder()..start();
    setState(() {});
    final state = AppScope.read(context);
    final current = _shown;
    Widget picker(BuildContext ctx) =>
        _SourcePicker(finder: finder, current: current, siteName: state.siteName, onPick: (c) => Navigator.of(ctx).pop(c));
    final VodCard? picked;
    if (isTouch(context)) {
      picked = await showModalBottomSheet<VodCard>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => FractionallySizedBox(heightFactor: 0.7, child: picker(ctx)),
      );
    } else {
      picked = await showDialog<VodCard>(
        context: context,
        builder: (ctx) => Dialog(child: SizedBox(width: 480, height: MediaQuery.sizeOf(ctx).height * 0.6, child: picker(ctx))),
      );
    }
    if (picked != null && mounted && !(picked.site == _shown.site && picked.id == _shown.id)) _pick(picked);
  }

  /// The probe of [line] / [episode] on every line of [d] that has it, unless there is a fresh one ([again] asks
  /// anew). A probe this page had under way for another episode stops.
  LineProbeRun? _probeLines(VodDetail d, int line, int episode, {bool again = false}) {
    final state = AppScope.read(context);
    if (!state.connected) return null;
    final run = _probes.probe(state.client, d, line: line, episode: episode, direct: state.fetchDirect, again: again);
    if (run != null && run.running && !identical(run, _probing)) {
      _probes.release(_probing);
      _probing = run;
    }
    return run;
  }

  /// The probe of what 播放 would play; null before there is one.
  LineProbeRun? _shownProbe(VodDetail d) {
    final state = AppScope.read(context);
    final target = _playTarget(d);
    return target == null || !state.connected ? null : _probes.find(state.client, d, target.$1, target.$2);
  }

  /// The episode 播放 would play: where the history says, else the first one of the line on screen.
  (int, int)? _playTarget(VodDetail d) {
    final resume = _resumePoint(d);
    if (resume != null) return (resume.$1, resume.$2);
    if (d.lines.isEmpty) return null;
    final line = _line.clamp(0, d.lines.length - 1);
    return d.lines[line].episodes.isEmpty ? null : (line, 0);
  }

  /// [episode] of [line], or the same episode on the line the probe found best ([choosePlayLine]): the one watched
  /// last time if it plays, else the best picture a line is fast enough for. Unchanged while there is no answer.
  (int, int) _bestLine(VodDetail d, int line, int episode) {
    final state = AppScope.read(context);
    final run = state.connected ? _probes.find(state.client, d, line, episode) : null;
    if (run == null) return (line, episode);
    final h = _history;
    final last = h == null ? -1 : d.lines.indexWhere((l) => l.name == h.line);
    final pick = choosePlayLine(run.results, lastWatched: last < 0 ? null : last, fallback: line, candidates: run.asked);
    if (pick == line) return (line, episode);
    final at = d.lines[pick].findEpisode(index: episode, name: d.lines[line].episodes[episode].name);
    return at == null ? (line, episode) : (pick, at);
  }

  /// Where the history says we were: (line, episode, position), matched by line name and episode id.
  (int, int, Duration)? _resumePoint(VodDetail d) {
    final h = _history;
    if (h == null || d.lines.isEmpty) return null;
    var line = d.lines.indexWhere((l) => l.name == h.line);
    if (line < 0) line = _line.clamp(0, d.lines.length - 1);
    final episodes = d.lines[line].episodes;
    if (episodes.isEmpty) return null;
    // Prefer the recorded position when it still holds the same episode: sites sometimes reuse one url
    // for several episodes, so matching by id alone can land on the wrong one.
    final atIndex = h.episodeIndex >= 0 && h.episodeIndex < episodes.length && episodes[h.episodeIndex].id == h.episodeId;
    var ep = atIndex ? h.episodeIndex : episodes.indexWhere((e) => e.id == h.episodeId);
    if (ep < 0) ep = h.episodeIndex.clamp(0, episodes.length - 1);
    return (line, ep, Duration(milliseconds: h.positionMs));
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        actions: [
          // The engine keeps details for a while; this asks the site again (new episodes, repaired lines).
          if (!state.userMode.simple)
            IconButton(key: const Key('detail-refresh'), tooltip: '刷新（重新向站点获取）', icon: const Icon(Icons.refresh), onPressed: () => setState(() => _start(refresh: true))),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          _Backdrop(pic: _d?.pic.isNotEmpty == true ? _d!.pic : widget.preview.pic),
          if (_searching != null)
            _searchingView(context)
          else if (_notFound)
            _notFoundView(context)
          else if (_loading)
            const LoadingView()
          else if (_error != null)
            StatusView(
              icon: Icons.cloud_off,
              message: '详情加载失败\n${errorText(_error)}',
              actionLabel: '重试',
              onAction: () => setState(_start),
            )
          else
            _content(context, _d!, state.siteName(_d!.site)),
        ],
      ),
    );
  }

  /// While the title is looked for on other sites.
  Widget _searchingView(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final finder = _finder;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          key: const Key('detail-searching'),
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.preview.pic.isNotEmpty) ...[
              ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: 112, height: 160, child: NetImage(widget.preview.pic))),
              const SizedBox(height: 16),
            ],
            Text(_title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(height: 14),
            Text(_searching!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
            if (finder != null)
              ListenableBuilder(
                listenable: finder,
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    finder.siteCount == 0 ? '' : '已搜 ${finder.answered}/${finder.siteCount} 个站点',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A card that stands for a title, and no other site has a copy that plays.
  Widget _notFoundView(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final finder = _ensureFinder();
    final n = finder.siteCount;
    final message = n == 0 ? '这个订阅里没有能搜索的站点，没法找《$_title》' : '没在其他站点找到《$_title》\n搜了 $n 个站点';
    final others = finder.all.length;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          key: const Key('detail-not-found'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                if (n > 0)
                  TvAutofocus(
                    child: FilledButton.tonal(
                      key: const Key('detail-find-retry'),
                      onPressed: () {
                        finder.restart();
                        setState(_start);
                      },
                      child: const Text('重试'),
                    ),
                  ),
                if (others > 0) OutlinedButton(onPressed: _showSourcePicker, child: Text('看看名字相近的（$others）')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 「来自 XX · 换一个」, and why this source is on screen when it is not the one that was opened.
  Widget _sourceLine(VodDetail d, String siteName, ColorScheme scheme) {
    final style = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    final finder = _finder;
    Widget change(int others) => TextButton(
          key: const Key('detail-change-source'),
          onPressed: _showSourcePicker,
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
          child: Text(others > 0 ? '换一个（$others）' : '换一个'),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text('来自 $siteName', style: style),
            // Drives hold the user's own files: there is nothing to look for elsewhere.
            if (!d.site.startsWith('drive:'))
              finder == null
                  ? change(0)
                  : ListenableBuilder(
                      listenable: finder,
                      builder: (context, _) => change(finder.all.where((c) => c.site != _shown.site || c.id != _shown.id).length),
                    ),
          ],
        ),
        if (_note != null) Text(_note!, key: const Key('detail-source-note'), style: style),
      ],
    );
  }

  Widget _content(BuildContext context, VodDetail d, String siteName) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final mode = AppScope.of(context).userMode;
    final simple = mode.simple;
    final resume = _resumePoint(d);
    if (widget.resume && !_resumed && resume != null) {
      _resumed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _play(d, resume.$1, resume.$2, start: resume.$3);
      });
    }
    if (resume != null && !_lineFromHistory) {
      // Start on the line the user watched last time.
      _lineFromHistory = true;
      _line = resume.$1;
    }
    // The probe of the episode 播放 would play, once the history has said which it is (on a phone only when the
    // user wants it: there it waits for 播放).
    final target = _libraryDone ? _playTarget(d) : null;
    if (target != null && LineProbeSettings.onDetail(context)) {
      final key = LineProbes.episodeKey(d, target.$1, target.$2);
      if (key != _probedKey) {
        _probedKey = key;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_d, d)) _probeLines(d, target.$1, target.$2);
        });
      }
    }
    final probe = _shownProbe(d);
    final wording = probeWording(mode.mode);
    final line = d.lines.isEmpty ? null : d.lines[_line.clamp(0, d.lines.length - 1)];
    // Some episode of this line is downloaded or under way: every episode button keeps room for its mark.
    final marked = line != null && line.episodes.any((e) => _downloads.find(d.site, line.name, e.id) != null);
    final naming = line == null ? EpisodeNaming.empty : EpisodeNaming.of(d.lines, d.lines.indexOf(line), title: d.name);
    final meta = [d.year, d.area, d.type, d.remarks].where((s) => s.isNotEmpty).join(' · ');

    final poster = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(width: wide ? 200 : 112, height: wide ? 286 : 160, child: NetImage(d.pic.isNotEmpty ? d.pic : _shown.pic.isNotEmpty ? _shown.pic : widget.preview.pic)),
    );
    // Narrow (a phone held upright): the title and facts go beside a small poster, the buttons under both.
    final heading = [
      Text(d.name, style: (wide ? theme.textTheme.headlineMedium : theme.textTheme.titleLarge)?.copyWith(fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (meta.isNotEmpty) Text(meta, style: TextStyle(color: scheme.onSurfaceVariant)),
      const SizedBox(height: 4),
      _sourceLine(d, siteName, scheme),
      if (d.director.isNotEmpty) ...[const SizedBox(height: 10), _kv('导演', d.director, scheme)],
      if (d.actor.isNotEmpty) ...[const SizedBox(height: 4), _kv('主演', d.actor, scheme)],
    ];
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wide) ...heading,
        const SizedBox(height: 18),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // The remote starts on the main action (TvAutofocus does nothing off TV).
            if (resume != null)
              TvAutofocus(
                key: const ValueKey('resume'),
                child: FilledButton.icon(
                  key: const Key('detail-play'),
                  onPressed: () => _play(d, resume.$1, resume.$2, start: resume.$3),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text('继续播放 ${EpisodeNaming.brief(EpisodeNaming.clean(d.lines[resume.$1].episodes[resume.$2].name), columns: 24)}  ${_fmt(resume.$3)}'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16)),
                ),
              )
            else
              TvAutofocus(
                key: const ValueKey('play'),
                child: FilledButton.icon(
                  key: const Key('detail-play'),
                  onPressed: line == null || line.episodes.isEmpty ? null : () => _play(d, _line, 0),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(line == null ? '暂无播放线路' : '播放'),
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16)),
                ),
              ),
            if (resume != null && line != null && line.episodes.isNotEmpty)
              OutlinedButton(
                onPressed: () => _play(d, _line, 0),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
                child: const Text('从头播放'),
              ),
            IconButton.filledTonal(
              tooltip: _favorite ? '取消收藏' : '收藏',
              onPressed: () => _toggleFavorite(d),
              icon: Icon(_favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                  color: _favorite ? Colors.pinkAccent : null),
            ),
            // Not for drive folders: their files are the user's own already, and the engine's download queue
            // resolves episodes through the sites, which drives are not.
            if (!simple && _downloads.available == true && line != null && !d.site.startsWith('drive:'))
              DownloadButton(detail: d, line: _line, watcher: _downloads, episode: resume != null && resume.$1 == _line ? resume.$2 : 0),
          ],
        ),
      ],
    );

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 56, 24, 32),
        children: [
          wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [poster, const SizedBox(width: 28), Expanded(child: info)])
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [poster, const SizedBox(width: 16), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: heading))],
                    ),
                    info,
                  ],
                ),
          if (d.content.isNotEmpty) ...[
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _plain(d.content),
                maxLines: _expanded ? null : 3,
                overflow: _expanded ? null : TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.6),
              ),
            ),
          ],
          if (mode.developer) _DevInfo(detail: d, line: line, runtime: AppScope.of(context).siteInfo(d.site)?.runtime.name ?? ''),
          if (d.lines.isNotEmpty) ...[
            const SizedBox(height: 28),
            // The line is the user's to choose in every mode. Simple mode numbers the lines (what the sites call
            // them means little) and leaves the row out when there is only one.
            if (!simple || d.lines.length > 1) ...[
              Text('线路', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i < d.lines.length; i++)
                    ChoiceChip(
                      key: Key('detail-line-$i'),
                      label: _lineLabel(d.lines, i, simple, probe?.of(i), wording),
                      selected: i == _line,
                      onSelected: (_) => setState(() {
                        _line = i;
                        _lineChosen = true;
                      }),
                    ),
                  ?_probeAction(d, probe),
                ],
              ),
              const SizedBox(height: 22),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('选集', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    [if (line!.episodes.length > 1) '共 ${line.episodes.length} 集', if (d.remarks.isNotEmpty) d.remarks].join(' · '),
                    key: const Key('detail-episodes-note'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              ],
            ),
            ..._namingNote(d, naming, scheme),
            const SizedBox(height: 10),
            EpisodeButtons(
              naming: naming,
              buttonWidth: wide ? 112 : _narrowEpisodeWidth(context),
              reserveMark: marked,
              mark: (i) {
                final download = _downloads.find(d.site, line.name, line.episodes[i].id);
                return download == null ? null : EpisodeDownloadMark(key: Key('download-mark-$i'), item: download, compact: true);
              },
              button: (context, i, label, row) => OutlinedButton(
                onPressed: () => _play(d, _line, i),
                style: OutlinedButton.styleFrom(
                  padding: row ? const EdgeInsets.symmetric(horizontal: 12) : const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                  alignment: row ? Alignment.centerLeft : null,
                  // The episode watched last time is highlighted.
                  backgroundColor: resume != null && resume.$1 == _line && resume.$2 == i ? scheme.primaryContainer : null,
                  side: BorderSide(color: scheme.outlineVariant),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: label,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Under 选集, when the names need a word: whose titles stand next to this line's numbers, or that this site
  /// only numbers its episodes while its remark speaks of dated ones (variety shows), with the way to another source.
  List<Widget> _namingNote(VodDetail d, EpisodeNaming naming, ColorScheme scheme) {
    final style = TextStyle(color: scheme.onSurfaceVariant, fontSize: 13);
    if (naming.borrowedFrom != null) {
      return [
        const SizedBox(height: 4),
        Text('这条线路只给了序号，标题取自线路「${naming.borrowedFrom}」的同一位置', key: const Key('detail-episodes-borrowed'), style: style),
      ];
    }
    if (!naming.onlyNumbers || naming.labels.length < 2 || !_remarkNamesEpisodes.hasMatch(d.remarks) || d.site.startsWith('drive:')) return const [];
    return [
      const SizedBox(height: 2),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text('这个站点的选集只给了序号，没有每一期的标题', key: const Key('detail-episodes-numbers'), style: style),
          TextButton(
            onPressed: _showSourcePicker,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
            child: const Text('看看别的来源'),
          ),
        ],
      ),
    ];
  }

  /// A remark that names an episode by more than its place: a date (`更新至20261120加更版`) or an issue (`更6期`).
  static final _remarkNamesEpisodes = RegExp(r'\d{6,}|期|版');

  /// On a narrow screen the episode buttons fill the row: as many of about 84 dp as fit, at least three.
  static double _narrowEpisodeWidth(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final width = MediaQuery.sizeOf(context).width - padding.left - padding.right - 48;
    final columns = ((width + 8) / 92).floor().clamp(3, 8);
    return (width - 8 * (columns - 1)) / columns - 0.5;
  }

  /// A line's chip: its name ([_lineChip]) and what the probe says of it (the wave while it is measured).
  static Widget _lineLabel(List<PlayLine> lines, int i, bool simple, LineProbe? probe, ProbeWording wording) {
    final name = Text(_lineChip(lines, i, simple));
    if (!LineProbeBadge.shows(probe, wording)) return name;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [name, const SizedBox(width: 8), LineProbeBadge(key: Key('detail-line-probe-$i'), probe: probe!, wording: wording)],
    );
  }

  /// After the lines: 「重新测一遍」 once they were probed, 「测一遍线路」 where the probe waits for 播放 (phones);
  /// nothing with an engine from before the probe, or when only one line has the episode.
  Widget? _probeAction(VodDetail d, LineProbeRun? run) {
    final target = _playTarget(d);
    if (target == null || d.site.startsWith('drive:') || LineProbes.linesWith(d, target.$1, target.$2).length < 2) return null;
    // Probing by itself: no button until the history has said what to probe (a probe that has gone stale since
    // can be asked for again).
    if (run == null && LineProbeSettings.onDetail(context) && _probedKey == null) return null;
    if (run != null && run.unsupported) return null;
    final running = run?.running ?? false;
    return TextButton.icon(
      key: const Key('detail-probe-again'),
      onPressed: running ? null : () => _probeLines(d, target.$1, target.$2, again: true),
      icon: const Icon(Icons.refresh_rounded, size: 18),
      label: Text(running ? '正在测…' : (run == null ? '测一遍线路' : '重新测一遍')),
    );
  }

  /// A line on its chip: the site's name and how many episodes it has; in simple mode its number, and the episodes
  /// only where the lines differ in that (one of them is ahead or behind).
  static String _lineChip(List<PlayLine> lines, int i, bool simple) {
    final count = lines[i].episodes.length;
    if (!simple) return '${lines[i].name}  $count';
    final differ = lines.any((l) => l.episodes.length != count);
    return differ ? '${lineTitle(lines, i, numbered: true)} · $count 集' : lineTitle(lines, i, numbered: true);
  }

  Widget _kv(String k, String v, ColorScheme scheme) => Text.rich(
        TextSpan(children: [
          TextSpan(text: '$k  ', style: TextStyle(color: scheme.onSurfaceVariant)),
          TextSpan(text: v),
        ]),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      );

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// Site descriptions often contain HTML.
  static String _plain(String html) => html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .trim();
}

/// Developer mode: what the site answered, as the engine names it (the keys and ids a subscription's author needs).
class _DevInfo extends StatelessWidget {
  const _DevInfo({required this.detail, required this.line, required this.runtime});

  final VodDetail detail;
  final PlayLine? line;
  final String runtime;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = line == null || line!.episodes.isEmpty ? null : line!.episodes.first;
    final rows = <(String, String)>[
      ('站点', '${detail.site}${runtime.isEmpty ? '' : '（$runtime）'}'),
      ('vod_id', detail.id),
      ('线路', detail.lines.isEmpty ? '无' : detail.lines.map((l) => '${l.name}×${l.episodes.length}').join('  ')),
      if (first != null) ('首集地址', first.id),
    ];
    return Container(
      key: const Key('detail-dev-info'),
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('开发者信息', style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          const SizedBox(height: 6),
          for (final (k, v) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 72, child: Text(k, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12, height: 1.5))),
                  Expanded(
                    child: SelectableText(v, minLines: 1, maxLines: 3, style: const TextStyle(fontFamilyFallback: ['Cascadia Mono', 'Consolas', 'Menlo', 'monospace'], fontSize: 12, height: 1.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The copies of a title found on other sites: the same title, then close names, as the search brings them.
class _SourcePicker extends StatelessWidget {
  const _SourcePicker({required this.finder, required this.current, required this.siteName, required this.onPick});

  final SourceFinder finder;
  final VodCard current;
  final String Function(String key) siteName;
  final ValueChanged<VodCard> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: finder,
      builder: (context, _) {
        final status = finder.finished
            ? '搜了 ${finder.siteCount} 个站点'
            : '还在搜… 已搜 ${finder.answered}/${finder.siteCount} 个站点';
        var first = true;
        Widget row(VodCard c) {
          final here = c.site == current.site && c.id == current.id;
          final broken = finder.isBroken(c);
          final sub = [siteName(c.site), c.remarks, if (broken) '试过，不能播放'].where((s) => s.isNotEmpty).join(' · ');
          final autofocus = first;
          first = false;
          if (isTv(context)) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: TvFocusable(
                key: Key('source-${c.site}-${c.id}'),
                autofocus: autofocus,
                onTap: () => onPick(c),
                scale: 1.03,
                child: Container(
                  constraints: const BoxConstraints(minHeight: 50),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(color: here ? scheme.primaryContainer : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Icon(here ? Icons.check_rounded : null, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
                        Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  ]),
                ),
              ),
            );
          }
          return ListTile(
            key: Key('source-${c.site}-${c.id}'),
            leading: Icon(here ? Icons.check_rounded : null),
            title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => onPick(c),
          );
        }

        Widget heading(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
            );
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('换一个来源', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(status, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12)),
              ]),
            ),
            if (finder.exact.isNotEmpty) ...[heading('同名'), for (final c in finder.exact) row(c)],
            if (finder.similar.isNotEmpty) ...[heading('名字相近'), for (final c in finder.similar) row(c)],
            if (finder.all.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(finder.finished ? '没有找到其他来源' : '还在搜…', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ),
          ],
        );
      },
    );
  }
}

/// Blurred poster behind the header, fading into the page background.
class _Backdrop extends StatelessWidget {
  const _Backdrop({required this.pic});

  final String pic;

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surface;
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      height: 420,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (pic.isNotEmpty)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 40, sigmaY: 40, tileMode: TileMode.mirror),
                child: Opacity(opacity: 0.45, child: NetImage(pic)),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [bg.withValues(alpha: 0.15), bg.withValues(alpha: 0.75), bg],
                  stops: const [0, 0.6, 0.95],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
