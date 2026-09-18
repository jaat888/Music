// lib/db/download_db.dart
// Permanently downloaded (offline) songs ka storage — cache se alag,
// ye user ke explicit download karne pe hi delete hoti hai.

import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../models/song.dart';
import 'app_database.dart';

class DownloadDB {
  DownloadDB._internal();
  static final DownloadDB instance = DownloadDB._internal();

  static const String _table = 'downloads';

  // FIX: ab apna alag openDatabase() nahi karte — sabke sabhi tables ek hi
  // jagah (AppDatabase) me guaranteed create hote hain. Dekho db/app_database.dart.
  Future<Database> get _database => AppDatabase.instance.database;

  // Saare downloaded songs, sabse naye pehle
  Future<List<Song>> getAll() async {
    final db = await _database;
    final rows = await db.query(_table, orderBy: 'created_at DESC');
    final songs = <Song>[];
    final staleIds = <String>[];
    for (final row in rows) {
      final song = Song.fromMap(row);
      final path = song.filePath;
      if (path == null || path.isEmpty || !await File(path).exists()) {
        staleIds.add(song.id);
        continue;
      }
      songs.add(song);
    }
    if (staleIds.isNotEmpty) {
      await db.delete(_table, where: 'id IN (${List.filled(staleIds.length, '?').join(',')})', whereArgs: staleIds);
    }
    return songs;
  }

  // Song ko downloads me add karo (filePath zaroor hona chahiye)
  Future<void> add(Song song) async {
    final db = await _database;
    await db.insert(
      _table,
      {
        'id': song.id,
        'title': song.title,
        'artist': song.artist,
        'thumb': song.thumb,
        'file_path': song.filePath ?? '',
        'duration': song.duration,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Download entry hatao (file khud disk se alag delete karni hogi)
  Future<void> delete(String id) async {
    final db = await _database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  // Check karo ki song already download hai ya nahi
  Future<bool> exists(String id) async {
    // A DB row is not enough: Android can remove/move the actual file.
    // Treat a stale row as not downloaded so the user can download it again.
    return (await getFilePath(id)) != null;
  }

  // NEW: downloaded file ka path seedha do (agar file abhi bhi disk pe
  // maujood hai) — offline/local-first playback ke liye use hota hai.
  Future<String?> getFilePath(String id) async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final path = rows.first['file_path'] as String?;
    if (path == null || path.isEmpty) {
      await db.delete(_table, where: 'id = ?', whereArgs: [id]);
      return null;
    }
    if (!await File(path).exists()) {
      // Remove the stale row immediately; otherwise every future download
      // attempt would incorrectly think the song is already downloaded.
      await db.delete(_table, where: 'id = ?', whereArgs: [id]);
      return null;
    }
    return path;
  }
}
