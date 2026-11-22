import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox_client/engine/episode_names.dart';
import 'package:tvbox_client/engine/vod_models.dart';
import 'package:tvbox_client/pages/player_info.dart';

/// The plain words of 播放信息 (pages/player_info.dart) and the names lines go by.
void main() {
  test('how playback is going is judged by what is buffered ahead', () {
    expect(PlayHealth.of(ahead: 28, buffering: false), PlayHealth.smooth);
    expect(PlayHealth.of(ahead: 10, buffering: false), PlayHealth.smooth);
    expect(PlayHealth.of(ahead: 6, buffering: false), PlayHealth.enough);
    expect(PlayHealth.of(ahead: 1, buffering: false), PlayHealth.thin);
    expect(PlayHealth.of(ahead: 0, buffering: false), PlayHealth.thin);
    expect(PlayHealth.of(ahead: 28, buffering: true), PlayHealth.waiting, reason: 'the player stopped to fetch more, whatever the number says');
  });

  test('the picture is named by its width, so a cropped film keeps its class', () {
    expect(PlayInfoPanel.quality(3840, 2160), '4K');
    expect(PlayInfoPanel.quality(3840, 1600), '4K');
    expect(PlayInfoPanel.quality(2560, 1440), '2K');
    expect(PlayInfoPanel.quality(1920, 1080), '1080p');
    expect(PlayInfoPanel.quality(1920, 800), '1080p');
    expect(PlayInfoPanel.quality(1280, 720), '720p');
    expect(PlayInfoPanel.quality(854, 480), '480p');
  });

  test('the speed is in the unit people know it by', () {
    expect(PlayInfoPanel.speed(3.2 * 1048576), '3.2 MB/s');
    expect(PlayInfoPanel.speed(640 * 1024), '640 KB/s');
  });

  test('a line goes by the site\'s name, or by its number in simple mode and when the site gave none', () {
    const lines = [PlayLine(name: '超级无敌4k', episodes: []), PlayLine(name: '', episodes: []), PlayLine(name: ' ikm3u8 ', episodes: [])];
    expect(lineTitle(lines, 0), '超级无敌4k');
    expect(lineTitle(lines, 1), '线路 2');
    expect(lineTitle(lines, 2), 'ikm3u8');
    expect([for (var i = 0; i < 3; i++) lineTitle(lines, i, numbered: true)], ['线路 1', '线路 2', '线路 3']);
  });
}
