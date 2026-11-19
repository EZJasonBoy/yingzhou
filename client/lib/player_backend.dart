import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// A media player and the widget that shows its picture.
typedef PlayerBackend = ({Player player, Widget view});

/// Makes a [PlayerBackend] when a page starts playing.
typedef PlayerBackendFactory = PlayerBackend Function();

/// The real thing: media_kit (libmpv on desktop). Widget tests hand the app a player of their own, because libmpv
/// cannot be loaded there.
///
/// On desktop libmpv draws the subtitles itself (libass): ASS styles and positions show as written, and the size and
/// position settings are libmpv's (`sub-scale`, `sub-pos`). Elsewhere media_kit draws plain text over the picture.
PlayerBackend mediaKitBackend() {
  final desktop = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux);
  final player = Player(configuration: PlayerConfiguration(libass: desktop));
  return (player: player, view: Video(controller: VideoController(player), controls: NoVideoControls, fill: Colors.black));
}
