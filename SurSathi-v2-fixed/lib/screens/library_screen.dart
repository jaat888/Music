// lib/screens/library_screen.dart
// Library tab — Liked Songs, Downloads, Playlists overview.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../db/liked_db.dart';
import '../db/download_db.dart';
import '../db/playlist_db.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../services/youtube_service.dart';
import '../widgets/mini_player.dart';
import 'create_playlist_screen.dart';
import 'downloads_screen.dart';
import 'full_player_screen.dart';
import 'liked_songs_screen.dart';
import 'playlist_detail_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  bool _loading = true;
  List<Song> _likedSongs = [];
  int _downloadsCount = 0;
  List<Playlist> _playlists = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final liked = await LikedDB.instance.getAll();
      final downloads = await DownloadDB.instance.getAll();
      final playlists = await PlaylistDB.instance.getAllPlaylists();
      if (!mounted) return;
      setState(() {
        _likedSongs = liked;
        _downloadsCount = downloads.length;
        _playlists = playlists;
      });
    } catch (e) {
      print('LIBRARY _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playSong(Song song) async {
    if (song.filePath != null && await File(song.filePath!).exists()) {
      await audioHandler.playFromFile(song, song.filePath!);
    } else {
      await audioHandler.playWithRetry(song, YoutubeService.instance.getAudioUrl);
    }
  }

  Future<void> _playAllLiked() async {
    if (_likedSongs.isEmpty) return;
    context.read<QueueService>().setQueue(_likedSongs, startIndex: 0);
    await _playSong(_likedSongs.first);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          'Library',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 24),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                color: kGreen,
                backgroundColor: kBgElev,
                child: _loading ? _buildShimmer() : _buildContent(),
              ),
            ),
            _MiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildShimmer() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: List.generate(
        3,
        (_) => Shimmer.fromColors(
          baseColor: kBgElev,
          highlightColor: const Color(0xFF2A3E5C),
          child: Container(
            height: 72,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: kBgElev,
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final liked = context.watch<LikeService>().likedCount;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _LibraryCard(
          icon: Icons.favorite,
          iconColor: kRed,
          title: 'Liked Songs',
          subtitle: '$liked songs',
          trailing: IconButton(
            icon: const Icon(Icons.play_circle_fill, color: kGreen, size: 30),
            onPressed: _playAllLiked,
          ),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LikedSongsScreen()),
          ).then((_) => _load()),
        ),
        const SizedBox(height: 12),
        _LibraryCard(
          icon: Icons.download_done,
          iconColor: kBlue,
          title: 'Downloads',
          subtitle: '$_downloadsCount songs',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DownloadsScreen()),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Playlists', style: AppText.displayS(color: kText)),
            TextButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CreatePlaylistScreen()),
              ).then((_) => _load()),
              icon: const Icon(Icons.add, color: kGreen, size: 18),
              label: Text('Create', style: AppText.bodyM(color: kGreen)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_playlists.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Koi playlist nahi bani abhi tak',
              style: AppText.bodyM(color: kTextDim),
            ),
          )
        else
          ..._playlists.map(
            (p) => _LibraryCard(
              icon: Icons.queue_music,
              iconColor: kPurple,
              title: p.name,
              subtitle: '${p.songIds.length} songs',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PlaylistDetailScreen(playlistId: p.id),
                ),
              ).then((_) => _load()),
              margin: const EdgeInsets.only(bottom: 10),
            ),
          ),
        const SizedBox(height: 90),
      ],
    );
  }
}

// ---------------- Reusable library section card ----------------

class _LibraryCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final EdgeInsets margin;

  const _LibraryCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      child: Material(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: AppText.bodyL(color: kText).copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(subtitle, style: AppText.bodyS(color: kTextDim)),
                    ],
                  ),
                ),
                trailing ??
                    const Icon(Icons.arrow_forward_ios, color: kTextDim, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------- Shared mini player wrapper (library screen) ----------------

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
