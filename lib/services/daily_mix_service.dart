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

  // NEW (2026-09-17, diagnostic — Daily Mix section "kabhi kabhi dikhti hi
  // nahi" report ke baad): koi bhi behaviour change nahi, sirf ye record
  // karta hai ki khaali list kis wajah se aayi — home_screen.dart isse
  // (sirf jab list khaali ho) ek chhota temporary reason dikha sakta hai,
  // taaki bina logcat ke bhi pata chale "history hi nahi hai" vs "history
  // hai par radio-pull fail ho raha".
  String? lastDebugInfo;

  // CHANGE (Batch 30 — user request: "personalization user jo sunta hai
  // usse update hona chahiye, har 4 hr mein"): pehle ye poore CALENDAR
  // DIN (date-string) ke hisaab se cache hota tha — matlab subah pehli
  // baar bana Mix raat tak bilkul wahi rehta tha, chahe user ne dopahar
  // tak 50 naye gaane kyun na sun liye ho. Ab har 4-ghante ka apna alag
  // bucket hai (raat 12-4, 4-8, 8-12, ...) — din mein 6 baar khud-ba-khud
  // fresh Mix banega, jo us waqt tak ki latest listening history use
  // karega.
  String get _periodKey {
    final now = DateTime.now();
    final bucket = now.hour ~/ 4; // 0-5 (4 ghante ka har block)
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}-b$bucket';
  }

  Future<List<DailyMix>> getTodaysMixes() async {
    final today = _periodKey;
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
          // BUG FIX: purana build isi (khaali) result ko yahan bhi valid
          // maan ke return kar deta tha — agar user ke phone pe pehle se
          // ek khaali `daily_mix_cache_v1` (aaj ki date ke saath) pada hai
          // is bug ki wajah se, to naya fix bhi kabhi trigger nahi hota
          // (kyunki yahi read-path pehle hi return kar deta). Ab khaali
          // stored cache ko IGNORE karke neeche fresh generate karte hain
          // — isse purana atka hua state bhi khud-ba-khud theek ho jaata
          // hai, app data clear karne ki zaroorat nahi.
          if (mixes.isNotEmpty) {
            _memoryCache = mixes;
            _memoryCacheDate = today;
            return mixes;
          }
        }
      } catch (_) {
        // Corrupt cache — bas fresh generate kar lo.
      }
    }

    final mixes = await _generate();
    // BUG FIX (user report: "history nahi thi tab khaali aaya, history
    // banne ke baad bhi khaali hi aa raha"): pehle EMPTY result (jab
    // abhi tak koi play-history nahi thi) bhi memory AUR disk dono me
    // poore din ke liye cache ho jaata tha. Matlab: agar app pehli baar
    // kholi (history = 0 songs) aur Daily Mix khaali aaya, to us DIN ke
    // baaki hisse me — chahe usi session me user 10 gaane sun le — Daily
    // Mix hamesha khaali hi dikhta rehta tha, kyunki cache sirf DATE
    // badalne pe invalidate hota tha, history badalne pe nahi. Fix:
    // khaali result ko KAHIN bhi cache mat karo (na memory, na disk) —
    // agli baar getTodaysMixes() call hone par (Home screen dobara khulne
    // par) fresh history ke saath turant dobara try hoga. Sirf ASLI
    // (non-empty) result poore din ke liye cache hota hai — wahi mehenga
    // radio-pull wala kaam hai jise bachana zaroori hai.
    if (mixes.isEmpty) return mixes;

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
    if (topArtists.isEmpty) {
      lastDebugInfo =
          'Abhi tak play-history khaali hai (koi gaana pura play nahi hua ya'
          ' PlayHistoryDB abhi tak likh nahi paayi) — Daily Mix banane ke'
          ' liye kam se kam 1 gaana play hona zaroori hai.';
      return [];
    }

    // Har top-artist ka apna sabse-zyada-chala-hua gaana chahiye "seed" ke
    // liye — ek hi query se sab artists ke top-song nikaal lete hain
    // (getMostPlayed poore library ka top hai, usme se per-artist pehla
    // match le lete hain).
    final mostPlayed = await PlayHistoryDB.instance.getMostPlayed(limit: 200);

    final mixes = <DailyMix>[];
    final failedArtists = <String>[];
    for (final entry in topArtists) {
      final artist = entry.key;
      final seedSong = mostPlayed
          .map((e) => e.key)
          .where((s) => s.artist == artist)
          .cast<Song?>()
          .firstWhere((s) => s != null, orElse: () => null);
      if (seedSong == null) {
        failedArtists.add('$artist (koi seed song nahi mila)');
        continue;
      }

      try {
        final songs = await YoutubeService.instance.getRadioQueue(
          seedSong.id,
          seedSong.title,
          artist,
          count: songsPerMix,
        );
        if (songs.isEmpty) {
          failedArtists.add('$artist (radio-pull ne 0 gaane diye)');
          continue;
        }
        mixes.add(DailyMix(title: '$artist Mix', seedArtist: artist, songs: songs));
      } catch (e) {
        failedArtists.add('$artist (radio-pull fail: $e)');
      }
    }
    if (mixes.isEmpty && failedArtists.isNotEmpty) {
      lastDebugInfo =
          'Top artists mile (${topArtists.map((e) => e.key).join(", ")}) par'
          ' inke liye radio-pull fail ho gaya: ${failedArtists.join(" | ")}';
    } else {
      lastDebugInfo = null;
    }
    return mixes;
  }
}
