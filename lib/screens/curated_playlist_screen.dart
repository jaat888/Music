// lib/screens/curated_playlist_screen.dart
//
// NEW (2026-09-19, v95) — Generic "title+artist list -> YouTube pe match
// karke play-able playlist" screen. JioSaavn playlists aur iTunes ka India
// Top Songs chart — dono isi EK screen ko reuse karte hain (dekho
// home_screen.dart). Pattern bilkul import_playlist_screen.dart ke
// Spotify-branch jaisa hai (ek-ek track YouTube pe search karke best-match
// video se play hota hai) — audio hamesha YouTube se hi aata hai, source
// se sirf naam/singer milta hai.

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

      // Har track ko YouTube pe search karke best-match video jodte hain —
      // ek-ek karke (rate-limit friendly), progress dikhate hue — bilkul
      // import_playlist_screen.dart ke Spotify-branch jaisa.
      //
      // FIX: pehle har baar playlist kholne par saare gaane dobara search hote
      // the. Ab pehle CuratedMatchCache (disk) dekhte hain — pehle se matched
      // gaane instantly aate hain, sirf naye gaano ke liye network jaata hai.
      final cache = CuratedMatchCache.instance;
      await cache.ensureLoaded();
      final matched = <Song>[];
      final seenIds = <String>{};
      var newlyMatched = 0;
      for (var i = 0; i < metas.length; i++) {
        final m = metas[i];
        if (!mounted) {
          unawaited(cache.flush());
          return;
        }
        Song? song = cache.get(m.title, m.artist);
        if (song == null) {
          setState(() {
            _progressText =
                'Match kar rahe hain ${i + 1}/${metas.length}: ${m.title}';
          });
          try {
            final query = m.artist.isNotEmpty ? '${m.title} ${m.artist}' : m.title;
            final results = await YoutubeService.instance.search(query, max: 3);
            if (results.isNotEmpty) {
              song = results.first.toSong();
              cache.put(m.title, m.artist, song);
              newlyMatched++;
              // Beech me screen band ho jaye to bhi ab tak ka kaam bacha rahe.
              if (newlyMatched % 5 == 0) unawaited(cache.flush());
            }
          } catch (_) {
            // Ek track match na ho (network/parsing) to poori playlist khaali
            // na ho — bas agla track try karo.
          }
        }
        if (song != null && seenIds.add(song.id)) matched.add(song);
      }
      unawaited(cache.flush());
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
      body: SafeArea(child: _buildBody()),
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
