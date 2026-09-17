// lib/services/cache_service.dart
// Auto-cache logic — jab koi song play hota hai to cache ho jaata hai,
// aur limit cross hone pe sabse purani unprotected (non-liked) file hat jaati hai.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/cache_db.dart';
import '../models/song.dart';

class CacheService extends ChangeNotifier {
  CacheService._internal();
  static final CacheService instance = CacheService._internal();

  static const int defaultLimitBytes = 3 * 1024 * 1024 * 1024; // 3GB (user ki request pe 2GB se badhaya)
  static const String _keyLimit = 'cache_limit_bytes';
  static const String _keyWifiOnly = 'cache_wifi_only';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _prefsInstance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  // Cache folder — app ke temporary/cache directory ke andar
  Future<Directory> getAudioCacheDir() async {
    final baseDir = await getTemporaryDirectory();
    final dir = Directory(p.join(baseDir.path, 'sursathi_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // Abhi tak ka total cache size (bytes me)
  Future<int> currentSize() async {
    return CacheDB.instance.totalSize();
  }

  // Cache limit — user setting se, default 2GB
  Future<int> getLimitBytes() async {
    final prefs = await _prefsInstance;
    return prefs.getInt(_keyLimit) ?? defaultLimitBytes;
  }

  Future<void> setLimit(int bytes) async {
    final prefs = await _prefsInstance;
    await prefs.setInt(_keyLimit, bytes);
    await enforceLimit();
    notifyListeners();
  }

  Future<bool> isWifiOnly() async {
    final prefs = await _prefsInstance;
    return prefs.getBool(_keyWifiOnly) ?? true;
  }

  Future<void> setWifiOnly(bool value) async {
    final prefs = await _prefsInstance;
    await prefs.setBool(_keyWifiOnly, value);
    notifyListeners();
  }

  // Song ko cache me daalo — pehle size check, fir DB entry, fir limit enforce
  Future<void> cacheSong(Song song, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return;
    final size = await file.length();

    await CacheDB.instance.add(song: song, filePath: filePath, size: size);
    await enforceLimit();
    notifyListeners();
  }

  // Jab tak size limit se zyada hai, sabse purani unprotected entry hatao
  // (protected=1 matlab liked song — kabhi delete nahi hogi)
  Future<void> enforceLimit() async {
    final limit = await getLimitBytes();
    var total = await currentSize();

    while (total > limit) {
      final oldest = await CacheDB.instance.getOldestUnprotected();
      if (oldest == null) break; // sab protected hai, aur kuch nahi hata sakte

      final filePath = oldest['file_path'] as String?;
      final id = oldest['id'] as String;
      final size = (oldest['size'] as num?)?.toInt() ?? 0;

      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      await CacheDB.instance.delete(id);
      total -= size;
    }
  }

  // Poora cache clear karo — liked (protected) songs ko chhod ke
  Future<void> clearAll() async {
    final entries = await CacheDB.instance.getAll();
    for (final entry in entries) {
      final protected = (entry['protected'] as int? ?? 0) == 1;
      if (protected) continue; // liked songs ki file safe rakho

      final filePath = entry['file_path'] as String?;
      if (filePath != null) {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      }
      await CacheDB.instance.delete(entry['id'] as String);
    }
    notifyListeners();
  }
}
