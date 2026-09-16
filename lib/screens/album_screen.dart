// lib/screens/album_screen.dart
// Album detail screen — YouTube search se songs laata hai (koi real
// "album API" nahi hai, sirf '<naam> full album' query). SliverAppBar
// ke saath collapsing header (square cover) aur Play All/Shuffle buttons.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/cache_db.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../services/youtube_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/shimmer_song_card.dart';
import '../widgets/song_card.dart';

class AlbumScreen extends StatefulWidget {
  final String albumName;
  final String? albumThumb;

  const AlbumScreen({
    super.key,
    required this.albumName,
    this.albumThumb,
  });

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

class _AlbumScreenState extends State<AlbumScreen> {
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
      final results = await YoutubeService.instance.search(
        '${widget.albumName} full album',
      );
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = results.map((r) => r.toSong()).toList();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
    } catch (e) {
      print('ALBUM _load() ERROR: $e');
      if (!mounted) return;
      setState(() => _songs = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    _refreshLikedIds();
  }

  Future<void> _refreshLikedIds() async {
    final likeService = context.read<LikeService>();
    final ids = <String>{};
    for (final s in _songs) {
      if (await likeService.isLiked(s.id)) ids.add(s.id);
    }
    if (!mounted) return;
    setState(() => _likedIds = ids);
  }

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

  Future<void> _download(Song song) async {
    final path = await YoutubeService.instance.download(song.id, song.title, author: song.artist);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path != null ? '${song.title} download ho gaya' : 'Download fail ho gaya',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: RefreshIndicator(
        onRefresh: _load,
        color: kGreen,
        backgroundColor: kBgElev,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: kBgElev,
              expandedHeight: 280,
              pinned: true,
              iconTheme: const IconThemeData(color: kText),
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [kBgElev, kBg],
                    ),
                  ),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _AlbumCover(thumb: widget.albumThumb),
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              widget.albumName,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.displayM(color: kText)
                                  .copyWith(fontSize: 22, fontWeight: FontWeight.w800),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Album · YouTube',
                            style: AppText.bodyM().copyWith(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kGreen,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _songs.isEmpty ? null : () => _playAll(),
                        icon: const Icon(Icons.play_arrow, color: kBg),
                        label: Text('Play All', style: AppText.button(color: kBg)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: kTextDim),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _songs.isEmpty ? null : () => _playAll(shuffle: true),
                        icon: const Icon(Icons.shuffle, color: kText),
                        label: Text('Shuffle', style: AppText.button(color: kText)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_loading)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate(
                    List.generate(6, (_) => const ShimmerSongCard()),
                  ),
                ),
              )
            else if (_songs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 60),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.search_off, color: kTextDim, size: 48),
                        const SizedBox(height: 10),
                        Text('Kuch nahi mila', style: AppText.bodyM(color: kTextDim)),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final song = _songs[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SongCard(
                          song: song,
                          isLiked: _likedIds.contains(song.id),
                          isCached: _cachedIds.contains(song.id),
                          onTap: () => _playFrom(i),
                          onPlay: () => _playFrom(i),
                          onDownload: () => _download(song),
                          onLike: () => _toggleLike(song),
                        ),
                      );
                    },
                    childCount: _songs.length,
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 90)),
          ],
        ),
      ),
    );
  }
}

// Album ka square cover — thumb na ho ya load fail ho to music-note fallback
class _AlbumCover extends StatelessWidget {
  final String? thumb;
  const _AlbumCover({this.thumb});

  @override
  Widget build(BuildContext context) {
    final hasThumb = thumb != null && thumb!.isNotEmpty;
    return Container(
      width: 180,
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppGlow.shadow(color: kPurple, opacity: 0.2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: hasThumb
            ? CachedNetworkImage(
                imageUrl: thumb!,
                width: 180,
                height: 180,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: kSurface),
                errorWidget: (_, __, ___) => Container(
                  color: kSurface,
                  child: const Icon(Icons.album, color: kTextDim, size: 56),
                ),
              )
            : Container(
                color: kSurface,
                child: const Icon(Icons.album, color: kTextDim, size: 56),
              ),
      ),
    );
  }
}
