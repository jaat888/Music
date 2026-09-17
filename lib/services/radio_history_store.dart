// lib/services/radio_history_store.dart
// Part 8 (Radio Mode) — Phase 2: Data layer (radio_history).
// Standalone file, koi protected pipeline file touch nahi hua.
//
// Roadmap section 3.1: har entry {songId, title, tags, language, playedAt,
// wasSkipped, skipPositionSec}. SharedPreferences me ek JSON list ke roop
// me store hota hai — bilkul equalizer_settings jaisa hi pattern (koi nayi
// SQLite table nahi, jaisa app ke doosre "settings-jaisa" data ke liye
// already use hota hai).
//
// Ye store hi non-repeat rule (roadmap section 5) enforce karne ke liye
// query helpers deta hai — actual candidate-pool building/scoring Phase 3
// (`radio_engine.dart`) ka kaam hoga, yahan sirf data + purge + simple
// lookups hain.
import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// Ek "gaana bajaya gaya" record. `wasSkipped`/`skipPositionSec` sirf
/// tab meaningful hain jab entry ek skip event ke liye likhi gayi ho —
/// poora sun liye gaane ke liye `wasSkipped=false`, `skipPositionSec=null`.
class RadioHistoryEntry {
  final String songId;
  final String title;
  final List<String> tags;
  final String language;
  final DateTime playedAt;
  final bool wasSkipped;
  final int? skipPositionSec;

  const RadioHistoryEntry({
    required this.songId,
    required this.title,
    required this.tags,
    required this.language,
    required this.playedAt,
    required this.wasSkipped,
    this.skipPositionSec,
  });

  factory RadioHistoryEntry.fromJson(Map<String, dynamic> json) {
    return RadioHistoryEntry(
      songId: json['songId'] as String,
      title: json['title'] as String? ?? '',
      tags: (json['tags'] as List?)?.cast<String>() ?? const [],
      language: json['language'] as String? ?? '',
      playedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['playedAt'] as num?)?.toInt() ?? 0,
      ),
      wasSkipped: json['wasSkipped'] as bool? ?? false,
      skipPositionSec: (json['skipPositionSec'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'songId': songId,
      'title': title,
      'tags': tags,
      'language': language,
      'playedAt': playedAt.millisecondsSinceEpoch,
      'wasSkipped': wasSkipped,
      'skipPositionSec': skipPositionSec,
    };
  }
}

class RadioHistoryStore {
  RadioHistoryStore._internal();
  static final RadioHistoryStore instance = RadioHistoryStore._internal();

  static const String _kPrefsKey = 'radio_history';

  // Roadmap section 5: "4-6 mahine tak koi gana repeat nahi" — 150 din
  // (~5 mahine) is range ke beech ka safe default.
  static const Duration maxAge = Duration(days: 150);

  final List<RadioHistoryEntry> _entries = [];
  bool _initialized = false;

  List<RadioHistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _entries
          ..clear()
          ..addAll(
            list.map((e) => RadioHistoryEntry.fromJson(e as Map<String, dynamic>)),
          );
      } catch (_) {
        // Corrupt data — khaali history se hi shuru kar do, crash nahi.
        _entries.clear();
      }
    }
    _initialized = true;
    // App start pe hi purani entries purge kar do (roadmap: "app start pe
    // ya periodically 4-6 mahine se purane entries auto-delete").
    await purgeOld();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kPrefsKey,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }

  /// `maxAge` se purani entries hata do. Non-repeat window isi list se
  /// enforce hoti hai, isliye purge hote hi wo gaane wapas "naya" (pool
  /// me eligible) ho jaate hain.
  Future<void> purgeOld() async {
    final cutoff = DateTime.now().subtract(maxAge);
    final before = _entries.length;
    _entries.removeWhere((e) => e.playedAt.isBefore(cutoff));
    if (_entries.length != before) {
      await _persist();
    }
  }

  /// Ek naya play/skip record add karo.
  Future<void> record({
    required String songId,
    required String title,
    required List<String> tags,
    required String language,
    required bool wasSkipped,
    int? skipPositionSec,
  }) async {
    if (!_initialized) await init();
    _entries.add(
      RadioHistoryEntry(
        songId: songId,
        title: title,
        tags: tags,
        language: language,
        playedAt: DateTime.now(),
        wasSkipped: wasSkipped,
        skipPositionSec: skipPositionSec,
      ),
    );
    await _persist();
  }

  /// Non-repeat check (roadmap section 5) — kya ye songId `maxAge` window
  /// ke andar already bajaya ja chuka hai (skip ho ya poora suna ho, dono
  /// count hoti hain — dobara nahi bajana).
  bool wasPlayedRecently(String songId) {
    return _entries.any((e) => e.songId == songId);
  }

  /// Fallback (roadmap section 5): pool bahut chhota pad jaaye to "sabse
  /// purana bajaya gaya" gaana wapas eligible karne ke liye — caller ye
  /// songIds use karke apne candidate pool me se exclusion hata sakta hai.
  /// Sabse purana (jaldi wapas eligible hone laayak) pehle aata hai.
  List<String> oldestPlayedSongIds({int limit = 20}) {
    final sorted = [..._entries]..sort((a, b) => a.playedAt.compareTo(b.playedAt));
    return sorted.map((e) => e.songId).toSet().take(limit).toList();
  }

  /// Marks the most recent play event for [songId] as skipped instead of
  /// adding a second, contradictory history row.
  Future<void> markLatestAsSkipped({
    required String songId,
    required int skipPositionSec,
  }) async {
    if (!_initialized) await init();
    for (var i = _entries.length - 1; i >= 0; i--) {
      final entry = _entries[i];
      if (entry.songId != songId) continue;
      _entries[i] = RadioHistoryEntry(
        songId: entry.songId,
        title: entry.title,
        tags: entry.tags,
        language: entry.language,
        playedAt: entry.playedAt,
        wasSkipped: true,
        skipPositionSec: math.max(0, skipPositionSec),
      );
      await _persist();
      return;
    }
  }

  /// Sirf testing/debug/reset ke liye — poori history clear karo.
  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }
}
