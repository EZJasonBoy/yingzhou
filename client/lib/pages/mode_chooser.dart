import 'package:material_ui/material_ui.dart';

import '../app_state.dart';
import '../ui/brand.dart';
import '../ui/device_form.dart';
import '../ui/tv/tv_focus.dart';
import '../ui/user_mode.dart';
import 'user_mode_settings.dart';

/// Shows [ModeChooser] in place of [child] on the very first start, until a way to use the app is picked. [ask] is
/// off in tests and wherever the app should open straight on its main screen.
class ModeGate extends StatelessWidget {
  const ModeGate({super.key, required this.ask, required this.child});

  final bool ask;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mode = AppScope.of(context).userMode;
    if (ask && mode.firstStart && !mode.chosen) return ModeChooser(onPicked: mode.set);
    return child;
  }
}

/// 选一种用法: simple, standard or developer, each with what it does and whom it is for. A remote picks with OK; with
/// touch or a mouse a card is chosen first and the button under them starts.
class ModeChooser extends StatefulWidget {
  const ModeChooser({super.key, required this.onPicked});

  final ValueChanged<UserMode> onPicked;

  @override
  State<ModeChooser> createState() => _ModeChooserState();
}

class _ModeChooserState extends State<ModeChooser> {
  UserMode _selected = UserMode.simple;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tv = isTv(context);
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 760;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BrandMark(size: tv ? 32 : 40),
        SizedBox(height: tv ? 8 : 12),
        Text('选一种用法', style: (wide && !tv ? theme.textTheme.headlineMedium : theme.textTheme.headlineSmall)?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('以后可以在「设置 → 外观 → 用法」里改。', style: TextStyle(color: scheme.onSurfaceVariant)),
      ],
    );
    Widget card(UserMode m) => _ModeCard(
          key: Key('mode-${m.name}'),
          mode: m,
          selected: m == _selected,
          wide: wide,
          autofocus: m == _selected,
          onTap: () {
            if (tv) {
              widget.onPicked(m);
            } else {
              setState(() => _selected = m);
            }
          },
          onFocus: () => setState(() => _selected = m),
        );
    final start = tv
        ? Text('← → 选择 · OK 用这种开始', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant))
        : SizedBox(
            width: wide ? 320 : double.infinity,
            child: FilledButton(
              key: const Key('mode-start'),
              onPressed: () => widget.onPicked(_selected),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: Text('用${_selected.label}模式开始'),
            ),
          );
    return Scaffold(
      body: SafeArea(
        child: wide
            ? Padding(
                padding: EdgeInsets.fromLTRB(tv ? 48 : 40, tv ? 28 : 40, tv ? 48 : 40, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    SizedBox(height: tv ? 20 : 28),
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1280, maxHeight: 340),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final m in UserMode.values) ...[
                              if (m != UserMode.values.first) const SizedBox(width: 20),
                              Expanded(child: card(m)),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Align(alignment: tv ? Alignment.center : Alignment.centerLeft, child: start),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 28, 16, 24),
                children: [
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: heading),
                  const SizedBox(height: 20),
                  for (final m in UserMode.values) Padding(padding: const EdgeInsets.only(bottom: 12), child: card(m)),
                  const SizedBox(height: 8),
                  start,
                  const SizedBox(height: 10),
                  Text('简单模式下，设置可以用 4 位密码锁住。', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
                ],
              ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({super.key, required this.mode, required this.selected, required this.wide, required this.autofocus, required this.onTap, required this.onFocus});

  final UserMode mode;
  final bool selected;
  final bool wide;
  final bool autofocus;
  final VoidCallback onTap;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tv = isTv(context);
    // On a TV the focus ring says which one is chosen; elsewhere the border does.
    final marked = selected && !tv;
    final name = Text(mode.label, style: (wide && !tv ? theme.textTheme.headlineSmall : theme.textTheme.titleLarge)?.copyWith(fontWeight: FontWeight.w700));
    final summary = Text(mode.summary, style: TextStyle(color: scheme.onSurface, height: 1.5, fontSize: wide && !tv ? 15 : 14));
    final audience = Text(mode.audience, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13));
    // The card shows the focus itself (a coral border): the usual glow would lie over all of its text.
    final focused = selected && tv;
    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      scale: 1.03,
      outline: false,
      borderRadius: BorderRadius.circular(16),
      onFocusChange: (focused) {
        if (focused && tv) onFocus();
      },
      child: Semantics(
        selected: selected,
        button: true,
        child: Container(
          padding: EdgeInsets.all(tv ? 18 : (wide ? 24 : 16)),
          decoration: BoxDecoration(
            color: marked || focused ? scheme.surfaceContainerHigh : scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: focused ? TvColors.coral : (marked ? scheme.primary : scheme.outlineVariant),
              width: focused ? 3 : (marked ? 2 : 1),
              strokeAlign: focused ? BorderSide.strokeAlignOutside : BorderSide.strokeAlignInside,
            ),
          ),
          child: wide
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(mode.icon, size: tv ? 30 : 40, color: selected ? scheme.primary : scheme.onSurfaceVariant),
                    SizedBox(height: tv ? 6 : 14),
                    name,
                    SizedBox(height: tv ? 4 : 10),
                    // What is left of the card's height is the description's.
                    Expanded(child: Align(alignment: Alignment.topLeft, child: summary)),
                    audience,
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(marked ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, size: 22, color: marked ? scheme.primary : scheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [name, const SizedBox(height: 4), summary, const SizedBox(height: 6), audience]),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
