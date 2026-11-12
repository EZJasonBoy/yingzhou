/// Where the user is in a video (engine protocol v1, `/history`).
class HistoryEntry {
  const HistoryEntry({
    required this.site,
    required this.vodId,
    required this.name,
    this.pic = '',
    this.line = '',
    this.episodeId = '',
    this.episodeName = '',
    this.episodeIndex = 0,
    this.positionMs = 0,
    this.durationMs = 0,
    this.updatedAt = 0,
  });

  final String site;
  final String vodId;
  final String name;
  final String pic;
  final String line;
  final String episodeId;
  final String episodeName;
  final int episodeIndex;
  final int positionMs;
  final int durationMs;
  final int updatedAt;

  double get progress => durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0, 1).toDouble();

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        site: j['site'] as String,
        vodId: j['vodId'] as String,
        name: j['name'] as String,
        pic: j['pic'] as String? ?? '',
        line: j['line'] as String? ?? '',
        episodeId: j['episodeId'] as String? ?? '',
        episodeName: j['episodeName'] as String? ?? '',
        episodeIndex: j['episodeIndex'] as int? ?? 0,
        positionMs: j['positionMs'] as int? ?? 0,
        durationMs: j['durationMs'] as int? ?? 0,
        updatedAt: j['updatedAt'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'site': site,
        'vodId': vodId,
        'name': name,
        'pic': pic,
        'line': line,
        'episodeId': episodeId,
        'episodeName': episodeName,
        'episodeIndex': episodeIndex,
        'positionMs': positionMs,
        'durationMs': durationMs,
      };
}

class FavoriteEntry {
  const FavoriteEntry({required this.site, required this.vodId, required this.name, this.pic = '', this.remarks = '', this.addedAt = 0});

  final String site;
  final String vodId;
  final String name;
  final String pic;
  final String remarks;
  final int addedAt;

  factory FavoriteEntry.fromJson(Map<String, dynamic> j) => FavoriteEntry(
        site: j['site'] as String,
        vodId: j['vodId'] as String,
        name: j['name'] as String,
        pic: j['pic'] as String? ?? '',
        remarks: j['remarks'] as String? ?? '',
        addedAt: j['addedAt'] as int? ?? 0,
      );

  Map<String, dynamic> toJson() => {'site': site, 'vodId': vodId, 'name': name, 'pic': pic, 'remarks': remarks};
}
