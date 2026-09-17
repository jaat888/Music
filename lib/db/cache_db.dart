// lib/db/cache_db.dart
// Cached audio files ka tracking — jab cache full ho to purani files
// (jo protected nahi hain) hataane ke kaam aata hai.

import 'dart:io';

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
  }) async {
    final db = await _database;
    final now = DateTime.now().millisecondsSinceEpoch;
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
        'last_played': now,
        'protected': 0,
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

  // NEW (2026-09-17) — cache entry ka poora record (title/artist/thumb/
  // duration samet), sirf file-path nahi — download-from-cache fix ke
  // liye chahiye (dekho youtube_service.dart download()).
  Future<Map<String, dynamic>?> getRow(String id) async {
    final db = await _database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final path = rows.first['file_path'] as String?;
    if (path == null || path.isEmpty || !await File(path).exists()) return null;
    return rows.first;
  }

  // NEW: cached file ka path do agar file abhi bhi disk pe maujood hai —
  // local-first playback (network resolve se bhi pehle check hota hai).
  Future<String?> getFilePath(String id) async {
    final db = await _database;
    final rows = await db.query(_table, where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final path = rows.first['file_path'] as String?;
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  // Sabse purani unprotected entry — cache eviction ke liye
  Future<Map<String, dynamic>?> getOldestUnprotected() async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'protected = ?',
      whereArgs: [0],
      orderBy: 'last_played ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // Entry ko protected mark karo — auto-delete se bach jayegi
  Future<void> markProtected(String id) async {
    final db = await _database;
    await db.update(
      _table,
      {'protected': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Poora cache table clear kar do
  Future<void> clearAll() async {
    final db = await _database;
    await db.delete(_table);
  }
}
