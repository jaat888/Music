// lib/services/daily_mix_service.dart
//
// NEW (2026-09-17) — "YouTube Music jaisa" personalization.
//
// User ka apna Google/YouTube account is app mein connect nahi hai (koi
// login flow nahi) — isliye YouTube ki khud ki "based on your account"
// wali personalization use nahi kar sakte. Iske bajaye APP KE ANDAR ka
// asli listening data (`PlayHistoryDB` — already Part 3 mein bana hua
// hai, har play record karta hai) use karte hain:
//
//   1. `PlayHistoryDB.getTopArtists()` se user ke top-played artists
//      nikaalte hain.
//   2. Har top artist ke liye, us artist ka (history mein) sabse zyada
//      chala hua gaana "seed" banate hain.
//   3. Us seed pe `YoutubeService.getRadioQueue()` (jo already mini-
//      player ke "Radio" feature ke liye bana hua hai — YouTube Music
//      ka apna "radio" endpoint use karta hai) chala ke ek 20-gaane ki
//      "Mix" banate hain — matlab NAYE (sirf apni library ke nahi)
//      gaane, YouTube khud choose karta hai jo us artist/style se milte
//      hain.
//
// "Roj change/update" (daily refresh): result ek din (aaj ki date) ke
// liye SharedPreferences mein cache hota hai — poora din same rehta hai
// (jaisa Spotify/YT Music ka Daily Mix karta hai), agle din khud-ba-khud
// naya generate hota hai (naya top-artist data ya bas naya radio-pull se).
//
// Naye user (jiski abhi koi play-history hi nahi) ke liye khaali list
// deta hai — home_screen.dart is section ko tab hi dikhata hai jab
// mixes ho.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../db/play_history_db.dart';
import '../models/song.dart';
import 'youtube_service.dart';

class DailyMix {
  final String title; // "Arijit Singh Mix"
  final String seedArtist;
  final List<Song> songs;
  DailyMix({required this.title, required this.seedArtist, required this.songs});

  Map<String, dynamic> toJson() => {
        'title': title,
        'seedArtist': seedArtist,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  factory DailyMix.fromJson(Map<String, dynamic> json) => DailyMix(
        title: json['title'] as String,
        seedArtist: json['seedArtist'] as String,
        songs: (json['songs'] as List)
            .map((s) => Song.fromJson(s as Map<String, dynamic>))
            .toList(),
      );
}

class DailyMixService {
  DailyMixService._internal();
  static final DailyMixService instance = DailyMixService._internal();

  static const String _prefsKey = 'daily_mix_cache_v1';
  static const int mixCount = 3;
  static const int songsPerMix = 20;

  List<DailyMix>? _memoryCache;
  String? _memoryCacheDate;

  String get _today {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<List<DailyMix>> getTodaysMixes() async {
    final today = _today;
    if (_memoryCache != null && _memoryCacheDate == today) {
      return _memoryCache!;
    }

    final prefs = await SharedPreferences.getInstance();
    final cachedRaw = prefs.getString(_prefsKey);
    if (cachedRaw != null) {
      try {
        final decoded = jsonDecode(cachedRaw) as Map<String, dynamic>;
        if (decoded['date'] == today) {
          final mixes = (decoded['mixes'] as List)
              .map((m) => DailyMix.fromJson(m as Map<String, dynamic>))
              .toList();
          _memoryCache = mixes;
          _memoryCacheDate = today;
          return mixes;
        }
      } catch (_) {
        // Corrupt cache — bas fresh generate kar lo.
      }
    }

    final mixes = await _generate();
    _memoryCache = mixes;
    _memoryCacheDate = today;
    try {
      await prefs.setString(
        _prefsKey,
        jsonEncode({
          'date': today,
          'mixes': mixes.map((m) => m.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Cache likhna fail ho to bhi mixes to dikha hi diye is session mein.
    }
    return mixes;
  }

  Future<List<DailyMix>> _generate() async {
    final topArtists =
        await PlayHistoryDB.instance.getTopArtists(limit: mixCount);
    if (topArtists.isEmpty) return [];

    // Har top-artist ka apna sabse-zyada-chala-hua gaana chahiye "seed" ke
    // liye — ek hi query se sab artists ke top-song nikaal lete hain
    // (getMostPlayed poore library ka top hai, usme se per-artist pehla
    // match le lete hain).
    final mostPlayed = await PlayHistoryDB.instance.getMostPlayed(limit: 200);

    final mixes = <DailyMix>[];
    for (final entry in topArtists) {
      final artist = entry.key;
      final seedSong = mostPlayed
          .map((e) => e.key)
          .where((s) => s.artist == artist)
          .cast<Song?>()
          .firstWhere((s) => s != null, orElse: () => null);
      if (seedSong == null) continue;

      try {
        final songs = await YoutubeService.instance.getRadioQueue(
          seedSong.id,
          seedSong.title,
          artist,
          count: songsPerMix,
        );
        if (songs.isEmpty) continue;
        mixes.add(DailyMix(title: '$artist Mix', seedArtist: artist, songs: songs));
      } catch (_) {
        // Ek artist ka radio-pull fail ho to baaki mixes pe koi asar nahi.
      }
    }
    return mixes;
  }
}
