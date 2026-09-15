// lib/db/playlist_db.dart
// User playlists aur unke songs ka mapping store karta hai.
//
// BATCH 14B: description + is_private columns (playlists table) aur
// title/artist/thumb/duration columns (playlist_songs table) add kiye.
// DB version 1 -> 2, onUpgrade me try-catch ke saath ALTER TABLE (agar
// column pehle se exist karta hai to bhi crash nahi hoga).

import 'package:sqflite/sqflite.dart';

import '../models/playlist.dart';
import '../models/song.dart';
import 'liked_db.dart';
import 'cache_db.dart';
import 'download_db.dart';
import 'app_database.dart';

class PlaylistDB {
  PlaylistDB._internal();
  static final PlaylistDB instance = PlaylistDB._internal();

  static const String _playlistsTable = 'playlists';
  static const String _songsTable = 'playlist_songs';

  // FIX: ab apna alag openDatabase() nahi karte — sabke sabhi tables (aur
  // playlist ka v1->v2 column migration) ek hi jagah (AppDatabase) me
  // guaranteed chalte hain. Dekho db/app_database.dart.
  Future<Database> get _database => AppDatabase.instance.database;

  // Nayi playlist banao (songIds khali list ke saath shuru hoti hai)
  Future<void> createPlaylist(Playlist playlist) async {
    final db = await _database;
    await db.insert(
      _playlistsTable,
      playlist.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Existing playlist ke selected fields update karo — jo field null pass
  // hoga wo touch nahi hoga (baaki purane value pe hi rahega).
  Future<void> updatePlaylist(
    String id, {
    String? name,
    String? description,
    String? coverEmoji,
    String? coverGradient,
    bool? isPrivate,
    bool? isCollaborative,
  }) async {
    final db = await _database;
    final values = <String, dynamic>{};
    if (name != null) values['name'] = name;
    if (description != null) values['description'] = description;
    if (coverEmoji != null) values['cover_emoji'] = coverEmoji;
    if (coverGradient != null) values['cover_gradient'] = coverGradient;
    if (isPrivate != null) values['is_private'] = isPrivate ? 1 : 0;
    if (isCollaborative != null) {
      values['is_collaborative'] = isCollaborative ? 1 : 0;
    }
    if (values.isEmpty) return; // kuch update karne layak nahi hai

    await db.update(
      _playlistsTable,
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Playlist ko private/public mark karo (quick toggle ke liye)
  Future<void> setPrivate(String id, bool isPrivate) async {
    final db = await _database;
    await db.update(
      _playlistsTable,
      {'is_private': isPrivate ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // Saari playlists laao (songIds bhi fill karke)
  Future<List<Playlist>> getAllPlaylists() async {
    final db = await _database;
    final rows = await db.query(_playlistsTable, orderBy: 'created_at DESC');

    final playlists = <Playlist>[];
    for (final row in rows) {
      final songIds = await _getSongIdsOnly(row['id'] as String);
      playlists.add(Playlist.fromMap(row, songIds: songIds));
    }
    return playlists;
  }

  // Ek specific playlist uski songIds ke saath
  Future<Playlist?> getPlaylist(String id) async {
    final db = await _database;
    final rows = await db.query(
      _playlistsTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final songIds = await _getSongIdsOnly(id);
    return Playlist.fromMap(rows.first, songIds: songIds);
  }

  // Playlist me song add karo — position aakhir me set hoti hai.
  // Ab poora Song object accept karta hai taaki title/artist/thumb/duration
  // bhi playlist_songs table me hi save ho jayein (purane sirf-id wale
  // design me har baar Liked/Cache/Download DB me dhoondhna padta tha).
  Future<void> addSongToPlaylist(String playlistId, Song song) async {
    final db = await _database;
    final existing = await db.query(
      _songsTable,
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    final nextPosition = existing.length;

    await db.insert(
      _songsTable,
      {
        'playlist_id': playlistId,
        'song_id': song.id,
        'position': nextPosition,
        'added_at': DateTime.now().millisecondsSinceEpoch,
        'title': song.title,
        'artist': song.artist,
        'thumb': song.thumb,
        'duration': song.duration,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Playlist se song hatao
  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final db = await _database;
    await db.delete(
      _songsTable,
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
    );
  }

  // Check karo ki ek song is playlist me already hai ya nahi
  Future<bool> isSongInPlaylist(String playlistId, String songId) async {
    final db = await _database;
    final rows = await db.query(
      _songsTable,
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  // Songs ka naya order save karo (drag-drop reorder ke baad)
  Future<void> reorderSongs(String playlistId, List<String> orderedSongIds) async {
    final db = await _database;
    final batch = db.batch();
    for (var i = 0; i < orderedSongIds.length; i++) {
      batch.update(
        _songsTable,
        {'position': i},
        where: 'playlist_id = ? AND song_id = ?',
        whereArgs: [playlistId, orderedSongIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  // Poori playlist delete karo (uske songs mapping samet)
  Future<void> deletePlaylist(String id) async {
    final db = await _database;
    await db.delete(_playlistsTable, where: 'id = ?', whereArgs: [id]);
    await db.delete(_songsTable, where: 'playlist_id = ?', whereArgs: [id]);
  }

  // Sirf song ids, position ke hisaab se sorted — Playlist.songIds field
  // fill karne ke liye internal use (ye List<String> hi rehti hai kyunki
  // Playlist model ka songIds field List<String> hai).
  Future<List<String>> _getSongIdsOnly(String playlistId) async {
    final db = await _database;
    final rows = await db.query(
      _songsTable,
      columns: ['song_id'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position ASC',
    );
    return rows.map((row) => row['song_id'] as String).toList();
  }

  // Playlist ki poori Song list, position ke hisaab se sorted.
  //
  // Purane data ke liye fallback: agar kisi row me title khali hai (yani
  // wo song is table ke naye columns aane se pehle add hua tha), to us
  // song ko LikedDB / CacheDB / DownloadDB me dhoond ke resolve karte hain.
  // Agar wahan bhi na mile to silently skip ho jaata hai (jaisa pehle
  // playlist_detail_screen ke _resolveSongs me hota tha).
  Future<List<Song>> getPlaylistSongs(String playlistId) async {
    final db = await _database;
    final rows = await db.query(
      _songsTable,
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position ASC',
    );

    Map<String, Song>? fallbackPool;
    Future<Map<String, Song>> loadFallbackPool() async {
      if (fallbackPool != null) return fallbackPool!;
      final pool = <String, Song>{};
      for (final s in await LikedDB.instance.getAll()) {
        pool[s.id] = s;
      }
      for (final row in await CacheDB.instance.getAll()) {
        pool.putIfAbsent(row['id'] as String, () => Song.fromMap(row));
      }
      for (final s in await DownloadDB.instance.getAll()) {
        pool.putIfAbsent(s.id, () => s);
      }
      fallbackPool = pool;
      return pool;
    }

    final songs = <Song>[];
    for (final row in rows) {
      final songId = row['song_id'] as String;
      final title = row['title'] as String?;

      if (title != null && title.isNotEmpty) {
        // Naya data — sab kuch playlist_songs table me hi mil gaya
        songs.add(Song(
          id: songId,
          title: title,
          artist: row['artist'] as String? ?? 'Unknown Artist',
          thumb: row['thumb'] as String? ?? '',
          duration: (row['duration'] as num?)?.toInt() ?? 0,
        ));
      } else {
        // Purana data — fallback DBs se resolve karne ki koshish karo
        final pool = await loadFallbackPool();
        final resolved = pool[songId];
        if (resolved != null) songs.add(resolved);
      }
    }
    return songs;
  }
}
