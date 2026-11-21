import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/engine/engine_client.dart';
import 'package:tvbox_client/engine/models.dart';
import 'package:tvbox_client/engine/source_finder.dart';
import 'package:tvbox_client/engine/vod_models.dart';

import 'fake_engine.dart';

SiteInfo site(String key, {bool changeable = true}) =>
    SiteInfo(key: key, name: key, type: 1, searchable: true, quickSearch: true, filterable: true, runtime: SiteRuntime.cms, changeable: changeable);

Map<String, Object> hit(String site, String id, String name) => {'site': site, 'id': id, 'name': name, 'pic': '', 'remarks': ''};

VodDetail detail(List<List<String>> lines) => VodDetail(
      site: 's',
      id: '1',
      name: 'x',
      lines: [
        for (var i = 0; i < lines.length; i++) PlayLine(name: 'L$i', episodes: [for (final n in lines[i]) Episode(id: n, name: n)]),
      ],
    );

void main() {
  test('titles are compared without markup, width, case, punctuation and copy tags; years and seasons count', () {
    expect(normalizeTitle('<b>星河往事</b>'), '星河往事');
    expect(normalizeTitle('星河往事【4K】'), '星河往事');
    expect(normalizeTitle('星河往事 (国语)'), '星河往事');
    expect(normalizeTitle('星河往事[更新至12集]'), '星河往事');
    expect(normalizeTitle('ＡＢＣ　Ｄ'), 'abcd');
    expect(normalizeTitle('流浪地球·2'), '流浪地球2');
    expect(sameTitle('星河往事', '星河往事 【HD】'), isTrue);
    expect(sameTitle('星河往事 第二季', '星河往事'), isFalse, reason: 'a second season is another title');
    expect(sameTitle('', ''), isFalse);
    expect(similarTitle('星河往事 第二季', '星河往事'), isTrue);
    expect(similarTitle('长夜', '星河往事'), isFalse);
    expect(searchKeyword(' 星河往事【4K】 '), '星河往事');
    expect(needsTitleSearch(const VodCard(site: 'd', id: 'msearch:星河往事', name: '星河往事')), isTrue);
    expect(needsTitleSearch(const VodCard(site: 'd', id: ' ', name: '星河往事')), isTrue);
    expect(needsTitleSearch(const VodCard(site: 'd', id: '12', name: '星河往事')), isFalse);
  });

  test('years more than one apart are different titles', () {
    expect(yearsConflict('2019', '2024'), isTrue);
    expect(yearsConflict('2023', '2024'), isFalse);
    expect(yearsConflict('', '2024'), isFalse);
  });

  test('an episode is found on another site by name or number, a film by its place', () {
    expect(episodeNumber('第12集'), 12);
    expect(episodeNumber('01'), 1);
    expect(episodeNumber('EP3'), 3);
    expect(episodeNumber('正片'), isNull);
    final series = detail([
      ['预告', '第01集', '第02集'],
    ]);
    expect(matchEpisode(series, name: '第2集', index: 1), (0, 2), reason: 'by number, past the trailer');
    expect(matchEpisode(series, name: '第9集', index: 8), isNull, reason: 'that site does not have it');
    final film = detail([
      ['HD'],
    ]);
    expect(matchEpisode(film, name: '正片', index: 0), (0, 0));
    final twoLines = detail([
      ['第1集'],
      ['第1集', '第2集'],
    ]);
    expect(matchEpisode(twoLines, name: '第2集', index: 1), (1, 1), reason: 'on whichever line has it');
  });

  test('the finder asks only the given sites, keeps the same title apart from close names, and ignores title cards', () async {
    final asked = <String>[];
    final client = EngineClient(Uri.parse('http://127.0.0.1:1'), httpClient: fakeEngine(hasConfig: true, searchAsked: asked, searchHits: {
      'a': [hit('a', '1', '星河往事 第二季'), hit('a', 'msearch:星河往事', '星河往事')],
      'b': [hit('b', '2', '星河往事【HD】')],
      'c': [hit('c', '3', '星河往事')],
      'other': [hit('other', '9', '星河往事')],
    }));
    final finder = SourceFinder(client: client, title: '星河往事', sites: [site('a'), site('b'), site('c', changeable: false)]);
    addTearDown(finder.dispose);
    final first = await finder.nextExact();
    expect(first?.site, 'b', reason: 'the first same title from a site that may be switched to');
    expect(await finder.nextExact(skip: {sourceKey('b', '2')}), isNull, reason: 'waits for the rest; c may not be picked');
    expect(asked.single, '星河往事|a,b,c');
    expect([for (final c in finder.exact) c.site], ['b', 'c']);
    expect([for (final c in finder.similar) c.site], ['a']);
    expect(finder.isAuto(finder.exact[1]), isFalse, reason: 'c is not changeable: listed, never picked on its own');
    finder.markBroken('b', '2');
    expect(await finder.nextExact(), isNull, reason: 'b does not play and c may not be switched to');
    expect(finder.finished, isTrue);
    expect(finder.answered, 3);
  });

  test('with no site to ask, the finder is done at once and asks nothing', () async {
    final asked = <String>[];
    final client = EngineClient(Uri.parse('http://127.0.0.1:1'), httpClient: fakeEngine(hasConfig: true, searchAsked: asked));
    final finder = SourceFinder(client: client, title: '星河往事', sites: const []);
    addTearDown(finder.dispose);
    expect(await finder.nextExact(), isNull);
    expect(asked, isEmpty, reason: 'an empty site list would mean every site to the engine');
  });
}
