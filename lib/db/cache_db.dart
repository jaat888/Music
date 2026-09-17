// lib/db/cache_db.dart
// Cached audio files ka tracking — jab cache full ho to purani files
// (jo protected nahi hain) hataane ke kaam aata hai.

import 'dart:io';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../models/song.dart';
import 'app_database.dart';

class CacheDB {
  CacheDB._internal();
  static final CacheDB instance = CacheDB._internal();

  static const String _table = 'cache';

  // FIX: ab apna alag openDatabase() nahi karte — sabke sabhi tables ek hi
  // jagah (AppDatabase) me guaranteed create hote hain. Dekho db/app_database.dart.
  Future<Database> get _database => AppDatabase.instance.database;

  // Saari cached entries, sabse naye pehle
  Future<List<Map<String, dynamic>>> getAll() async {
    final db = await _database;
    return db.query(_table, orderBy: 'cached_at DESC');
  }

  // Naya cache entry add karo
  Future<void> add({
    required Song song,
    required String filePath,
    required int size,
    int? protectedFlag,
    bool markAsPlayed = false,
  }) async {
    final db = await _database;
    // Preserve an existing protected flag when refreshing an already-cached
    // favorite. Replacing it with protected=0 would create a small race
    // where a favorite could become evictable during recache.
    final existing = await db.query(_table, columns: ['protected'],
        where: 'id = ?', whereArgs: [song.id], limit: 1);
    final existingProtected = existing.isNotEmpty
        ? ((existing.first['protected'] as num?)?.toInt() ?? 0)
        : 0;
    final safeProtected = math.max(
      existingProtected,
      protectedFlag ?? 0,
    );

    final existingRow = await db.query(
      _table,
      columns: ['last_played'],
      where: 'id = ?',
      whereArgs: [song.id],
      limit: 1,
    );
    final oldLastPlayed = existingRow.isNotEmpty
        ? ((existingRow.first['last_played'] as num?)?.toInt() ?? 0)
        : 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastPlayed = markAsPlayed ? now : oldLastPlayed;

    await db.insert(
      _table,
      {
        'id': song.id,
        'title': song.title,
        'artist': song.artist,
        'thumb': song.thumb,
        'file_path': filePath,
        'size': size,
        'duration': song.duration,
        'cached_at': now,
        'last_played': lastPlayed,
        'protected': safeProtected,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // last_played ya size jaise fields update karne ke liye
  Future<void> update(
    String id, {
    int? lastPlayed,
    int? size,
    int? protected,
  }) async {
    final db = await _database;
    final values = <String, dynamic>{};
    if (lastPlayed != null) values['last_played'] = lastPlayed;
    if (size != null) values['size'] = size;
    if (protected != null) values['protected'] = protected;
    if (values.isEmpty) return;

    await db.update(_table, values, where: 'id = ?', whereArgs: [id]);
  }

  // Cache entry delete karo (file khud disk se alag delete karni hogi)
  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  // Poori cache ka total size (bytes me)
  Future<int> totalSize() async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT SUM(size) as total FROM $_table',
    );
    final total = result.first['total'];
    return (total as num?)?.toInt() ?? 0;
  }

  Future<bool> _looksLikeAudioFile(File file) async {
    try {
      final length = await file.length();
      if (length < 4096) return false;
      final raf = await file.open();
      try {
        final head = await raf.read(12);
        if (head.length >= 8 &&
            head[4] == 0x66 && head[5] == 0x74 &&
            head[6] == 0x79 && head[7] == 0x70) return true;
        if (head.length >= 4 &&
            head[0] == 0x1A && head[1] == 0x45 &&
            head[2] == 0xDF && head[3] == 0xA3) return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Future<Map<String, dynamic>?> getRow(String id) async {
    final db = await _database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final path = rows.first['file_path'] as String?;
    if (path == null || path.isEmpty) {
      await db.delete(_table, where: 'id = ?', whereArgs: [id]);
      return null;
    }
    final file = File(path);
    if (!await file.exists() || !await _looksLikeAudioFile(file)) {
      try { if (await file.exists()) await file.delete(); } catch (_) {}
      await db.delete(_table, where: 'id = ?', whereArgs: [id]);
      return null;
    }
    return rows.first;
  }

  Future<String?> getFilePath(String id) async {
    final row = await getRow(id);
    return row?['file_path'] as String?;
  }

  Future<int> countUnprotectedPlayed() async {
    final db = await _database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_table WHERE protected = 0 AND last_played > 0',
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>?> getOldestUnprotectedPlayed() async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'protected = ? AND last_played > ?',
      whereArgs: [0, 0],
      orderBy: 'last_played ASC, cached_at ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // Size-limit eviction can also evict prefetch-only rows when needed.
  Future<Map<String, dynamic>?> getOldestUnprotected() async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'protected = ?',
      whereArgs: [0],
      orderBy: 'last_played ASC, cached_at ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> markProtected(String id) async {
    final db = await _database;
    await db.update(_table, {'protected': 1}, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> clearAll() async {
    final db = await _database;
    await db.delete(_table);
  }
}
