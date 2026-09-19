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
  Future<List<ItunesTrackMeta>> getTopSongs({
    String country = 'in',
    int limit = 50,
  }) async {
    try {
      final uri = Uri.parse(
        'https://rss.marketingtools.apple.com/api/v2/$country/music/most-played/$limit/songs.json',
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
      // Network/parsing fail — bas khaali list, Home screen crash nahi
      // hoga (dekho home_screen.dart ke try/catch).
      return [];
    }
  }
}
