// lib/screens/mood_playlist_screen.dart
// Part 6 (Engagement) — mood-based auto playlist. Ek tap se ("chill",
// "workout", "party", "sad", "focus") ek playlist ban jaati hai: pehle
// apni library (liked+cache+download pool, jaisa smart_playlist_screen.dart
// karta hai) me se us mood se milte-julte gaane (title/artist keyword
// match) chunte hain, aur agar wo kam pade to YoutubeService.search() se
// online supplement karte hain (jaisa radio mode karta hai, dekho
// getRadioQueue()) — koi audio-feature analysis nahi hai (wo scope se
// bahar hai), sirf keyword-heuristic + online fallback.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../db/cache_db.dart';
import '../db/download_db.dart';
import '../db/liked_db.dart';
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

class _Mood {
  final String label;
  final String emoji;
  final List<String> keywords;
  final String searchQuery;
  const _Mood(this.label, this.emoji, this.keywords, this.searchQuery);
}

const List<_Mood> _kMoods = [
  _Mood('Chill', '😌', ['lofi', 'chill', 'acoustic', 'unplugged', 'calm', 'soft'],
      'chill lofi hindi songs'),
  _Mood('Workout', '🔥', ['workout', 'gym', 'pump', 'power', 'beast'],
      'workout gym hindi songs'),
  _Mood('Party', '🎉', ['party', 'dance', 'dj', 'remix', 'club'],
      'party dance hindi songs'),
  _Mood('Sad', '💔', ['sad', 'breakup', 'dard', 'judaai', 'tanha', 'heartbreak'],
      'sad hindi songs'),
  _Mood('Focus', '📚', ['instrumental', 'lofi', 'focus', 'study', 'calm'],
      'focus instrumental lofi songs'),
];

class MoodPlaylistScreen extends StatefulWidget {
  const MoodPlaylistScreen({super.key});

  @override
  State<MoodPlaylistScreen> createState() => _MoodPlaylistScreenState();
}

class _MoodPlaylistScreenState extends State<MoodPlaylistScreen> {
  _Mood? _selected;
  bool _loading = false;
  List<Song> _songs = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};

  // Liked + Cache + Download — same pool pattern jo smart_playlist_screen.dart
  // (Part 3) use karta hai.
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

  bool _matchesMood(Song s, _Mood mood) {
    final haystack = '${s.title} ${s.artist}'.toLowerCase();
    return mood.keywords.any((k) => haystack.contains(k));
  }

  Future<void> _pickMood(_Mood mood) async {
    setState(() {
      _selected = mood;
      _loading = true;
      _songs = [];
    });
    try {
      final pool = await _libraryPool();
      final fromLibrary = pool.values.where((s) => _matchesMood(s, mood)).toList()
        ..shuffle();

      final combined = <String, Song>{for (final s in fromLibrary) s.id: s};

      // Library se kam pade (naye users / khaali library) to online
      // search se bhar do — radio mode jaisa hi fallback pattern.
      if (combined.length < 15) {
        try {
          final results = await YoutubeService.instance.search(mood.searchQuery, max: 25);
          for (final r in results) {
            combined.putIfAbsent(r.id, () => r.toSong());
          }
        } catch (_) {
          // Online search fail ho (network/parsing) to bhi library-wale
          // gaane to dikh hi jaayenge — poori playlist khaali nahi hogi.
        }
      }

      final liked = await LikeService.instance.getAllLiked();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _songs = combined.values.toList();
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
      });
    } catch (e) {
      print('MOOD_PLAYLIST(${mood.label}) _pickMood() ERROR: $e');
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
        title: Text('Moods', style: AppText.displayM(color: kGreen).copyWith(fontSize: 20)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: _kMoods.map((m) {
                  final selected = _selected?.label == m.label;
                  return ChoiceChip(
                    label: Text('${m.emoji}  ${m.label}'),
                    selected: selected,
                    onSelected: (_) => _pickMood(m),
                    backgroundColor: kSurface,
                    selectedColor: kGreen,
                    labelStyle: AppText.bodyS(color: selected ? kBg : kText).copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_selected == null) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 80),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.mood, color: kTextDim, size: 48),
                const SizedBox(height: 10),
                Text(
                  'Ek mood tap karo — playlist khud ban jaayegi',
                  style: AppText.bodyM(color: kTextDim),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: List.generate(5, (_) => const ShimmerSongCard()),
      );
    }
    if (_songs.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 80),
        children: [
          Center(
            child: Text(
              'Is mood ke liye kuch nahi mila',
              style: AppText.bodyM(color: kTextDim),
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
