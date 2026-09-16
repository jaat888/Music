// lib/screens/home_screen.dart
// Root screen — bottom nav (Home/Search/Library/Downloads) + mini player.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../services/youtube_service.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../widgets/song_card.dart';
import '../widgets/category_card.dart';
import '../widgets/section_header.dart';
import '../widgets/shimmer_song_card.dart';
import '../widgets/mini_player.dart';
import 'search_screen.dart';
import 'library_screen.dart';
import 'downloads_screen.dart';
import 'full_player_screen.dart';
import 'debug_screen.dart';

// Home ki 12 categories — naam, emoji, search query
class _Category {
  final String name;
  final String emoji;
  final String query;
  const _Category(this.name, this.emoji, this.query);
}

const List<_Category> _kCategories = [
  _Category('Bollywood', '🎬', 'bollywood hits songs'),
  _Category('Punjabi', '🕺', 'punjabi hits songs'),
  _Category('Haryanvi', '🎤', 'haryanvi hits songs'),
  _Category('Lo-Fi', '🌙', 'lofi hits songs'),
  _Category('Party', '🎉', 'party hits songs'),
  _Category('Romantic', '💕', 'romantic hits songs'),
  _Category('Workout', '💪', 'workout hits songs'),
  _Category('Old Hits', '📻', 'old hits songs'),
  _Category('Arijit', '🎵', 'arijit singh hits songs'),
  _Category('Chill', '☕', 'chill hits songs'),
  _Category('Devotional', '🕉', 'devotional hits songs'),
  _Category('Hip-Hop', '🎧', 'hip-hop hits songs'),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

  void _goToSearchTab() => setState(() => _tabIndex = 1);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: IndexedStack(
        index: _tabIndex,
        children: [
          _HomeTabContent(onSearchTap: _goToSearchTab),
          const SearchScreen(),
          const LibraryScreen(),
          const DownloadsScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tabIndex,
        onTap: (i) => setState(() => _tabIndex = i),
        backgroundColor: kBgElev,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: kGreen,
        unselectedItemColor: kTextDim,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music),
            label: 'Library',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download_done),
            label: 'Downloads',
          ),
        ],
      ),
    );
  }
}

// ---------------- Home tab body (Tab 0) ----------------

class _HomeTabContent extends StatefulWidget {
  final VoidCallback onSearchTap;
  const _HomeTabContent({required this.onSearchTap});

  @override
  State<_HomeTabContent> createState() => _HomeTabContentState();
}

