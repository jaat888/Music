// lib/screens/playlist_detail_screen.dart
// Ek playlist ka poora view — cover, songs list (drag reorder + swipe delete),
// rename/change-cover/share/delete menu.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../db/playlist_db.dart';
import '../db/liked_db.dart';
import '../db/cache_db.dart';
import '../db/download_db.dart';
import '../services/background_service.dart';
import '../services/download_queue_service.dart';
import '../services/queue_service.dart';
import '../services/like_service.dart';
import '../widgets/song_card.dart';
import '../widgets/shimmer_song_card.dart';
import 'create_playlist_screen.dart';
import 'search_screen.dart';
import 'add_to_playlist_sheet.dart';
import '../widgets/mini_player.dart';
import 'full_player_screen.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistId;
  const PlaylistDetailScreen({super.key, required this.playlistId});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  bool _loading = true;
  Playlist? _playlist;
  List<Song> _songs = [];
  Set<String> _likedIds = {};
  Set<String> _cachedIds = {};
  Set<String> _downloadedIds = {};

  // PART 5 (2026-09-17) — "Recently added" sort toggle. `_recentlyAddedIds`
  // DB se ordered ids (added_at DESC) hain; `_displaySongs` getter isi
  // order me `_songs` (jinka poora Song data already loaded/resolved hai)
  // ko rearrange karta hai — koi extra DB fetch/resolve nahi. Jab ye ON
  // hai, drag-to-reorder disable ho jaata hai (recently-added order ek
  // computed view hai, manual reorder ka concept yahan nahi banta).
  bool _sortRecentlyAdded = false;
  List<String> _recentlyAddedIds = [];

  List<Song> get _displaySongs {
    if (!_sortRecentlyAdded) return _songs;
    final byId = {for (final s in _songs) s.id: s};
    final ordered = _recentlyAddedIds.map((id) => byId[id]).whereType<Song>().toList();
    // Safety: agar koi song `_recentlyAddedIds` me na ho (edge case — bahut
    // purana data jiska `added_at` kisi wajah se missing ho), use bhi list
    // ke aakhir me dikha do, gayab na ho.
    final seen = ordered.map((s) => s.id).toSet();
    ordered.addAll(_songs.where((s) => !seen.contains(s.id)));
    return ordered;
  }

  @override
  void initState() {
    super.initState();
    _load();
    // BUG FIX (v37): ek dedicated listener (single field ki jagah list-
    // based, dekho download_queue_service.dart) — sirf isi screen ki
    // _downloadedIds update karta hai, kisi aur (jaise main.dart ka global
    // SnackBar) listener ko overwrite nahi karta. dispose() mein hataana
    // zaroori hai warna screen band hone ke baad bhi ye reference rukega.
    DownloadQueueService.instance.addFinishListener(_onDownloadFinished);
  }

  void _onDownloadFinished(Song song, bool success) {
    if (success && mounted) setState(() => _downloadedIds.add(song.id));
  }

  @override
  void dispose() {
    DownloadQueueService.instance.removeFinishListener(_onDownloadFinished);
    super.dispose();
  }

  // BATCH 14B: PlaylistDB.getPlaylistSongs() ab seedha List<Song> deta hai
  // (title/artist/thumb/duration playlist_songs table me hi save hote
  // hain, purane data ke liye Liked/Cache/Download DB fallback bhi
  // PlaylistDB ke andar hi handle ho jaata hai) — isliye yahan alag se
  // resolve karne ki zaroorat nahi rahi.
  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final playlist = await PlaylistDB.instance.getPlaylist(widget.playlistId);
      final songs = playlist == null
          ? <Song>[]
          : await PlaylistDB.instance.getPlaylistSongs(playlist.id);
      final recentlyAddedIds = playlist == null
          ? <String>[]
          : await PlaylistDB.instance.getRecentlyAddedSongIds(playlist.id);
      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();
      final downloaded = await DownloadDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _playlist = playlist;
        _songs = songs;
        _recentlyAddedIds = recentlyAddedIds;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
        _downloadedIds = downloaded.map((s) => s.id).toSet();
      });
    } catch (e) {
      print('PLAYLIST_DETAIL _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalMinutes =>
      (_songs.fold<int>(0, (sum, s) => sum + s.duration) / 60).round();

  Future<void> _playAll({bool shuffle = false}) async {
    if (_songs.isEmpty) return;
    // "Recently Added" sort ON ho to usi order me play karo (jo screen pe
    // dikh raha hai) — consistent feel, "Play All" wahi bajaye jo user dekh
    // raha hai.
    var list = List<Song>.of(_displaySongs);
    if (shuffle) {
      list.shuffle();
      context.read<QueueService>().setShuffle(true);
    }
    context.read<QueueService>().setQueue(list, startIndex: 0);
    await audioHandler.playWithRetry(list.first);
  }

  // BUG FIX (Part 5): pehle `int index` leta tha jo hamesha `_songs`
  // (position-order) ke against resolve hota tha — "Recently Added" sort ON
  // hone par UI `_displaySongs` (ALAG order) dikhata, isliye tap karne par
  // galat gaana baj jaata (index mismatch). Ab poora `Song` object leta hai
  // aur currently-DISPLAYED list ke against hi apna index nikalta hai.
  Future<void> _playFrom(Song song) async {
    final list = _displaySongs;
    final startIndex = list.indexOf(song);
    context.read<QueueService>().setQueue(list, startIndex: startIndex < 0 ? 0 : startIndex);
    await audioHandler.playWithRetry(song);
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

  Future<void> _download(Song song) async {
    // FIX (user request): single-song download pehle duplicate check nahi
    // karta tha (sirf "Download All" karta tha) — ab yahan bhi check hai.
    if (_downloadedIds.contains(song.id) ||
        await DownloadDB.instance.exists(song.id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ye gaana pehle se downloaded hai')),
      );
      return;
    }
    // BUG FIX (v37 — download queue/progress visibility): shared
    // DownloadQueueService use karte hain; jab wo poora ho jaaye to
    // _downloadedIds update kar do taaki UI turant reflect kare.
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

  // NEW — poori playlist ek baar me download karo.
  //
  // BUG FIX (2026-09-17, v42): pehle ye apna ALAG serial for-loop chalata
  // tha (shared DownloadQueueService use hi nahi karta tha) — ek modal
  // dialog block kiye rakhta jab tak sab 1-1 karke download na ho jaayein.
  // Ab shared queue ka `enqueueAll()` use karta hai — poori playlist ek
  // saath queue mein jaati hai, 3-parallel download (speed fix), aur
  // Downloads screen se progress/pause bhi dikhta hai, koi blocking dialog
  // nahi.
  Future<void> _downloadAll() async {
    if (_songs.isEmpty) return;
    final toQueue = <Song>[];
    var skipped = 0;
    for (final song in _songs) {
      if (await DownloadDB.instance.exists(song.id)) {
        skipped++;
      } else {
        toQueue.add(song);
      }
    }
    DownloadQueueService.instance.enqueueAll(toQueue);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${toQueue.length} gaane download queue mein daale, $skipped pehle se downloaded',
        ),
      ),
    );
  }

  Future<void> _removeSong(Song song) async {
    await PlaylistDB.instance.removeSongFromPlaylist(widget.playlistId, song.id);
    if (!mounted) return;
    setState(() => _songs.removeWhere((s) => s.id == song.id));
  }

  Future<void> _confirmRemove(Song song) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Playlist se hataein?', style: AppText.displayS()),
        content: Text('"${song.title}" is playlist se hat jayega.', style: AppText.bodyM()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Hatao', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
    if (confirm == true) await _removeSong(song);
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) newIndex -= 1;
    setState(() {
      final item = _songs.removeAt(oldIndex);
      _songs.insert(newIndex, item);
    });
    // Fire-and-forget — UI already reordered locally (jaisa background_service
    // ka auto-cache pattern hai, dekho NOTES.md #4).
    PlaylistDB.instance.reorderSongs(widget.playlistId, _songs.map((s) => s.id).toList());
  }

  Future<void> _rename() async {
    final playlist = _playlist;
    if (playlist == null) return;
    final ctrl = TextEditingController(text: playlist.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Rename Playlist', style: AppText.displayS()),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          cursorColor: kGreen,
          style: AppText.bodyL(color: kText),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text('Save', style: AppText.button(color: kGreen)),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    final updated = playlist.copyWith(name: newName);
    await PlaylistDB.instance.createPlaylist(updated); // replace = update, dekho NOTES.md
    if (!mounted) return;
    setState(() => _playlist = updated);
  }

  Future<void> _changeCover() async {
    final playlist = _playlist;
    if (playlist == null) return;
    String emoji = playlist.coverEmoji;
    String key = playlist.coverGradient;

    await showModalBottomSheet(
      context: context,
      backgroundColor: kBgElev,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Cover badlo', style: AppText.displayS()),
                const SizedBox(height: 14),
                SizedBox(
                  height: 64,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: kPlaylistEmojis.length,
                    itemBuilder: (context, i) {
                      final e = kPlaylistEmojis[i];
                      return GestureDetector(
                        onTap: () => setSheetState(() => emoji = emoji == e ? '' : e),
                        child: Container(
                          width: 56,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: kSurface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: emoji == e ? kGreen : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(e, style: const TextStyle(fontSize: 24)),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  height: 60,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: kPlaylistGradients.length,
                    itemBuilder: (context, i) {
                      final k = kPlaylistGradients.keys.elementAt(i);
                      return GestureDetector(
                        onTap: () => setSheetState(() => key = k),
                        child: Container(
                          width: 60,
                          margin: const EdgeInsets.only(right: 10),
                          decoration: BoxDecoration(
                            gradient: kPlaylistGradients[k],
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: key == k ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kGreen,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: Text('Done', style: AppText.button(color: kBg)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final updated = playlist.copyWith(coverEmoji: emoji, coverGradient: key);
    await PlaylistDB.instance.createPlaylist(updated);
    if (!mounted) return;
    setState(() => _playlist = updated);
  }

  void _share() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied')),
    );
  }

  Future<void> _deletePlaylist() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Playlist delete karein?', style: AppText.displayS()),
        content: Text('Ye permanently delete ho jayegi.', style: AppText.bodyM()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await PlaylistDB.instance.deletePlaylist(widget.playlistId);
    if (!mounted) return;
    Navigator.pop(context);
  }

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kBgElev,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.edit, color: kTextDim),
              title: Text('Rename', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                _rename();
              },
            ),
            ListTile(
              leading: Icon(Icons.image, color: kTextDim),
              title: Text('Change cover', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                _changeCover();
              },
            ),
            ListTile(
              leading: Icon(Icons.share, color: kTextDim),
              title: Text('Share', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                _share();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: kRed),
              title: Text('Delete playlist', style: AppText.bodyL(color: kRed)),
              onTap: () {
                Navigator.pop(ctx);
                _deletePlaylist();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlist = _playlist;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          playlist?.name ?? 'Playlist',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
        actions: [
          // PART 5 (2026-09-17) — "Recently added" sort toggle. ON hone par
          // list added_at DESC (sabse naya pehle) dikhati hai, ghadi-icon
          // green ho jaata hai jab active ho (baaki icon-state patterns
          // jaisa — dekho radio/sleep-timer chips full_player_screen.dart
          // me).
          IconButton(
            icon: Icon(
              Icons.schedule_rounded,
              color: _sortRecentlyAdded ? kGreen : kText,
            ),
            tooltip: _sortRecentlyAdded
                ? 'Recently Added se sorted — tap karke custom order pe wapas jao'
                : 'Recently Added se sort karo',
            onPressed: (playlist == null || _songs.isEmpty)
                ? null
                : () => setState(() => _sortRecentlyAdded = !_sortRecentlyAdded),
          ),
          // NEW — poori playlist ek tap me download.
          IconButton(
            icon: Icon(Icons.download_for_offline_outlined, color: kText),
            tooltip: 'Playlist download karo',
            onPressed: (playlist == null || _songs.isEmpty) ? null : _downloadAll,
          ),
          IconButton(
            icon: Icon(Icons.more_vert, color: kText),
            onPressed: playlist == null ? null : _showMenu,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: List.generate(4, (_) => const ShimmerSongCard()),
                    )
                  : playlist == null
                      ? Center(
                          child: Text(
                            'Playlist nahi mili',
                            style: AppText.bodyM(color: kTextDim),
                          ),
                        )
                      : _buildBody(playlist),
            ),
            const _PlaylistDetailMiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(Playlist playlist) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            children: [
              Hero(
                tag: 'playlist-${playlist.id}',
                child: Container(
                  width: 180,
                  height: 180,
                  decoration: BoxDecoration(
                    gradient: coverGradientFor(playlist.coverGradient),
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: AppGlow.shadow(color: kGreen, opacity: 0.25),
                  ),
                  alignment: Alignment.center,
                  child: playlist.coverEmoji.isNotEmpty
                      ? Text(playlist.coverEmoji, style: const TextStyle(fontSize: 64))
                      : const Icon(Icons.queue_music, color: Colors.white70, size: 56),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                playlist.name,
                textAlign: TextAlign.center,
                style: AppText.displayL(color: kText)
                    .copyWith(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                '${_songs.length} songs · $_totalMinutes min',
                style: AppText.bodyS().copyWith(fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kGreen,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _songs.isEmpty ? null : () => _playAll(),
                      icon: Icon(Icons.play_arrow, color: kBg),
                      label: Text('Play All', style: AppText.button(color: kBg)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: kTextDim),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _songs.isEmpty ? null : () => _playAll(shuffle: true),
                      icon: Icon(Icons.shuffle, color: kText),
                      label: Text('Shuffle', style: AppText.button(color: kText)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _songs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.music_off, color: kTextDim, size: 48),
                      const SizedBox(height: 10),
                      Text('Koi gaana nahi', style: AppText.bodyM(color: kTextDim)),
                      const SizedBox(height: 14),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: kGreen),
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const SearchScreen()),
                        ),
                        child: Text('Add karo', style: AppText.button(color: kBg)),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // PART 5: "Recently Added" active ho to ek chhota label —
                    // taaki confusion na ho ki list kis order me hai (aur
                    // isiliye drag-handle bhi hide hai, kyunki is order me
                    // manual reorder ka koi matlab nahi banta).
                    if (_sortRecentlyAdded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Row(
                          children: [
                            Icon(Icons.schedule_rounded, color: kGreen, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Recently Added — sabse naya sabse upar',
                              style: AppText.bodyS(color: kGreen),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: _sortRecentlyAdded
                          ? _buildSongList(reorderable: false)
                          : _buildSongList(reorderable: true),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  // PART 5: list-building ab ek shared helper me hai taaki custom-order
  // (ReorderableListView, drag+delete) aur Recently-Added order (plain
  // ListView, sirf delete — reorder yahan disable hai) dono ek hi UI/logic
  // (Dismissible/SongCard) reuse karein, koi duplicate code na ho.
  Widget _buildSongList({required bool reorderable}) {
    final songs = _displaySongs;

    Widget buildTile(Song song, int i) {
      return Dismissible(
        key: ValueKey(song.id),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: kRed,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.delete, color: Colors.white),
        ),
        onDismissed: (_) => _removeSong(song),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: GestureDetector(
            onLongPress: () {
              HapticFeedback.mediumImpact();
              _confirmRemove(song);
            },
            child: Row(
              children: [
                if (reorderable)
                  ReorderableDragStartListener(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.drag_handle, color: kTextDim),
                    ),
                  )
                else
                  const SizedBox(width: 0),
                Expanded(
                  child: SongCard(
                    song: song,
                    isLiked: _likedIds.contains(song.id),
                    isCached: _cachedIds.contains(song.id),
                    isDownloaded: _downloadedIds.contains(song.id),
                    onTap: () => _playFrom(song),
                    onPlay: () => _playFrom(song),
                    onAddToPlaylist: () => _addToPlaylist(song),
                    onDownload: () => _download(song),
                    onLike: () => _toggleLike(song),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (reorderable) {
      return ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
        itemCount: songs.length,
        onReorder: _onReorder,
        itemBuilder: (context, i) => buildTile(songs[i], i),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      itemCount: songs.length,
      itemBuilder: (context, i) => buildTile(songs[i], i),
    );
  }
}


class _PlaylistDetailMiniPlayerBar extends StatelessWidget {
  const _PlaylistDetailMiniPlayerBar();

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
