// lib/screens/smart_playlist_screen.dart
// Part 3 (Library smarts) — "smart auto-playlists" jo koi manual playlist
// nahi hain, balki existing data (play_history + liked/cache/download pool)
// se automatically compute hote hain: Most Played, Never Played, Downloaded
// Only. Teeno ek hi generic screen share karte hain (mode param se) taaki
// look/behaviour consistent rahe aur code duplicate na ho.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/cache_db.dart';
import '../db/download_db.dart';
import '../db/liked_db.dart';
import '../db/play_history_db.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../services/download_queue_service.dart';
import '../services/youtube_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/shimmer_song_card.dart';
import '../widgets/song_card.dart';

enum SmartPlaylistMode { mostPlayed, neverPlayed, downloadedOnly }

class SmartPlaylistScreen extends StatefulWidget {
  final SmartPlaylistMode mode;
  const SmartPlaylistScreen({super.key, required this.mode});

  @override
  State<SmartPlaylistScreen> createState() => _SmartPlaylistScreenState();
}

class _SmartPlaylistScreenState extends State<SmartPlaylistScreen> {
  bool _loading = true;
  List<Song> _songs = [];
  // song_id -> play count, sirf "Most Played" mode me use hota hai
  // (subtitle me "N plays" dikhane ke liye).
  final Map<String, int> _playCounts = {};
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};

  String get _title {
    switch (widget.mode) {
      case SmartPlaylistMode.mostPlayed:
        return 'Most Played';
      case SmartPlaylistMode.neverPlayed:
        return 'Never Played';
      case SmartPlaylistMode.downloadedOnly:
        return 'Downloaded Only';
    }
  }

  String get _emptyMessage {
    switch (widget.mode) {
      case SmartPlaylistMode.mostPlayed:
        return 'Abhi tak kuch bhi baar-baar play nahi hua';
      case SmartPlaylistMode.neverPlayed:
        return 'Sab kuch kam se kam ek baar play ho chuka hai';
      case SmartPlaylistMode.downloadedOnly:
        return 'Koi song download nahi hai';
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Liked + Cache + Download — merge karke ek id->Song pool banao (jaisa
  // stats_screen.dart/playlist_db.dart pehle se karte hain), taaki "Never
  // Played" poori library dekh sake, sirf downloads/liked hi nahi.
  Future<Map<String, Song>> _libraryPool() async {
    final pool = <String, Song>{};
    for (final s in await LikedDB.instance.getAll()) {
      pool[s.id] = s;
    }
    for (final row in await CacheDB.instance.getAll()) {
      final s = Song.fromMap(row);
      pool.putIfAbsent(s.id, () => s);
    }
    for (final s in await DownloadDB.instance.getAll()) {
      pool.putIfAbsent(s.id, () => s);
    }
    return pool;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      List<Song> songs;
      _playCounts.clear();
      switch (widget.mode) {
        case SmartPlaylistMode.mostPlayed:
          final mostPlayed = await PlayHistoryDB.instance.getMostPlayed(limit: 100);
          songs = mostPlayed.map((e) => e.key).toList();
          for (final e in mostPlayed) {
            _playCounts[e.key.id] = e.value;
          }
          break;
        case SmartPlaylistMode.neverPlayed:
          final pool = await _libraryPool();
          final playedIds = await PlayHistoryDB.instance.getPlayedIds();
          songs = pool.values.where((s) => !playedIds.contains(s.id)).toList();
          break;
        case SmartPlaylistMode.downloadedOnly:
          songs = await DownloadDB.instance.getAll();
          break;
      }
      final liked = await LikeService.instance.getAllLiked();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
    } catch (e) {
      print('SMART_PLAYLIST(${widget.mode}) _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playFrom(int index) async {
    context.read<QueueService>().setQueue(_songs, startIndex: index);
    final song = _songs[index];
    final localPath = await DownloadDB.instance.getFilePath(song.id) ??
        await CacheDB.instance.getFilePath(song.id);
    if (localPath != null) {
      await audioHandler.playFromFile(song, localPath);
    } else {
      await audioHandler.playWithRetry(song);
    }
  }

  // BUG FIX (v37 — download queue/progress visibility): shared
  // DownloadQueueService use karte hain.
  Future<void> _download(Song song) async {
    if (DownloadQueueService.instance.isActive(song.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${song.title}" already download queue mein hai')),
      );
      return;
    }
    DownloadQueueService.instance.enqueue(song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${song.title}" download queue mein daal diya')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(_title, style: AppText.displayM(color: kGreen).copyWith(fontSize: 20)),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: kGreen,
          backgroundColor: kBgElev,
          child: _loading ? _buildShimmer() : _buildBody(),
        ),
      ),
    );
  }

  Widget _buildShimmer() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: List.generate(5, (_) => const ShimmerSongCard()),
    );
  }

  Widget _buildBody() {
    if (_songs.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 80),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.auto_awesome, color: kTextDim, size: 48),
                const SizedBox(height: 10),
                Text(_emptyMessage, style: AppText.bodyM(color: kTextDim), textAlign: TextAlign.center),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _songs.length,
      itemBuilder: (context, i) {
        final song = _songs[i];
        final count = _playCounts[song.id];
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (count != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 2),
                  child: Text(
                    '$count ${count == 1 ? 'play' : 'plays'}',
                    style: AppText.bodyS(color: kGreen),
                  ),
                ),
              SongCard(
                song: song,
                isLiked: _likedIds.contains(song.id),
                isCached: _cachedIds.contains(song.id),
                isDownloaded: widget.mode == SmartPlaylistMode.downloadedOnly,
                onTap: () => _playFrom(i),
                onPlay: () => _playFrom(i),
                onDownload: () => _download(song),
                onLike: () async {
                  await context.read<LikeService>().toggleLike(song);
                  if (!mounted) return;
                  setState(() {
                    if (_likedIds.contains(song.id)) {
                      _likedIds.remove(song.id);
                    } else {
                      _likedIds.add(song.id);
                    }
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
