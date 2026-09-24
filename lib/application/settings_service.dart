import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Aparência do controle.
enum AppThemeMode {
  light('Claro'),
  dark('Escuro'),
  highContrast('Alto contraste');

  const AppThemeMode(this.label);
  final String label;
}

/// Preferências não sensíveis do app.
class SettingsService extends ChangeNotifier {
  static const _themeKey = 'kremote.theme';
  static const _hapticsKey = 'kremote.haptics';

  AppThemeMode _theme = AppThemeMode.dark;
  bool _haptics = true;

  AppThemeMode get theme => _theme;
  bool get haptics => _haptics;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final t = p.getString(_themeKey);
    _theme = AppThemeMode.values.where((e) => e.name == t).firstOrNull ?? AppThemeMode.dark;
    _haptics = p.getBool(_hapticsKey) ?? true;
    notifyListeners();
  }

  Future<void> setTheme(AppThemeMode t) async {
    _theme = t;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_themeKey, t.name);
  }

  Future<void> setHaptics(bool v) async {
    _haptics = v;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(_hapticsKey, v);
  }
}
