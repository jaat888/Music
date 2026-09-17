// lib/screens/downloads_screen.dart
// Downloads tab — permanently saved songs (Music/SurSathi/), offline playback.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../db/download_db.dart';
import '../db/liked_db.dart';
import '../services/background_service.dart';
import '../services/download_queue_service.dart';
import '../services/like_service.dart';
import '../services/queue_service.dart';
import '../widgets/song_card.dart';
import '../widgets/mini_player.dart';
import 'full_player_screen.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool _loading = true;
  List<Song> _downloads = [];
  Set<String> _likedIds = {};

  // NEW (v41 — user request): "select karke delete kar sakein" — select
  // mode + bulk delete.
  bool _selectMode = false;
  Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
    // BUG FIX (v37 — "downloads mein kaunsa queue mein hai kabhi nahi
    // dikhta"): jab bhi koi download poora ho, list turant refresh karo.
    DownloadQueueService.instance.addFinishListener(_onDownloadFinished);
  }

  void _onDownloadFinished(Song song, bool success) {
    if (mounted) _load();
  }

  @override
  void dispose() {
    DownloadQueueService.instance.removeFinishListener(_onDownloadFinished);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final downloads = await DownloadDB.instance.getAll();
      final liked = await LikedDB.instance.getAll();
      if (!mounted) return;
      setState(() {
        _downloads = downloads;
        _likedIds = liked.map((s) => s.id).toSet();
      });
    } catch (e) {
      print('DOWNLOADS _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _play(int index) async {
    final song = _downloads[index];
    if (song.filePath == null) return;
    context.read<QueueService>().setQueue(_downloads, startIndex: index);
    await audioHandler.playFromFile(song, song.filePath!);
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

  // NOTE: SongCard me alag se onDelete param nahi hai (Batch 6 se fixed hai),
  // isliye "download" icon hi yahan delete action ke liye reuse ho raha hai —
  // dekho NOTES.md #10.
  Future<void> _confirmDelete(Song song) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Delete karein?', style: AppText.displayS(color: kText)),
        content: Text(
          '"${song.title}" hamesha ke liye delete ho jayega.',
          style: AppText.bodyM(color: kTextDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (song.filePath != null) {
      final file = File(song.filePath!);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await DownloadDB.instance.delete(song.id);
    if (!mounted) return;
    setState(() => _downloads.removeWhere((s) => s.id == song.id));
  }

  // NEW (v41): select mode toggle + bulk delete.
  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selectedIds.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _selectAll() {
    setState(() {
      if (_selectedIds.length == _downloads.length) {
        _selectedIds.clear();
      } else {
        _selectedIds = _downloads.map((s) => s.id).toSet();
      }
    });
  }

  Future<void> _confirmDeleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: kBgElev,
        title: Text('Delete karein?', style: AppText.displayS(color: kText)),
        content: Text(
          '${_selectedIds.length} gaane hamesha ke liye delete ho jayenge.',
          style: AppText.bodyM(color: kTextDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: AppText.button(color: kTextDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete', style: AppText.button(color: kRed)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    for (final song in _downloads.where((s) => _selectedIds.contains(s.id))) {
      if (song.filePath != null) {
        final file = File(song.filePath!);
        if (await file.exists()) await file.delete();
      }
      await DownloadDB.instance.delete(song.id);
    }
    if (!mounted) return;
    setState(() {
      _downloads.removeWhere((s) => _selectedIds.contains(s.id));
      _selectedIds.clear();
      _selectMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          _selectMode ? '${_selectedIds.length} selected' : 'Downloads',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 24),
        ),
        // NEW (v41 — user request): select mode se multi-select + delete.
        actions: [
          if (_downloads.isNotEmpty && _selectMode) ...[
            IconButton(
              icon: Icon(
                _selectedIds.length == _downloads.length
                    ? Icons.deselect
                    : Icons.select_all,
                color: kText,
              ),
              tooltip: 'Select All',
              onPressed: _selectAll,
            ),
            IconButton(
              icon: Icon(Icons.delete, color: kRed),
              tooltip: 'Delete selected',
              onPressed: _selectedIds.isEmpty ? null : _confirmDeleteSelected,
            ),
          ],
          if (_downloads.isNotEmpty)
            IconButton(
              icon: Icon(_selectMode ? Icons.close : Icons.checklist, color: kText),
              tooltip: _selectMode ? 'Cancel' : 'Select',
              onPressed: _toggleSelectMode,
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // NEW (v37 — "kaunsa download ho raha hai, kaunsa queue mein
            // hai kabhi nahi dikhta"): DownloadQueueService ek
            // ChangeNotifier hai — ListenableBuilder se seedha listen
            // karke, jab bhi progress/queue badle, ye section turant
            // rebuild ho jaata hai (koi extra Provider setup ki zaroorat
            // nahi).
            ListenableBuilder(
              listenable: DownloadQueueService.instance,
              builder: (context, _) => _buildQueueSection(),
            ),
            Expanded(child: _buildBody()),
            _MiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueSection() {
    final q = DownloadQueueService.instance;
    final current = q.currentSong;
    if (current == null && q.queue.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kBgElev,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kGreen.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (current != null) ...[
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kGreen),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Download ho raha hai: ${current.title}',
                    style: AppText.bodyM(color: kText),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${(q.currentProgress * 100).round()}%',
                  style: AppText.bodyS(color: kGreen),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: q.currentProgress > 0 ? q.currentProgress : null,
                minHeight: 4,
                color: kGreen,
                backgroundColor: kSurface,
              ),
            ),
          ],
          if (q.queue.isNotEmpty) ...[
            if (current != null) const SizedBox(height: 10),
            Text(
              '${q.queue.length} gaana queue mein baaki: '
              '${q.queue.take(3).map((s) => s.title).join(", ")}'
              '${q.queue.length > 3 ? "..." : ""}',
              style: AppText.bodyS(color: kTextDim),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: List.generate(
          3,
          (_) => Shimmer.fromColors(
            baseColor: kBgElev,
            highlightColor: const Color(0xFF2A3E5C),
            child: Container(
              height: 76,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: kBgElev,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      );
    }

    if (_downloads.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: kGreen,
        backgroundColor: kBgElev,
        child: ListView(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.5,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.download_done,
                      color: Colors.white24,
                      size: 80,
                    ),
                    const SizedBox(height: 14),
                    Text('Koi download nahi', style: AppText.bodyL(color: kTextDim)),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40),
                      child: Text(
                        'Songs ko download karo offline sunne ke liye',
                        textAlign: TextAlign.center,
                        style: AppText.bodyS(color: kTextDim),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: kGreen,
      backgroundColor: kBgElev,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _downloads.length,
        itemBuilder: (context, i) {
          final song = _downloads[i];
          final selected = _selectedIds.contains(song.id);
          final row = _selectMode
              ? Row(
                  children: [
                    Checkbox(
                      value: selected,
                      activeColor: kGreen,
                      onChanged: (_) => _toggleSelected(song.id),
                    ),
                    Expanded(
                      child: SongCard(
                        song: song,
                        isLiked: _likedIds.contains(song.id),
                        isCached: false,
                        onTap: () => _toggleSelected(song.id),
                        onPlay: () => _toggleSelected(song.id),
                        onDownload: () => _toggleSelected(song.id),
                        onLike: () => _toggleSelected(song.id),
                      ),
                    ),
                  ],
                )
              : SongCard(
                  song: song,
                  isLiked: _likedIds.contains(song.id),
                  isCached: false,
                  onTap: () => _play(i),
                  onPlay: () => _play(i),
                  onDownload: () => _confirmDelete(song),
                  onLike: () => _toggleLike(song),
                );

          if (_selectMode) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: row,
            );
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Dismissible(
              key: ValueKey(song.id),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) async {
                await _confirmDelete(song);
                return false; // list _confirmDelete ke andar khud update hoti hai
              },
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: kRed.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.delete, color: Colors.white),
              ),
              child: row,
            ),
          );
        },
      ),
    );
  }
}

// ---------------- Shared mini player wrapper (downloads screen) ----------------

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
