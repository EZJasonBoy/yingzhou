import 'package:shared_preferences/shared_preferences.dart';

/// Small local preferences of this client (which engine, which site). Everything else lives in the engine.
abstract class SettingsStore {
  String? getString(String key);
  Future<void> setString(String key, String value);
}

class SharedPreferencesSettings implements SettingsStore {
  SharedPreferencesSettings._(this._prefs);

  final SharedPreferences _prefs;

  static Future<SharedPreferencesSettings> load() async => SharedPreferencesSettings._(await SharedPreferences.getInstance());

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  Future<void> setString(String key, String value) => _prefs.setString(key, value);
}

class MemorySettings implements SettingsStore {
  final _values = <String, String>{};

  @override
  String? getString(String key) => _values[key];

  @override
  Future<void> setString(String key, String value) async => _values[key] = value;
}
