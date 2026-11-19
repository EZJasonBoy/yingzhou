import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../device_form.dart';
import 'tv_focus.dart';
import 'tv_text_input.dart';

/// The 10-foot frame around the whole app on a TV (main.dart puts it around the navigator):
///
/// - overscan: many TVs cut off the edges of the picture, so about 5 % on every side is added to the safe-area
///   padding; everything that respects [SafeArea] keeps clear of it, while video still fills the screen;
/// - slightly larger type;
/// - the remote's BACK key closes menus the way Esc does on a keyboard (then, if nothing took it, Android's own back);
/// - the focus outline ([TvFocusRing]) and the gate that keeps the system keyboard closed until OK
///   ([TvTextInputGate]).
///
/// Off TV nothing changes: the same widgets are there (so switching modes keeps the navigator and its pages), but
/// they pass everything through.
class TvAppFrame extends StatelessWidget {
  const TvAppFrame({super.key, required this.child});

  final Widget child;

  /// The share of the screen kept clear on every side.
  static const overscan = 0.05;

  /// How much larger text is on a TV.
  static const textScale = 1.1;

  @override
  Widget build(BuildContext context) {
    final tv = isTv(context);
    final media = MediaQuery.of(context);
    final size = media.size;
    final safe = tv ? EdgeInsets.symmetric(horizontal: size.width * overscan, vertical: size.height * overscan) : EdgeInsets.zero;
    return MediaQuery(
      data: tv
          ? media.copyWith(
              padding: _max(media.padding, safe),
              viewPadding: _max(media.viewPadding, safe),
              textScaler: TextScaler.linear(media.textScaler.scale(1) * textScale),
              navigationMode: NavigationMode.directional,
            )
          : media,
      child: _BackKeyGuard(
        // Phones and tablets send BACK as a key too (button navigation), with the same double back.
        enabled: !isDesktop(context),
        child: Shortcuts(
          shortcuts: tv ? _tvShortcuts : const <ShortcutActivator, Intent>{},
          child: FocusTraversalGroup(
            // Off TV the same policy as the app's own top-level group, so nothing changes there.
            policy: tv ? TvTraversalPolicy() : ReadingOrderTraversalPolicy(),
            child: TvFocusRing(
              enabled: tv,
              child: TvTextInputGate(enabled: tv, child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// BACK closes menus like Esc; ↑ / ↓ move the focus out of a text field too (a single-line field would move its
  /// caret to the start or the end and keep the focus, trapping the remote). ← / → still move the caret.
  static const _tvShortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
    SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up, ignoreTextFields: false),
    SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down, ignoreTextFields: false),
  };

  static EdgeInsets _max(EdgeInsets a, EdgeInsets b) => EdgeInsets.fromLTRB(
    a.left > b.left ? a.left : b.left,
    a.top > b.top ? a.top : b.top,
    a.right > b.right ? a.right : b.right,
    a.bottom > b.bottom ? a.bottom : b.bottom,
  );
}

/// Android goes back a page when BACK is let go (key up) and the app did not take the key. A panel or a dialog that
/// closes on BACK takes the key down; nothing below takes the key up, which Flutter then hands back to Android, and
/// Android goes back a page as well: the dialog closes and the page behind it goes too (or the quit question comes
/// straight back). This sits above every handler of the app: a key up of BACK reaches it only when nobody took it,
/// and it keeps it when the key down never got this far, i.e. something in the app already acted on that press.
class _BackKeyGuard extends StatefulWidget {
  const _BackKeyGuard({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_BackKeyGuard> createState() => _BackKeyGuardState();
}

class _BackKeyGuardState extends State<_BackKeyGuard> {
  /// The last BACK key down was not taken by the app (Android's own back follows on key up).
  bool _downPassed = false;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (!widget.enabled || event.logicalKey != LogicalKeyboardKey.goBack) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      _downPassed = true;
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      final passed = _downPassed;
      _downPassed = false;
      return passed ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: widget.child);
}

/// The theme on a TV: [base] with focus that shows from across the room (a coral fill on focused buttons, chips and
/// list rows, under the outline of [TvFocusRing]). Anywhere else [base] itself.
ThemeData tvTheme(BuildContext context, ThemeData base) {
  if (!isTv(context)) return base;
  final focus = TvColors.coral.withValues(alpha: 0.28);
  WidgetStateProperty<Color?> overlay(WidgetStateProperty<Color?>? _) => WidgetStateProperty.resolveWith((states) {
    if (states.contains(WidgetState.focused)) return focus;
    if (states.contains(WidgetState.pressed)) return base.colorScheme.onSurface.withValues(alpha: 0.12);
    if (states.contains(WidgetState.hovered)) return base.colorScheme.onSurface.withValues(alpha: 0.08);
    return null;
  });
  final buttons = ButtonStyle(overlayColor: overlay(null));
  return base.copyWith(
    focusColor: focus,
    filledButtonTheme: FilledButtonThemeData(style: buttons),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttons),
    textButtonTheme: TextButtonThemeData(style: buttons),
    elevatedButtonTheme: ElevatedButtonThemeData(style: buttons),
    iconButtonTheme: IconButtonThemeData(style: buttons),
    segmentedButtonTheme: SegmentedButtonThemeData(style: buttons),
    menuButtonTheme: MenuButtonThemeData(style: buttons),
    listTileTheme: base.listTileTheme.copyWith(selectedTileColor: base.colorScheme.primaryContainer.withValues(alpha: 0.45)),
    tooltipTheme: const TooltipThemeData(triggerMode: TooltipTriggerMode.manual),
    // Bars and lists are scrolled by moving the focus; a scrollbar is only clutter.
    scrollbarTheme: const ScrollbarThemeData(thickness: WidgetStatePropertyAll(0)),
  );
}
