// lib/screens/search_screen.dart
// Search tab — debounced YouTube search, recent searches, popular chips.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../services/youtube_service.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../services/search_history.dart';
import '../widgets/song_card.dart';
import '../widgets/section_header.dart';
import '../widgets/mini_player.dart';
import 'add_to_playlist_sheet.dart';
import 'full_player_screen.dart';
import 'artist_screen.dart';
import 'live_playlist_screen.dart';

// Popular chips ke liye 8 fixed categories (naam -> search query)
const Map<String, String> _kPopular = {
  'Bollywood': 'bollywood hits songs',
  'Punjabi': 'punjabi hits songs',
  'Haryanvi': 'haryanvi hits songs',
  'Lo-Fi': 'lofi hits songs',
  'Party': 'party hits songs',
  'Romantic': 'romantic hits songs',
  'Workout': 'workout hits songs',
  'Old Hits': 'old hits songs',
};

class SearchScreen extends StatefulWidget {
  final String? initialQuery;
  const SearchScreen({super.key, this.initialQuery});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> with SingleTickerProviderStateMixin {
  late final TextEditingController _controller;
  late final TabController _tabController;
  Timer? _debounce;

  bool _loading = false;
  bool _searched = false;
  String _query = '';
  List<YtResult> _results = [];
  List<String> _history = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};
  String? _debugError; // TEMPORARY — screen pe error dikhane ke liye
  // NEW (2026-09-16, v15): kaunsa backend layer results de raha hai, ye
  // pehle sirf print() logs me jaata tha (onProgress kabhi UI se wire hi
  // nahi hua tha) — isliye "purane/generic YouTube results aa rahe hain,
  // YT Music jaisa nahi" jaisi complaints debug karna mushkil tha. Ab
  // results ke saath ek chhota source badge dikhta hai.
  String? _searchSource;

  // NEW — "Artists" aur "Playlists" tabs (YouTube Music jaisa categorized
  // search). Lazy-loaded: jab tak user us tab pe tap na kare, unki apni
  // alag network call nahi hoti (Songs tab pehle se load hoti hai).
  bool _artistsLoaded = false;
  bool _loadingArtists = false;
  List<YtArtistResult> _artistResults = [];

  bool _playlistsLoaded = false;
  bool _loadingPlaylists = false;
  List<YtPlaylistPreview> _playlistResults = [];

  // NEW — mic se search (voice search)
  final SpeechToText _speech = SpeechToText();
  bool _listening = false;

  // BUG FIX (2026-09-16, v17): "search unlimited nahi hai, limited gaane
  // aate hain" — ab Songs tab scroll ke end tak pahunchne pe khud-ba-khud
  // agla page load karta hai (dekho youtube_service.dart ka
  // loadMoreSearchResults()). _hasMore false hone ka matlab hai YouTube
  // ke paas is query ke liye aur results nahi bache (list khud khatam ho
  // gayi hai, koi bug nahi).
  final ScrollController _songsScrollController = ScrollController();
  bool _loadingMore = false;
  bool _hasMore = true;

  // BUG FIX (2026-09-16, v20): "purana gana search me dikhta hai" — koi
  // sequence guard nahi tha yahan. `_runSearch()` popular chip / history
  // tap / voice-search / debounced typing — kisi se bhi call ho sakta hai,
  // aur ye sab ek dusre ko cancel nahi karte the. Agar user jaldi-jaldi do
  // alag queries chala de (e.g. ek chip tap kiya, network slow nikla, phir
  // dusra chip tap kar diya), to DONO ke network calls parallel chalte the
  // — jo bhi baad me (kisi bhi order me) complete hota, wahi `setState()`
  // se `_results` ko overwrite kar deta tha. Matlab agar PEHLI (purani)
  // query ka response DUSRI (nayi) query ke response ke BAAD aata, to
  // screen pe purani/galat query ke results reh jaate the — bilkul jaisa
  // user report kar raha tha ("purana gana araha hai"), search bar me text
  // kuch aur hoga lekin list neeche purani query ki hogi.
  // Fix: har `_runSearch()` call apna unique `_searchSeq` token leta hai.
  // Jab response aaye, check hota hai ki ye ab bhi LATEST search hai ki
  // nahi — agar iske baad koi naya search shuru ho chuka hai, to ye purana
  // response chup-chaap discard ho jaata hai (state ko touch hi nahi
  // karta).
  int _searchSeq = 0;

