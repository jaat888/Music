// lib/screens/search_screen.dart
// Search tab — debounced YouTube search, recent searches, popular chips.

import 'dart:async';

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
import '../services/search_history.dart';
import '../widgets/song_card.dart';
import '../widgets/section_header.dart';
import '../widgets/mini_player.dart';
import 'add_to_playlist_sheet.dart';
import 'full_player_screen.dart';

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

class _SearchScreenState extends State<SearchScreen> {
  late final TextEditingController _controller;
  Timer? _debounce;

  bool _loading = false;
  bool _searched = false;
  List<YtResult> _results = [];
  List<String> _history = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};
  String? _debugError; // TEMPORARY — screen pe error dikhane ke liye

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
    _loadHistory();
    if ((widget.initialQuery ?? '').trim().isNotEmpty) {
      _runSearch(widget.initialQuery!.trim());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
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
    setState(() {
      _loading = true;
      _searched = true;
    });

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
      final results = await YoutubeService.instance.search(query);
      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();

      if (!mounted) return;
      setState(() {
        _results = results;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        _debugError = results.isEmpty
            ? 'search() ne 0 results diye (exception nahi aayi — ho sakta'
                ' hai YouTube rate-limit kar raha ho)'
            : null;
      });
    } catch (e) {
      print('SEARCH _runSearch() ERROR: $e');
      if (!mounted) return;
      setState(() {
        _results = []; // empty state dikhega, spinner atka nahi rahega
        _debugError = 'EXCEPTION: $e'; // TEMPORARY — screen pe dikhega
      });
    } finally {
      if (mounted) {
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
    await audioHandler.playWithRetry(
      songs[index],
      YoutubeService.instance.getAudioUrl,
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
            suffixIcon: _controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, color: kTextDim),
                    onPressed: () {
                      _controller.clear();
                      _onChanged('');
                    },
                  )
                : const Icon(Icons.search, color: kTextDim),
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

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _results.length,
      itemBuilder: (context, i) {
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
