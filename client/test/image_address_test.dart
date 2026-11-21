import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/ui/image_address.dart';

/// Cover and logo addresses as TVBox configs and spiders write them. The engine addresses are made up; nothing
/// here touches the network.
void main() {
  const remoteEngine = 'http://192.168.1.5:19978';
  const localEngine = 'http://127.0.0.1:19978';

  ImageAddress parse(String raw, {String? engine}) => ImageAddress.parse(raw, engineUrl: engine)!;

  test('a plain URL is fetched as it is, with no headers, kept under the key it always had', () {
    final a = parse('  https://img.example/a.jpg ');
    expect(a.url, 'https://img.example/a.jpg');
    expect(a.headers, isEmpty);
    expect(a.cacheKey, 'https://img.example/a.jpg');
    expect(a.dataUri, isNull);
  });

  test('each header suffix is cut off the address and sent', () {
    expect(parse('https://img.example/a.jpg@Referer=https://site.example/').headers, {'Referer': 'https://site.example/'});
    expect(parse('https://img.example/a.jpg@User-Agent=okhttp/3.12.0').headers, {'User-Agent': 'okhttp/3.12.0'});
    expect(parse('https://img.example/a.jpg@Cookie=sid=1; t=2').headers, {'Cookie': 'sid=1; t=2'});
    final h = parse('https://img.example/a.jpg@Headers={"Origin":"https://site.example","X-Token":"t1"}');
    expect(h.url, 'https://img.example/a.jpg');
    expect(h.headers, {'Origin': 'https://site.example', 'X-Token': 't1'});
  });

  test('suffixes combine in any order; the address ends at the first of them', () {
    final a = parse('https://img.example/a.jpg@User-Agent=UA1@Referer=https://r.example/@Cookie=c=1');
    expect(a.url, 'https://img.example/a.jpg');
    expect(a.headers, {'User-Agent': 'UA1', 'Referer': 'https://r.example/', 'Cookie': 'c=1'});
    expect(a.cacheKey, 'https://img.example/a.jpg@User-Agent=UA1@Referer=https://r.example/@Cookie=c=1');
  });

  test('@Headers keys are normalised and the single suffixes win over them', () {
    final a = parse('https://img.example/a.jpg@Headers={"ua":"json-ua","referer":"https://json.example/","COOKIE":"j=1"}@Referer=https://single.example/');
    expect(a.headers, {'User-Agent': 'json-ua', 'Referer': 'https://single.example/', 'Cookie': 'j=1'});
  });

  test('@Headers may be URL-encoded', () {
    final encoded = Uri.encodeComponent('{"Referer":"https://site.example/","User-Agent":"UA 2"}');
    expect(parse('https://img.example/a.jpg@Headers=$encoded').headers, {'Referer': 'https://site.example/', 'User-Agent': 'UA 2'});
    // Raw JSON with a % that does not decode still reads.
    expect(parse('https://img.example/a.jpg@Headers={"Cookie":"p=100%"}').headers, {'Cookie': 'p=100%'});
  });

  test('bad @Headers are ignored, the rest of the address still works', () {
    for (final bad in ['{not json', '["a","b"]', '', '%E0%A4%A']) {
      final a = parse('https://img.example/a.jpg@Headers=$bad@Referer=https://r.example/');
      expect(a.url, 'https://img.example/a.jpg', reason: bad);
      expect(a.headers, {'Referer': 'https://r.example/'}, reason: bad);
    }
    expect(parse('https://img.example/a.jpg@Headers={"X-A":{"nested":1},"X-B":null,"X-C":7}').headers, {'X-C': '7'});
  });

  test('an @ that is not a header marker is part of the address', () {
    expect(parse('https://img.example/@2x.png').url, 'https://img.example/@2x.png');
    expect(parse('https://user@img.example/a.png').url, 'https://user@img.example/a.png');
    final a = parse('https://img.example/@2x.png@Referer=https://r.example/');
    expect(a.url, 'https://img.example/@2x.png');
    expect(a.headers, {'Referer': 'https://r.example/'});
  });

  test('Douban covers get a Douban Referer and a browser User-Agent, unless the address gives its own', () {
    for (final host in ['img1.doubanio.com', 'doubanio.com', 'img9.douban.com', 'douban.com']) {
      final a = parse('https://$host/view/photo/s_ratio_poster/public/p1.jpg');
      expect(a.headers['Referer'], ImageAddress.doubanReferer, reason: host);
      expect(a.headers['User-Agent'], ImageAddress.browserUserAgent, reason: host);
    }
    final own = parse('https://img1.doubanio.com/p1.jpg@Referer=https://site.example/@User-Agent=UA3');
    expect(own.headers, {'Referer': 'https://site.example/', 'User-Agent': 'UA3'});
    final ownJson = parse('https://img1.doubanio.com/p1.jpg@Headers={"referer":"https://json.example/"}');
    expect(ownJson.headers['Referer'], 'https://json.example/');
    expect(ownJson.headers['User-Agent'], ImageAddress.browserUserAgent);
    // Lookalike hosts are not Douban.
    expect(parse('https://notdoubanio.com/p.jpg').headers, isEmpty);
    expect(parse('https://doubanio.com.example/p.jpg').headers, isEmpty);
  });

  test('data: images are carried as they are, whatever the case of the scheme', () {
    const png = 'data:image/png;base64,iVBORw0KGgo=';
    final a = parse(png);
    expect(a.dataUri, png);
    expect(a.url, isNull);
    expect(a.cacheKey, png);
    expect(parse('DATA:image/gif;base64,R0lGOD').dataUri, 'DATA:image/gif;base64,R0lGOD');
  });

  test('proxy:// goes to the engine\'s /proxy, wherever the engine is', () {
    expect(parse('proxy://do=img&url=https%3A%2F%2Fx', engine: remoteEngine).url, '$remoteEngine/proxy?do=img&url=https%3A%2F%2Fx');
    expect(parse('proxy://do=img', engine: '$localEngine/').url, '$localEngine/proxy?do=img');
    expect(parse('proxy://?do=img', engine: remoteEngine).url, '$remoteEngine/proxy?do=img');
    final withHeaders = parse('proxy://do=img@Referer=https://r.example/', engine: remoteEngine);
    expect(withHeaders.url, '$remoteEngine/proxy?do=img');
    expect(withHeaders.headers, {'Referer': 'https://r.example/'});
    expect(withHeaders.cacheKey, 'proxy://do=img@Referer=https://r.example/');
    expect(ImageAddress.parse('proxy://do=img'), isNull, reason: 'no engine to send it to');
  });

  test('the engine\'s loopback address goes to the engine when the engine is on another device', () {
    // Remote engine, same port: the engine's own address.
    expect(parse('http://127.0.0.1:19978/proxy?do=img&x=%2F', engine: remoteEngine).url, '$remoteEngine/proxy?do=img&x=%2F');
    expect(parse('http://localhost:19978/logo/a.png', engine: remoteEngine).url, '$remoteEngine/logo/a.png');
    expect(parse('http://127.0.0.1:19978', engine: remoteEngine).url, remoteEngine);
    expect(parse('http://127.0.0.1:19978/proxy?do=img', engine: 'https://tv.example:8443').url, 'http://127.0.0.1:19978/proxy?do=img', reason: 'another port');
    // Remote engine, another port: something else on that machine; left as it is.
    expect(parse('http://127.0.0.1:8080/a.png', engine: remoteEngine).url, 'http://127.0.0.1:8080/a.png');
    // Engine on this machine: the address works as it is.
    expect(parse('http://127.0.0.1:19978/proxy?do=img', engine: localEngine).url, 'http://127.0.0.1:19978/proxy?do=img');
    expect(parse('http://localhost:19978/proxy?do=img', engine: localEngine).url, 'http://localhost:19978/proxy?do=img');
    // No engine known: as it is.
    expect(parse('http://127.0.0.1:19978/proxy?do=img').url, 'http://127.0.0.1:19978/proxy?do=img');
    // The key stays the address as written.
    expect(parse('http://127.0.0.1:19978/proxy?do=img', engine: remoteEngine).cacheKey, 'http://127.0.0.1:19978/proxy?do=img');
  });

  test('protocol-relative addresses are fetched over https', () {
    final a = parse('//img.example/a.jpg@Referer=https://r.example/');
    expect(a.url, 'https://img.example/a.jpg');
    expect(a.headers, {'Referer': 'https://r.example/'});
    expect(parse('//img3.doubanio.com/p.jpg').headers['Referer'], ImageAddress.doubanReferer);
  });

  test('blank addresses and schemes this client cannot load give nothing', () {
    for (final raw in ['', '   ', 'assets://img/a.png', 'file:///sdcard/a.png', 'clan://a/b.png', 'ftp://h/a.png', '/upload/a.png', 'img.example/a.png', '@Referer=https://r.example/', 'http://']) {
      expect(ImageAddress.parse(raw, engineUrl: remoteEngine), isNull, reason: raw);
    }
  });

  test('the cache key is the address as written: stable, and different when the headers differ', () {
    const raw = 'https://img.example/a.jpg@Referer=https://r.example/';
    expect(parse(raw).cacheKey, parse(' $raw ').cacheKey);
    expect(parse(raw, engine: remoteEngine).cacheKey, parse(raw, engine: localEngine).cacheKey);
    expect(parse(raw).cacheKey, isNot(parse('https://img.example/a.jpg@Referer=https://other.example/').cacheKey));
    expect(parse(raw).cacheKey, isNot(parse('https://img.example/a.jpg').cacheKey));
  });
}
