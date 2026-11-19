// Normalised video data from engine protocol v1 (docs/protocol.md).

class VodCard {
  const VodCard({required this.site, required this.id, required this.name, this.pic = '', this.remarks = ''});

  final String site;
  final String id;
  final String name;
  final String pic;
  final String remarks;

  factory VodCard.fromJson(Map<String, dynamic> j) => VodCard(
        site: j['site'] as String,
        id: j['id'] as String,
        name: j['name'] as String,
        pic: j['pic'] as String? ?? '',
        remarks: j['remarks'] as String? ?? '',
      );
}

class VodClass {
  const VodClass({required this.id, required this.name});

  final String id;
  final String name;

  factory VodClass.fromJson(Map<String, dynamic> j) => VodClass(id: j['id'] as String, name: j['name'] as String);
}

class FilterValue {
  const FilterValue({required this.name, required this.value});

  final String name;
  final String value;

  factory FilterValue.fromJson(Map<String, dynamic> j) =>
      FilterValue(name: j['name'] as String, value: j['value'] as String);
}

class VodFilter {
  const VodFilter({required this.key, required this.name, required this.values});

  final String key;
  final String name;
  final List<FilterValue> values;

  factory VodFilter.fromJson(Map<String, dynamic> j) => VodFilter(
        key: j['key'] as String,
        name: j['name'] as String,
        values: [for (final v in j['values'] as List<dynamic>) FilterValue.fromJson(v as Map<String, dynamic>)],
      );
}

class HomeResult {
  const HomeResult({required this.classes, required this.filters, required this.list});

  final List<VodClass> classes;
  final Map<String, List<VodFilter>> filters;
  final List<VodCard> list;

  factory HomeResult.fromJson(Map<String, dynamic> j) => HomeResult(
        classes: [for (final c in j['classes'] as List<dynamic>) VodClass.fromJson(c as Map<String, dynamic>)],
        filters: (j['filters'] as Map<String, dynamic>? ?? const {}).map(
          (k, v) => MapEntry(k, [for (final f in v as List<dynamic>) VodFilter.fromJson(f as Map<String, dynamic>)]),
        ),
        list: [for (final c in j['list'] as List<dynamic>) VodCard.fromJson(c as Map<String, dynamic>)],
      );
}

class VodPage {
  const VodPage({required this.page, required this.pageCount, required this.total, required this.list});

  final int page;

  /// 0 when the site does not say.
  final int pageCount;
  final int total;
  final List<VodCard> list;

  bool get hasMore => pageCount == 0 ? list.isNotEmpty : page < pageCount;

  factory VodPage.fromJson(Map<String, dynamic> j) => VodPage(
        page: j['page'] as int,
        pageCount: j['pageCount'] as int,
        total: j['total'] as int,
        list: [for (final c in j['list'] as List<dynamic>) VodCard.fromJson(c as Map<String, dynamic>)],
      );
}

class Episode {
  const Episode({required this.id, required this.name});

  final String id;
  final String name;

  factory Episode.fromJson(Map<String, dynamic> j) => Episode(id: j['id'] as String, name: j['name'] as String);
}

class PlayLine {
  const PlayLine({required this.name, required this.episodes});

  final String name;
  final List<Episode> episodes;

  /// Where this line keeps the episode that another line of the same title has at [index] under [name]: the same
  /// place in the list, unless the names show this line is laid out differently (a trailer first, newest first,
  /// episodes missing). Null when this line does not have the episode.
  int? findEpisode({required int index, required String name}) {
    final wanted = name.trim();
    final inRange = index >= 0 && index < episodes.length;
    if (inRange && episodes[index].name.trim() == wanted) return index;
    final byName = episodes.indexWhere((e) => e.name.trim() == wanted);
    if (byName >= 0) return byName;
    return inRange ? index : null;
  }

  factory PlayLine.fromJson(Map<String, dynamic> j) => PlayLine(
        name: j['name'] as String,
        episodes: [for (final e in j['episodes'] as List<dynamic>) Episode.fromJson(e as Map<String, dynamic>)],
      );
}

class VodDetail {
  const VodDetail({
    required this.site,
    required this.id,
    required this.name,
    this.pic = '',
    this.year = '',
    this.area = '',
    this.type = '',
    this.actor = '',
    this.director = '',
    this.content = '',
    this.remarks = '',
    this.lines = const [],
  });

