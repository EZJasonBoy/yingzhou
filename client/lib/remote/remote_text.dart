import 'package:material_ui/material_ui.dart';

/// The text field that has the focus on this screen, for a remote to type into: the phone shows its keyboard, what
/// is typed there is put into the field as if typed here, and Enter submits it. Typing a search or an address with
/// four arrow keys is what this spares.
///
/// It follows the focus (any `EditableText`: `TextField`, a search bar, a dialog's field) and the field's text, and
/// tells its listeners when either changes.
class RemoteTextField extends ChangeNotifier {
  RemoteTextField() {
    FocusManager.instance.addListener(_focusChanged);
    _focusChanged();
  }

  EditableTextState? _field;
  TextEditingController? _controller;
  String _lastText = '';

  /// What the remote is told (`text` in the state): null when no text field has the focus.
  Map<String, Object?>? get state {
    final field = _current;
    if (field == null) return null;
    final secret = field.widget.obscureText;
    return {
      // What is in a password field stays on this screen.
      'value': secret ? '' : field.textEditingValue.text,
      'hint': _hint(field),
      'secret': secret,
      'multiline': field.widget.maxLines != 1,
    };
  }

  EditableTextState? get _current {
    final field = _field;
    return field != null && field.mounted && !field.widget.readOnly ? field : null;
  }

  /// Replaces the field's text with [value], the caret at its end, the way typing does (formatters, `onChanged`).
  bool setText(String value) {
    final field = _current;
    if (field == null) return false;
    field.userUpdateTextEditingValue(
      TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length)),
      SelectionChangedCause.keyboard,
    );
    return true;
  }

  /// Enter on the remote's keyboard: the field's own action (search, go, done).
  bool submit() {
    final field = _current;
    if (field == null) return false;
    final action = field.widget.textInputAction;
    field.performAction(action == null || action == TextInputAction.newline || action == TextInputAction.none ? TextInputAction.done : action);
    return true;
  }

  static String _hint(EditableTextState field) {
    final decoration = field.context.findAncestorWidgetOfExactType<TextField>()?.decoration;
    return decoration?.hintText ?? decoration?.labelText ?? '';
  }

  static EditableTextState? _editable(FocusNode? node) {
    final context = node?.context;
    if (context == null || !context.mounted) return null;
    if (context is StatefulElement && context.state is EditableTextState) return context.state as EditableTextState;
    try {
      return context.findAncestorStateOfType<EditableTextState>();
    } catch (_) {
      // The focus is still on something that is being taken out of the tree (a page closing): no field.
      return null;
    }
  }

  void _focusChanged() {
    final next = _editable(FocusManager.instance.primaryFocus);
    if (identical(next, _field)) return;
    _controller?.removeListener(_textChanged);
    _field = next;
    _controller = next?.widget.controller;
    _controller?.addListener(_textChanged);
    _lastText = next?.textEditingValue.text ?? '';
    notifyListeners();
  }

  void _textChanged() {
    // The caret moving is nothing to tell a remote about.
    final text = _controller?.text ?? '';
    if (text == _lastText) return;
    _lastText = text;
    notifyListeners();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    _controller?.removeListener(_textChanged);
    super.dispose();
  }
}
