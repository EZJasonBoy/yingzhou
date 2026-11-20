import 'package:material_ui/material_ui.dart';

import '../settings.dart';

const _seed = Color(0xFF4F8CFF);

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

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: Brightness.dark).copyWith(
    surface: const Color(0xFF111318),
    surfaceContainerLowest: const Color(0xFF0B0D11),
    surfaceContainerLow: const Color(0xFF15181E),
    surfaceContainer: const Color(0xFF1A1D24),
    surfaceContainerHigh: const Color(0xFF20242C),
    surfaceContainerHighest: const Color(0xFF272B34),
  );
  return _build(scheme);
}

ThemeData buildLightTheme() => _build(ColorScheme.fromSeed(seedColor: _seed));

/// Chinese text: without these, Windows picks a font per run of text, and a title with a character that only the
/// simplified fonts have (纸, 页, 盘 …) comes out in another, lighter typeface than the title next to it.
const _cjkFallback = ['Microsoft YaHei UI', 'Microsoft YaHei', 'PingFang SC', 'Noto Sans CJK SC', 'Noto Sans SC'];

ThemeData _build(ColorScheme scheme) => ThemeData(
      colorScheme: scheme,
      fontFamilyFallback: _cjkFallback,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
        showCheckmark: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primaryContainer,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primaryContainer,
      ),
      tabBarTheme: TabBarThemeData(
        dividerColor: Colors.transparent,
        tabAlignment: TabAlignment.start,
        labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 15),
      ),
    );
