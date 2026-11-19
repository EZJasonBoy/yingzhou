import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:tvbox_client/pages/player_tracks.dart' show MpvProperties;
import 'package:tvbox_client/player_backend.dart';

/// A media_kit player without libmpv, for widget tests: the test says what each address does, and moves the
/// picture along by hand.
///
/// An address plays unless it is listed: one in [broken] reports an error and never loads (a dead link), one in
/// [silent] loads nothing and says nothing (a server that hangs).
class FakePlayer extends PlatformPlayer implements MpvProperties {
  FakePlayer() : super(configuration: const PlayerConfiguration());

  final broken = <String>{};
  final silent = <String>{};

  /// Every address handed to the player, and every position it was sent to.
  final opened = <String>[];
  final seeks = <Duration>[];

  /// How long each media claims to be.
  Duration length = const Duration(minutes: 40);

  /// How long the player takes to report the position it was sent to (a real one answers a moment later).
  Duration seekDelay = Duration.zero;

  final _timers = <Timer>[];

  /// The stream's own audio and subtitle tracks, reported once the media is in (a picture is always there).
  List<AudioTrack> audioTracks = [const AudioTrack('1', null, null)];
  List<SubtitleTrack> subtitleTracksInStream = const [];

  /// Every subtitle and audio track the page chose, and the libmpv properties it set (last value of each).
  final subtitleChoices = <SubtitleTrack>[];
  final audioChoices = <AudioTrack>[];
  final mpv = <String, String>{};
  int _nextTrackId = 100;

  @override
  Future<void> setMpvProperty(String name, String value) async => mpv[name] = value;

  void _tracks(Tracks tracks) {
    state = state.copyWith(tracks: tracks);
    tracksController.add(tracks);
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {
    subtitleChoices.add(track);
    var chosen = track;
    // Like libmpv: a subtitle from outside becomes a track of its own, listed with the others.
    if (track.uri || track.data) {
      chosen = SubtitleTrack('${_nextTrackId++}', track.title, track.language);
      _tracks(Tracks(video: state.tracks.video, audio: state.tracks.audio, subtitle: [...state.tracks.subtitle, chosen]));
    }
    state = state.copyWith(track: state.track.copyWith(subtitle: chosen));
    trackController.add(state.track);
  }

  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    audioChoices.add(track);
    state = state.copyWith(track: state.track.copyWith(audio: track));
    trackController.add(state.track);
  }

  /// The player for the app, with nothing where the picture would be.
  PlayerBackend backend() => (player: Player(platformPlayer: this), view: const SizedBox.expand());

  void _later(Duration delay, void Function() action) => _timers.add(Timer(delay, action));

  void _cancelTimers() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
  }

  void _position(Duration p) {
    state = state.copyWith(position: p);
    positionController.add(p);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    await stop();
    final url = (playable as Media).uri;
    opened.add(url);
    // media_kit says "playing" as soon as it has been told to play, whatever becomes of the media.
    state = state.copyWith(playing: true);
    playingController.add(true);
    if (broken.contains(url)) {
      _later(const Duration(milliseconds: 50), () => errorController.add('Failed to open $url.'));
    } else if (!silent.contains(url)) {
      _later(const Duration(milliseconds: 50), () {
        state = state.copyWith(duration: length);
        durationController.add(length);
        _tracks(
          Tracks(
            video: [VideoTrack.auto(), VideoTrack.no(), const VideoTrack('1', null, null)],
            audio: [AudioTrack.auto(), AudioTrack.no(), ...audioTracks],
            subtitle: [SubtitleTrack.auto(), SubtitleTrack.no(), ...subtitleTracksInStream],
          ),
        );
      });
      // First frames: the position moves on from wherever it was sent.
      _later(const Duration(milliseconds: 150), () => advance(const Duration(milliseconds: 100)));
      _later(const Duration(milliseconds: 250), () => advance(const Duration(milliseconds: 100)));
    }
  }

  @override
  Future<void> stop() async {
    _cancelTimers();
    _tracks(const Tracks());
    state = state.copyWith(playing: false, completed: false, position: Duration.zero, duration: Duration.zero);
    playingController.add(false);
    completedController.add(false);
    positionController.add(Duration.zero);
    durationController.add(Duration.zero);
  }

  @override
  Future<void> seek(Duration duration) async {
    seeks.add(duration);
    if (seekDelay == Duration.zero) {
      _position(duration);
    } else {
      _later(seekDelay, () => _position(duration));
    }
  }

  /// What the player has read ahead reaches to [end].
  void bufferTo(Duration end) {
    state = state.copyWith(buffer: end);
    bufferController.add(end);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> playOrPause() async {
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }

  @override
  Future<void> dispose() {
    _cancelTimers();
    return super.dispose();
  }

  // ---- what the test does to the media that is playing

  /// The picture moves on by [by].
  void advance(Duration by) => _position(state.position + by);

  /// Playback has got to [position].
  void playTo(Duration position) {
    _position(position - const Duration(milliseconds: 100));
    _position(position);
  }

  /// The stream ends here, wherever that is.
  void end() {
    state = state.copyWith(playing: false, completed: true);
    playingController.add(false);
    completedController.add(true);
  }

  /// The player logs an error; what happens to the picture afterwards is up to the test.
  void fail(String message) => errorController.add(message);
}
