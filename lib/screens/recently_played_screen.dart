// lib/screens/recently_played_screen.dart
// Part 3 (Library smarts) — asli "Recently Played" (dekho NOTES.md #14,
// jahan ye pehle skip kar diya gaya tha kyunki koi history mechanism
// nahi tha). Ab lib/db/play_history_db.dart se asli data aata hai.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/download_db.dart';
import '../db/cache_db.dart';
import '../db/play_history_db.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/local_media_resolver.dart';
import '../services/queue_service.dart';
import '../services/download_queue_service.dart';
import '../services/youtube_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/shimmer_song_card.dart';
import '../widgets/song_card.dart';

class RecentlyPlayedScreen extends StatefulWidget {
  const RecentlyPlayedScreen({super.key});

  @override
  State<RecentlyPlayedScreen> createState() => _RecentlyPlayedScreenState();
}

class _RecentlyPlayedScreenState extends State<RecentlyPlayedScreen> {
  bool _loading = true;
  List<Song> _songs = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final recent = await PlayHistoryDB.instance.getRecent(limit: 100);
      final liked = await LikeService.instance.getAllLiked();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = recent;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
    } catch (e) {
      print('RECENTLY_PLAYED _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playFrom(int index) async {
    context.read<QueueService>().setQueue(_songs, startIndex: index);
    final song = _songs[index];
    // (2026-09-18: consolidated — dekho local_media_resolver.dart)
    final localPath = await LocalMediaResolver.instance.getPath(song.id);
    if (localPath != null) {
      await audioHandler.playFromFile(song, localPath);
    } else {
      await audioHandler.playWithRetry(song);
    }
  }

  // BUG FIX (v37 — "kaunsa download ho raha hai, kaunsa queue mein hai
  // kabhi pata nahi chalta"): shared DownloadQueueService use karte hain
  // (progress notification + queue-state wahi maintain karta hai).
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

  Future<void> _confirmClearHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Play history clear karein?', style: AppText.displayS()),
        content: Text(
          'Recently played list khali ho jayegi. Liked/downloaded songs par asar nahi padega.',
          style: AppText.bodyM(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await PlayHistoryDB.instance.clearAll();
    if (!mounted) return;
    setState(() => _songs = []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Recently Played', style: AppText.displayM(color: kGreen).copyWith(fontSize: 20)),
        actions: [
          IconButton(
            icon: Icon(Icons.delete_sweep_outlined, color: kText),
            tooltip: 'Clear history',
            onPressed: _songs.isEmpty ? null : _confirmClearHistory,
          ),
        ],
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
                Icon(Icons.history, color: kTextDim, size: 48),
                const SizedBox(height: 10),
                Text('Abhi tak kuch bhi play nahi hua', style: AppText.bodyM(color: kTextDim)),
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
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SongCard(
            song: song,
            isLiked: _likedIds.contains(song.id),
            isCached: _cachedIds.contains(song.id),
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
        );
      },
    );
  }
}
