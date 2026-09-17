// lib/screens/daily_mix_screen.dart
// NEW (2026-09-17) — ek Daily Mix ke gaane dikhata hai (DailyMixService se
// aaye hue, already-resolved List<Song> — koi extra fetch nahi karna
// padta). Layout smart_playlist_screen.dart jaisa hi hai (consistency).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/cache_db.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/daily_mix_service.dart';
import '../services/download_queue_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/song_card.dart';

class DailyMixScreen extends StatefulWidget {
  final DailyMix mix;
  const DailyMixScreen({super.key, required this.mix});

  @override
  State<DailyMixScreen> createState() => _DailyMixScreenState();
}

class _DailyMixScreenState extends State<DailyMixScreen> {
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};

  @override
  void initState() {
    super.initState();
    _loadFlags();
  }

  Future<void> _loadFlags() async {
    final liked = await LikeService.instance.getAllLiked();
    final cached = await CacheDB.instance.getAll();
    if (!mounted) return;
    setState(() {
      _likedIds = liked.map((s) => s.id).toSet();
      _cachedIds = cached.map((e) => e['id'] as String).toSet();
    });
  }

  Future<void> _playFrom(int index) async {
    context.read<QueueService>().setQueue(widget.mix.songs, startIndex: index);
    await audioHandler.playWithRetry(widget.mix.songs[index]);
  }

  void _download(Song song) {
    if (DownloadQueueService.instance.isActive(song.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${song.title}" already download queue mein hai')),
      );
      return;
    }
    DownloadQueueService.instance.enqueue(song);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${song.title}" download queue mein daal diya')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final songs = widget.mix.songs;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(widget.mix.title,
            style: AppText.displayM(color: kGreen).copyWith(fontSize: 20)),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Sab download karo',
            onPressed: () => DownloadQueueService.instance.enqueueAll(songs),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: songs.length,
          itemBuilder: (context, i) {
            final song = songs[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SongCard(
                song: song,
                isLiked: _likedIds.contains(song.id),
                isCached: _cachedIds.contains(song.id),
                isDownloaded: false,
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
        ),
      ),
    );
  }
}
