// lib/screens/home_screen.dart
// Root screen — bottom nav (Home/Search/Library/Downloads) + mini player.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../services/daily_mix_service.dart';
import '../services/download_queue_service.dart';
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
import 'live_playlist_screen.dart';
import 'daily_mix_screen.dart';
import 'debug_screen.dart';
import 'settings_screen.dart';

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
  // YouTube Music jaisa live/curated home feed — "Quick picks", "Trending",
  // "Mixed for you" jaise sections, seedhe YT Music se, har baar refresh pe
  // naye/updated. _trending (fixed query) ab sirf FALLBACK hai — agar live
  // feed kisi wajah se khaali aaye.
  List<YtHomeSection> _homeSections = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};
  // NEW (2026-09-17) — "Your Daily Mixes" (dekho daily_mix_service.dart).
  List<DailyMix> _dailyMixes = [];
  String? _debugError; // TEMPORARY — screen pe error dikhane ke liye, taaki
  // bina logcat/computer ke bhi pata chal sake kya fail ho raha hai

  // ---------------- Home feed "infinite scroll" (client-side) ----------------
  // IMPORTANT — HONESTY NOTE: `dart_ytmusic_api` ka `getHomeSections()`
  // andar hi khud saare continuation-pages ek loop me exhaust karke ek
  // SAATH poori list wapas karta hai (package ka apna source dekha —
  // `while (continuation != null) { ... }` seedha usi call ke andar hai).
  // Matlab jab tak `getHomeFeed()` return karta hai, YouTube se poora
  // data ALREADY aa chuka hota hai — humein "agla network batch" jaisa
  // koi real continuation token milta hi nahi (package expose nahi karta).
  // Isliye "infinite scroll pe agla batch fetch" yahan asal me EK extra
  // network call NAHI hai — jo already-fetched sections hain, unhi ka
  // agla chunk reveal hota hai (client-side pagination). UX bilkul
  // "infinite scroll" jaisa hi lagta hai (chhota spinner + neeche scroll
  // karte hi aur content), bas underlying network trip repeat nahi hoti.
  static const int _kInitialSectionBatch = 6;
  static const int _kSectionBatchStep = 6;
  int _visibleSectionCount = _kInitialSectionBatch;
  bool _loadingMoreSections = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMoreSections) return;
    if (_visibleSectionCount >= _homeSections.length) return;
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Neeche se ~400px pehle hi agla batch reveal karo, taaki user ko
    // scroll rukta hua na dikhe.
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _revealMoreSections();
    }
  }

  Future<void> _revealMoreSections() async {
    setState(() => _loadingMoreSections = true);
    // Chhota artificial delay — sirf spinner ka UX feel dene ke liye
    // (jaisa asli network "load more" lagta), koi real network call
    // yahan nahi ho rahi (dekho upar wala HONESTY NOTE).
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() {
      _visibleSectionCount =
          (_visibleSectionCount + _kSectionBatchStep).clamp(0, _homeSections.length);
      _loadingMoreSections = false;
    });
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
      // Layer 1: YT Music ka live/curated home feed.
      // BUMPED again (2026-09-17, infinite-scroll): 20→40 sections. Ye
      // EXTRA network cost nahi hai — `getHomeSections()` package ke
      // andar hi poora feed ek call me fetch kar leta hai (dekho state
      // ke upar wala HONESTY NOTE); yahan sirf ye tay hota hai ki uss
      // already-fetched list se hum kitna client-side rakhte hain, taaki
      // "scroll karke aur sections" dikhane ke liye kuch bacha rahe.
      final homeSections =
          await YoutubeService.instance.getHomeFeed(maxSections: 40, maxItemsPerSection: 30);

      // Layer 2 (FALLBACK): agar live feed khaali aaye (parsing fail,
      // network hiccup, etc.), purana fixed-query "Trending Now" use
      // hota hai — home screen kabhi bilkul khaali nahi rehti.
      List<YtResult> results = [];
      if (homeSections.isEmpty) {
        results = await YoutubeService.instance.search(
          'top hindi songs 2024',
          max: 30,
        );
      }

      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();
      // NEW (2026-09-17): Daily Mixes alag se load karte hain (apna
      // try/catch — inme koi bhi dikkat ho to poora home feed fail nahi
      // hona chahiye, mixes bas section hide ho jaata hai).
      List<DailyMix> dailyMixes = [];
      try {
        dailyMixes = await DailyMixService.instance.getTodaysMixes();
      } catch (e) {
        print('DAILY MIX _load() ERROR: $e');
      }

      if (!mounted) return;
      setState(() {
        _homeSections = homeSections;
        _trending = results;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        _dailyMixes = dailyMixes;
        // Refresh (pull-to-refresh ya pehli load) — reveal-count reset,
        // taaki purane scroll-position ka batch naye feed pe carry na ho.
        _visibleSectionCount = _kInitialSectionBatch;
        // TEMPORARY debug info — agar dono (live feed + fallback) khaali
        // hain par exception nahi aayi, to ye batata hai ki YouTube ne
        // genuinely 0 results diye (rate-limit ya query issue), exception
        // nahi hai.
        _debugError = (homeSections.isEmpty && results.isEmpty)
            ? 'Home feed aur fallback search dono se 0 results (exception'
                ' nahi aayi — ho sakta hai YouTube rate-limit kar raha ho,'
                ' thodi der baad refresh karke dekho)'
            : null;
      });
    } catch (e) {
      // Error ko console/logcat pe print karo taaki pata chale kya fail
      // hua (LikedDB, CacheDB, ya kuch aur) — silently swallow nahi karna.
      print('HOME _load() ERROR: $e');
      if (!mounted) return;
      setState(() {
        _homeSections = [];
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

  // NEW (2026-09-16, v11): home feed ke kisi bhi songs-section se play
  // karne ke liye — us section ke gaano ki apni queue banti hai.
  Future<void> _playFromSection(YtHomeSection section, int index) async {
    final songs = section.songs.map((r) => r.toSong()).toList();
    context.read<QueueService>().setQueue(songs, startIndex: index);
    await audioHandler.playWithRetry(songs[index]);
  }

  void _openLivePlaylist(YtPlaylistPreview p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LivePlaylistScreen(
          playlistId: p.id,
          title: p.title,
          subtitle: p.subtitle,
          thumb: p.thumb,
        ),
      ),
    );
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
  // kabhi pata nahi chalta"): shared DownloadQueueService use karte hain
  // (progress notification + queue-state wahi maintain karta hai).
  Future<void> _download(YtResult result) async {
    final song = result.toSong();
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

  void _openCategory(String query) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => SearchScreen(initialQuery: query)),
    );
  }

  // NEW (2026-09-16, v11): home ka poora feed banata hai — agar loading
  // hai to shimmer, agar live YT Music home feed mila hai to uske
  // sections (songs ya curated live playlists dono), warna purana
  // fixed-query "Trending Now" fallback.
  List<Widget> _buildFeedWidgets() {
    if (_loading) {
      return [
        SectionHeader(title: 'Trending Now'),
        Column(children: List.generate(4, (_) => const ShimmerSongCard())),
      ];
    }

    if (_homeSections.isNotEmpty) {
      final widgets = <Widget>[];
      // Sirf `_visibleSectionCount` sections abhi render hote hain —
      // "load more" scroll listener (`_onScroll`/`_revealMoreSections`)
      // isse dheere-dheere badhata hai.
      final visibleSections = _homeSections.take(_visibleSectionCount);
      for (final section in visibleSections) {
        widgets.add(SectionHeader(title: section.title));
        if (section.kind == YtHomeSectionKind.songs) {
          widgets.add(
            Column(
              children: List.generate(section.songs.length, (i) {
                final r = section.songs[i];
                final song = r.toSong();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SongCard(
                    song: song,
                    isLiked: _likedIds.contains(song.id),
                    isCached: _cachedIds.contains(song.id),
                    onTap: () => _playFromSection(section, i),
                    onPlay: () => _playFromSection(section, i),
                    onDownload: () => _download(r),
                    onLike: () => _toggleLike(song),
                  ),
                );
              }),
            ),
          );
        } else {
          // Curated live playlists — horizontal scroll cards, tap karne
          // pe LivePlaylistScreen khulti hai (tracks wahin load hote hain).
          widgets.add(
            SizedBox(
              height: 170,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: section.playlists.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final p = section.playlists[i];
                  return _LivePlaylistCard(
                    preview: p,
                    onTap: () => _openLivePlaylist(p),
                  );
                },
              ),
            ),
          );
        }
      }
      // "Infinite scroll" spinner — jab tak neeche scroll karke agla
      // batch load ho raha ho (chhota, list ke end me).
      if (_loadingMoreSections) {
        widgets.add(
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: kGreen),
              ),
            ),
          ),
        );
      }
      return widgets;
    }

    // FALLBACK: live feed khaali aaya — purana fixed-query trending
    return [
      SectionHeader(title: 'Trending Now'),
      if (_trending.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 30),
          child: Center(
            child: Column(
              children: [
                Text('Kuch nahi mila', style: AppText.bodyM(color: kTextDim)),
                // TEMPORARY — debug ke liye, exact wajah screen pe dikha
                // rahe hain taaki screenshot se pata chal sake.
                if (_debugError != null) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
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
    ];
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
                controller: _scrollController,
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
                        icon: Icon(Icons.bug_report, color: kTextDim),
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
                        icon: Icon(Icons.settings, color: kTextDim),
                        // BUG FIX (v38 — user report: "settings pe click
                        // karte hi 'Settings jald aa rahi hai' aata hai"):
                        // `settings_screen.dart` (861 lines, poori settings
                        // UI) already ban chuki thi, lekin isse kabhi kisi
                        // screen se navigate hi nahi kiya gaya tha — ye
                        // button abhi bhi purana placeholder SnackBar
                        // dikhata tha. Ab seedha SettingsScreen open karta
                        // hai.
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const SettingsScreen(),
                            ),
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
                          Icon(Icons.search, color: kTextDim, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Gaana, artist, album...',
                            style: AppText.bodyM(color: kTextDim),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // NEW (2026-09-17) — "YouTube Music jaisa" personalized
                  // Daily Mixes: user ki apni listening-history (top
                  // artists) se banti hain, roz refresh hoti hain. Naya
                  // user (koi history nahi) ke liye khaali list aati hai —
                  // us case me section hi nahi dikhta (Categories seedha
                  // aage aa jaata hai).
                  if (_dailyMixes.isNotEmpty) ...[
                    SectionHeader(title: 'Your Daily Mixes'),
                    SizedBox(
                      height: 180,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _dailyMixes.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final mix = _dailyMixes[i];
                          return _DailyMixCard(mix: mix);
                        },
                      ),
                    ),
                  ],
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
                  ..._buildFeedWidgets(),
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

// ---------------- Live/curated playlist card (YT Music home feed) ----------------

class _LivePlaylistCard extends StatelessWidget {
  final YtPlaylistPreview preview;
  final VoidCallback onTap;

  const _LivePlaylistCard({required this.preview, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 130,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: preview.thumb.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: preview.thumb,
                      width: 130,
                      height: 130,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        width: 130,
                        height: 130,
                        color: kSurface,
                        child: Icon(Icons.queue_music, color: kTextDim),
                      ),
                    )
                  : Container(
                      width: 130,
                      height: 130,
                      color: kSurface,
                      child: Icon(Icons.queue_music, color: kTextDim),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              preview.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.bodyM(color: kText).copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            if (preview.subtitle.isNotEmpty)
              Text(
                preview.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyS(color: kTextDim),
              ),
          ],
        ),
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

// ---------------- Daily Mix card (2026-09-17, NEW) ----------------
// YouTube Music ke "Daily Mix" cards jaisa — seed-artist ke naam wala
// title, mix ke pehle gaane ka thumbnail background, tap karke poori mix
// khulti hai (daily_mix_screen.dart).
class _DailyMixCard extends StatelessWidget {
  final DailyMix mix;
  const _DailyMixCard({required this.mix});

  @override
  Widget build(BuildContext context) {
    final coverThumb = mix.songs.isNotEmpty ? mix.songs.first.thumb : '';
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DailyMixScreen(mix: mix)),
      ),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: coverThumb.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: coverThumb,
                      width: 140,
                      height: 140,
                      fit: BoxFit.cover,
                      errorWidget: (context, url, error) => Container(
                        width: 140,
                        height: 140,
                        color: kSurface,
                        child: const Icon(Icons.auto_awesome, color: Colors.white54),
                      ),
                    )
                  : Container(
                      width: 140,
                      height: 140,
                      color: kSurface,
                      child: const Icon(Icons.auto_awesome, color: Colors.white54),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              mix.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.bodyM(color: kText).copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              '${mix.songs.length} gaane',
              style: AppText.bodyS(color: kTextDim),
            ),
          ],
        ),
      ),
    );
  }
}
