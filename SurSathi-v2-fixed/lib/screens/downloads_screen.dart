// lib/screens/downloads_screen.dart
// Downloads tab — permanently saved songs (Music/SurSathi/), offline playback.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/download_db.dart';
import '../db/liked_db.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../widgets/song_card.dart';
import '../widgets/mini_player.dart';
import 'full_player_screen.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _loading = true;
  List<Song> _downloads = [];
  Set<String> _likedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final downloads = await DownloadDB.instance.getAll();
      final liked = await LikedDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _downloads = downloads;
        _likedIds = liked.map((s) => s.id).toSet();
      });
    } catch (e) {
      print('DOWNLOADS _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(int index) async {
    final song = _downloads[index];
    if (song.filePath == null) return;
    context.read<QueueService>().setQueue(_downloads, startIndex: index);
    await audioHandler.playFromFile(song, song.filePath!);
  }

  Future<void> _toggleLike(Song song) async {
    await context.read<LikeService>().toggleLike(song);
    if (!mounted) return;
    setState(() {
      if (_likedIds.contains(song.id)) {
        _likedIds.remove(song.id);
      } else {
        _likedIds.add(song.id);
      }
    });
  }

  // NOTE: SongCard me alag se onDelete param nahi hai (Batch 6 se fixed hai),
  // isliye "download" icon hi yahan delete action ke liye reuse ho raha hai —
  // dekho NOTES.md #10.
  Future<void> _confirmDelete(Song song) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Delete karein?', style: AppText.displayS(color: kText)),
        content: Text(
          '"${song.title}" hamesha ke liye delete ho jayega.',
          style: AppText.bodyM(color: kTextDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (song.filePath != null) {
      final file = File(song.filePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await DownloadDB.instance.delete(song.id);
    if (!mounted) return;
    setState(() => _downloads.removeWhere((s) => s.id == song.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          'Downloads',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 24),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            _MiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: List.generate(
          3,
          (_) => Shimmer.fromColors(
            baseColor: kBgElev,
            highlightColor: const Color(0xFF2A3E5C),
            child: Container(
              height: 76,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: kBgElev,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      );
    }

    if (_downloads.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: kGreen,
        backgroundColor: kBgElev,
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_done,
                      color: Colors.white24,
                      size: 80,
                    ),
                    const SizedBox(height: 14),
                    Text('Koi download nahi', style: AppText.bodyL(color: kTextDim)),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'Songs ko download karo offline sunne ke liye',
                        textAlign: TextAlign.center,
                        style: AppText.bodyS(color: kTextDim),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: kGreen,
      backgroundColor: kBgElev,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _downloads.length,
        itemBuilder: (context, i) {
          final song = _downloads[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Dismissible(
              key: ValueKey(song.id),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) async {
                await _confirmDelete(song);
                return false; // list _confirmDelete ke andar khud update hoti hai
              },
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: kRed.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              child: SongCard(
                song: song,
                isLiked: _likedIds.contains(song.id),
                isCached: false,
                onTap: () => _play(i),
                onPlay: () => _play(i),
                onDownload: () => _confirmDelete(song),
                onLike: () => _toggleLike(song),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ---------------- Shared mini player wrapper (downloads screen) ----------------

class _MiniPlayerBar extends StatelessWidget {
  const _MiniPlayerBar();

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<QueueService>();
    final song = queue.currentSong;
    if (song == null) return const SizedBox.shrink();

    return FutureBuilder<bool>(
      future: LikeService.instance.isLiked(song.id),
      builder: (context, snap) {
        return MiniPlayer(
          isLiked: snap.data ?? false,
          onLike: () => context.read<LikeService>().toggleLike(song),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FullPlayerScreen()),
            );
          },
        );
      },
    );
  }
}
