import 'package:material_ui/material_ui.dart';

import '../settings.dart';
import 'brand.dart';
import 'yz_tokens.dart';

/// Light or dark, as chosen in 设置 → 外观 and kept in the client's settings under [key]. Until the user chooses,
/// phones and tablets follow the system, and desktops and TVs are dark.
class ThemeChoice extends ChangeNotifier {
  ThemeChoice([this._settings]) : _mode = ThemeMode.values.asNameMap()[_settings?.getString(key) ?? ''];

  static const key = 'ui.theme';

  final SettingsStore? _settings;
  ThemeMode? _mode;

  /// What the user chose; null while they have not.
  ThemeMode? get mode => _mode;

  /// The mode to use on a device that is [touch] (a phone or a tablet) or not.
  ThemeMode resolve({required bool touch}) => _mode ?? (touch ? ThemeMode.system : ThemeMode.dark);

  Future<void> set(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _settings?.setString(key, mode.name);
  }
}

/// The design lab's switch (lib/design_lab): the theme from before the design system, to compare the two side by
/// side. Always false in the app.
bool debugLegacyTheme = false;

/// 夜: the design system's dark theme (docs/design/tokens.json → yz_tokens.dart). Desktops and TVs by default.
ThemeData buildDarkTheme() => debugLegacyTheme ? _legacy(Brightness.dark) : _yz(YzTokens.dark, Brightness.dark);

/// 晨: the light theme. Phones and tablets that follow a light system.
ThemeData buildLightTheme() => debugLegacyTheme ? _legacy(Brightness.light) : _yz(YzTokens.light, Brightness.light);

/// Chinese text: without these, Windows picks a font per run of text, and a title with a character that only the
/// simplified fonts have (纸, 页, 盘 …) comes out in another, lighter typeface than the title next to it.
final _sans = YzType.families[YzFamily.sans]!;

TextStyle _t(TextStyle s, Color c) => s.copyWith(color: c, fontFamilyFallback: _sans);

