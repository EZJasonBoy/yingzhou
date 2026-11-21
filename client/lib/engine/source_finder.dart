import 'dart:async';

import 'package:flutter/foundation.dart';

import 'engine_client.dart';
import 'models.dart';
import 'vod_models.dart';

/// A card that stands for a title rather than for something its site can play: a recommendation site's
/// `msearch:` card, or one with no id. TVBox and FongMi never open its detail; they look for the title on the
/// other sites, and so does 映舟.
bool needsTitleSearch(VodCard card) => card.id.trim().isEmpty || card.id.startsWith('msearch:');

/// Bracketed tags that say how a copy is, not what it is: 「【4K】」「(国语)」「[更新至12集]」.
final _tag = RegExp(
  r'[\[【(（]\s*(?:hd|高清|超清|标清|蓝光|4k|1080p|720p|国语|粤语|国粤|中字|中文字幕|双语|tc|抢先版|完结|全集|已完结|更新[^\]】)）]*)\s*[\]】)）]',
  caseSensitive: false,
);
final _html = RegExp(r'<[^>]*>');
final _punct = RegExp(r'''[\s·•・\-—–_:：,，.。!！?？'"“”‘’《》〈〉「」『』【】\[\]()（）/、~～]''');

String _halfWidth(String s) {
  final out = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0xFF01 && r <= 0xFF5E) {
      out.writeCharCode(r - 0xFEE0);
    } else if (r == 0x3000) {
      out.write(' ');
    } else {
      out.writeCharCode(r);
    }
  }
  return out.toString();
}

/// A title as compared between sites: no markup, half-width, lower case, without the tags above, spaces and
/// punctuation. Years and season words stay, so a remake or a second season is not taken for the first.
String normalizeTitle(String s) => _halfWidth(s.replaceAll(_html, '')).replaceAll(_tag, '').toLowerCase().replaceAll(_punct, '');

/// What to search for: the title without markup and tags.
String searchKeyword(String title) => _halfWidth(title.replaceAll(_html, '')).replaceAll(_tag, '').trim();

/// The same title, as an automatic switch requires (FongMi: equal names).
bool sameTitle(String a, String b) {
  final x = normalizeTitle(a);
  return x.isNotEmpty && x == normalizeTitle(b);
}

/// A name close enough to list as another choice (FongMi's manual list: the name contains the keyword).
bool similarTitle(String candidate, String title) {
  final c = normalizeTitle(candidate);
  final t = normalizeTitle(title);
  if (c.length < 2 || t.length < 2) return false;
  return c.contains(t) || t.contains(c);
}

/// Two details whose years are both known and more than a year apart are different titles with the same name.
bool yearsConflict(String a, String b) {
  int? year(String s) => int.tryParse(RegExp(r'(19|20)\d{2}').firstMatch(s)?.group(0) ?? '');
  final x = year(a);
  final y = year(b);
  return x != null && y != null && (x - y).abs() > 1;
}

String sourceKey(String site, String id) => '$site\n$id';

final _episodeNumber = [
  RegExp(r'^(?:第\s*)?0*(\d{1,4})\s*(?:集|话|話|期|回)?$'),
  RegExp(r'^(?:ep?|episode)\s*\.?\s*0*(\d{1,4})$', caseSensitive: false),
];

/// The number an episode name stands for (「第1集」「01」「EP1」), or null when it has none (「正片」「HD」).
int? episodeNumber(String name) {
  final n = name.trim();
  for (final r in _episodeNumber) {
    final m = r.firstMatch(n);
    if (m != null) return int.tryParse(m.group(1)!);
  }
  return null;
}

/// Where another site keeps the episode this one has at [index] under [name]: (line, episode) found by name or by
/// episode number on any line; for a name with no number (a film's 「正片」) the same place on the first line that
/// has it. Null when that site does not have the episode.
(int, int)? matchEpisode(VodDetail detail, {required String name, required int index}) {
  final wanted = name.trim();
  final number = episodeNumber(wanted);
  for (var l = 0; l < detail.lines.length; l++) {
    final episodes = detail.lines[l].episodes;
    for (var e = 0; e < episodes.length; e++) {
      final n = episodes[e].name.trim();
      if (n == wanted || (number != null && episodeNumber(n) == number)) return (l, e);
    }
  }
  if (number == null) {
    for (var l = 0; l < detail.lines.length; l++) {
      if (index >= 0 && index < detail.lines[l].episodes.length) return (l, index);
    }
  }
  return null;
}

