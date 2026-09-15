// lib/screens/add_to_playlist_sheet.dart
// Bottom sheet function — song ko kisi playlist me add karne ke liye.

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../db/playlist_db.dart';
import 'create_playlist_screen.dart';

Future<void> showAddToPlaylistSheet(BuildContext context, Song song) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: kBgElev,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (ctx) => _AddToPlaylistSheet(song: song),
  );
}

class _AddToPlaylistSheet extends StatefulWidget {
  final Song song;
  const _AddToPlaylistSheet({required this.song});

  @override
  State<_AddToPlaylistSheet> createState() => _AddToPlaylistSheetState();
}

class _AddToPlaylistSheetState extends State<_AddToPlaylistSheet> {
  bool _loading = true;
  List<Playlist> _playlists = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final playlists = await PlaylistDB.instance.getAllPlaylists();
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _loading = false;
    });
  }

  Future<void> _createNew() async {
    // NOTE: CreatePlaylistScreen playlist ki id String return karta hai
    // (Navigator.pop(context, id)) — taaki yahan seedha usi naye playlist
    // me song add kiya ja sake.
    final newId = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const CreatePlaylistScreen()),
    );
    if (newId == null) return;
    // BATCH 14B: addSongToPlaylist ab poora Song object leta hai (id nahi),
    // taaki title/artist/thumb/duration playlist_songs table me hi save ho.
    await PlaylistDB.instance.addSongToPlaylist(newId, widget.song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✓ Playlist ban gayi aur gaana add ho gaya')),
    );
    Navigator.pop(context);
  }

  Future<void> _toggle(Playlist playlist) async {
    final already = playlist.songIds.contains(widget.song.id);
    if (already) {
      await PlaylistDB.instance.removeSongFromPlaylist(playlist.id, widget.song.id);
      if (!mounted) return;
      await _load(); // list refresh — sheet khuli rehti hai
      return;
    }

    await PlaylistDB.instance.addSongToPlaylist(playlist.id, widget.song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✓ Added to ${playlist.name}')),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.6;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: kTextDim.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Add to Playlist', style: AppText.displayS(color: kText)),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: kGreen.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.add, color: kGreen),
                ),
                title: Text('Create new playlist', style: AppText.bodyL(color: kText)),
                onTap: _createNew,
              ),
              const Divider(color: kSurface, height: 1),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: CircularProgressIndicator(color: kGreen),
                        ),
                      )
                    : _playlists.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                'Koi playlist nahi. Naya banao.',
                                style: AppText.bodyM(color: kTextDim),
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: _playlists.length,
                            itemBuilder: (context, i) {
                              final p = _playlists[i];
                              final already = p.songIds.contains(widget.song.id);
                              return ListTile(
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    gradient: coverGradientFor(p.coverGradient),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  alignment: Alignment.center,
                                  child: p.coverEmoji.isNotEmpty
                                      ? Text(p.coverEmoji, style: const TextStyle(fontSize: 18))
                                      : const Icon(Icons.queue_music,
                                          color: Colors.white70, size: 18),
                                ),
                                title: Text(p.name, style: AppText.bodyL(color: kText)),
                                subtitle:
                                    Text('${p.songIds.length} songs', style: AppText.bodyS()),
                                trailing: already
                                    ? const Icon(Icons.check_circle, color: kGreen)
                                    : null,
                                onTap: () => _toggle(p),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
