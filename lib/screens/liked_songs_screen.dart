// lib/screens/liked_songs_screen.dart
// Sabhi liked songs ki list — heart cover, play all/shuffle, swipe-to-unlike.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../services/background_service.dart';
import '../services/queue_service.dart';
import '../services/like_service.dart';
import '../services/download_queue_service.dart';
import '../services/youtube_service.dart';
import '../widgets/song_card.dart';
import '../widgets/shimmer_song_card.dart';

class LikedSongsScreen extends StatefulWidget {
  const LikedSongsScreen({super.key});

  @override
  State<LikedSongsScreen> createState() => _LikedSongsScreenState();
}

class _LikedSongsScreenState extends State<LikedSongsScreen> {
  bool _loading = true;
  List<Song> _songs = [];
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
      final songs = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
    } catch (e) {
      print('LIKED_SONGS _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalMinutes =>
      (_songs.fold<int>(0, (sum, s) => sum + s.duration) / 60).round();

  Future<void> _playAll({bool shuffle = false}) async {
    if (_songs.isEmpty) return;
    var list = List<Song>.of(_songs);
    if (shuffle) {
      list.shuffle();
      context.read<QueueService>().setShuffle(true);
    }
    context.read<QueueService>().setQueue(list, startIndex: 0);
    await audioHandler.playWithRetry(list.first);
  }

  Future<void> _playFrom(int index) async {
    context.read<QueueService>().setQueue(_songs, startIndex: index);
    await audioHandler.playWithRetry(_songs[index]);
  }

  // onLike heart tap ho ya swipe — dono hi "unlike" hai kyunki is screen
  // ke sab songs already liked hote hain.
  Future<void> _unlike(Song song) async {
    await context.read<LikeService>().toggleLike(song);
    if (!mounted) return;
    setState(() => _songs.removeWhere((s) => s.id == song.id));
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

  Future<void> _confirmClearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Sab liked songs hataein?', style: AppText.displayS()),
        content: Text('Ye sabhi liked songs unlike ho jayenge.', style: AppText.bodyM()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Clear All', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    for (final s in List<Song>.of(_songs)) {
      await context.read<LikeService>().toggleLike(s);
    }
    if (!mounted) return;
    setState(() => _songs.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          'Liked Songs',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
        actions: [
          // NOTE: Spec ne sirf "more_vert" bola tha bina options detail kiye —
          // yahan sabse relevant ek action (Clear all) rakh diya gaya hai.
          IconButton(
            icon: Icon(Icons.more_vert, color: kText),
            onPressed: _songs.isEmpty ? null : _confirmClearAll,
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
      children: List.generate(4, (_) => const ShimmerSongCard()),
    );
  }

  Widget _buildBody() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [kRed, kPurple],
              ),
              borderRadius: BorderRadius.circular(18),
              boxShadow: AppGlow.shadow(color: kRed, opacity: 0.25),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.favorite, color: Colors.white, size: 64),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Liked Songs',
          textAlign: TextAlign.center,
          style: AppText.displayL(color: kText)
              .copyWith(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            '${_songs.length} songs',
            style: AppText.bodyS().copyWith(fontSize: 13),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: kGreen,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _songs.isEmpty ? null : () => _playAll(),
                icon: Icon(Icons.play_arrow, color: kBg),
                label: Text('Play All', style: AppText.button(color: kBg)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: kTextDim),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _songs.isEmpty ? null : () => _playAll(shuffle: true),
                icon: Icon(Icons.shuffle, color: kText),
                label: Text('Shuffle', style: AppText.button(color: kText)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_songs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Center(
              child: Column(
                children: [
                  Icon(Icons.favorite_border, color: kTextDim, size: 48),
                  const SizedBox(height: 10),
                  Text('Koi liked song nahi', style: AppText.bodyM(color: kTextDim)),
                  const SizedBox(height: 4),
                  Text('Songs pe heart tap karo', style: AppText.bodyS()),
                ],
              ),
            ),
          )
        else
          ...List.generate(_songs.length, (i) {
            final song = _songs[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Dismissible(
                key: ValueKey(song.id),
                direction: DismissDirection.startToEnd,
                background: Container(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 20),
                  decoration: BoxDecoration(
                    color: kRed,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.favorite_border, color: Colors.white),
                ),
                onDismissed: (_) => _unlike(song),
                child: SongCard(
                  song: song,
                  isLiked: true,
                  isCached: _cachedIds.contains(song.id),
                  onTap: () => _playFrom(i),
                  onPlay: () => _playFrom(i),
                  onDownload: () => _download(song),
                  onLike: () => _unlike(song),
                ),
              ),
            );
          }),
        const SizedBox(height: 90),
      ],
    );
  }
}
