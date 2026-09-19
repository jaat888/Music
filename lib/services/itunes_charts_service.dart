// lib/services/itunes_charts_service.dart
//
// NEW (2026-09-19, v95) — Apple ka free, public, KEYLESS "Marketing Tools"
// RSS/JSON feed — koi login, koi API key nahi chahiye, Apple khud hi ise
// public hosts karta hai (rss.marketingtools.apple.com). Sirf title+artist
// milta hai (audio nahi) — hamesha jaisa poore app mein pattern hai, gaana
// YouTube se hi match/play hota hai (dekho curated_playlist_screen.dart).
//
// Scope note: iTunes sirf EK flat "most-played" chart deta hai per
// country — Spotify/JioSaavn jaisi kai-kai category-wise curated playlists
// nahi (dekho conversation/NOTES.md) — isliye Home screen pe ye sirf ek
// "India Top Songs" card ki tarah dikhta hai, poori category-list ki
// tarah nahi.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ItunesTrackMeta {
  final String title;
  final String artist;
  final String artwork;
  ItunesTrackMeta({
    required this.title,
    required this.artist,
    required this.artwork,
  });
}

class ItunesChartsService {
  ItunesChartsService._internal();
  static final ItunesChartsService instance = ItunesChartsService._internal();

  // country: ISO 2-letter Apple storefront code — "in" India ke liye.
  static const _cachePrefix = 'itunes_top_songs_v2';
  String _cachedAtKey(String country) => '${_cachePrefix}_${country}_cached_at_ms';
  String _payloadKey(String country) => '${_cachePrefix}_${country}_payload';
  int? _lastAttemptCycleMs;

  // The chart is a daily snapshot anchored to 06:00 local device time. Home
  // never re-downloads it just because the screen was opened again; at most
  // one successful refresh is accepted per daily 06:00 -> 06:00 window.
  // On a network failure the last good snapshot remains visible.
  Future<List<ItunesTrackMeta>> getTopSongs({
    String country = 'in',
    int limit = 50,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final cycleStart = _latestSixAm(now);
    final cached = _decode(prefs.getString(_payloadKey(country)));
    final cachedAt = prefs.getInt(_cachedAtKey(country)) ?? 0;

    if (cached.isNotEmpty && cachedAt >= cycleStart.millisecondsSinceEpoch) {
      return cached.take(limit).toList(growable: false);
    }

    // Avoid hammering the Apple feed multiple times inside the same app
    // session when the daily refresh attempt already failed.
    if (_lastAttemptCycleMs == cycleStart.millisecondsSinceEpoch) {
      return cached.take(limit).toList(growable: false);
    }
    _lastAttemptCycleMs = cycleStart.millisecondsSinceEpoch;

    final fresh = await _fetchTopSongs(country: country, limit: limit);
    if (fresh.isNotEmpty) {
      await prefs.setString(_payloadKey(country), _encode(fresh));
      await prefs.setInt(_cachedAtKey(country), now.millisecondsSinceEpoch);
      return fresh;
    }

    // Stale-but-real data is better than replacing the section with an empty
    // list when Apple/network is temporarily unavailable.
    return cached.take(limit).toList(growable: false);
  }

  Future<List<ItunesTrackMeta>> _fetchTopSongs({
    required String country,
    required int limit,
  }) async {
    try {
      final safeLimit = limit.clamp(1, 200).toInt();
      final uri = Uri.parse(
        'https://rss.marketingtools.apple.com/api/v2/$country/music/most-played/$safeLimit/songs.json',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];

      dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        return [];
      }
      if (decoded is! Map) return [];
      final feed = decoded['feed'];
      if (feed is! Map) return [];
      final results = feed['results'];
      if (results is! List) return [];

      final out = <ItunesTrackMeta>[];
      for (final raw in results) {
        if (raw is! Map) continue;
        final title = raw['name']?.toString();
        if (title == null || title.isEmpty) continue;
        out.add(ItunesTrackMeta(
          title: title,
          artist: raw['artistName']?.toString() ?? '',
          artwork: raw['artworkUrl100']?.toString() ?? '',
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  DateTime _latestSixAm(DateTime now) {
    var six = DateTime(now.year, now.month, now.day, 6);
    if (now.isBefore(six)) {
      six = six.subtract(const Duration(days: 1));
    }
    return six;
  }

  String _encode(List<ItunesTrackMeta> songs) => jsonEncode(
        songs
            .map((song) => {
                  'title': song.title,
                  'artist': song.artist,
                  'artwork': song.artwork,
                })
            .toList(),
      );

  List<ItunesTrackMeta> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <ItunesTrackMeta>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final title = item['title']?.toString();
        if (title == null || title.isEmpty) continue;
        out.add(ItunesTrackMeta(
          title: title,
          artist: item['artist']?.toString() ?? '',
          artwork: item['artwork']?.toString() ?? '',
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

}
