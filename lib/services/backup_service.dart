// lib/services/backup_service.dart
// Part 4 — Playlists + Liked songs ko ek JSON file me export/import karna,
// taaki phone change/reinstall pe user ka data na khoye. Sirf DB-level
// data hai (playlists + playlist_songs + liked) — downloaded/cached audio
// files khud shamil nahi hain (wo phone-specific hain, dobara download
// karne padenge — playlists/likes hi asli "list" data hai jo migrate
// karne layak hai).

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../db/liked_db.dart';
import '../db/playlist_db.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class BackupSummary {
  final int playlists;
  final int playlistSongs;
  final int likedSongs;
  const BackupSummary({
    required this.playlists,
    required this.playlistSongs,
    required this.likedSongs,
  });
}

class BackupService {
  BackupService._internal();
  static final BackupService instance = BackupService._internal();

  static const int _formatVersion = 1;

  Map<String, dynamic> _songToJson(Song s) => {
        'id': s.id,
        'title': s.title,
        'artist': s.artist,
        'thumb': s.thumb,
        'duration': s.duration,
      };

  Song _songFromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as String,
        title: j['title'] as String? ?? 'Unknown',
        artist: j['artist'] as String? ?? 'Unknown Artist',
        thumb: j['thumb'] as String? ?? '',
        duration: (j['duration'] as num?)?.toInt() ?? 0,
      );

  // ---------------- Export ----------------

  Future<Map<String, dynamic>> _buildBackupMap() async {
    final liked = await LikedDB.instance.getAll();
    final playlists = await PlaylistDB.instance.getAllPlaylists();

    final playlistsJson = <Map<String, dynamic>>[];
    for (final p in playlists) {
      final songs = await PlaylistDB.instance.getPlaylistSongs(p.id);
      playlistsJson.add({
        'id': p.id,
        'name': p.name,
        'description': p.description,
        'coverEmoji': p.coverEmoji,
        'coverGradient': p.coverGradient,
        'isCollaborative': p.isCollaborative,
        'isPrivate': p.isPrivate,
        'createdAt': p.createdAt.millisecondsSinceEpoch,
        'songs': songs.map(_songToJson).toList(),
      });
    }

    return {
      'app': 'SurSathi',
      'formatVersion': _formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'likedSongs': liked.map(_songToJson).toList(),
      'playlists': playlistsJson,
    };
  }

  // JSON file bana ke uska path deta hai (share_plus se share karne ke liye).
  Future<File> exportToFile() async {
    final map = await _buildBackupMap();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(map);
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File('${dir.path}/sursathi_backup_$stamp.json');
    await file.writeAsString(jsonStr);
    return file;
  }

  Future<BackupSummary> exportSummary() async {
    final liked = await LikedDB.instance.getAll();
    final playlists = await PlaylistDB.instance.getAllPlaylists();
    var songCount = 0;
    for (final p in playlists) {
      songCount += p.songIds.length;
    }
    return BackupSummary(
      playlists: playlists.length,
      playlistSongs: songCount,
      likedSongs: liked.length,
    );
  }

  // ---------------- Import ----------------

  // File padh ke sirf preview count deta hai — asli import se pehle user
  // ko confirm dialog me dikhane ke liye (kya-kya aa raha hai).
  Future<BackupSummary> previewFile(File file) async {
    final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    return _summaryFromMap(map);
  }

  BackupSummary _summaryFromMap(Map<String, dynamic> map) {
    final liked = (map['likedSongs'] as List?) ?? const [];
    final playlists = (map['playlists'] as List?) ?? const [];
    var songCount = 0;
    for (final p in playlists) {
      songCount += ((p as Map)['songs'] as List? ?? const []).length;
    }
    return BackupSummary(
      playlists: playlists.length,
      playlistSongs: songCount,
      likedSongs: liked.length,
    );
  }

  // Backup file se data restore karta hai. Ye "merge" hai, destructive
  // replace nahi — existing liked songs/playlists delete nahi hoti, backup
  // wala data unke upar add/overwrite ho jaata hai (same id ho to us
  // playlist ka meta+songs refresh ho jaate hain, warna nayi playlist ban
  // jaati hai). Isliye same backup do baar import karna bhi safe hai.
  Future<BackupSummary> importFromFile(File file) async {
    final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;

    final likedJson = (map['likedSongs'] as List?) ?? const [];
    for (final j in likedJson) {
      await LikedDB.instance.add(_songFromJson(j as Map<String, dynamic>));
    }

    final playlistsJson = (map['playlists'] as List?) ?? const [];
    for (final pj in playlistsJson) {
      final p = pj as Map<String, dynamic>;
      final playlist = Playlist(
        id: p['id'] as String,
        name: p['name'] as String? ?? 'Untitled',
        description: p['description'] as String?,
        coverEmoji: p['coverEmoji'] as String? ?? '🎵',
        coverGradient: p['coverGradient'] as String? ?? 'default',
        songIds: const [],
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (p['createdAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
        ),
        isCollaborative: p['isCollaborative'] as bool? ?? false,
        isPrivate: p['isPrivate'] as bool? ?? false,
      );
      await PlaylistDB.instance.createPlaylist(playlist);

      final songsJson = (p['songs'] as List?) ?? const [];
      for (final sj in songsJson) {
        await PlaylistDB.instance.addSongToPlaylist(
          playlist.id,
          _songFromJson(sj as Map<String, dynamic>),
        );
      }
    }

    return _summaryFromMap(map);
  }
}
