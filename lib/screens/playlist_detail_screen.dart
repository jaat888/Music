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
import '../services/background_service.dart';
import '../services/queue_service.dart';
import '../services/like_service.dart';
import '../services/youtube_service.dart';
import '../widgets/song_card.dart';
import '../widgets/shimmer_song_card.dart';
import 'create_playlist_screen.dart';
import 'search_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
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
      final liked = await LikedDB.instance.getAll();
      final cached = await CacheDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _playlist = playlist;
        _songs = songs;
        _likedIds = liked.map((s) => s.id).toSet();
        _cachedIds = cached.map((e) => e['id'] as String).toSet();
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
    var list = List<Song>.of(_songs);
    if (shuffle) {
      list.shuffle();
      context.read<QueueService>().setShuffle(true);
    }
    context.read<QueueService>().setQueue(list, startIndex: 0);
    await audioHandler.playWithRetry(list.first, YoutubeService.instance.getAudioUrl);
  }

  Future<void> _playFrom(int index) async {
    context.read<QueueService>().setQueue(_songs, startIndex: index);
    await audioHandler.playWithRetry(_songs[index], YoutubeService.instance.getAudioUrl);
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

  Future<void> _download(Song song) async {
    final path = await YoutubeService.instance.download(song.id, song.title);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text(path != null ? '${song.title} download ho gaya' : 'Download fail ho gaya'),
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
              leading: const Icon(Icons.edit, color: kTextDim),
              title: Text('Rename', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                _rename();
              },
            ),
            ListTile(
              leading: const Icon(Icons.image, color: kTextDim),
              title: Text('Change cover', style: AppText.bodyL()),
              onTap: () {
                Navigator.pop(ctx);
                _changeCover();
              },
            ),
            ListTile(
              leading: const Icon(Icons.share, color: kTextDim),
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
          IconButton(
            icon: const Icon(Icons.more_vert, color: kText),
            onPressed: playlist == null ? null : _showMenu,
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? ListView(
                padding: const EdgeInsets.all(16),
                children: List.generate(4, (_) => const ShimmerSongCard()),
              )
            : playlist == null
                ? Center(
                    child: Text('Playlist nahi mili', style: AppText.bodyM(color: kTextDim)),
                  )
                : _buildBody(playlist),
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
                      icon: const Icon(Icons.play_arrow, color: kBg),
                      label: Text('Play All', style: AppText.button(color: kBg)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: kTextDim),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _songs.isEmpty ? null : () => _playAll(shuffle: true),
                      icon: const Icon(Icons.shuffle, color: kText),
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
                      const Icon(Icons.music_off, color: kTextDim, size: 48),
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
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                  itemCount: _songs.length,
                  onReorder: _onReorder,
                  itemBuilder: (context, i) {
                    final song = _songs[i];
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
                              ReorderableDragStartListener(
                                index: i,
                                child: const Padding(
                                  padding: EdgeInsets.only(right: 4),
                                  child: Icon(Icons.drag_handle, color: kTextDim),
                                ),
                              ),
                              Expanded(
                                child: SongCard(
                                  song: song,
                                  isLiked: _likedIds.contains(song.id),
                                  isCached: _cachedIds.contains(song.id),
                                  onTap: () => _playFrom(i),
                                  onPlay: () => _playFrom(i),
                                  onDownload: () => _download(song),
                                  onLike: () => _toggleLike(song),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
