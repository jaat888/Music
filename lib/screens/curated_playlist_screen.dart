// lib/screens/curated_playlist_screen.dart
//
// NEW (2026-09-19, v95) — Generic "title+artist list -> YouTube pe match
// karke play-able playlist" screen. JioSaavn playlists aur iTunes ka India
// Top Songs chart — dono isi EK screen ko reuse karte hain (dekho
// home_screen.dart). Pattern bilkul import_playlist_screen.dart ke
// Spotify-branch jaisa hai (ek-ek track YouTube pe search karke best-match
// video se play hota hai) — audio hamesha YouTube se hi aata hai, source
// se sirf naam/singer milta hai. Match requests ab 10-at-a-time parallel
// waves me run hoti hain; disk cache hits network ko bypass karte hain.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/cache_db.dart';
import '../models/song.dart';
import '../services/background_service.dart';
import '../services/curated_match_cache.dart';
import '../services/like_service.dart';
import '../services/local_media_resolver.dart';
import '../services/queue_service.dart';
import '../services/download_queue_service.dart';
import '../services/youtube_service.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';
import '../widgets/shimmer_song_card.dart';
import '../widgets/song_card.dart';
import '../widgets/mini_player.dart';
import 'add_to_playlist_sheet.dart';
import 'full_player_screen.dart';

// Source-agnostic track metadata — JioSaavnTrackMeta/ItunesTrackMeta dono
// yahan convert ho jaate hain, taaki screen ko alag-alag service classes
// import na karni padein.
class CuratedTrackMeta {
  final String title;
  final String artist;
  const CuratedTrackMeta(this.title, this.artist);
}

class CuratedPlaylistScreen extends StatefulWidget {
  final String title;
  final String subtitle;
  final Future<List<CuratedTrackMeta>> Function() metaLoader;

  const CuratedPlaylistScreen({
    super.key,
    required this.title,
    required this.subtitle,
    required this.metaLoader,
  });

  @override
  State<CuratedPlaylistScreen> createState() => _CuratedPlaylistScreenState();
}

class _CuratedPlaylistScreenState extends State<CuratedPlaylistScreen> {
  bool _loading = true;
  String? _error;
  String? _progressText;
  List<Song> _songs = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _songs = [];
      _progressText = null;
    });
    try {
      final metas = await widget.metaLoader();
      if (metas.isEmpty) {
        throw Exception('Is playlist mein koi gaana nahi mila.');
      }

      // Pehle ye har track ko 1-1 karke YouTube pe search karta tha, isliye
      // 50-song playlist ka wait sum of 50 network calls jaisa lagta tha.
      // Ab cache hit instant hai aur cache-miss searches 10-at-a-time waves
      // me parallel chalte hain. Playlist/order deterministic rehta hai.
      final cache = CuratedMatchCache.instance;
      await cache.ensureLoaded();
      final slots = List<Song?>.filled(metas.length, null);
      final seenIds = <String>{};
      var completed = 0;
      const parallel = 10;

      for (var start = 0; start < metas.length; start += parallel) {
        if (!mounted) {
          unawaited(cache.flush());
          return;
        }
        final end = (start + parallel).clamp(0, metas.length);
        final results = await Future.wait(
          [
            for (var i = start; i < end; i++)
              _matchCuratedTrack(metas[i], cache),
          ],
        );

        for (var offset = 0; offset < results.length; offset++) {
          final song = results[offset];
          final index = start + offset;
          completed++;
          if (song != null && seenIds.add(song.id)) {
            slots[index] = song;
          }
        }

        final matched = [
          for (final song in slots)
            if (song != null) song,
        ];
        if (mounted) {
          setState(() {
            _songs = matched;
            _progressText =
                'Playlists load ho rahi hain: $completed/${metas.length}';
          });
        }
      }

      await cache.flush();
      final matched = [
        for (final song in slots)
          if (song != null) song,
      ];
      if (matched.isEmpty) {
        throw Exception('Koi bhi gaana YouTube pe match nahi hua.');
      }

      final liked = await LikeService.instance.getAllLiked();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = matched;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
      // First 20 playback URLs ko bhi background me warm karo taaki first
      // few taps par resolve wait minimum ho.
      audioHandler.prefetchPlaylistSongs(matched, count: 20);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _progressText = null;
        });
      }
    }
  }

  Future<void> _playFrom(int index) async {
    context.read<QueueService>().setQueue(_songs, startIndex: index);
    final song = _songs[index];
    final localPath = await LocalMediaResolver.instance.getPath(song.id);
    if (localPath != null) {
      await audioHandler.playFromFile(song, localPath);
    } else {
      await audioHandler.playWithRetry(song);
    }
  }

  Future<Song?> _matchCuratedTrack(
    CuratedTrackMeta meta,
    CuratedMatchCache cache,
  ) async {
    final cached = cache.get(meta.title, meta.artist);
    if (cached != null) return cached;

    try {
      final query = meta.artist.isNotEmpty
          ? '${meta.title} ${meta.artist}'
          : meta.title;
      final results = await YoutubeService.instance.search(query, max: 3);
      if (results.isEmpty) return null;
      final song = results.first.toSong();
      cache.put(meta.title, meta.artist, song);
      return song;
    } catch (_) {
      return null;
    }
  }

  Future<void> _addToPlaylist(Song song) async {
    await showAddToPlaylistSheet(context, song);
  }

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
        title: Text(
          widget.title,
          style: AppText.displayM().copyWith(fontSize: 18),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            const _CuratedMiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_progressText != null) ...[
            Text(_progressText!, style: AppText.bodyS(color: kTextDim)),
            const SizedBox(height: 10),
          ],
          ...List.generate(6, (_) => const ShimmerSongCard()),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.error_outline, color: kTextDim, size: 40),
                const SizedBox(height: 10),
                Text(_error!, style: AppText.bodyM(color: kTextDim), textAlign: TextAlign.center),
                const SizedBox(height: 14),
                TextButton(onPressed: _load, child: const Text('Dobara try karein')),
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
            onAddToPlaylist: () => _addToPlaylist(song),
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


class _CuratedMiniPlayerBar extends StatelessWidget {
  const _CuratedMiniPlayerBar();

  @override
  Widget build(BuildContext context) {
    final queue = context.watch<QueueService>();
    final song = queue.currentSong;
    if (song == null) return const SizedBox.shrink();

    return FutureBuilder<bool>(
      future: LikeService.instance.isLiked(song.id),
      builder: (context, snap) => MiniPlayer(
        isLiked: snap.data ?? false,
        onLike: () => context.read<LikeService>().toggleLike(song),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const FullPlayerScreen()),
        ),
      ),
    );
  }
}
