import 'vod_models.dart';

/// What a line is called on screen. Sites name their lines as they like (`超级无敌4k`, `ikm3u8`); [numbered] (simple
/// mode) calls them 线路 1, 线路 2 … in the site's order instead. A line without a name is numbered either way.
String lineTitle(List<PlayLine> lines, int index, {bool numbered = false}) {
  final name = lines[index].name.trim();
  return numbered || name.isEmpty ? '线路 ${index + 1}' : name;
}

/// What one episode is called on screen.
class EpisodeLabel {
  const EpisodeLabel({required this.number, required this.text, required this.full, this.also});

  /// Its place in the line, from 1.
  final int number;

  /// The name to show: the site's, without what every episode of the line shares (the title of the show, the
  /// resolution, the file extension).
  final String text;

  /// The name as the site gave it.
  final String full;

  /// What another line of the same title calls the episode at this place, when this line only numbers its
  /// episodes; null otherwise.
  final String? also;
}

/// How the episodes of a line are named and laid out. Sites follow no common rule: `1`, `第01集`, `20261120期`,
/// `第15期：两位嘉宾的名字`, `片名.2026.EP15.4K.WEB-DL.mp4`. Names that all fit a small button are shown as the site
/// gave them, in a grid; long ones lose what they all share and, when still long, are listed in rows where a title
/// has room for two lines.
class EpisodeNaming {
  const EpisodeNaming._({required this.labels, required this.compact, required this.onlyNumbers, this.borrowedFrom});

  final List<EpisodeLabel> labels;

  /// Every name fits a small button: a grid. Otherwise rows with the number in front.
  final bool compact;

  /// The line itself only numbers its episodes (`1`, `02`, `第3集`).
  final bool onlyNumbers;

  /// The line whose names are shown next to this line's numbers ([EpisodeLabel.also]); null when none are.
  final String? borrowedFrom;

  /// The widest name a grid button holds, in columns: a CJK character takes two, a Latin letter or digit one.
  static const compactColumns = 12;

  static const empty = EpisodeNaming._(labels: [], compact: true, onlyNumbers: false);

  /// The naming of [lines]`[line]`. [title] is the show's name, dropped from the front of long episode names.
  factory EpisodeNaming.of(List<PlayLine> lines, int line, {String title = ''}) {
    if (line < 0 || line >= lines.length) return empty;
    final episodes = lines[line].episodes;
    if (episodes.isEmpty) return empty;
    final full = [for (final e in episodes) e.name];
    var texts = [for (final n in full) clean(n)];
    if (_widest(texts) > compactColumns) {
      texts = [for (final t in texts) _withoutTitle(t, title)];
      texts = withoutSharedEnds(texts);
    }
    // A name that came out empty (the site gave none, or it was nothing but the show's title) is its number.
    texts = [for (var i = 0; i < texts.length; i++) texts[i].isEmpty ? '${i + 1}' : texts[i]];
    final numbers = texts.every(isOrdinal);
    List<String>? also;
    String? from;
    if (numbers && episodes.length > 1) {
      for (var other = 0; other < lines.length; other++) {
        if (other == line || lines[other].episodes.length != episodes.length) continue;
        var names = [for (final e in lines[other].episodes) clean(e.name)];
        if (names.where(isOrdinal).length * 2 > names.length) continue;
        names = withoutSharedEnds([for (final n in names) _withoutTitle(n, title)]);
        also = names;
        from = lines[other].name;
        break;
      }
    }
    return EpisodeNaming._(
      labels: [
        for (var i = 0; i < texts.length; i++)
          EpisodeLabel(number: i + 1, text: texts[i], full: full[i], also: also == null || also[i].isEmpty || also[i] == texts[i] ? null : also[i]),
      ],
      compact: also == null && _widest(texts) <= compactColumns,
      onlyNumbers: numbers,
      borrowedFrom: also == null ? null : from,
    );
  }