/// Looks for one title on other sites through the engine's aggregated search, and keeps what it finds: the same
/// title ([exact]) and close names ([similar]), in the order the sites answer. Only sites marked `changeable` may be
/// switched to on their own ([nextExact]); the others are still listed for the user to pick.
///
/// One search serves a detail page and the player opened from it; the page owns it and disposes of it, which
/// cancels the request.
class SourceFinder extends ChangeNotifier {
  SourceFinder({required this.client, required this.title, required List<SiteInfo> sites})
      : _sites = sites,
        _changeable = {for (final s in sites) if (s.changeable) s.key};

  final EngineClient client;
  final List<SiteInfo> _sites;
  final Set<String> _changeable;

  /// The title looked for.
  final String title;

  final exact = <VodCard>[];
  final similar = <VodCard>[];
  final _seen = <String>{};
  final _broken = <String>{};
  final _waiters = <Completer<void>>[];
  StreamSubscription<SearchEvent>? _search;
  bool _disposed = false;

  bool started = false;
  bool finished = false;
  int answered = 0;
  String? error;

  /// How many sites are asked.
  int get siteCount => _sites.length;
  bool get searching => started && !finished;

  /// Every card found, the same title first.
  List<VodCard> get all => [...exact, ...similar];

  bool isAuto(VodCard card) => _changeable.contains(card.site);
  bool isBroken(VodCard card) => _broken.contains(sourceKey(card.site, card.id));

  /// Starts the search; a second call does nothing. With no site to ask, it is finished at once (an empty site list
  /// would mean every site to the engine).
  void start() {
    if (started || _disposed) return;
    started = true;
    if (_sites.isEmpty || normalizeTitle(title).isEmpty) {
      _finish();
      return;
    }
    _search = client.searchAll(searchKeyword(title), sites: {for (final s in _sites) s.key}).listen(
      _onEvent,
      onError: (Object e) {
        error = e is EngineException ? e.message : '$e';
        _finish();
      },
      onDone: _finish,
    );
    _changed();
  }

  /// Searches again (after a failure), keeping what was found not to play.
  void restart() {
    unawaited(_search?.cancel());
    _search = null;
    exact.clear();
    similar.clear();
    _seen.clear();
    started = false;
    finished = false;
    answered = 0;
    error = null;
    start();
  }

  /// [site]'s copy does not play (no lines, or every line failed): never picked on its own again.
  void markBroken(String site, String id) {
    _broken.add(sourceKey(site, id));
    _changed();
  }

  /// The next card of the same title on a `changeable` site that is not known to be broken and not in [skip]
  /// (keys from [sourceKey]); waits while the search is still going. Null when there is none.
  Future<VodCard?> nextExact({Set<String> skip = const {}}) async {
    start();
    while (true) {
      for (final c in exact) {
        if (isAuto(c) && !isBroken(c) && !skip.contains(sourceKey(c.site, c.id))) return c;
      }
      if (finished || _disposed) return null;
      final wait = Completer<void>();
      _waiters.add(wait);
      await wait.future;
    }
  }

  void _onEvent(SearchEvent event) {
    switch (event) {
      case SearchSiteStatus(:final status) when status != 'started':
        answered++;
      case SearchResults(:final items):
        for (final card in items) {
          _add(card);
        }
      case SearchEnd():
        _finish();
        return;
      default:
        return;
    }
    _changed();
  }

  void _add(VodCard card) {
    if (needsTitleSearch(card) || card.isFolder) return;
    if (!_seen.add(sourceKey(card.site, card.id))) return;
    if (sameTitle(card.name, title)) {
      exact.add(card);
    } else if (similarTitle(card.name, title)) {
      similar.add(card);
    }
  }

  void _finish() {
    if (finished) return;
    finished = true;
    _changed();
  }

  void _changed() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_search?.cancel());
    _search = null;
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
    super.dispose();
  }
}
