// lib/db/play_history_db.dart
// Part 3 (Library smarts) — asli play-history table. Pehle koi bhi
// "play count" ya "recently played" sirf UI/dummy-hash based tha (dekho
// NOTES.md #14, #24) kyunki koi actual per-play record kabhi likha hi
// nahi jaata tha. Ye table har successful playback start pe ek row
// insert karti hai (background_service.dart se, sirf jab `player.play()`
// fail nahi hota) — isi se "Recently Played", "Most Played" aur
// "Never Played" teeno asli data se ban sakte hain.

import 'package:sqflite/sqflite.dart';

import '../models/song.dart';
import 'app_database.dart';

class PlayHistoryDB {
  PlayHistoryDB._internal();
  static final PlayHistoryDB instance = PlayHistoryDB._internal();

  static const String _table = 'play_history';

  Future<Database> get _database => AppDatabase.instance.database;

  // Har play ka apna row — jaanbujhke replace/upsert nahi karte, taaki
  // "Most Played" ke liye COUNT(*) sahi rahe. Fire-and-forget se call
  // hota hai (background_service.dart), isliye khud kabhi throw nahi
  // karta — history likhna fail ho to playback pe koi asar nahi padna
  // chahiye.
  Future<void> recordPlay(Song song) async {
    try {
      final db = await _database;
      await db.insert(_table, {
        'song_id': song.id,
        'title': song.title,
        'artist': song.artist,
        'thumb': song.thumb,
        'duration': song.duration,
        'played_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      // Logging/history kabhi bhi playback ko block/crash nahi karni chahiye.
    }
  }

  // "Recently Played" — har song ka sirf sabse latest play, naye-se-purane.
  Future<List<Song>> getRecent({int limit = 50}) async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT song_id, title, artist, thumb, duration, MAX(played_at) as played_at
      FROM $_table
      GROUP BY song_id
      ORDER BY played_at DESC
      LIMIT ?
    ''', [limit]);
    return rows.map(_songFromHistoryRow).toList();
  }

  // "Most Played" — total play-count ke hisaab se, sabse zyada pehle.
  Future<List<MapEntry<Song, int>>> getMostPlayed({int limit = 50}) async {
    final db = await _database;
    final rows = await db.rawQuery('''
      SELECT song_id, title, artist, thumb, duration,
             COUNT(*) as play_count, MAX(played_at) as played_at
      FROM $_table
      GROUP BY song_id
      ORDER BY play_count DESC, played_at DESC
      LIMIT ?
    ''', [limit]);
    return rows
        .map((r) => MapEntry(_songFromHistoryRow(r), (r['play_count'] as num).toInt()))
        .toList();
  }

  // Sirf un song-ids ka set jinka kabhi bhi koi play-record bana ho —
  // "Never Played" (library pool minus ye set) nikalne ke kaam aata hai.
  Future<Set<String>> getPlayedIds() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT DISTINCT song_id FROM $_table',
    );
    return rows.map((r) => r['song_id'] as String).toSet();
  }

  Future<int> playCountFor(String songId) async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as c FROM $_table WHERE song_id = ?',
      [songId],
    );
    return (result.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete(_table);
  }

  // ---------------- Part 6 (Stats/Streak gamification) ----------------
  // Real StatsScreen ke liye — pehle ye sab dummy SharedPreferences
  // counters + id.hashCode-based fake play-count se ban rahe the (koi
  // asli per-play record use hi nahi hota tha). Ab yahi play_history
  // table (jo Part 3 me bani thi) source-of-truth hai.

  Future<int> totalPlays({int? sinceMillis}) async {
    final db = await _database;
    final rows = sinceMillis == null
        ? await db.rawQuery('SELECT COUNT(*) as c FROM $_table')
        : await db.rawQuery(
            'SELECT COUNT(*) as c FROM $_table WHERE played_at >= ?',
            [sinceMillis],
          );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  // Per-play elapsed time track nahi hoti (sirf "play shuru hua" record
  // hota hai) — is liye gaane ki poori duration ko hi ek listen maan ke
  // sum karte hain. Approximation hai, par ab kam-se-kam asli play-count
  // pe based hai, random hash pe nahi.
  Future<int> totalListenedSeconds({int? sinceMillis}) async {
    final db = await _database;
    final rows = sinceMillis == null
        ? await db.rawQuery('SELECT COALESCE(SUM(duration), 0) as s FROM $_table')
        : await db.rawQuery(
            'SELECT COALESCE(SUM(duration), 0) as s FROM $_table WHERE played_at >= ?',
            [sinceMillis],
          );
    return (rows.first['s'] as num?)?.toInt() ?? 0;
  }

  Future<List<MapEntry<String, int>>> getTopArtists({
    int limit = 5,
    int? sinceMillis,
  }) async {
    final db = await _database;
    final rows = sinceMillis == null
        ? await db.rawQuery('''
            SELECT artist, COUNT(*) as c FROM $_table
            WHERE artist IS NOT NULL AND artist != ''
            GROUP BY artist ORDER BY c DESC LIMIT ?
          ''', [limit])
        : await db.rawQuery('''
            SELECT artist, COUNT(*) as c FROM $_table
            WHERE artist IS NOT NULL AND artist != '' AND played_at >= ?
            GROUP BY artist ORDER BY c DESC LIMIT ?
          ''', [sinceMillis, limit]);
    return rows
        .map((r) => MapEntry(r['artist'] as String, (r['c'] as num).toInt()))
        .toList();
  }

  // Current streak — kitne consecutive DIN (aaj ya kal tak) me kam-se-kam
  // ek play hua hai. Poori table pe GROUP BY na karke (bade libraries pe
  // mehenga) sirf recent 3000 rows dekhte hain — streak vaise bhi kisi
  // ek gap pe turant reset ho jaata hai, isliye itna kaafi hai.
  Future<int> currentStreakDays() async {
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT played_at FROM $_table ORDER BY played_at DESC LIMIT 3000',
    );
    if (rows.isEmpty) return 0;

    final playedDays = <int>{};
    for (final r in rows) {
      final ms = (r['played_at'] as num).toInt();
      final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
      playedDays.add(DateTime(d.year, d.month, d.day).millisecondsSinceEpoch);
    }

    final now = DateTime.now();
    var cursor = DateTime(now.year, now.month, now.day);
    // Aaj koi play na hua ho to bhi streak "toota" nahi maante jab tak
    // din khatam na ho jaaye — kal tak play hua ho to streak abhi bhi
    // zinda hai.
    if (!playedDays.contains(cursor.millisecondsSinceEpoch)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }

    var streak = 0;
    while (playedDays.contains(cursor.millisecondsSinceEpoch)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  // Pichle 7 dino (aaj samet) ka per-din play-count, purane-se-naye order
  // me — chart aur date-labels dono isi se banate hain (fixed Mon..Sun
  // labels nahi, kyunki wo hamesha sahi din se align nahi hote the).
  Future<List<MapEntry<DateTime, int>>> last7DaysCounts() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(const Duration(days: 6));

    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT played_at FROM $_table WHERE played_at >= ?',
      [start.millisecondsSinceEpoch],
    );

    final counts = <int, int>{
      for (var i = 0; i < 7; i++) start.add(Duration(days: i)).millisecondsSinceEpoch: 0,
    };
    for (final r in rows) {
      final ms = (r['played_at'] as num).toInt();
      final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
      final dayKey = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
      if (counts.containsKey(dayKey)) {
        counts[dayKey] = counts[dayKey]! + 1;
      }
    }
    return counts.entries
        .map((e) => MapEntry(DateTime.fromMillisecondsSinceEpoch(e.key), e.value))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
  }

  Song _songFromHistoryRow(Map<String, dynamic> row) {
    return Song(
      id: row['song_id'] as String,
      title: row['title'] as String? ?? 'Unknown',
      artist: row['artist'] as String? ?? 'Unknown Artist',
      thumb: row['thumb'] as String? ?? '',
      duration: (row['duration'] as num?)?.toInt() ?? 0,
    );
  }
}