ThemeData _yz(YzTokens t, Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme(
    brightness: b,
    // Material paints text and icons in primary (text buttons, selected icons, sliders): the coral that reads as text.
    primary: t.accentInk,
    onPrimary: dark ? t.onAccent : Colors.white,
    primaryContainer: t.accentSoft,
    onPrimaryContainer: t.accentInk,
    secondary: t.accentInk,
    onSecondary: dark ? t.onAccent : Colors.white,
    secondaryContainer: t.accentSoft,
    onSecondaryContainer: t.accentInk,
    tertiary: t.waveMint,
    onTertiary: t.onAccent,
    error: t.danger,
    onError: dark ? t.onAccent : Colors.white,
    surface: t.bg,
    onSurface: t.ink,
    onSurfaceVariant: t.inkMuted,
    surfaceContainerLowest: t.surfaceSunk,
    surfaceContainerLow: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surfaceRaised,
    surfaceContainerHighest: t.surfaceHover,
    outline: t.lineStrong,
    outlineVariant: t.line,
    shadow: Colors.black,
    scrim: t.scrim,
    inverseSurface: t.ink,
    onInverseSurface: t.bg,
    inversePrimary: t.accent,
    surfaceTint: Colors.transparent,
  );
  final base = ThemeData(colorScheme: scheme, brightness: b);
  final text = base.textTheme.copyWith(
    displayLarge: _t(YzType.display.copyWith(fontSize: 48, height: 1.15), t.ink),
    displayMedium: _t(YzType.display, t.ink),
    displaySmall: _t(YzType.display.copyWith(fontSize: 34, height: 1.2), t.ink),
    headlineLarge: _t(YzType.pageTitle, t.ink),
    headlineMedium: _t(YzType.pageTitle.copyWith(fontSize: 24, height: 1.33), t.ink),
    headlineSmall: _t(YzType.headline, t.ink),
    titleLarge: _t(YzType.headline.copyWith(fontSize: 22, height: 1.3), t.ink),
    titleMedium: _t(YzType.title, t.ink),
    titleSmall: _t(YzType.title.copyWith(fontSize: 14, height: 1.43), t.ink),
    bodyLarge: _t(YzType.body, t.ink),
    bodyMedium: _t(YzType.body.copyWith(fontSize: 14, height: 1.43), t.ink),
    bodySmall: _t(YzType.bodySm, t.inkMuted),
    labelLarge: _t(YzType.label, t.ink),
    labelMedium: _t(YzType.label.copyWith(fontSize: 13, height: 1.38), t.ink),
    labelSmall: _t(YzType.caption, t.inkMuted),
  );
  final rMd = BorderRadius.circular(Yz.radiusMd);
  final rSm = BorderRadius.circular(Yz.radiusSm);
  final wave = [t.waveRose, t.waveGold, t.waveMint];
  return base.copyWith(
    extensions: [t],
    textTheme: text,
    scaffoldBackgroundColor: t.bg,
    canvasColor: t.bg,
    dividerColor: t.line,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: t.bg,
      foregroundColor: t.ink,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(color: t.surface, elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: rMd)),
    // Chips are small rounded rectangles, not pills; selected = soft coral ground, coral text, no checkmark.
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: rSm),
      backgroundColor: t.surfaceHover,
      selectedColor: t.accentSoft,
      labelStyle: _t(YzType.label, t.ink),
      secondaryLabelStyle: _t(YzType.label, t.accentInk),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        disabledBackgroundColor: t.surfaceHover,
        minimumSize: const Size(64, Yz.controlMd),
        padding: const EdgeInsets.symmetric(horizontal: Yz.space5),
        shape: RoundedRectangleBorder(borderRadius: rMd),
        textStyle: YzType.label.copyWith(fontWeight: FontWeight.w600, fontFamilyFallback: _sans),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: t.ink,
        side: BorderSide(color: t.lineStrong),
        minimumSize: const Size(64, Yz.controlMd),
        padding: const EdgeInsets.symmetric(horizontal: Yz.space5),
        shape: RoundedRectangleBorder(borderRadius: rMd),
        textStyle: YzType.label.copyWith(fontFamilyFallback: _sans),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: t.accentInk,
        shape: RoundedRectangleBorder(borderRadius: rMd),
        textStyle: YzType.label.copyWith(fontFamilyFallback: _sans),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: t.accentSoft,
        selectedForegroundColor: t.accentInk,
        foregroundColor: t.ink,
        side: BorderSide(color: t.lineStrong),
        shape: RoundedRectangleBorder(borderRadius: rSm),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surfaceHover,
      hintStyle: _t(YzType.body, t.inkFaint),
      border: OutlineInputBorder(borderRadius: rSm, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: rSm, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: rSm, borderSide: BorderSide(color: t.focus, width: 1.5)),
    ),
    // Navigation: no pill behind the current entry; its icon and name turn coral (the shell adds the wave).
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: t.surfaceSunk,
      indicatorColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: t.accentInk),
      unselectedIconTheme: IconThemeData(color: t.inkMuted),
      selectedLabelTextStyle: _t(YzType.caption.copyWith(fontWeight: FontWeight.w600), t.accentInk),
      unselectedLabelTextStyle: _t(YzType.caption, t.inkMuted),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: t.surfaceSunk,
      indicatorColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? t.accentInk : t.inkMuted)),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => _t(YzType.caption.copyWith(fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500), s.contains(WidgetState.selected) ? t.accentInk : t.inkMuted),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      dividerColor: Colors.transparent,
      tabAlignment: TabAlignment.start,
      indicator: WaveTabIndicator(colors: wave),
      indicatorSize: TabBarIndicatorSize.label,
      labelColor: t.ink,
      unselectedLabelColor: t.inkMuted,
      labelStyle: _t(YzType.body.copyWith(fontWeight: FontWeight.w600), t.ink),
      unselectedLabelStyle: _t(YzType.body, t.inkMuted),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: t.accent,
      inactiveTrackColor: t.ink.withValues(alpha: 0.22),
      thumbColor: t.accent,
      overlayColor: t.accentSoft,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.onAccent : t.lineStrong),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accent : Colors.transparent),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? t.accent : t.lineStrong),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: t.surfaceRaised,
      contentTextStyle: _t(YzType.body, t.ink),
      actionTextColor: t.accentInk,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: rMd),
    ),
    dialogTheme: DialogThemeData(backgroundColor: t.surfaceRaised, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Yz.radiusLg))),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Yz.radiusLg))),
    ),
    popupMenuTheme: PopupMenuThemeData(color: t.surfaceRaised, surfaceTintColor: Colors.transparent, shape: RoundedRectangleBorder(borderRadius: rMd)),
    menuTheme: MenuThemeData(style: MenuStyle(backgroundColor: WidgetStatePropertyAll(t.surfaceRaised), surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent))),
    dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(selectedColor: t.accentInk, iconColor: t.inkMuted, textColor: t.ink),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.accentInk, linearTrackColor: t.surfaceHover, circularTrackColor: Colors.transparent),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: t.surfaceRaised, borderRadius: rSm),
      textStyle: _t(YzType.bodySm, t.ink),
    ),
    iconTheme: IconThemeData(color: t.inkMuted),
  );
}

// ---- the theme from before the design system, for the design lab's comparison ------------------------------------

const _legacySeed = Color(0xFF4F8CFF);

ThemeData _legacy(Brightness b) {
  final scheme = b == Brightness.dark
      ? ColorScheme.fromSeed(seedColor: _legacySeed, brightness: Brightness.dark).copyWith(
          surface: const Color(0xFF111318),
          surfaceContainerLowest: const Color(0xFF0B0D11),
          surfaceContainerLow: const Color(0xFF15181E),
          surfaceContainer: const Color(0xFF1A1D24),
          surfaceContainerHigh: const Color(0xFF20242C),
          surfaceContainerHighest: const Color(0xFF272B34),
        )
      : ColorScheme.fromSeed(seedColor: _legacySeed);
  return ThemeData(
    colorScheme: scheme,
    fontFamilyFallback: _sans,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent, scrolledUnderElevation: 0, centerTitle: false),
    cardTheme: CardThemeData(color: scheme.surfaceContainerLow, elevation: 0, margin: EdgeInsets.zero, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    chipTheme: ChipThemeData(
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      backgroundColor: scheme.surfaceContainerHigh,
      selectedColor: scheme.primaryContainer,
      labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
      showCheckmark: false,
    ),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: scheme.surfaceContainerHigh, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)),
    navigationRailTheme: NavigationRailThemeData(backgroundColor: scheme.surfaceContainerLowest, indicatorColor: scheme.primaryContainer),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: scheme.surfaceContainerLowest, indicatorColor: scheme.primaryContainer),
    tabBarTheme: const TabBarThemeData(
      dividerColor: Colors.transparent,
      tabAlignment: TabAlignment.start,
      labelStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(fontSize: 15),
    ),
  );
}
