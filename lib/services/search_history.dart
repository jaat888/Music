// lib/services/search_history.dart
// Recent searches store karta hai — search screen pe suggestions ke liye.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistory extends ChangeNotifier {
  SearchHistory._internal();
  static final SearchHistory instance = SearchHistory._internal();

  static const String _key = 'search_history';
  static const int _maxEntries = 20;

  SharedPreferences? _prefs;
  List<String> _history = [];
  bool _loaded = false;

  Future<SharedPreferences> get _prefsInstance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final prefs = await _prefsInstance;
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw) as List<dynamic>;
      _history = decoded.map((e) => e.toString()).toList();
    }
    _loaded = true;
  }

  Future<void> _save() async {
    final prefs = await _prefsInstance;
    await prefs.setString(_key, jsonEncode(_history));
  }

  // Nayi search add karo — duplicate ho to top pe move ho jaayegi
  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    await _load();

    _history.removeWhere((e) => e.toLowerCase() == trimmed.toLowerCase());
    _history.insert(0, trimmed);

    if (_history.length > _maxEntries) {
      _history = _history.sublist(0, _maxEntries);
    }

    await _save();
    notifyListeners();
  }

  Future<List<String>> getAll() async {
    await _load();
    return List.unmodifiable(_history);
  }

  Future<void> remove(String query) async {
    await _load();
    _history.removeWhere((e) => e.toLowerCase() == query.toLowerCase());
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    await _load();
    _history.clear();
    await _save();
    notifyListeners();
  }
}
