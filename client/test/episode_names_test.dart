import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/engine/episode_names.dart';
import 'package:tvbox_client/engine/vod_models.dart';

PlayLine line(String name, List<String> episodes) =>
    PlayLine(name: name, episodes: [for (var i = 0; i < episodes.length; i++) Episode(id: 'e$i', name: episodes[i])]);

List<String> texts(EpisodeNaming n) => [for (final l in n.labels) l.text];

void main() {
  test('short names stay as the site gave them, in a grid', () {
    for (final names in [
      ['第1集', '第2集', '第3集'],
      ['01', '02', '03'],
      ['20261113期', '20261120期'],
      ['HD中字', '国语版'],
      ['正片'],
    ]) {
      final n = EpisodeNaming.of([line('a', names)], 0, title: '片名');
      expect(n.compact, isTrue, reason: '$names');
      expect(texts(n), names);
    }
  });

  test('file names lose the title, the tags they share and the extension, and fit the grid again', () {
    final n = EpisodeNaming.of([
      line('a', ['后会友期.2026.EP01.4K.WEB-DL.H265.mp4', '后会友期.2026.EP02.4K.WEB-DL.H265.mp4', '后会友期.2026.EP15.4K.WEB-DL.H265.mp4']),
    ], 0, title: '后会友期');
    expect(texts(n), ['EP01', 'EP02', 'EP15']);
    expect(n.compact, isTrue);
    expect(n.labels.first.full, '后会友期.2026.EP01.4K.WEB-DL.H265.mp4', reason: 'the name as given is kept for the tooltip');
  });

  test('a number is never cut in two: 第01集 … 第09集 keep their zeros', () {
    final out = EpisodeNaming.withoutSharedEnds(['某某某某 第01集 很长很长的标题甲', '某某某某 第02集 很长很长的标题乙']);
    expect(out, ['第01集 很长很长的标题甲', '第02集 很长很长的标题乙']);
    expect(EpisodeNaming.withoutSharedEnds(['S01E01', 'S01E02']), ['S01E01', 'S01E02'], reason: 'too little is shared to drop');
  });

  test('long titles are listed in rows, numbered by their place', () {
    final n = EpisodeNaming.of([
      line('a', ['第1期：先导片 六位朋友再次出发', '第2期：雪山脚下的第一夜', '20261120加更版：没播出的那些事']),
    ], 0, title: '后会友期');
    expect(n.compact, isFalse);
    expect([for (final l in n.labels) l.number], [1, 2, 3]);
    expect(n.labels[1].text, '第2期：雪山脚下的第一夜');
  });

  test('a line that only numbers its episodes borrows the titles of a line of the same length', () {
    final lines = [
      line('超清', ['1', '2', '3']),
      line('短的', ['1', '2']),
      line('蓝光', ['20261106期', '20261113抢鲜版', '20261120加更版']),
    ];
    final n = EpisodeNaming.of(lines, 0, title: '后会友期');
    expect(n.onlyNumbers, isTrue);
    expect(n.borrowedFrom, '蓝光');
    expect([for (final l in n.labels) l.also], ['20261106期', '20261113抢鲜版', '20261120加更版']);
    expect(n.compact, isFalse, reason: 'a number with a title next to it needs a row');

    final alone = EpisodeNaming.of([lines[0], lines[1]], 0);
    expect(alone.onlyNumbers, isTrue);
    expect(alone.borrowedFrom, isNull, reason: 'no line of the same length has titles');
    expect(alone.compact, isTrue);
  });

  test('brief cuts by width: a CJK character counts for two', () {
    expect(EpisodeNaming.brief('第2集'), '第2集');
    expect(EpisodeNaming.brief('第15期：两位嘉宾一起去了很远很远的地方', columns: 12), '第15期：两…');
    expect(EpisodeNaming.columnsOf('第15期'), 6);
  });

  test('an empty name is its number', () {
    expect(texts(EpisodeNaming.of([line('a', ['', '  '])], 0)), ['1', '2']);
  });
}