  /// [name] short enough for a button or a sentence: as it is up to [columns] wide, else cut with an ellipsis.
  static String brief(String name, {int columns = 20}) {
    if (columnsOf(name) <= columns) return name;
    final out = StringBuffer();
    var used = 0;
    for (final r in name.runes) {
      final w = _wide(r) ? 2 : 1;
      if (used + w > columns - 1) break;
      out.writeCharCode(r);
      used += w;
    }
    return '${out.toString().trimRight()}…';
  }

  /// How wide [text] is in a monospace sense: CJK and full-width characters take two columns.
  static int columnsOf(String text) {
    var n = 0;
    for (final r in text.runes) {
      n += _wide(r) ? 2 : 1;
    }
    return n;
  }

  static bool _wide(int rune) => rune >= 0x2E80;

  static int _widest(List<String> texts) => texts.fold(0, (m, t) {
        final w = columnsOf(t);
        return w > m ? w : m;
      });

  static final _extension = RegExp(r'\.(mp4|mkv|m3u8|ts|flv|avi|mov|rmvb|rm|wmv|webm|mpg|mpeg|m4v|3gp)$', caseSensitive: false);
  static final _spaces = RegExp(r'\s+');
  static final _edges = RegExp(r'^[\s._\-:：·|/]+|[\s._\-:：·|/]+$');
  static final _ordinal = RegExp(r'^(第\s*)?\d{1,4}(\s*[集话話])?$');

  /// A name without its video file extension and stray whitespace.
  static String clean(String name) => name.trim().replaceFirst(_extension, '').replaceAll(_spaces, ' ').trim();

  /// `1`, `02`, `第3集`: a place in the list, not a title.
  static bool isOrdinal(String text) => _ordinal.hasMatch(text);

  /// [text] without the show's [title] in front of it, when something is left.
  static String _withoutTitle(String text, String title) {
    final t = title.trim();
    if (t.length < 2 || !text.startsWith(t)) return text;
    final rest = text.substring(t.length).replaceAll(_edges, '');
    return rest.isEmpty ? text : rest;
  }

  /// [texts] without the beginning and the end that all of them share (`片名.2026.` … `.4K.WEB-DL`). A shared part
  /// is only dropped when it is at least four columns wide, never in the middle of a number or a word, and never
  /// when that would leave a name empty.
  static List<String> withoutSharedEnds(List<String> texts) {
    if (texts.length < 2) return texts;
    final runes = [for (final t in texts) t.runes.toList()];
    final shortest = runes.fold<int>(runes.first.length, (m, r) => r.length < m ? r.length : m);
    var p = 0;
    while (p < shortest && runes.every((r) => r[p] == runes.first[p])) {
      p++;
    }
    // Not inside a number or a word: `EP1` | `5` and `Sea` | `son` stay whole.
    while (p > 0 && _alnum(runes.first[p - 1]) && runes.any((r) => p < r.length && _alnum(r[p]))) {
      p--;
    }
    // `第` belongs to the number after it.
    if (p > 0 && runes.first[p - 1] == 0x7B2C && runes.any((r) => p < r.length && r[p] >= 0x30 && r[p] <= 0x39)) p--;
    if (columnsOf(String.fromCharCodes(runes.first.take(p))) < 4) p = 0;
    var s = 0;
    while (s < shortest - p && runes.every((r) => r[r.length - 1 - s] == runes.first[runes.first.length - 1 - s])) {
      s++;
    }
    while (s > 0 && _alnum(runes.first[runes.first.length - s]) && runes.any((r) => r.length - s - 1 >= 0 && _alnum(r[r.length - s - 1]))) {
      s--;
    }
    if (columnsOf(String.fromCharCodes(runes.first.skip(runes.first.length - s))) < 4) s = 0;
    if (p == 0 && s == 0) return texts;
    final out = [for (final r in runes) String.fromCharCodes(r.sublist(p, r.length - s)).replaceAll(_edges, '')];
    return out.any((t) => t.isEmpty) ? texts : out;
  }

  static bool _alnum(int r) => (r >= 0x30 && r <= 0x39) || (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
}
