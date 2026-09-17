// lib/screens/duplicate_songs_screen.dart
// Part 3 (Library smarts) — duplicate-song detector. Library me ek hi
// gaana kai baar alag video-id se aa sakta hai (alag search result se
// download/like/cache ho gaya) — ye screen title+artist normalize karke
// aise groups dhoondti hai aur user ko extra copies hatane deti hai.

import 'dart:io';

import 'package:flutter/material.dart';

import '../db/cache_db.dart';
import '../db/download_db.dart';
import '../db/liked_db.dart';
import '../models/song.dart';
import '../theme/colors.dart';
import '../theme/typography.dart';

class DuplicateSongsScreen extends StatefulWidget {
  const DuplicateSongsScreen({super.key});

  @override
  State<DuplicateSongsScreen> createState() => _DuplicateSongsScreenState();
}

class _DuplicateSongsScreenState extends State<DuplicateSongsScreen> {
  bool _loading = true;
  // Har group ek hi (title+artist) ke multiple copies hain.
  List<List<Song>> _groups = [];
  Set<String> _likedIds = {};
  Set<String> _downloadedIds = {};
  Set<String> _cachedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  // "Believer (Official Video) [Lyrics]" aur "Believer" ko same maanne ke
  // liye — common YouTube upload-title clutter hata dete hain, phir
  // lowercase + extra-space trim.
  String _normalize(String s) {
    var out = s.toLowerCase();
    out = out.replaceAll(
      RegExp(
        r'\(.*?\)|\[.*?\]|official video|official audio|official music video|'
        r'lyrics?|lyric video|audio|hd|hq|4k|full video|music video|ft\.?.*$',
      ),
      '',
    );
    out = out.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    return out;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final liked = await LikedDB.instance.getAll();
      final cachedRows = await CacheDB.instance.getAll();
      final downloaded = await DownloadDB.instance.getAll();
      final cached = cachedRows.map((r) => Song.fromMap(r)).toList();

      // Merged pool, distinct by id (ek hi song alag sources me ho sakta hai).
      final pool = <String, Song>{};
      for (final s in [...liked, ...cached, ...downloaded]) {
        pool[s.id] = s;
      }

      final byKey = <String, List<Song>>{};
      for (final s in pool.values) {
        final key = '${_normalize(s.title)}|${_normalize(s.artist)}';
        if (key.trim() == '|') continue; // dono khali ho gaye, skip
        byKey.putIfAbsent(key, () => []).add(s);
      }

      final groups = byKey.values.where((g) => g.length > 1).toList()
        ..sort((a, b) => b.length.compareTo(a.length));

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _likedIds = liked.map((s) => s.id).toSet();
        _downloadedIds = downloaded.map((s) => s.id).toSet();
        _cachedIds = cached.map((s) => s.id).toSet();
      });
    } catch (e) {
      print('DUPLICATE_SONGS _load() ERROR: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Is specific copy ko har jagah se hata do (liked/cache/download + disk
  // file agar hai) — baaki copies (group ke doosre songs) untouched rehte
  // hain.
  Future<void> _removeCopy(Song song) async {
    try {
      if (_likedIds.contains(song.id)) {
        await LikedDB.instance.remove(song.id);
      }
      if (_downloadedIds.contains(song.id)) {
        final path = await DownloadDB.instance.getFilePath(song.id);
        if (path != null && await File(path).exists()) {
          await File(path).delete();
        }
        await DownloadDB.instance.delete(song.id);
      }
      if (_cachedIds.contains(song.id)) {
        final path = await CacheDB.instance.getFilePath(song.id);
        if (path != null && await File(path).exists()) {
          await File(path).delete();
        }
        await CacheDB.instance.delete(song.id);
      }
    } catch (e) {
      print('DUPLICATE_SONGS _removeCopy ERROR: $e');
    }
    if (!mounted) return;
    setState(() {
      for (final g in _groups) {
        g.removeWhere((s) => s.id == song.id);
      }
      _groups.removeWhere((g) => g.length <= 1);
    });
  }

  String _sourcesLabel(Song s) {
    final parts = <String>[];
    if (_likedIds.contains(s.id)) parts.add('Liked');
    if (_downloadedIds.contains(s.id)) parts.add('Downloaded');
    if (_cachedIds.contains(s.id)) parts.add('Cached');
    return parts.isEmpty ? '' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        elevation: 0,
        title: Text(
          'Duplicate Songs',
          style: AppText.displayM(color: kGreen).copyWith(fontSize: 20),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: kGreen,
          backgroundColor: kBgElev,
          child: _loading ? const Center(child: CircularProgressIndicator(color: kGreen)) : _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_groups.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 80),
        children: [
          Center(
            child: Column(
              children: [
                Icon(Icons.filter_none, color: kTextDim, size: 48),
                const SizedBox(height: 10),
                Text('Koi duplicate nahi mila', style: AppText.bodyM(color: kTextDim)),
                const SizedBox(height: 4),
                Text('Liked/downloaded/cached songs check kiye gaye',
                    style: AppText.bodyS(color: kTextDim)),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _groups.length,
      itemBuilder: (context, gi) {
        final group = _groups[gi];
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: kBgElev,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                child: Text(
                  '${group.length} copies · ${group.first.title}',
                  style: AppText.bodyM(color: kText).copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              ...group.map(
                (song) => ListTile(
                  dense: true,
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyM(color: kText),
                  ),
                  subtitle: Text(
                    [song.artist, _sourcesLabel(song)].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.bodyS(color: kTextDim),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: kRed),
                    tooltip: 'Ye copy hatao',
                    onPressed: () => _removeCopy(song),
                  ),
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }
}
