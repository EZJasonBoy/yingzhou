import 'package:material_ui/material_ui.dart';

import 'tv_focus.dart';

/// An on-screen keyboard for the remote, like TVBox's search: letters and digits in a grid of six, with delete,
/// clear and search under it. Letters are for titles written in Latin letters, pinyin or pinyin initials that sites
/// understand; Chinese goes through the system keyboard ([onSystemInput]).
class TvSearchKeyboard extends StatelessWidget {
  const TvSearchKeyboard({super.key, required this.controller, required this.onSearch, this.onSystemInput, this.onPhoneInput, this.firstKeyFocus});

  final TextEditingController controller;
  final VoidCallback onSearch;

  /// Opens the system keyboard (Chinese, voice) on the search field.
  final VoidCallback? onSystemInput;

  /// Types the search on a phone (a QR code; see `ui/phone_input.dart`).
  final VoidCallback? onPhoneInput;

  /// The focus of the first key ("A"), so the page can put the focus there.
  final FocusNode? firstKeyFocus;

  static const keys = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890';
  static const columns = 6;

  void _type(String s) {
    final text = controller.text + s;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _delete() {
    final text = controller.text;
    if (text.isEmpty) return;
    final chars = text.characters;
    final next = chars.take(chars.length - 1).toString();
    controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, VoidCallback onTap, {Key? k, FocusNode? focusNode, IconData? icon, bool primary = false}) => TvFocusable(
      key: k,
      focusNode: focusNode,
      onTap: onTap,
      center: false,
      scale: 1.12,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(color: primary ? scheme.primary : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20, color: primary ? scheme.onPrimary : scheme.onSurface),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, color: primary ? scheme.onPrimary : scheme.onSurface),
                    ),
                  ),
                ],
              )
            : Text(
                label,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: primary ? scheme.onPrimary : scheme.onSurface),
              ),
      ),
    );
    final rows = <Widget>[];
    for (var r = 0; r < keys.length / columns; r++) {
      rows.add(
        Expanded(
          child: Row(
            children: [
              for (var c = 0; c < columns; c++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: key(
                      keys[r * columns + c],
                      () => _type(keys[r * columns + c]),
                      k: Key('tv-key-${keys[r * columns + c]}'),
                      focusNode: r == 0 && c == 0 ? firstKeyFocus : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    rows.add(
      Expanded(
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: key('删除', _delete, k: const Key('tv-key-delete'), icon: Icons.backspace_outlined),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: key('清空', controller.clear, k: const Key('tv-key-clear'), icon: Icons.clear_all_rounded),
              ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: key('搜索', onSearch, k: const Key('tv-key-search'), icon: Icons.search_rounded, primary: true),
              ),
            ),
          ],
        ),
      ),
    );
    if (onSystemInput != null || onPhoneInput != null) {
      rows.add(
        Expanded(
          child: Row(
            children: [
              if (onSystemInput != null)
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: key(
                      onPhoneInput == null ? '输入法（中文、语音）' : '中文 / 语音',
                      onSystemInput!,
                      k: const Key('tv-key-ime'),
                      icon: Icons.keyboard_alt_outlined,
                    ),
                  ),
                ),
              if (onPhoneInput != null)
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: key('手机输入', onPhoneInput!, k: const Key('tv-key-phone'), icon: Icons.qr_code_2_rounded),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }
}
