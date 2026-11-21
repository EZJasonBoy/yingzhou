import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'update_dialog.dart';
import 'update_service.dart';

/// The automatic update check: when the user turned it on, a while after start (so the engine and its GitHub
/// proxy setting are there) and then every few hours, it asks if a day has passed since the last check. A newer
/// version is shown once (the dialog), when nothing is on top of the home page; the 更新 card keeps showing it.
class UpdateWatcher extends StatefulWidget {
  const UpdateWatcher({super.key, required this.child, this.firstCheck = const Duration(seconds: 20), this.every = const Duration(hours: 3)});

  final Widget child;
  final Duration firstCheck;
  final Duration every;

  @override
  State<UpdateWatcher> createState() => _UpdateWatcherState();
}

class _UpdateWatcherState extends State<UpdateWatcher> {
  Timer? _first;
  Timer? _again;
  Timer? _waitToShow;

  @override
  void initState() {
    super.initState();
    _first = Timer(widget.firstCheck, _tick);
    _again = Timer.periodic(widget.every, (_) => _tick());
  }

  @override
  void dispose() {
    _first?.cancel();
    _again?.cancel();
    _waitToShow?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (!mounted) return;
    final service = UpdateService.of(context);
    if (!service.due || service.checking) return;
    final result = await service.check();
    if (result == null || !result.newer || service.notifiedVersion == result.release!.version) return;
    _waitToShow?.cancel();
    // Not over the player or another page: when the home page is on top again.
    _waitToShow = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) return timer.cancel();
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      timer.cancel();
      await service.markNotified(result.release!.version);
      if (mounted) await showUpdateDialog(context, result);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