class _HomeTabContentState extends State<_HomeTabContent> {
  bool _loading = true;
  List<YtResult> _trending = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};
  String? _debugError; // TEMPORARY — screen pe error dikhane ke liye, taaki
  // bina logcat/computer ke bhi pata chal sake kya fail ho raha hai

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);

    // BUG FIX: pehle is method me try-catch NAHI tha. Agar LikedDB ya
    // CacheDB me koi bhi error aata (jo YoutubeService.search() ke andar
    // silently catch nahi hota, kyunki wo alag service hai), to setState()
    // wali line kabhi chalti hi nahi thi — aur `_loading` hamesha `true`
    // reh jaata, isliye "Trending Now" section hamesha shimmer dikhata
    // rehta tha, chahe YouTube search khud kaam kar raha ho (jaisa debug
    // screen me dikh raha tha).
    try {
      final results = await YoutubeService.instance.search(
        'top hindi songs 2024',
        max: 30,
      );
      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();

      if (!mounted) return;
      setState(() {
        _trending = results;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        // TEMPORARY debug info — agar results khaali hain par exception
        // nahi aayi, to ye batata hai ki YouTube ne genuinely 0 results
        // diye (rate-limit ya query issue), exception nahi hai.
        _debugError = results.isEmpty
            ? 'search() ne 0 results diye (exception nahi aayi — ho sakta'
                ' hai YouTube rate-limit kar raha ho, thodi der baad'
                ' refresh karke dekho)'
            : null;
      });
    } catch (e) {
      // Error ko console/logcat pe print karo taaki pata chale kya fail
      // hua (LikedDB, CacheDB, ya kuch aur) — silently swallow nahi karna.
      print('HOME _load() ERROR: $e');
      if (!mounted) return;
      setState(() {
        _trending = []; // empty state dikhega, shimmer nahi
        _debugError = 'EXCEPTION: $e'; // TEMPORARY — screen pe dikhega
      });
    } finally {
      // Ye hamesha chalega — chahe try me sab sahi ho ya exception aaye.
      // Isse `_loading` kabhi bhi hamesha-true nahi reh sakta.
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _playFromTrending(int index) async {
    final songs = _trending.map((r) => r.toSong()).toList();
    context.read<QueueService>().setQueue(songs, startIndex: index);
    await audioHandler.playWithRetry(songs[index]);
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

  Future<void> _download(YtResult result) async {
    final path = await YoutubeService.instance.download(
      result.id,
      result.title,
      author: result.author,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          path != null ? '${result.title} download ho gaya' : 'Download fail ho gaya',
        ),
      ),
    );
  }

  void _openCategory(String query) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(initialQuery: query)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: kGreen,
              backgroundColor: kBgElev,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const SizedBox(height: 8),
                  // ---------- Top bar: logo + title + settings ----------
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          gradient: AppGradients.greenBlue,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.music_note,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('SurSathi', style: AppText.displayM(color: kGreen)),
                      const Spacer(),
                      // Debug screen — YouTube search/stream troubleshooting
                      IconButton(
                        icon: const Icon(Icons.bug_report, color: kTextDim),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const DebugScreen(),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings, color: kTextDim),
                        onPressed: () {
                          // Settings screen Batch 13 me banegi
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Settings jald aa rahi hai')),
                          );
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // ---------- Search bar (tap -> Search tab) ----------
                  GestureDetector(
                    onTap: widget.onSearchTap,
                    child: Container(
                      height: 46,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: kSurface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.search, color: kTextDim, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Gaana, artist, album...',
                            style: AppText.bodyM(color: kTextDim),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SectionHeader(title: 'Categories'),
                  SizedBox(
                    height: 95,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _kCategories.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final c = _kCategories[i];
                        return CategoryCard(
                          name: c.name,
                          emoji: c.emoji,
                          index: i,
                          onTap: () => _openCategory(c.query),
                        );
                      },
                    ),
                  ),
                  SectionHeader(title: 'Trending Now'),
                  if (_loading)
                    Column(
                      children: List.generate(
                        4,
                        (_) => const ShimmerSongCard(),
                      ),
                    )
                  else if (_trending.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 30),
                      child: Center(
                        child: Column(
                          children: [
                            Text(
                              'Kuch nahi mila',
                              style: AppText.bodyM(color: kTextDim),
                            ),
                            // TEMPORARY — debug ke liye, exact wajah screen
                            // pe dikha rahe hain taaki screenshot se pata
                            // chal sake. Baad me ye block hata dena.
                            if (_debugError != null) ...[
                              const SizedBox(height: 10),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                ),
                                child: Text(
                                  _debugError!,
                                  textAlign: TextAlign.center,
                                  style: AppText.bodyS(color: kRed),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  else
                    Column(
                      children: List.generate(_trending.length, (i) {
                        final r = _trending[i];
                        final song = r.toSong();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: SongCard(
                            song: song,
                            isLiked: _likedIds.contains(song.id),
                            isCached: _cachedIds.contains(song.id),
                            onTap: () => _playFromTrending(i),
                            onPlay: () => _playFromTrending(i),
                            onDownload: () => _download(r),
                            onLike: () => _toggleLike(song),
                          ),
                        );
                      }),
                    ),
                  const SizedBox(height: 90), // mini player + bottom nav ke liye jagah
                ],
              ),
            ),
          ),
          _HomeMiniPlayerBar(),
        ],
      ),
    );
  }
}

// ---------------- Shared mini player wrapper ----------------
// Har tab ke apne Scaffold me bhi yahi pattern repeat hota hai
// (search/library/downloads screens me bhi same shape ki private
// class hai — NOTES.md #10 dekho).

class _HomeMiniPlayerBar extends StatelessWidget {
  const _HomeMiniPlayerBar();

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
