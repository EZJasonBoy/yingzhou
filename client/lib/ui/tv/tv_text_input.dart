import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'tv_focus.dart';

/// Text fields with a remote control.
///
/// Flutter opens the soft keyboard as soon as a text field gets the focus. On a TV that means the system keyboard
/// covers the screen whenever the D-pad merely passes over a field, and takes over the D-pad. While this is enabled
/// the system keyboard stays closed until the user presses OK on the field, like native TV apps: a do-nothing
/// [TextInputControl] stands in for the system one (the field still has the focus, and a hardware keyboard still
/// types into it). OK hands the field to the system keyboard; leaving the field puts the stand-in back.
class TvTextInputGate extends StatefulWidget {
  const TvTextInputGate({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  /// Focuses the text field of [node] and opens the system keyboard for it, as OK on the field does (a button
  /// "输入法" next to a field). Without a gate it just focuses the field.
  static void openKeyboard(FocusNode node) {
    final gate = _TvTextInputGateState._current;
    final editable = _TvTextInputGateState._editable(node);
    if (gate == null || !gate.widget.enabled || editable == null) {
      node.requestFocus();
      return;
    }
    gate._openFor(node, editable);
  }

  @override
  State<TvTextInputGate> createState() => _TvTextInputGateState();
}

class _NoKeyboard with TextInputControl {}

class _TvTextInputGateState extends State<TvTextInputGate> {
  static final _gate = _NoKeyboard();
  static _TvTextInputGateState? _current;
  bool _gated = false;

  /// The field the system keyboard was opened for; leaving it closes the gate again.
  FocusNode? _open;

  @override
  void initState() {
    super.initState();
    _current = this;
    FocusManager.instance.addListener(_focusChanged);
    if (widget.enabled) _close();
  }

  @override
  void didUpdateWidget(TvTextInputGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) _close();
    if (!widget.enabled && oldWidget.enabled) _release();
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    FocusManager.instance.removeListener(_focusChanged);
    _release();
    super.dispose();
  }

  void _close() {
    if (_gated) return;
    _gated = true;
    _open = null;
    TextInput.setInputControl(_gate);
  }

  void _release() {
    if (!_gated) return;
    _gated = false;
    TextInput.restorePlatformInputControl();
  }

  /// Between letting go of the field and focusing it again to reconnect it.
  bool _reconnecting = false;

  void _focusChanged() {
    if (!widget.enabled || _reconnecting) return;
    final node = FocusManager.instance.primaryFocus;
    if (_open != null && node != _open) {
      // Left the field (or it gave up the focus after submitting): no keyboard for the next one until OK.
      if (node != null && node is! FocusScopeNode) _close();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (_open != null && FocusManager.instance.primaryFocus != _open) _close();
      });
    }
  }

  static EditableTextState? _editable(FocusNode? node) {
    final context = node?.context;
    if (context == null || !context.mounted) return null;
    if (context is StatefulElement && context.state is EditableTextState) return context.state as EditableTextState;
    return context.findAncestorStateOfType<EditableTextState>();
  }

  /// OK on a focused text field: open the system keyboard for it. BACK on a field whose keyboard is closed: back, as
  /// anywhere else (Android would otherwise hand the key to the field's input connection, which swallows it).
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!widget.enabled) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.goBack) {
      final node = FocusManager.instance.primaryFocus;
      final context = node?.context;
      if (_editable(node) == null || context == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) {
        _close();
        Navigator.maybeOf(context)?.maybePop();
      }
      return KeyEventResult.handled;
    }
    // ← / → move the caret, and leave the field once the caret is at that end (the field beside it is reachable).
    if (TvKeys.isLeft(event.logicalKey) || TvKeys.isRight(event.logicalKey)) {
      final editable = _editable(FocusManager.instance.primaryFocus);
      if (editable == null || !editable.mounted) return KeyEventResult.ignored;
      final left = TvKeys.isLeft(event.logicalKey);
      final value = editable.textEditingValue;
      final selection = value.selection;
      final atEnd = !selection.isValid || (selection.isCollapsed && (left ? selection.baseOffset <= 0 : selection.baseOffset >= value.text.length));
      if (!atEnd) return KeyEventResult.ignored;
      if (event is! KeyUpEvent) {
        // From above the field's own actions: the shell's (which knows the edges of the page) or the app's.
        Actions.maybeInvoke(editable.context, DirectionalFocusIntent(left ? TraversalDirection.left : TraversalDirection.right));
      }
      return KeyEventResult.handled;
    }
    if (!TvKeys.isActivate(event.logicalKey) || event.logicalKey == LogicalKeyboardKey.space) return KeyEventResult.ignored;
    final node = FocusManager.instance.primaryFocus;
    final editable = _editable(node);
    if (editable == null || node == null || editable.widget.readOnly) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _openFor(node, editable);
    return KeyEventResult.handled;
  }

  void _openFor(FocusNode node, EditableTextState editable) {
    if (!_gated) {
      if (!node.hasPrimaryFocus) node.requestFocus();
      editable.requestKeyboard();
      return;
    }
    _gated = false;
    _open = node;
    _reconnecting = true;
    TextInput.restorePlatformInputControl();
    // The field told the platform "no keyboard" when it got the focus; connect it again so it asks for the real one.
    if (node.hasFocus) node.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (node.context != null && node.canRequestFocus) node.requestFocus();
      SchedulerBinding.instance.addPostFrameCallback((_) => _reconnecting = false);
      SchedulerBinding.instance.scheduleFrame();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.child);
  }
}
