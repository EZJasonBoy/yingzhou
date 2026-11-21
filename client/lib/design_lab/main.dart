// 设计台 (design lab): the real app in every device form side by side — desktop, phone, tablet, TV — each one a
// full, live copy with its own state, all talking to one engine. Edit a page and hot reload (r in the terminal)
// updates every frame at once; click or use the keyboard inside any frame as in the app.
//
//   tvbox-engine --demo --port 19978                      (or the promo source's engine, see tools/promo)
//   flutter run -d windows -t lib/design_lab/main.dart [--dart-define=ENGINE_URL=http://127.0.0.1:19978]
//
// Scripted use (screenshots for reviews): --dart-define=LAB_SHOT=<file.png> saves the whole canvas once the frames
// have loaded, LAB_EXIT=true quits afterwards; LAB_FRAMES=desktop,phone,tablet,tv,phone-landscape picks the frames,
// LAB_THEME=light|dark and LAB_ZOOM=0.5 set the rest. See docs/design-lab.md.
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import '../mobile/playback_host.dart';
import '../ui/poster_cache.dart';
import 'design_lab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await PlaybackHost.init();
  PosterCache.instance = await PosterCache.open();
  runApp(const DesignLab());
}
