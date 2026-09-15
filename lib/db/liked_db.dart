// lib/db/liked_db.dart
// Liked songs ka local storage — sqflite use karke.

import 'package:sqflite/sqflite.dart';

import '../models/song.dart';
import 'app_database.dart';

class LikedDB {
  LikedDB._internal();
  static final LikedDB instance = LikedDB._internal();

  static const String _table = 'liked';

  // FIX: ab apna alag openDatabase() nahi karte — sabke sabhi tables ek hi
  // jagah (AppDatabase) me guaranteed create hote hain. Dekho db/app_database.dart.
  Future<Database> get _database => AppDatabase.instance.database;

  // Saare liked songs, sabse naye pehle
  Future<List<Song>> getAll() async {
    final db = await _database;
    final rows = await db.query(_table, orderBy: 'liked_at DESC');
    return rows.map((row) => Song.fromMap(row)).toList();
  }

  // Song ko liked me add karo (agar already hai to replace ho jayega)
  Future<void> add(Song song) async {
    final db = await _database;
    await db.insert(
      _table,
      {
        'id': song.id,
        'title': song.title,
        'artist': song.artist,
        'thumb': song.thumb,
        'duration': song.duration,
        'liked_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Liked se hata do
  Future<void> remove(String id) async {
    final db = await _database;
    await db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  // Check karo ki song liked hai ya nahi
  Future<bool> isLiked(String id) async {
    final db = await _database;
    final rows = await db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // Saare liked songs clear kar do
  Future<void> clearAll() async {
    final db = await _database;
    await db.delete(_table);
  }
}
