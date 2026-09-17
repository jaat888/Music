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
    return rows.map((row) => Song.fromMap(row)).toList();
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
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
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
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) return null; // DB me hai par file gayab
    return path;
  }
}
