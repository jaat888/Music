// lib/services/discover_weekly_service.dart
//
// "Discover Weekly" / "Release Radar" jaisa feature — Spotify ke asli
// Discover Weekly jaisa NAHI hai (wo lakhon users ka listening data
// cross-compare karta hai — collaborative filtering — jo ek solo app me
// scale nahi ho sakta). Ye do "achievable" tareeke combine karta hai:
//
//   Layer A — Apna data + YouTube ka apna "related" (Radio):
//     PlayHistoryDB se top artists nikaalo, har artist ke top-played
//     gaane ko seed bana ke YoutubeService.getRadioQueue() chalao — ye
//     YouTube khud "is jaisa aur kya hai" batata hai. DailyMixService
//     bhi yahi karta hai, lekin Discover Weekly isme se sirf UNHI
//     gaano ko rakhta hai jo already liked/cached/history me NAHI hain
//     — matlab genuinely "naya, abhi tak na suna" content.
//
//   Layer B (BONUS) — Last.fm "similar artists" (real ML/collaborative
//     data, khud train nahi kiya, Last.fm ka free public API use hota
//     hai): top artist ka Last.fm "similar artist" nikaalo, us similar
//     artist ke top tracks (naam+artist, JAISA spotify_service.dart
//     Spotify se karta hai) lo, phir YouTube pe search karke video-id
//     match karo. Ye Layer A se ALAG artists ke gaane laata hai — matlab
//     "tumhare pasand ke jaisa lekin bilkul naya artist" — asli Discover
//     Weekly ki spirit isi se sabse zyada milti hai.
//
// Dono layers ko milaa ke, already-known (liked/cached/history) content
// hata ke, HAFTE (ISO week) ke hisaab se stable rakha jaata hai — poora
// hafta same rehta hai, naya hafta shuru hote hi khud naya generate ho
// jaata hai (Spotify ke Monday-refresh jaisa).
//
// Last.fm API key: build-time `--dart-define-from-file=env.json` se
// (dekho spotify_service.dart — bilkul same pattern). Key nahi hai to
// Layer B bas skip ho jaata hai, Layer A (jo kabhi fail nahi hota) se
// hi list banti hai — kabhi bhi khaali screen nahi.
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../db/cache_db.dart';
import '../db/liked_db.dart';
import '../db/play_history_db.dart';
import '../models/song.dart';
import 'youtube_service.dart';

class DiscoverWeeklyService {
  DiscoverWeeklyService._internal();
  static final DiscoverWeeklyService instance =
      DiscoverWeeklyService._internal();

  static const String _lastfmApiKey =
      String.fromEnvironment('LASTFM_API_KEY');
  bool get isLastfmConfigured => _lastfmApiKey.isNotEmpty;

  static const int _seedArtistCount = 5; // kitne top-artist seed banenge
  static const int _perArtistFromRadio = 12; // Layer A: har artist se kitna
  static const int _similarArtistsPerSeed = 2; // Layer B: har seed ke kitne
  // similar artist try karein
  static const int _tracksPerSimilarArtist = 6; // Layer B: har similar
  // artist se kitne track try karein
  static const int _targetTotal = 30; // final playlist ka size-cap

  List<Song>? _memoryCache;
  String? _memoryCacheWeek;

  // ISO-jaisa "saal-hafta" key — poora hafta same, naya hafta naya.
  String get _thisWeekKey {
    final now = DateTime.now();
    final startOfYear = DateTime(now.year, 1, 1);
    final weekNum = ((now.difference(startOfYear).inDays) / 7).floor();
    return '${now.year}-W$weekNum';
  }

  Future<List<Song>> getThisWeeksMix({
    void Function(String status)? onProgress,
  }) async {
    final week = _thisWeekKey;
    if (_memoryCache != null && _memoryCacheWeek == week) {
      return _memoryCache!;
    }
    final songs = await _generate(onProgress: onProgress);
    _memoryCache = songs;
    _memoryCacheWeek = week;
    return songs;
  }

