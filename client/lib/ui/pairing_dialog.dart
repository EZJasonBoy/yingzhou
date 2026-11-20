import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';

/// Shows the pairing dialog whenever the engine on another device asks for pairing (no token yet, or it was
/// revoked), wherever the user is in the app.
class PairingGate extends StatefulWidget {
  const PairingGate({super.key, required this.child});

  final Widget child;

  @override
  State<PairingGate> createState() => _PairingGateState();
}

class _PairingGateState extends State<PairingGate> {
  bool _open = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (state.needsPairing && !_open) {
      _open = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const PairingDialog());
        _open = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    return widget.child;
  }
}

/// 「与引擎配对」: the code the engine shows (in its 「局域网共享」 settings, or in its log when it runs headless).
class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key});

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The engine makes a code if none is showing; a headless engine prints it.
    AppScope.read(context).requestPairingCode();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final state = AppScope.read(context);
    if (_code.text.trim().isEmpty || state.busy) return;
    final ok = await state.pair(_code.text);
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('与引擎配对'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(state.engineUrl, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            const Text('在引擎所在的设备上打开「设置 → 局域网共享」查看配对码；没有界面的引擎（NAS、Docker）把配对码打印在日志里。'),
            const SizedBox(height: 16),
            TextField(
              key: const Key('pairing-code'),
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              style: const TextStyle(fontSize: 24, letterSpacing: 6),
              decoration: const InputDecoration(labelText: '配对码', hintText: '6 位数字'),
              onSubmitted: (_) => _submit(),
            ),
            if (state.pairingError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(state.pairingError!, style: TextStyle(color: scheme.error)),
              ),
            if (state.busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            state.dismissPairing();
            Navigator.of(context).pop();
          },
          child: const Text('取消'),
        ),
        FilledButton(onPressed: state.busy ? null : _submit, child: const Text('配对')),
      ],
    );
  }
}