  final String site;
  final String id;
  final String name;
  final String pic;
  final String year;
  final String area;
  final String type;
  final String actor;
  final String director;
  final String content;
  final String remarks;
  final List<PlayLine> lines;

  factory VodDetail.fromJson(Map<String, dynamic> j) => VodDetail(
        site: j['site'] as String,
        id: j['id'] as String,
        name: j['name'] as String,
        pic: j['pic'] as String? ?? '',
        year: j['year'] as String? ?? '',
        area: j['area'] as String? ?? '',
        type: j['type'] as String? ?? '',
        actor: j['actor'] as String? ?? '',
        director: j['director'] as String? ?? '',
        content: j['content'] as String? ?? '',
        remarks: j['remarks'] as String? ?? '',
        lines: [for (final l in j['lines'] as List<dynamic>? ?? const []) PlayLine.fromJson(l as Map<String, dynamic>)],
      );
}

class PlayInfo {
  const PlayInfo({
    required this.kind,
    this.url = '',
    this.headers = const {},
    this.sniffPageUrl,
    this.parsedBy = '',
    this.cache = '',
    this.subtitles = const [],
    this.danmaku = '',
  });

  /// `direct` or `sniff`.
  final String kind;
  final String url;
  final Map<String, String> headers;
  final String? sniffPageUrl;
  final String parsedBy;

  /// Not empty when the engine's stream cache serves [url]; the key to ask the engine which parts it holds.
  final String cache;

  /// Subtitles the site named, each an engine address the player can open (UTF-8 SRT / ASS / WebVTT).
  final List<ExternalSubtitle> subtitles;

  /// Where the site's danmaku come from ("" when it named none); the danmaku themselves come from `/danmaku`.
  final String danmaku;

  bool get isDirect => kind == 'direct';

  factory PlayInfo.fromJson(Map<String, dynamic> j) => PlayInfo(
        kind: j['kind'] as String,
        url: j['url'] as String? ?? '',
        headers: (j['headers'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, v.toString())),
        sniffPageUrl: (j['sniff'] as Map<String, dynamic>?)?['pageUrl'] as String?,
        parsedBy: j['parsedBy'] as String? ?? '',
        cache: j['cache'] as String? ?? '',
        subtitles: [for (final s in j['subtitles'] as List<dynamic>? ?? const []) ExternalSubtitle.fromJson(s as Map<String, dynamic>)],
        danmaku: j['danmaku'] as String? ?? '',
      );
}

/// A subtitle file that is not part of the stream: one the site named (served by the engine) or one from disk.
class ExternalSubtitle {
  const ExternalSubtitle({required this.name, this.lang = '', this.format = '', required this.url});

  final String name;
  final String lang;

  /// srt | ass | ssa | vtt
  final String format;
  final String url;

  factory ExternalSubtitle.fromJson(Map<String, dynamic> j) => ExternalSubtitle(
        name: j['name'] as String? ?? '',
        lang: j['lang'] as String? ?? '',
        format: j['format'] as String? ?? '',
        url: j['url'] as String? ?? '',
      );
}

/// One event of the aggregated search stream.
sealed class SearchEvent {
  const SearchEvent();
}

class SearchSiteStatus extends SearchEvent {
  const SearchSiteStatus({required this.site, required this.status, this.count = 0, this.ms = 0, this.message});

  final String site;

  /// started | done | error
  final String status;
  final int count;
  final int ms;
  final String? message;

  factory SearchSiteStatus.fromJson(Map<String, dynamic> j) => SearchSiteStatus(
        site: j['site'] as String,
        status: j['status'] as String,
        count: j['count'] as int? ?? 0,
        ms: j['ms'] as int? ?? 0,
        message: j['message'] as String?,
      );
}

class SearchResults extends SearchEvent {
  const SearchResults({required this.site, required this.items});

  final String site;
  final List<VodCard> items;

  factory SearchResults.fromJson(Map<String, dynamic> j) => SearchResults(
        site: j['site'] as String,
        items: [for (final c in j['items'] as List<dynamic>) VodCard.fromJson(c as Map<String, dynamic>)],
      );
}

class SearchEnd extends SearchEvent {
  const SearchEnd({required this.sites, required this.ms});

  final int sites;
  final int ms;

  factory SearchEnd.fromJson(Map<String, dynamic> j) => SearchEnd(sites: j['sites'] as int, ms: j['ms'] as int);
}