  Future<List<Song>> _generate({
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Tumhara listening data dekh rahe hain...');
    final topArtists =
        await PlayHistoryDB.instance.getTopArtists(limit: _seedArtistCount);
    if (topArtists.isEmpty) return [];

    final mostPlayed = await PlayHistoryDB.instance.getMostPlayed(limit: 200);
    final liked = await LikedDB.instance.getAll();
    final cached = await CacheDB.instance.getAll();

    // "Already known" set — ye songs Discover Weekly me NAHI aane chahiye,
    // warna "discover" ka matlab hi nahi rehta.
    final knownIds = <String>{
      ...liked.map((s) => s.id),
      ...cached.map((e) => e['id'] as String),
      ...mostPlayed.map((e) => e.key.id),
    };

    final result = <Song>[];
    final seenIds = <String>{};
    void addIfNew(Song s) {
      if (s.id.isEmpty) return;
      if (knownIds.contains(s.id)) return;
      if (seenIds.contains(s.id)) return;
      seenIds.add(s.id);
      result.add(s);
    }

    // ---------------- Layer A: apna history + YouTube Radio ----------------
    onProgress?.call('Tumhare pasand ke artists se naye gaane dhoond rahe...');
    for (final entry in topArtists) {
      final artist = entry.key;
      final seedSong = mostPlayed
          .map((e) => e.key)
          .where((s) => s.artist == artist)
          .cast<Song?>()
          .firstWhere((s) => s != null, orElse: () => null);
      if (seedSong == null) continue;
      try {
        final radioSongs = await YoutubeService.instance.getRadioQueue(
          seedSong.id,
          seedSong.title,
          artist,
          count: _perArtistFromRadio * 2, // extra le lo, kuch known nikal jaayenge
        );
        for (final s in radioSongs) {
          addIfNew(s);
        }
      } catch (e) {
        print('DISCOVER WEEKLY Layer A ERROR ($artist): $e');
        // Ek artist fail ho to baaki continue karte hain.
      }
    }

    // ---------------- Layer B (BONUS): Last.fm similar artists ----------------
    if (isLastfmConfigured) {
      onProgress?.call('Last.fm se similar artists dhoond rahe...');
      for (final entry in topArtists) {
        final seedArtist = entry.key;
        List<String> similar;
        try {
          similar = await _lastfmSimilarArtists(seedArtist);
        } catch (e) {
          print('DISCOVER WEEKLY Layer B (similar-artist) ERROR ($seedArtist): $e');
          continue;
        }
        for (final similarArtist in similar.take(_similarArtistsPerSeed)) {
          List<String> trackNames;
          try {
            trackNames = await _lastfmTopTracks(similarArtist);
          } catch (e) {
            print('DISCOVER WEEKLY Layer B (top-tracks) ERROR ($similarArtist): $e');
            continue;
          }
          for (final trackName in trackNames.take(_tracksPerSimilarArtist)) {
            try {
              // Last.fm sirf naam deta hai (audio nahi) — YouTube pe
              // seedha search karke match karte hain, bilkul jaisa
              // import_playlist_screen.dart Spotify tracks ke liye karta
              // hai.
              final matches = await YoutubeService.instance.search(
                '$trackName $similarArtist',
                max: 1,
              );
              if (matches.isNotEmpty) addIfNew(matches.first.toSong());
            } catch (e) {
              print('DISCOVER WEEKLY Layer B (yt-match) ERROR ($trackName): $e');
              // Ek track match fail ho to baaki pe koi asar nahi.
            }
            if (result.length >= _targetTotal) break;
          }
          if (result.length >= _targetTotal) break;
        }
        if (result.length >= _targetTotal) break;
      }
    }

    // Stable-per-week shuffle — same hafte me refresh karo to order same
    // rahe (isi hafte ki date se seeded), naya hafta aate hi khud badal
    // jaayega (kyunki seed khud hi week ke saath badalta hai).
    result.shuffle(_weekSeededRandom());
    return result.take(_targetTotal).toList();
  }

  math.Random _weekSeededRandom() {
    return math.Random(_thisWeekKey.hashCode);
  }

  // ---------------- Last.fm (public, no-OAuth read endpoints) ----------------

  Future<List<String>> _lastfmSimilarArtists(String artist) async {
    final uri = Uri.parse('https://ws.audioscrobbler.com/2.0/').replace(
      queryParameters: {
        'method': 'artist.getsimilar',
        'artist': artist,
        'api_key': _lastfmApiKey,
        'format': 'json',
        'limit': '5',
      },
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Last.fm getsimilar error (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final similarArtists = data['similarartists'] as Map<String, dynamic>?;
    final artistList = (similarArtists?['artist'] as List?) ?? [];
    return artistList
        .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }

  Future<List<String>> _lastfmTopTracks(String artist) async {
    final uri = Uri.parse('https://ws.audioscrobbler.com/2.0/').replace(
      queryParameters: {
        'method': 'artist.gettoptracks',
        'artist': artist,
        'api_key': _lastfmApiKey,
        'format': 'json',
        'limit': '8',
      },
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Last.fm gettoptracks error (${res.statusCode})');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final topTracks = data['toptracks'] as Map<String, dynamic>?;
    final trackList = (topTracks?['track'] as List?) ?? [];
    return trackList
        .map((t) => (t as Map<String, dynamic>)['name'] as String? ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
  }
}
