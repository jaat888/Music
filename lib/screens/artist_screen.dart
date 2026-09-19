// lib/screens/artist_screen.dart
// Artist detail screen — YouTube search se songs laata hai (koi real
// "artist API" nahi hai, sirf '<naam> songs' query). SliverAppBar ke
// saath collapsing header (image + naam) aur Follow/Play All buttons.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/cache_db.dart';
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
import 'album_screen.dart';

class ArtistScreen extends StatefulWidget {
  final String artistName;
  final String? artistThumb;

  const ArtistScreen({
    super.key,
    required this.artistName,
    this.artistThumb,
  });

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  bool _loading = true;

  // NOTE: koi FollowService/backend nahi hai app me — "Follow" sirf is
  // screen ke andar ka local UI state hai, kahin persist nahi hota
  // (NOTES.md dekho).
  bool _following = false;

  List<Song> _songs = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};

  // BUG FIX (feature wiring): AlbumScreen (album detail UI — poori tarah
  // functional, apna "<naam> full album" search khud karti hai) ke paas
  // app me kahin se bhi Navigator.push nahi hota tha. App me koi real
  // "artist ke albums" API nahi hai (ArtistScreen khud bhi sirf
  // "<artist> songs" text-search se bani hai — dekho upar wala class
  // comment), isliye yahan bhi wahi pattern follow karte hain: ek chhota
  // "<artist> album" search karke uske results ko album-tiles ki tarah
  // dikhate hain — tap karne par AlbumScreen khulti hai.
  List<YtResult> _albumResults = [];
  bool _loadingAlbums = true;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    if (!mounted) return;
    setState(() => _loadingAlbums = true);
    try {
      final results = await YoutubeService.instance.search(
        '${widget.artistName} album',
        max: 10,
      );
      if (!mounted) return;
      setState(() => _albumResults = results);
    } catch (e) {
      print('ARTIST albums-section ERROR: $e');
      if (!mounted) return;
      setState(() => _albumResults = []);
    } finally {
      if (mounted) setState(() => _loadingAlbums = false);
    }
  }

  void _openAlbum(YtResult r) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumScreen(albumName: r.title, albumThumb: r.thumb),
      ),
    );
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final results = await YoutubeService.instance.search(
        '${widget.artistName} songs',
        max: 20,
      );
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = results.map((r) => r.toSong()).toList();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
    } catch (e) {
      print('ARTIST _load() ERROR: $e');
      if (!mounted) return;
      setState(() => _songs = []);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    // Liked ids alag se refresh karo (naye search results ke against check karne ke liye)
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

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    context.read<QueueService>().setQueue(_songs, startIndex: 0);
    await audioHandler.playWithRetry(_songs.first);
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

  // BUG FIX (v37 — "kaunsa download ho raha hai, kaunsa queue mein hai
  // kabhi pata nahi chalta"): seedha YoutubeService.download() call karne
  // ke bajaye shared DownloadQueueService mein daalte hain — progress
  // notification aur queue-state wahi maintain karta hai.
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
      body: RefreshIndicator(
        onRefresh: _load,
        color: kGreen,
        backgroundColor: kBgElev,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: kBgElev,
              expandedHeight: 260,
              pinned: true,
              iconTheme: IconThemeData(color: kText),
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration:  BoxDecoration(
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
                          _ArtistAvatar(thumb: widget.artistThumb),
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              widget.artistName,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.displayL(color: kText)
                                  .copyWith(fontSize: 26, fontWeight: FontWeight.w800),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'YouTube Artist',
                            style: AppText.bodyM().copyWith(fontSize: 13),
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
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: kGreen),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () => setState(() => _following = !_following),
                        icon: Icon(
                          _following ? Icons.check : Icons.add,
                          color: kGreen,
                        ),
                        label: Text(
                          _following ? 'Following' : 'Follow',
                          style: AppText.button(color: kGreen),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kGreen,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: _songs.isEmpty ? null : _playAll,
                        icon: Icon(Icons.play_arrow, color: kBg),
                        label: Text('Play All', style: AppText.button(color: kBg)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // ---------- Albums (feature wiring — see _loadAlbums()) ----------
            if (_loadingAlbums || _albumResults.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Albums',
                        style: AppText.displayS(color: kText).copyWith(fontSize: 16),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        height: 150,
                        child: _loadingAlbums
                            ? ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: 4,
                                separatorBuilder: (_, __) => const SizedBox(width: 12),
                                itemBuilder: (_, __) => Container(
                                  width: 110,
                                  height: 110,
                                  decoration: BoxDecoration(
                                    color: kSurface,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              )
                            : ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _albumResults.length,
                                separatorBuilder: (_, __) => const SizedBox(width: 12),
                                itemBuilder: (context, i) {
                                  final r = _albumResults[i];
                                  return GestureDetector(
                                    onTap: () => _openAlbum(r),
                                    child: SizedBox(
                                      width: 110,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: CachedNetworkImage(
                                              imageUrl: r.thumb,
                                              width: 110,
                                              height: 110,
                                              fit: BoxFit.cover,
                                              errorWidget: (_, __, ___) => Container(
                                                width: 110,
                                                height: 110,
                                                color: kSurface,
                                                child: Icon(Icons.album, color: kTextDim),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          Text(
                                            r.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppText.bodyS(color: kText).copyWith(fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
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
                    List.generate(5, (_) => const ShimmerSongCard()),
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
                        Icon(Icons.search_off, color: kTextDim, size: 48),
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

// Artist ki circle image — thumb na ho ya load fail ho to person icon fallback
class _ArtistAvatar extends StatelessWidget {
  final String? thumb;
  const _ArtistAvatar({this.thumb});

  @override
  Widget build(BuildContext context) {
    final hasThumb = thumb != null && thumb!.isNotEmpty;
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: AppGlow.shadow(color: kGreen, opacity: 0.2),
      ),
      child: ClipOval(
        child: hasThumb
            ? CachedNetworkImage(
                imageUrl: thumb!,
                width: 140,
                height: 140,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(color: kSurface),
                errorWidget: (_, __, ___) => Container(
                  color: kSurface,
                  child: Icon(Icons.person, color: kTextDim, size: 56),
                ),
              )
            : Container(
                color: kSurface,
                child: Icon(Icons.person, color: kTextDim, size: 56),
              ),
      ),
    );
  }
}