  // NEW (2026-09-16, v21): YouTube/YT Music jaisa "Upload date" filter —
  // dekho _buildDateFilterChips(). Default relevance hai (purana behavior,
  // koi change nahi).
  YtDateFilter _dateFilter = YtDateFilter.relevance;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(_onTabChanged);
    _songsScrollController.addListener(_onSongsScroll);
    _loadHistory();
    if ((widget.initialQuery ?? '').trim().isNotEmpty) {
      _runSearch(widget.initialQuery!.trim());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _songsScrollController.removeListener(_onSongsScroll);
    _songsScrollController.dispose();
    if (_listening) _speech.stop();
    super.dispose();
  }

  // List ke aakhri ~400px reh jaane pe agla page load shuru kar do —
  // isse user ko "load more" button dabana nahi padta, YouTube Music jaisa
  // seamless infinite scroll milta hai.
  void _onSongsScroll() {
    if (_loadingMore || !_hasMore || !_searched) return;
    if (!_songsScrollController.hasClients) return;
    final pos = _songsScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) {
      _loadMoreResults();
    }
  }

  // BUG FIX (v17, cont.): agar results itne kam hain ki list screen ko
  // scroll hi nahi karti (chhoti screen ya bahut kam results), to
  // _onSongsScroll() kabhi trigger hi nahi hota (scroll listener sirf
  // asal scroll event pe fire hota hai) — list "unlimited" feel hone ke
  // bajaye hamesha wahi chhota batch dikhati reh jaati. Isliye har naye
  // results set ke baad (initial search ya load-more), ek frame ke baad
  // check karte hain ki list abhi bhi scrollable nahi hai — agar nahi
  // hai aur aur results ho sakte hain, to khud hi agla page load kar
  // dete hain.
  void _maybeAutoLoadMore() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadingMore || !_hasMore) return;
      if (!_songsScrollController.hasClients) return;
      if (_songsScrollController.position.maxScrollExtent <= 0) {
        _loadMoreResults();
      }
    });
  }

  Future<void> _loadMoreResults() async {
    if (_loadingMore || !_hasMore || _query.isEmpty) return;
    final seq = _searchSeq; // isi search session ka "load more" hai
    final query = _query;
    setState(() => _loadingMore = true);
    final more = await YoutubeService.instance.loadMoreSearchResults(
      query,
      dateFilter: _dateFilter,
    );
    // BUG FIX (v20): agar is dauraan user ne naya search chala diya
    // (`_searchSeq` aage badh gaya), to ye purani query ka "load more"
    // response naye query ke `_results` me mix nahi hona chahiye —
    // discard kar do (dekho `_searchSeq` comment upar).
    if (!mounted || seq != _searchSeq) return;
    // Pehle se dikh rahe IDs (Layer 1 ka pehla batch ya pichhle pages) ko
    // dobara na dikhaye — explode ka page 1 kabhi-kabhi YT Music ke
    // results se overlap kar sakta hai.
    final existingIds = _results.map((r) => r.id).toSet();
    final fresh = more.where((r) => !existingIds.contains(r.id)).toList();
    setState(() {
      _results = [..._results, ...fresh];
      _loadingMore = false;
      // Agar YouTube ne bilkul khaali page diya (list khud khatam), ya
      // lagataar sirf duplicate hi mile (matlab naya kuch nahi bacha), to
      // aage try karna band kar do.
      if (more.isEmpty) _hasMore = false;
    });
    _maybeAutoLoadMore();
  }

  // Jis tab pe user pehli baar jaaye, uski results us waqt load hoti hain
  // (query already _runSearch se pata chal chuki hoti hai).
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index == 1 && !_artistsLoaded) {
      _loadArtists(_query);
    } else if (_tabController.index == 2 && !_playlistsLoaded) {
      _loadPlaylists(_query);
    }
    // NEW (v21): date-filter chips row sirf Songs tab pe dikhti hai —
    // tab badalne pe rebuild taaki wo row dikhe/chhupe.
    if (mounted) setState(() {});
  }

  // NEW (2026-09-16, v21): YouTube/YT Music jaisa "Upload date" filter chip
  // select hone pe — sirf tab badle to hi dobara search chalao (khamakha
  // wahi filter dobara select karne pe kuch na ho).
  void _onDateFilterChanged(YtDateFilter f) {
    if (f == _dateFilter) return;
    setState(() => _dateFilter = f);
    if (_query.isNotEmpty) _runSearch(_query);
  }

  static const Map<YtDateFilter, String> _kDateFilterLabels = {
    YtDateFilter.relevance: 'Relevance',
    YtDateFilter.hour: 'Last hour',
    YtDateFilter.today: 'Today',
    YtDateFilter.week: 'This week',
    YtDateFilter.month: 'This month',
    YtDateFilter.year: 'This year',
  };

  // YouTube/YT Music jaisa filter-chips row — "Relevance" default hai
  // (purana behavior), baaki sab "Upload date" se filter karte hain.
  Widget _buildDateFilterChips() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: _kDateFilterLabels.entries.map((e) {
          final selected = _dateFilter == e.key;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(e.value),
              selected: selected,
              onSelected: (_) => _onDateFilterChanged(e.key),
              selectedColor: kGreen,
              backgroundColor: kBgElev,
              labelStyle: AppText.bodyS(
                color: selected ? Colors.black : kText,
              ).copyWith(fontWeight: selected ? FontWeight.bold : FontWeight.normal),
              side: BorderSide.none,
            ),
          );
        }).toList(),
      ),
    );
  }

  Future<void> _loadArtists(String query) async {
    if (query.isEmpty) return;
    setState(() => _loadingArtists = true);
    final results = await YoutubeService.instance.searchArtists(query);
    if (!mounted) return;
    setState(() {
      _artistResults = results;
      _artistsLoaded = true;
      _loadingArtists = false;
    });
  }

  Future<void> _loadPlaylists(String query) async {
    if (query.isEmpty) return;
    setState(() => _loadingPlaylists = true);
    final results = await YoutubeService.instance.searchPlaylists(query);
    if (!mounted) return;
    setState(() {
      _playlistResults = results;
      _playlistsLoaded = true;
      _loadingPlaylists = false;
    });
  }

  // ---------------- Voice search ----------------

  Future<void> _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    final available = await _speech.initialize(
      onStatus: (status) {
        if ((status == 'done' || status == 'notListening') && mounted) {
          setState(() => _listening = false);
        }
      },
      onError: (error) {
        if (mounted) setState(() => _listening = false);
      },
    );
    if (!available) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Voice search is device pe available nahi hai')),
      );
      return;
    }
    setState(() => _listening = true);
    await _speech.listen(
      onResult: (result) {
        _controller.text = result.recognizedWords;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
        if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
          setState(() => _listening = false);
          _runSearch(result.recognizedWords.trim());
        }
      },
    );
  }

  Future<void> _loadHistory() async {
    final h = await SearchHistory.instance.getAll();
    if (!mounted) return;
    setState(() => _history = h);
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _searched = false;
        _results = [];
      });
      _loadHistory();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () {
      _runSearch(value.trim());
    });
  }

  Future<void> _runSearch(String query) async {
    if (query.isEmpty) return;
    if (!mounted) return;
    final seq = ++_searchSeq; // is search ka apna unique token
    setState(() {
      _loading = true;
      _searched = true;
      _query = query;
      _searchSource = null;
      // Naya query — purane Artists/Playlists tab results ab stale hain
      _artistsLoaded = false;
      _artistResults = [];
      _playlistsLoaded = false;
      _playlistResults = [];
      // Naya query — purani pagination state reset karo taaki naye query
      // ke "load more" purane query ke page se continue na ho.
      _hasMore = true;
      _loadingMore = false;
    });
    // Agar user pehle se Artists/Playlists tab pe hai, turant reload karo
    if (_tabController.index == 1) {
      _loadArtists(query);
    } else if (_tabController.index == 2) {
      _loadPlaylists(query);
    }

    // BUG FIX: pehle yahan try-catch nahi tha. SearchHistory.add(),
    // LikedDB.getAll() ya CacheDB.getAll() me se koi bhi fail hota
    // (YoutubeService.search() ke andar to already try-catch hai, isliye
    // wo khud kabhi throw nahi karta) to setState() wali line skip ho
    // jaati aur `_loading` hamesha `true` reh jaata — isliye search screen
    // pe kabhi kuch nahi dikhta tha (spinner atka rehta), jabki debug
    // screen pe same query kaam kar rahi thi (wahan LikedDB/CacheDB
    // touch hi nahi hota).
    try {
      await SearchHistory.instance.add(query);
      // NEW: onProgress se pata chalta hai YT Music (Layer 1) ya generic
      // YouTube search (Layer 2, fallback) — dono me se kaunsa results
      // de raha hai. Sirf last/relevant status line rakhte hain.
      String? source;
      final results = await YoutubeService.instance.search(
        query,
        dateFilter: _dateFilter,
        onProgress: (status) {
          if (status.startsWith('YT Music: OK')) {
            source = 'YouTube Music';
          } else if (status.startsWith('YouTube search: OK')) {
            source = 'YouTube (generic — YT Music se match nahi mila)';
          }
        },
      );
      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();

      // Is response ke aane tak koi NAYA search shuru ho chuka ho to ye
      // purana response chup-chaap discard — state ko touch hi mat karo
      // (dekho `_searchSeq` comment upar).
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = results;
        _searchSource = source;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        _debugError = results.isEmpty
            ? 'search() ne 0 results diye (exception nahi aayi — ho sakta'
                ' hai YouTube rate-limit kar raha ho)'
            : null;
      });
      _maybeAutoLoadMore();
    } catch (e) {
      print('SEARCH _runSearch() ERROR: $e');
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _results = []; // empty state dikhega, spinner atka nahi rahega
        _debugError = 'EXCEPTION: $e'; // TEMPORARY — screen pe dikhega
      });
    } finally {
      if (mounted && seq == _searchSeq) {
        setState(() => _loading = false);
      }
    }

    if (mounted) {
      _loadHistory();
    }
  }

  void _searchFor(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: query.length),
    );
    _runSearch(query);
  }

  Future<void> _playResult(int index) async {
    final songs = _results.map((r) => r.toSong()).toList();
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

  Future<void> _addToPlaylist(Song song) async {
    await showAddToPlaylistSheet(context, song);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: TextField(
          controller: _controller,
          autofocus: widget.initialQuery == null,
          cursorColor: kGreen,
          style: AppText.bodyL(color: kText),
          onChanged: _onChanged,
          onSubmitted: (v) => _runSearch(v.trim()),
          decoration: InputDecoration(
            hintText: 'Gaana, artist, album...',
            hintStyle: AppText.bodyM(color: kTextDim),
            border: InputBorder.none,
            suffixIconConstraints: const BoxConstraints(minWidth: 84, maxHeight: 48),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // NEW — mic se bol ke search karo
                IconButton(
                  icon: Icon(
                    _listening ? Icons.mic : Icons.mic_none,
                    color: _listening ? kGreen : kTextDim,
                  ),
                  tooltip: 'Bol ke search karo',
                  onPressed: _toggleListening,
                ),
                if (_controller.text.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close, color: kTextDim),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  )
                else
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(Icons.search, color: kTextDim),
                  ),
              ],
            ),
          ),
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
    if (!_searched) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          if (_history.isNotEmpty) ...[
            SectionHeader(title: 'Recent Searches'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _history
                  .map(
                    (q) => ActionChip(
                      label: Text(q, style: AppText.bodyS(color: kText)),
                      backgroundColor: kSurface,
                      onPressed: () => _searchFor(q),
                    ),
                  )
                  .toList(),
            ),
          ],
          SectionHeader(title: 'Popular'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _kPopular.entries
                .map(
                  (e) => ActionChip(
                    label: Text(e.key, style: AppText.bodyS(color: kText)),
                    backgroundColor: kBgElev,
                    onPressed: () => _searchFor(e.value),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 40),
        ],
      );
    }

    // NEW — search ho chuki hai: ab YouTube Music jaisa 3 tabs me results
    // (Songs / Artists / Playlists), har tab apni khud ki loading/empty
    // state handle karta hai.
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          indicatorColor: kGreen,
          labelColor: kGreen,
          unselectedLabelColor: kTextDim,
          labelStyle: AppText.bodyS().copyWith(fontWeight: FontWeight.bold),
          tabs: const [
            Tab(text: 'Songs'),
            Tab(text: 'Artists'),
            Tab(text: 'Playlists'),
          ],
        ),
        // NEW (v21): "Upload date" filter chips — YouTube/YT Music jaisa.
        // Sirf Songs tab pe relevant hai (Artists/Playlists is filter ko
        // use hi nahi karte).
        if (_tabController.index == 0) _buildDateFilterChips(),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSongsTab(),
              _buildArtistsTab(),
              _buildPlaylistsTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSongsTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kGreen));
    }

    if (_results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, color: Colors.white24, size: 64),
            const SizedBox(height: 12),
            Text('Kuch nahi mila', style: AppText.bodyM(color: kTextDim)),
            // TEMPORARY — debug ke liye
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
      );
    }

    // Extra rows: 1 source badge (agar hai) + 1 "load more" spinner/end
    // marker row hamesha aakhir me (jab tak search ho chuki hai).
    final hasHeader = _searchSource != null;

    return ListView.builder(
      controller: _songsScrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _results.length + (hasHeader ? 1 : 0) + 1,
      itemBuilder: (context, i) {
        // TEMPORARY debug badge — batata hai results kaunse layer se aaye
        // (YT Music vs generic YouTube fallback), taaki "purane/wrong
        // gaane aa rahe hain" jaisi complaints me pata chal sake ki YT
        // Music layer fail kyun ho raha tha.
        if (hasHeader) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Source: $_searchSource',
                style: AppText.bodyS(color: kTextDim).copyWith(fontSize: 11),
              ),
            );
          }
          i -= 1;
        }

        // BUG FIX (2026-09-16, v17): "search unlimited nahi hai" — list
        // ka aakhri item ab ek "load more" marker hai. Jab tak aur
        // results available ho sakte hain (_hasMore), yahan pahunchte hi
        // _onSongsScroll() khud-ba-khud agla page load kar deta hai
        // (spinner dikhta hai). Jab YouTube ke paas is query ke liye
        // sach me aur kuch bacha na ho (_hasMore false), "Aur gaane nahi
        // bache" dikhta hai — taaki ye clear ho ki list-end hai, koi
        // atka hua loading nahi.
        if (i == _results.length) {
          if (!_hasMore) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Text(
                  'Aur gaane nahi bache',
                  style: AppText.bodyS(color: kTextDim),
                ),
              ),
            );
          }
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: kGreen),
              ),
            ),
          );
        }

        final r = _results[i];
        final song = r.toSong();
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: SongCard(
            song: song,
            isLiked: _likedIds.contains(song.id),
            isCached: _cachedIds.contains(song.id),
            onTap: () => _playResult(i),
            onPlay: () => _playResult(i),
            onAddToPlaylist: () => _addToPlaylist(song),
            onLike: () => _toggleLike(song),
          ),
        );
      },
    );
  }

  Widget _buildArtistsTab() {
    if (_loadingArtists) {
      return const Center(child: CircularProgressIndicator(color: kGreen));
    }
    if (_artistResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined, color: Colors.white24, size: 64),
            const SizedBox(height: 12),
            Text('Koi artist nahi mila', style: AppText.bodyM(color: kTextDim)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _artistResults.length,
      itemBuilder: (context, i) {
        final a = _artistResults[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: kBgElev,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ArtistScreen(artistName: a.name, artistThumb: a.thumb),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: a.thumb,
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            Container(width: 52, height: 52, color: kSurface),
                        errorWidget: (context, url, error) => Container(
                          width: 52,
                          height: 52,
                          color: kSurface,
                          child: const Icon(Icons.person, color: kTextDim),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyM(color: kText).copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: kTextDim),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlaylistsTab() {
    if (_loadingPlaylists) {
      return const Center(child: CircularProgressIndicator(color: kGreen));
    }
    if (_playlistResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.queue_music, color: Colors.white24, size: 64),
            const SizedBox(height: 12),
            Text('Koi playlist nahi mili', style: AppText.bodyM(color: kTextDim)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _playlistResults.length,
      itemBuilder: (context, i) {
        final pl = _playlistResults[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: kBgElev,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LivePlaylistScreen(
                    playlistId: pl.id,
                    title: pl.title,
                    subtitle: pl.subtitle,
                    thumb: pl.thumb,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: CachedNetworkImage(
                        imageUrl: pl.thumb,
                        width: 56,
                        height: 56,
                        fit: BoxFit.cover,
                        placeholder: (context, url) =>
                            Container(width: 56, height: 56, color: kSurface),
                        errorWidget: (context, url, error) => Container(
                          width: 56,
                          height: 56,
                          color: kSurface,
                          child: const Icon(Icons.queue_music, color: kTextDim),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            pl.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyM(color: kText).copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            pl.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.bodyS().copyWith(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: kTextDim),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------- Shared mini player wrapper (search screen) ----------------

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
