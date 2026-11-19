import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'mobile/playback_host.dart';

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
  return (player: player, view: Video(controller: VideoController(player, configuration: androidVideoConfiguration()), controls: NoVideoControls, fill: Colors.black));
}

/// How the video is decoded and shown on Android.
///
/// Phones, tablets and boxes keep media_kit's choice: libmpv's OpenGL output (`vo=gpu`) with `hwdec=auto-safe`,
/// which takes MediaCodec when the device's decoder can do the stream and decodes in software when it cannot, so
/// any stream libmpv can read shows a picture, and subtitles and danmaku are drawn the same way on every device.
///
/// The emulator's OpenGL refuses the context libmpv asks for (`eglCreateContext: EGL_BAD_ATTRIBUTE`), so the
/// picture stays black there while the sound plays; media_kit also turns hardware decoding off on emulators. There
/// MediaCodec renders straight into the video surface instead (`vo=mediacodec_embed`), which needs no OpenGL in
/// libmpv. See docs/architecture.md section 4.
VideoControllerConfiguration androidVideoConfiguration() {
  if (PlaybackHost.isAndroidEmulator) return const VideoControllerConfiguration(vo: 'mediacodec_embed', hwdec: 'mediacodec');
  return const VideoControllerConfiguration();
}
