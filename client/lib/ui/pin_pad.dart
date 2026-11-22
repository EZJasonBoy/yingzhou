import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import 'device_form.dart';
import 'tv/tv_focus.dart';

/// Four digits, entered on a pad that works with a finger, a mouse, a keyboard's number keys and a remote (its number
/// keys, or the D-pad over the pad).
///
/// [onEntered] gets the four digits and answers what is wrong with them, or null when they were taken; a wrong code
/// empties the dots and shows the answer under them.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.title, this.subtitle, required this.onEntered});

  final String title;
  final String? subtitle;
  final Future<String?> Function(String pin) onEntered;

  static const length = 4;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  String? _error;
  bool _busy = false;
  final _focus = FocusNode(debugLabel: 'pin-pad');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _digit(int d) {
    if (_busy || _pin.length >= PinPad.length) return;
    setState(() {
      _pin += '$d';
      _error = null;
    });
    if (_pin.length == PinPad.length) _submit();
  }

  void _erase() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final error = await widget.onEntered(_pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pin = '';
      _error = error;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final digit = TvKeys.digit(event.logicalKey);
    if (digit != null) {
      _digit(digit);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace || event.logicalKey == LogicalKeyboardKey.delete) {
      _erase();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tv = isTv(context);
    final key = tv ? 60.0 : 64.0;
    Widget digit(int d) => _PadKey(key: Key('pin-$d'), size: key, autofocus: d == 1, onTap: () => _digit(d), child: Text('$d', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: scheme.onSurface)));
    return Focus(
      focusNode: _focus,
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, size: 32, color: scheme.primary),
          const SizedBox(height: 12),
          Text(widget.title, textAlign: TextAlign.center, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          if (widget.subtitle != null) ...[
            const SizedBox(height: 6),
            Text(widget.subtitle!, textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5)),
          ],
          const SizedBox(height: 20),
          Semantics(
            label: '已输入 ${_pin.length} 位，共 ${PinPad.length} 位',
            child: Row(
              key: const Key('pin-dots'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < PinPad.length; i++)
                  Container(
                    width: 14,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 9),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i < _pin.length ? scheme.primary : Colors.transparent,
                      border: Border.all(color: i < _pin.length ? scheme.primary : scheme.outline, width: 2),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 34,
            child: Center(
              child: _error == null ? null : Text(_error!, key: const Key('pin-error'), style: TextStyle(color: scheme.error, fontSize: 13)),
            ),
          ),
          for (final row in const [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final d in row) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: digit(d)),
                ],
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: SizedBox(width: key * 1.25, height: key)),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: digit(0)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _PadKey(
                  key: const Key('pin-erase'),
                  size: key,
                  flat: true,
                  onTap: _erase,
                  child: Icon(Icons.backspace_outlined, color: scheme.onSurfaceVariant, semanticLabel: '删除一位'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({super.key, required this.size, required this.onTap, required this.child, this.autofocus = false, this.flat = false});

  final double size;
  final VoidCallback onTap;
  final Widget child;
  final bool autofocus;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      center: false,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: size * 1.25,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: flat ? Colors.transparent : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
        child: child,
      ),
    );
  }
}

/// Asks for a new code twice; the code, or null when the user gave up.
Future<String?> askNewPin(BuildContext context) async {
  String? first;
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => Dialog(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PinPad(
                key: ValueKey(first == null),
                title: first == null ? '设一个 4 位密码' : '再输一遍',
                subtitle: first == null ? '简单模式下，进「设置」要先输它' : null,
                onEntered: (pin) async {
                  if (first == null) {
                    setState(() => first = pin);
                    return null;
                  }
                  if (pin != first) {
                    setState(() => first = null);
                    return '两次不一样，重新设';
                  }
                  Navigator.of(context).pop(pin);
                  return null;
                },
              ),
              const SizedBox(height: 4),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Shows [child] only once the code of 设置 has been entered, when simple mode has one ([UserModeController.locked]).
/// Watching is never behind the lock: only the pages that change how the app is set up.
class LockGate extends StatelessWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mode = AppScope.of(context).userMode;
    if (!mode.locked) return child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: PinPad(
              key: const Key('settings-lock'),
              title: '设置已上锁',
              subtitle: '输入 4 位密码，才能改订阅、换用法。\n看片不受影响。',
              onEntered: (pin) async => mode.unlock(pin) ? null : '密码不对',
            ),
          ),
        ),
      ),
    );
  }
}
