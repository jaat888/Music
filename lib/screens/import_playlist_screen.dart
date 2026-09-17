// lib/screens/import_playlist_screen.dart
//
// YouTube ya Spotify playlist link paste karke local playlist bana lo.
//   - YouTube: seedha video-list nikalti hai (YoutubeService already isse
//     support karta hai) — koi login/key nahi chahiye.
//   - Spotify: SIRF public playlists. Login nahi hota — Spotify ka
//     Client Credentials app-token (SpotifyService) sirf metadata
//     (title+artist) deta hai; har track ko phir YouTube pe search karke
//     best-match audio jod diya jaata hai. Isliye Spotify match hamesha
//     100% accurate nahi hoga (kabhi galat version/cover mil sakta hai).
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../theme/colors.dart';
import '../theme/typography.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../db/playlist_db.dart';
import '../services/youtube_service.dart';
import '../services/spotify_service.dart';

enum _SourceKind { youtube, spotify, unknown }

class _ImportRow {
  final Song song;
  bool selected;
  _ImportRow(this.song, {this.selected = true});
}

class ImportPlaylistScreen extends StatefulWidget {
  const ImportPlaylistScreen({super.key});

  @override
  State<ImportPlaylistScreen> createState() => _ImportPlaylistScreenState();
}

class _ImportPlaylistScreenState extends State<ImportPlaylistScreen> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _progressText;
  List<_ImportRow> _rows = [];

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  _SourceKind _detect(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('spotify.com') || lower.contains('spotify:playlist')) {
      return _SourceKind.spotify;
    }
    if (lower.contains('youtube.com') ||
        lower.contains('youtu.be') ||
        lower.contains('music.youtube.com') ||
        RegExp(r'^[A-Za-z0-9_-]{13,34}$').hasMatch(url.trim())) {
      return _SourceKind.youtube;
    }
    return _SourceKind.unknown;
  }

  String? _extractYoutubePlaylistId(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.queryParameters.containsKey('list')) {
      return uri.queryParameters['list'];
    }
    // Bare playlist ID paste kiya ho sakta hai
    if (RegExp(r'^[A-Za-z0-9_-]{13,34}$').hasMatch(trimmed)) return trimmed;
    return null;
  }

  Future<void> _fetch() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _rows = [];
      _progressText = 'Playlist dhoondh rahe hain...';
    });

    try {
      final kind = _detect(url);
      if (kind == _SourceKind.youtube) {
        final playlistId = _extractYoutubePlaylistId(url);
        if (playlistId == null) {
          throw Exception('YouTube playlist link samajh nahi aaya. Poora link paste karein.');
        }
        final results = await YoutubeService.instance.getYtMusicPlaylistTracks(
          playlistId,
        );
        if (results.isEmpty) {
          throw Exception('Is playlist mein koi gaana nahi mila (private ho sakti hai).');
        }
        setState(() {
          _nameController.text = 'Imported Playlist';
          _rows = results.map((r) => _ImportRow(r.toSong())).toList();
        });
      } else if (kind == _SourceKind.spotify) {
        if (!SpotifyService.instance.isConfigured) {
          throw Exception(
            'Spotify Client ID/Secret set nahi hai. env.json set karke app '
            'dobara build karein.',
          );
        }
        final playlistId = SpotifyService.extractPlaylistId(url);
        if (playlistId == null) {
          throw Exception('Spotify playlist link samajh nahi aaya. Poora link paste karein.');
        }
        final meta = await SpotifyService.instance.getPlaylistTracks(playlistId);
        if (meta.tracks.isEmpty) {
          throw Exception('Is playlist mein koi track nahi mila (private ho sakti hai).');
        }
        _nameController.text = meta.name;

        // Har Spotify track ko YouTube pe match karo — ek-ek karke (rate
        // limit friendly), progress dikhate hue.
        final matched = <_ImportRow>[];
        for (var i = 0; i < meta.tracks.length; i++) {
          final t = meta.tracks[i];
          if (!mounted) return;
          setState(() {
            _progressText = 'Match kar rahe hain ${i + 1}/${meta.tracks.length}: ${t.title}';
          });
          try {
            final query = t.artist.isNotEmpty ? '${t.title} ${t.artist}' : t.title;
            final results = await YoutubeService.instance.search(query, max: 3);
            if (results.isNotEmpty) {
              matched.add(_ImportRow(results.first.toSong()));
            }
          } catch (_) {
            // ek track match na ho to poora import na roko
          }
        }
        if (matched.isEmpty) {
          throw Exception('Koi bhi track YouTube pe match nahi hua.');
        }
        setState(() => _rows = matched);
      } else {
        throw Exception('Ye link YouTube ya Spotify ka nahi lag raha.');
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() {
        _loading = false;
        _progressText = null;
      });
    }
  }

  Future<void> _save() async {
    final selected = _rows.where((r) => r.selected).map((r) => r.song).toList();
    if (selected.isEmpty) return;
    final name = _nameController.text.trim().isEmpty
        ? 'Imported Playlist'
        : _nameController.text.trim();

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
    for (final song in selected) {
      await PlaylistDB.instance.addSongToPlaylist(id, song);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$name" import ho gayi — ${selected.length} gaane')),
    );
    Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text('Playlist Import karein', style: AppText.displayM().copyWith(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'YouTube ya Spotify playlist ka link paste karein',
            style: AppText.bodyM(color: kTextDim),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _urlController,
            style: AppText.bodyM(),
            decoration: InputDecoration(
              hintText: 'https://open.spotify.com/playlist/... ya YouTube link',
              hintStyle: AppText.bodyM(color: kTextDim),
              filled: true,
              fillColor: kSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _loading ? null : _fetch,
              style: ElevatedButton.styleFrom(
                backgroundColor: kGreen,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text('Fetch karein', style: AppText.button(color: Colors.black)),
            ),
          ),
          if (_progressText != null) ...[
            const SizedBox(height: 10),
            Text(_progressText!, style: AppText.bodyS(color: kTextDim)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!, style: AppText.bodyM(color: kRed)),
          ],
          if (_rows.isNotEmpty) ...[
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              style: AppText.displayS(),
              decoration: InputDecoration(
                labelText: 'Playlist ka naam',
                labelStyle: AppText.bodyM(color: kTextDim),
                filled: true,
                fillColor: kSurface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '${_rows.where((r) => r.selected).length}/${_rows.length} gaane selected',
              style: AppText.bodyS(color: kTextDim),
            ),
            const SizedBox(height: 8),
            ..._rows.map(
              (row) => CheckboxListTile(
                value: row.selected,
                onChanged: (v) => setState(() => row.selected = v ?? false),
                activeColor: kGreen,
                title: Text(row.song.title, style: AppText.bodyM(), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(row.song.artist, style: AppText.bodyS(color: kTextDim), maxLines: 1, overflow: TextOverflow.ellipsis),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _rows.any((r) => r.selected) ? _save : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: kGreen,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text('Playlist banayein', style: AppText.button(color: Colors.black)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
