// lib/services/theme_service.dart
// User ke theme preferences (mode, accent color, font scale) manage karta hai.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Accent color options — Settings screen me isi list se choose hoga
enum AccentOption { green, blue, purple, pink, orange }

extension AccentOptionColor on AccentOption {
  Color get color {
    switch (this) {
      case AccentOption.green:
        return const Color(0xFF1DB954);
      case AccentOption.blue:
        return const Color(0xFF1E90FF);
      case AccentOption.purple:
        return const Color(0xFF7C6CF0);
      case AccentOption.pink:
        return const Color(0xFFFF6BD6);
      case AccentOption.orange:
        return const Color(0xFFFF9F43);
    }
  }
}

class ThemeService extends ChangeNotifier {
  ThemeService._internal();
  static final ThemeService instance = ThemeService._internal();

  static const String _keyThemeMode = 'theme_mode';
  static const String _keyAccent = 'accent_color';
  static const String _keyFontScale = 'font_scale';
  static const String _keyAnimationSpeed = 'animation_speed';
  static const String _keyDynamicColors = 'dynamic_colors';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _prefsInstance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // ---------------- Theme mode ----------------

  Future<ThemeMode> getThemeMode() async {
    final prefs = await _prefsInstance;
    final value = prefs.getString(_keyThemeMode) ?? 'dark';
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.dark; // SurSathi default dark hi rahega
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    final prefs = await _prefsInstance;
    await prefs.setString(_keyThemeMode, mode.name);
    notifyListeners();
  }

  // ---------------- Accent color ----------------

  Future<AccentOption> getAccent() async {
    final prefs = await _prefsInstance;
    final value = prefs.getString(_keyAccent) ?? AccentOption.green.name;
    return AccentOption.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AccentOption.green,
    );
  }

  Future<void> setAccent(AccentOption accent) async {
    final prefs = await _prefsInstance;
    await prefs.setString(_keyAccent, accent.name);
    notifyListeners();
  }

  // ---------------- Font scale ----------------

  Future<double> getFontScale() async {
    final prefs = await _prefsInstance;
    return prefs.getDouble(_keyFontScale) ?? 1.0;
  }

  Future<void> setFontScale(double scale) async {
    final prefs = await _prefsInstance;
    await prefs.setDouble(_keyFontScale, scale);
    notifyListeners();
  }

  // ---------------- Animation speed ----------------
  // 1.0 = normal, 0.5 = slow (motion-sensitive users ke liye), 1.5 = fast

  Future<double> getAnimationSpeed() async {
    final prefs = await _prefsInstance;
    return prefs.getDouble(_keyAnimationSpeed) ?? 1.0;
  }

  Future<void> setAnimationSpeed(double speed) async {
    final prefs = await _prefsInstance;
    await prefs.setDouble(_keyAnimationSpeed, speed);
    notifyListeners();
  }

  // ---------------- Dynamic colors (Material You) ----------------

  Future<bool> isDynamicColors() async {
    final prefs = await _prefsInstance;
    return prefs.getBool(_keyDynamicColors) ?? false;
  }

  Future<void> setDynamicColors(bool value) async {
    final prefs = await _prefsInstance;
    await prefs.setBool(_keyDynamicColors, value);
    notifyListeners();
  }
}
