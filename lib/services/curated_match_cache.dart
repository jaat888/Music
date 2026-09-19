// lib/services/curated_match_cache.dart
//
// "title + artist" -> YouTube match ka persistent cache.
//
// PROBLEM (user report): iTunes "India Top Songs" chart ka list to daily
// cache hota tha, lekin CuratedPlaylistScreen har baar playlist kholne par
// 50 ke 50 gaane dobara YouTube pe ek-ek karke search karta tha
// ("Match kar rahe hain 1/50 ..."), isliye playlist har baar naye sire se load
// hoti dikhti thi. Ab har successful match yahan disk pe save hota hai, aur
// agli baar playlist khulte hi cache se instantly aati hai — network sirf
// un gaano ke liye jo pehle kabhi match nahi hue (jaise chart me naya gaana).
//
// JioSaavn playlists bhi isi cache se fayda uthati hain (same screen).
// Match na hone wale gaane cache nahi hote, taaki agli baar phir try ho.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

class _Entry {
  final Song song;
  final int savedAtMs;
  const _Entry(this.song, this.savedAtMs);
}

class CuratedMatchCache {
  CuratedMatchCache({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static final CuratedMatchCache instance = CuratedMatchCache();

  static const String _prefsKey = 'curated_yt_match_v1';

  /// YouTube video id lambe time tak valid rehte hain; phir bhi 45 din baad
  /// entry expire karke fresh match lete hain.
  static const Duration maxAge = Duration(days: 45);
  static const int maxEntries = 500;

  final DateTime Function() _clock;
  final Map<String, _Entry> _entries = <String, _Entry>{};
  Future<void>? _loading;
  bool _dirty = false;

  /// Title/artist ka normalized key (case + extra spaces ignore).
  static String keyFor(String title, String artist) {
    String n(String v) =>
        v.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${n(title)}|${n(artist)}';
  }

  /// Disk se ek baar load (baar-baar call safe hai).
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        try {
          final s = value['s'];
          final t = value['t'];
          if (s is! Map || t is! num) return;
          _entries.putIfAbsent(
            key,
            () => _Entry(Song.fromJson(Map<String, dynamic>.from(s)), t.toInt()),
          );
        } catch (_) {
          // Ek kharab entry poore cache ko kharab na kare.
        }
      });
    } catch (_) {}
  }

  /// Cached match (ensureLoaded ke baad). Expire ho chuka ho to null.
  Song? get(String title, String artist) {
    final entry = _entries[keyFor(title, artist)];
    if (entry == null) return null;
    final age = _clock().millisecondsSinceEpoch - entry.savedAtMs;
    if (age > maxAge.inMilliseconds) return null;
    return entry.song;
  }

  /// Memory me daalta hai; disk pe `flush()` se jaata hai.
  void put(String title, String artist, Song song) {
    _entries[keyFor(title, artist)] =
        _Entry(song, _clock().millisecondsSinceEpoch);
    _dirty = true;
  }

  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      final now = _clock().millisecondsSinceEpoch;
      _entries.removeWhere(
        (_, e) => now - e.savedAtMs > maxAge.inMilliseconds,
      );
      if (_entries.length > maxEntries) {
        final sorted = _entries.entries.toList()
          ..sort((a, b) => b.value.savedAtMs.compareTo(a.value.savedAtMs));
        for (final e in sorted.skip(maxEntries)) {
          _entries.remove(e.key);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          for (final e in _entries.entries)
            e.key: {'s': e.value.song.toJson(), 't': e.value.savedAtMs},
        }),
      );
    } catch (_) {
      _dirty = true;
    }
  }
}
