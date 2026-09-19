// lib/screens/home_screen.dart
// Root screen — bottom nav (Home/Search/Library/Downloads) + mini player.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../services/daily_mix_service.dart';
import '../services/discover_weekly_service.dart';
import '../services/download_queue_service.dart';
import '../services/youtube_service.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../services/jiosaavn_service.dart';
import '../services/itunes_charts_service.dart';
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
import 'curated_playlist_screen.dart';
import 'daily_mix_screen.dart';
import 'debug_screen.dart';
import 'settings_screen.dart';
import 'radio_language_select_screen.dart';
import 'radio_player_screen.dart';

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

// NEW (2026-09-17) — curated `_homeSections` khatam hone ke baad, scroll
// ko "genuinely infinite" banane ke liye category-search se generate hue
// extra sections (dekho _HomeTabContentState._loadMoreExtraCategory).
class _ExtraSection {
  final String title;
  final List<YtResult> songs;
  _ExtraSection({required this.title, required this.songs});
}

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
  // NEW — "Discover Weekly" (dekho discover_weekly_service.dart) —
  // DailyMix jaisa hi shape (title+songs) me store karte hain taaki
  // seedha `_DailyMixCard` reuse ho sake.
  DailyMix? _discoverWeekly;
  // NEW (2026-09-17, diagnostic): Daily Mix khaali kyun aayi (agar aayi) —
  // sirf tab dikhta hai jab genuinely kuch fail hua ho (naya user jiski
  // history hi nahi hai, uske liye ye null rehta hai aur section chupa
  // rehta hai, jaisa pehle tha).
  String? _dailyMixDebug;
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

  // NEW (Batch 30 — user ne pichla "stop after 12" fix reject kiya:
  // "YouTube se AUR playlist fetch karne the, tune pura hi band kar
  // diya"): pehle categories khatam hone par modulo se REPEAT hote the
  // (same query, same 12 results baar-baar) — wo asli bug tha. Uska
  // pehla fix sirf "12 ke baad ruk jao" tha, jo user ko pasand nahi aaya
  // kyunki feed genuinely infinite nahi raha. ASLI sahi fix: har
  // category ka apna continuation token (YouTube ka real "next page"
  // pagination, `youtube_service.dart searchPage()`) alag se yaad
  // rakho — isliye jab category cycle karke wapas aati hai, wahi purane
  // 12 gaane nahi, us category ka AGLA page (naye 12 gaane) aata hai.
  // Sirf tab woh category permanently skip hoti hai jab YouTube khud
  // keh de "is query ke liye aur results nahi" (continuation == null).
  int _extraCategoryCursor = 0;
  final List<_ExtraSection> _extraSections = [];
  // category name -> agla continuation token (null = pehla page abhi tak nahi maanga)
  final Map<String, String?> _categoryContinuation = {};
  // category jinke liye YouTube ne khud bola "aur results nahi bache"
  final Set<String> _categoryExhausted = {};

  // NEW (2026-09-19, v95) — extra curated-playlist sources (JioSaavn +
  // iTunes), dekho jiosaavn_service.dart / itunes_charts_service.dart ke
  // top comments. Dono apne alag `_load*()` + try/catch me hain, taaki
  // agar in mein se koi bhi source down/slow ho ya shape badal jaaye, to
  // wo sirf apna hi section khaali chhod de — asli YT Music feed
  // (`_load()`, upar) ya doosra source bilkul unaffected rahe.
  List<JioSaavnPlaylistPreview> _jioSaavnPlaylists = [];
  bool _jioSaavnLoading = true;
  List<ItunesTrackMeta> _itunesTop = [];
  bool _itunesLoading = true;

  Future<void> _loadJioSaavn() async {
    if (!mounted) return;
    setState(() => _jioSaavnLoading = true);
    try {
      final collected = <JioSaavnPlaylistPreview>[];
      final seen = <String>{};
      // Apni hi existing categories (Bollywood/Punjabi/Haryanvi/...) reuse
      // karte hain taaki language-coverage consistent rahe — har category
      // ke liye chhoti si JioSaavn playlist-search.
      for (final cat in _kCategories.take(10)) {
        if (!mounted) return;
        List<JioSaavnPlaylistPreview> results;
        try {
          results = await JioSaavnService.instance.searchPlaylists(
            '${cat.name} hits',
            max: 3,
          );
        } catch (_) {
          results = []; // ek category fail ho to baaki try karte rehna hai
        }
        for (final r in results) {
          if (seen.add(r.id)) collected.add(r);
        }
        if (collected.length >= 24) break;
      }
      if (!mounted) return;
      setState(() {
        _jioSaavnPlaylists = collected;
        _jioSaavnLoading = false;
      });
    } catch (e) {
      print('HOME jiosaavn-section ERROR: $e');
      if (mounted) setState(() => _jioSaavnLoading = false);
    }
  }

  Future<void> _loadItunesChart() async {
    if (!mounted) return;
    setState(() => _itunesLoading = true);
    try {
      final tracks =
          await ItunesChartsService.instance.getTopSongs(country: 'in', limit: 50);
      if (!mounted) return;
      setState(() {
        _itunesTop = tracks;
        _itunesLoading = false;
      });
    } catch (e) {
      print('HOME itunes-section ERROR: $e');
      if (mounted) setState(() => _itunesLoading = false);
    }
  }

  // Pull-to-refresh sabhi teeno source refresh kare (asli YT feed +
  // JioSaavn + iTunes) — taaki playlists "updated rehna chahiye" wali
  // requirement poori ho. Teeno parallel/independent hain, ek fail ho to
  // baaki do normally load ho jaayenge.
  Future<void> _refreshAll() async {
    await Future.wait([
      _load(),
      _loadJioSaavn(),
      _loadItunesChart(),
    ]);
  }

  void _openJioSaavnPlaylist(JioSaavnPlaylistPreview p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CuratedPlaylistScreen(
          title: p.title,
          subtitle: p.subtitle,
          metaLoader: () async {
            final tracks = await JioSaavnService.instance.getPlaylistTracks(p.id);
            return tracks.map((t) => CuratedTrackMeta(t.title, t.artist)).toList();
          },
        ),
      ),
    );
  }

  void _openItunesChart() {
    final snapshot = _itunesTop; // is tap ke waqt ka data, baad me badlega to bhi consistent
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CuratedPlaylistScreen(
          title: '🇮🇳 India Top Songs',
          subtitle: 'Apple Music charts',
          metaLoader: () async =>
              snapshot.map((t) => CuratedTrackMeta(t.title, t.artist)).toList(),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load();
    // JioSaavn/iTunes ko _load() se independent, parallel fire karte hain —
    // taaki asli YT feed ka loading in dono ke response ka wait na kare.
    _loadJioSaavn();
    _loadItunesChart();
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
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    // Neeche se ~400px pehle hi agla batch reveal karo, taaki user ko
    // scroll rukta hua na dikhe.
    if (pos.pixels < pos.maxScrollExtent - 400) return;
    if (_visibleSectionCount < _homeSections.length) {
      _revealMoreSections();
    } else if (_categoryExhausted.length < _kCategories.length) {
      // Curated feed khatam ho chuka — ab category-search se agla
      // (genuinely NAYA — continuation-paginated) section generate karo.
      // Jab tak KAM SE KAM ek category ke paas aur pages bache hain,
      // scroll kabhi "dead end" nahi hoga.
      _loadMoreExtraCategory();
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

  Future<void> _loadMoreExtraCategory() async {
    setState(() => _loadingMoreSections = true);
    try {
      // Cycle karte hue agli NON-EXHAUSTED category dhoondo (max ek poora
      // chakkar — agar sab exhausted hain to bahar nikal jao, upar wala
      // `_onScroll` guard waise bhi isko yahan tak aane hi nahi dega).
      for (var tries = 0; tries < _kCategories.length; tries++) {
        final cat = _kCategories[_extraCategoryCursor % _kCategories.length];
        _extraCategoryCursor++;
        if (_categoryExhausted.contains(cat.name)) continue;

        final page = await YoutubeService.instance.searchPage(
          cat.query,
          continuation: _categoryContinuation[cat.name],
        );
        _categoryContinuation[cat.name] = page.continuation;
        if (page.continuation == null) _categoryExhausted.add(cat.name);

        if (page.items.isNotEmpty) {
          if (mounted) {
            setState(() {
              _extraSections.add(_ExtraSection(
                title: '${cat.emoji} ${cat.name} — aur gaane',
                songs: page.items,
              ));
            });
          }
          break; // is scroll-trigger ke liye ek section kaafi hai
        }
        // Khaali page mila (par exhausted nahi) — agli category try karo
        // isi loop ke andar, taaki scroll "kuch nahi hua" jaisa na lage.
      }
    } catch (e) {
      // Ek category fail ho to bhi scroll "atka hua" nahi lagega — agli
      // baar scroll karne pe agli category try hogi.
      print('HOME extra-category ERROR: $e');
    } finally {
      if (mounted) setState(() => _loadingMoreSections = false);
    }
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
      String? dailyMixDebug;
      try {
        dailyMixes = await DailyMixService.instance.getTodaysMixes();
        // Sirf tab dikhega jab genuinely radio-pull fail hua ho (naye
        // user ke "abhi history hi nahi hai" case me chhupa rehta hai —
        // dekho daily_mix_service.dart ka lastDebugInfo).
        if (dailyMixes.isEmpty) {
          dailyMixDebug = DailyMixService.instance.lastDebugInfo;
        }
      } catch (e) {
        print('DAILY MIX _load() ERROR: $e');
        dailyMixDebug = 'EXCEPTION: $e';
      }

      // NEW: Discover Weekly — apna try/catch (Last.fm down ho, ya history
      // hi na ho — poora home feed fail nahi hona chahiye, section bas
      // hide ho jaata hai).
      DailyMix? discoverWeekly;
      try {
        final songs = await DiscoverWeeklyService.instance.getThisWeeksMix();
        if (songs.isNotEmpty) {
          discoverWeekly = DailyMix(
            title: 'Discover Weekly',
            seedArtist: 'Discover Weekly',
            songs: songs,
          );
        }
      } catch (e) {
        print('DISCOVER WEEKLY _load() ERROR: $e');
      }

      if (!mounted) return;
      setState(() {
        _homeSections = homeSections;
        _trending = results;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        _dailyMixes = dailyMixes;
        _discoverWeekly = discoverWeekly;
        _dailyMixDebug = dailyMixDebug;
        // Refresh (pull-to-refresh ya pehli load) — reveal-count reset,
        // taaki purane scroll-position ka batch naye feed pe carry na ho.
        _visibleSectionCount = _kInitialSectionBatch;
        // Extra (category-generated) sections bhi reset — naya feed aane
        // ke baad purani "aur gaane" sections dobara se cycle honi chahiye.
        _extraSections.clear();
        _extraCategoryCursor = 0;
        _categoryContinuation.clear();
        _categoryExhausted.clear();
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

  // NEW (2026-09-17): "aur gaane" (category-generated) extra sections se
  // play karne ke liye.
  Future<void> _playFromExtra(_ExtraSection section, int index) async {
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
      // NEW (2026-09-17): curated feed khatam hone ke baad generate hue
      // "aur gaane" (category-search) sections — asli infinite scroll.
      widgets.addAll(_buildExtraSectionWidgets());
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
      // Fallback (Trending Now) ke khatam hone ke baad bhi wahi extra
      // category-generated sections — yahan bhi scroll kabhi dead-end
      // nahi hona chahiye.
      ..._buildExtraSectionWidgets(),
    ];
  }

  // NEW (2026-09-17): dono feed-branches (curated + fallback trending) me
  // shared — "load more" spinner + ab tak generate hue extra sections.
  List<Widget> _buildExtraSectionWidgets() {
    final widgets = <Widget>[];
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
    for (final extra in _extraSections) {
      widgets.add(SectionHeader(title: extra.title));
      widgets.add(
        Column(
          children: List.generate(extra.songs.length, (i) {
            final r = extra.songs[i];
            final song = r.toSong();
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SongCard(
                song: song,
                isLiked: _likedIds.contains(song.id),
                isCached: _cachedIds.contains(song.id),
                onTap: () => _playFromExtra(extra, i),
                onPlay: () => _playFromExtra(extra, i),
                onDownload: () => _download(r),
                onLike: () => _toggleLike(song),
              ),
            );
          }),
        ),
      );
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshAll,
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
                      // Radio Mode — Phase 9 entry point. Keep this as a
                      // lightweight additive hook: tapping the icon opens the
                      // existing Radio language/session flow directly.
                      Semantics(
                        button: true,
                        label: 'Open Radio Mode',
                        child: IconButton(
                          tooltip: 'Radio Mode',
                          icon: const Icon(Icons.radio_rounded),
                          color: kTextDim,
                          splashRadius: 22,
                          onPressed: () async {
                            final prefs = await SharedPreferences.getInstance();
                            final saved = prefs.getStringList('radio_selected_languages') ?? const <String>[];
                            if (!context.mounted) return;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => saved.isNotEmpty
                                    ? RadioPlayerScreen(languages: saved)
                                    : const RadioLanguageSelectScreen(),
                              ),
                            );
                          },
                        ),
                      ),
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
                  ] else if (!_loading && _dailyMixDebug != null) ...[
                    // TEMPORARY — sirf tab dikhta hai jab Daily Mix
                    // genuinely fail hui ho (naya user "abhi history nahi
                    // hai" case me ye poora block hi nahi dikhta).
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Daily Mix nahi ban paayi: $_dailyMixDebug',
                        style: AppText.bodyS(color: kTextDim),
                      ),
                    ),
                  ],
                  // NEW — "Discover Weekly" (bonus feature — dekho
                  // discover_weekly_service.dart ka top comment): apna
                  // listening-history + YouTube radio + (agar configured
                  // hai) Last.fm "similar artist" data combine karke ek
                  // pura-hafta-stable list. Naya user (history nahi) ke
                  // liye khaali aata hai — section hide.
                  if (_discoverWeekly != null) ...[
                    SectionHeader(title: 'Discover Weekly'),
                    SizedBox(
                      height: 180,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _DailyMixCard(mix: _discoverWeekly!),
                        ],
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
                  // NEW (2026-09-19, v95) — extra curated-playlist sources.
                  // Dono sections independent hain (_jioSaavnLoading /
                  // _itunesLoading alag flags) — ek khaali/fail ho to
                  // doosra bhi normally dikhta rahega.
                  if (_jioSaavnLoading) ...[
                    SectionHeader(title: 'India ki Playlists'),
                    SizedBox(
                      height: 180,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: 4,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (_, __) => Container(
                          width: 130,
                          height: 130,
                          decoration: BoxDecoration(
                            color: kSurface,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ] else if (_jioSaavnPlaylists.isNotEmpty) ...[
                    SectionHeader(title: 'India ki Playlists'),
                    SizedBox(
                      height: 180,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _jioSaavnPlaylists.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, i) {
                          final p = _jioSaavnPlaylists[i];
                          return _LivePlaylistCard(
                            preview: YtPlaylistPreview(
                              id: p.id,
                              title: p.title,
                              subtitle: p.subtitle,
                              thumb: p.thumb,
                            ),
                            onTap: () => _openJioSaavnPlaylist(p),
                          );
                        },
                      ),
                    ),
                  ],
                  if (!_itunesLoading && _itunesTop.isNotEmpty) ...[
                    SectionHeader(title: 'iTunes — India Top Songs'),
                    SizedBox(
                      height: 180,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _LivePlaylistCard(
                            preview: YtPlaylistPreview(
                              id: 'itunes_top_in',
                              title: 'India Top ${_itunesTop.length}',
                              subtitle: 'Apple Music',
                              thumb: _itunesTop.first.artwork,
                            ),
                            onTap: _openItunesChart,
                          ),
                        ],
                      ),
                    ),
                  ],
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
