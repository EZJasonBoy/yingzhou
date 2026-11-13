/// Live TV (engine protocol v1, `/live`).
class LiveSourceInfo {
  const LiveSourceInfo({required this.index, required this.name, this.hasEpg = false, this.supported = true});

  final int index;
  final String name;
  final bool hasEpg;
  final bool supported;

  factory LiveSourceInfo.fromJson(Map<String, dynamic> j) => LiveSourceInfo(
    index: (j['index'] as num).toInt(),
    name: j['name'] as String? ?? '',
    hasEpg: j['hasEpg'] as bool? ?? false,
    supported: j['supported'] as bool? ?? true,
  );
}

class LiveUrl {
  const LiveUrl({required this.url, this.label = '', this.headers = const {}});

  final String url;
  final String label;
  final Map<String, String> headers;

  factory LiveUrl.fromJson(Map<String, dynamic> j) => LiveUrl(
    url: j['url'] as String? ?? '',
    label: j['label'] as String? ?? '',
    headers: (j['headers'] as Map<String, dynamic>? ?? const {}).map((k, v) => MapEntry(k, '$v')),
  );
}

class LiveChannel {
  const LiveChannel({required this.name, this.logo = '', this.urls = const []});

  final String name;
  final String logo;
  final List<LiveUrl> urls;

  factory LiveChannel.fromJson(Map<String, dynamic> j) => LiveChannel(
    name: j['name'] as String? ?? '',
    logo: j['logo'] as String? ?? '',
    urls: [for (final u in j['urls'] as List? ?? const []) LiveUrl.fromJson(u as Map<String, dynamic>)],
  );
}

class LiveGroup {
  const LiveGroup({required this.name, this.channels = const []});

  final String name;
  final List<LiveChannel> channels;

  factory LiveGroup.fromJson(Map<String, dynamic> j) => LiveGroup(
    name: j['name'] as String? ?? '',
    channels: [for (final c in j['channels'] as List? ?? const []) LiveChannel.fromJson(c as Map<String, dynamic>)],
  );
}

class LiveList {
  const LiveList({required this.source, required this.name, this.groups = const []});

  final int source;
  final String name;
  final List<LiveGroup> groups;

  factory LiveList.fromJson(Map<String, dynamic> j) => LiveList(
    source: (j['source'] as num).toInt(),
    name: j['name'] as String? ?? '',
    groups: [for (final g in j['groups'] as List? ?? const []) LiveGroup.fromJson(g as Map<String, dynamic>)],
  );
}

class EpgProgram {
  const EpgProgram({required this.start, required this.end, required this.title});

  final DateTime start;
  final DateTime end;
  final String title;

  bool isOnAt(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  double progressAt(DateTime t) {
    final total = end.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0, 1).toDouble();
  }

  factory EpgProgram.fromJson(Map<String, dynamic> j) => EpgProgram(
    start: DateTime.fromMillisecondsSinceEpoch((j['start'] as num).toInt()),
    end: DateTime.fromMillisecondsSinceEpoch((j['end'] as num).toInt()),
    title: j['title'] as String? ?? '',
  );
}

class EpgDay {
  const EpgDay({required this.channel, required this.date, this.programs = const []});

  final String channel;
  final String date;
  final List<EpgProgram> programs;

  EpgProgram? current(DateTime now) {
    for (final p in programs) {
      if (p.isOnAt(now)) return p;
    }
    return null;
  }

  factory EpgDay.fromJson(Map<String, dynamic> j) => EpgDay(
    channel: j['channel'] as String? ?? '',
    date: j['date'] as String? ?? '',
    programs: [for (final p in j['programs'] as List? ?? const []) EpgProgram.fromJson(p as Map<String, dynamic>)],
  );
}
