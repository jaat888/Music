// lib/screens/live_playlist_screen.dart
// NEW (2026-09-16, v11): YouTube Music ki ek curated/"live" playlist ke
// andar ke gaane dikhata hai. Home feed (getHomeFeed) me jo playlist
// cards aate hain, unhe tap karne pe ye screen khulti hai aur us
// playlist ke tracks getYtMusicPlaylistTracks() se load karti hai —
// koi hardcoded data nahi, seedha YT Music se live aata hai.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../services/youtube_service.dart';
import '../services/background_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../services/download_queue_service.dart';
import '../db/playlist_db.dart';
import '../models/playlist.dart';
import 'package:uuid/uuid.dart';
import '../widgets/song_card.dart';
import '../widgets/shimmer_song_card.dart';
import '../widgets/mini_player.dart';
import 'add_to_playlist_sheet.dart';
import 'full_player_screen.dart';

class LivePlaylistScreen extends StatefulWidget {
  final String playlistId;
  final String title;
  final String subtitle;
  final String thumb;

  const LivePlaylistScreen({
    super.key,
    required this.playlistId,
    required this.title,
    required this.subtitle,
    required this.thumb,
  });

  @override
  State<LivePlaylistScreen> createState() => _LivePlaylistScreenState();
}

class _LivePlaylistScreenState extends State<LivePlaylistScreen> {
  bool _loading = true;
  List<YtResult> _tracks = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final tracks = await YoutubeService.instance.getYtMusicPlaylistTracks(
        widget.playlistId,
        fallbackTitle: widget.title,
        fallbackSubtitle: widget.subtitle,
      );
      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        _error = tracks.isEmpty
            ? 'Ye playlist abhi load nahi ho paayi (khaali hai ya YouTube'
                ' se load fail hua). Thodi der baad try karo.'
            : null;
      });
    } catch (e) {
      print('LIVE PLAYLIST _load() ERROR: $e');
      if (!mounted) return;
      setState(() {
        _tracks = [];
        _error = 'EXCEPTION: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _playFrom(int index) async {
    final songs = _tracks.map((r) => r.toSong()).toList();
    context.read<QueueService>().setQueue(songs, startIndex: index);
    await audioHandler.playWithRetry(songs[index]);
  }

  Future<void> _playAll() async {
    if (_tracks.isEmpty) return;
    await _playFrom(0);
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

  // NEW (v41 — user request): poori playlist ek tap me local library me
  // save karo (naya playlist bana ke) — bilkul "Import" feature jaisa hi,
  // bas seedha isi screen se, koi link paste nahi karna.
  Future<void> _addAllToLibrary() async {
    if (_tracks.isEmpty) return;
    final controller = TextEditingController(text: widget.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Library me save karein', style: AppText.displayS()),
        content: TextField(
          controller: controller,
          style: AppText.bodyM(),
          decoration: const InputDecoration(labelText: 'Playlist ka naam'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text('Save', style: AppText.button(color: kGreen)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final id = const Uuid().v4();
    await PlaylistDB.instance.createPlaylist(
      Playlist(
        id: id,
        name: name,
        coverEmoji: '📥',
        coverGradient: 'default',
        songIds: const [],
        createdAt: DateTime.now(),
      ),
    );
    for (final r in _tracks) {
      await PlaylistDB.instance.addSongToPlaylist(id, r.toSong());
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$name" library me save ho gayi — ${_tracks.length} gaane')),
    );
  }

  // NEW (v41 — user request): poori playlist ek tap me download queue me
  // daal do — jo already downloaded/queued hain wo skip ho jaate hain.
  //
  // BUG FIX (2026-09-17, v42 — "playlist download pe app lag karti hai"):
  // pehle yahan loop mein har gaane ke liye alag `enqueue()` call hota tha
  // (98 gaano ke liye 98 alag notifyListeners() — ek hi frame ke andar
  // itne UI rebuild se lag hota tha). Ab `enqueueAll()` — poori list ek
  // saath, sirf EK notify.
  Future<void> _downloadAll() async {
    if (_tracks.isEmpty) return;
    final songs = _tracks.map((r) => r.toSong()).toList();
    final before = DownloadQueueService.instance.queue.length +
        DownloadQueueService.instance.activeSongs.length;
    DownloadQueueService.instance.enqueueAll(songs);
    final added = DownloadQueueService.instance.queue.length +
        DownloadQueueService.instance.activeSongs.length -
        before;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$added gaane download queue mein daal diye')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
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
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.arrow_back, color: kText),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: widget.thumb.isNotEmpty
                              ? CachedNetworkImage(
                                  imageUrl: widget.thumb,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    width: 72,
                                    height: 72,
                                    color: kSurface,
                                    child:  Icon(Icons.queue_music,
                                        color: kTextDim),
                                  ),
                                )
                              : Container(
                                  width: 72,
                                  height: 72,
                                  color: kSurface,
                                  child:  Icon(Icons.queue_music,
                                      color: kTextDim),
                                ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                style: AppText.displayS(),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (widget.subtitle.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  widget.subtitle,
                                  style: AppText.bodyM(color: kTextDim),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_tracks.isNotEmpty)
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _playAll,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: kGreen,
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Play All'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // NEW (v41): poori playlist library me save karo
                          Container(
                            decoration: BoxDecoration(
                              color: kSurface,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: IconButton(
                              icon: Icon(Icons.playlist_add, color: kText),
                              tooltip: 'Library me save karein',
                              onPressed: _addAllToLibrary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // NEW (v41): poori playlist ek tap me download
                          Container(
                            decoration: BoxDecoration(
                              color: kSurface,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: IconButton(
                              icon: Icon(Icons.download_for_offline_outlined, color: kText),
                              tooltip: 'Playlist download karo',
                              onPressed: _downloadAll,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    if (_loading)
                      Column(
                        children: List.generate(5, (_) => const ShimmerSongCard()),
                      )
                    else if (_tracks.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Center(
                          child: Column(
                            children: [
                              Text(
                                'Kuch nahi mila',
                                style: AppText.bodyM(color: kTextDim),
                              ),
                              if (_error != null) ...[
                                const SizedBox(height: 10),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 20),
                                  child: Text(
                                    _error!,
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
                        children: List.generate(_tracks.length, (i) {
                          final r = _tracks[i];
                          final song = r.toSong();
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: SongCard(
                              song: song,
                              isLiked: _likedIds.contains(song.id),
                              isCached: _cachedIds.contains(song.id),
                              onTap: () => _playFrom(i),
                              onPlay: () => _playFrom(i),
                              onAddToPlaylist: () => _addToPlaylist(song),
                              onLike: () => _toggleLike(song),
                            ),
                          );
                        }),
                      ),
                    const SizedBox(height: 90),
                  ],
                ),
              ),
            ),
            _LivePlaylistMiniPlayerBar(),
          ],
        ),
      ),
    );
  }
}

class _LivePlaylistMiniPlayerBar extends StatelessWidget {
  const _LivePlaylistMiniPlayerBar();

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
