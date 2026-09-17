// lib/services/lyrics_service.dart
// Multi-source Radio lyrics. Synced LRC is preferred; Indian-language/plain
// lyrics fall back through JioSaavn and lyrics.ovh so Radio never depends on
// a single lyrics provider.
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';

class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class LyricsResult {
  final List<LyricLine>? synced;
  final String? plain;
  final String source;
  const LyricsResult({this.synced, this.plain, this.source = 'unknown'});

  bool get hasSynced => synced != null && synced!.isNotEmpty;
  bool get hasPlain => plain != null && plain!.trim().isNotEmpty;
  bool get hasAny => hasSynced || hasPlain;
}

class LyricsService {
  LyricsService._internal();
  static final LyricsService instance = LyricsService._internal();

  static const _lrcBase = 'https://lrclib.net/api';
  static const _jioBase = 'https://www.jiosaavn.com/api.php';
  static const _ovhBase = 'https://api.lyrics.ovh/v1';
  static const _userAgent = 'SurSathi/55 RadioLyrics';

  // v3 deliberately invalidates v2's single-provider/negative cache.
  String _cacheKey(String songId) => 'lyrics_v3_$songId';

  Future<LyricsResult?> getForSong({
    required String songId,
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey(songId));
    if (cached != null) {
      final decoded = _decode(cached);
      if (decoded != null && decoded.hasAny) return decoded;
    }

    final result = await _fetchMultiSource(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );

    // Cache only a real result. A temporary provider/network failure should
    // not permanently turn a song into "no lyrics".
    if (result != null && result.hasAny) {
      await prefs.setString(_cacheKey(songId), _encode(result));
    }
    return result;
  }

  Future<void> prefetchForSongs(Iterable<Song> songs, {int maxSongs = 10}) async {
    // Keep requests serial and bounded. LRCLIB explicitly asks clients to
    // avoid bursts and to identify themselves with a User-Agent.
    for (final song in songs.take(maxSongs)) {
      await getForSong(
        songId: song.id,
        title: song.title,
        artist: song.artist,
        durationSeconds: song.duration,
      );
      await Future.delayed(const Duration(milliseconds: 220));
    }
  }

  Future<LyricsResult?> _fetchMultiSource({
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    // 1) LRCLIB exact signature -> best source for synchronized LRC.
    final exact = await _fetchLrclibExact(title, artist, durationSeconds);
    if (exact?.hasSynced == true) return exact;

    // 2) LRCLIB title/artist search -> catches remasters, regional releases,
    // duration mismatches and Indian catalogue variants.
    final searched = await _fetchLrclibSearch(title, artist, durationSeconds);
    if (searched?.hasSynced == true) return searched;

    // Keep a useful plain result while the next providers are queried.
    LyricsResult? plain = exact?.hasPlain == true ? exact : searched;

    // 3) JioSaavn's public web API. This is particularly useful for Hindi,
    // Punjabi, Haryanvi and other Indian catalogue songs. Its lyrics endpoint
    // is plain-text rather than guaranteed LRC, so never invent timestamps.
    final jio = await _fetchJioSaavn(title, artist);
    if (jio?.hasPlain == true) plain ??= jio;

    // 4) Generic plain-lyrics fallback.
    final ovh = await _fetchLyricsOvh(title, artist);
    if (ovh?.hasPlain == true) plain ??= ovh;

    return plain;
  }

  Future<LyricsResult?> _fetchLrclibExact(
    String title,
    String artist,
    int durationSeconds,
  ) async {
    try {
      final uri = Uri.parse('$_lrcBase/get').replace(queryParameters: {
        'track_name': title,
        'artist_name': artist,
        if (durationSeconds > 0) 'duration': '$durationSeconds',
      });
      final response = await http.get(uri, headers: _headers).timeout(
            const Duration(seconds: 7),
          );
      if (response.statusCode != 200) return null;
      return _fromJsonBody(response.body, source: 'LRCLIB');
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _fetchLrclibSearch(
    String title,
    String artist,
    int durationSeconds,
  ) async {
    try {
      final uri = Uri.parse('$_lrcBase/search').replace(queryParameters: {
        'track_name': title,
        'artist_name': artist,
      });
      final response = await http.get(uri, headers: _headers).timeout(
            const Duration(seconds: 7),
          );
      if (response.statusCode != 200) return null;
      final raw = jsonDecode(response.body);
      if (raw is! List) return null;

      Map<String, dynamic>? best;
      var bestScore = double.negativeInfinity;
      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final parsed = _fromJsonMap(map, source: 'LRCLIB');
        if (!parsed.hasAny) continue;
        final candidateTitle = (map['trackName'] ?? map['name'] ?? '').toString();
        final candidateArtist = (map['artistName'] ?? '').toString();
        final candidateDuration = (map['duration'] as num?)?.toDouble() ?? 0;
        final score = _matchScore(
          title,
          artist,
          durationSeconds,
          candidateTitle,
          candidateArtist,
          candidateDuration,
        );
        if (score > bestScore) {
          bestScore = score;
          best = map;
        }
      }
      return best == null ? null : _fromJsonMap(best, source: 'LRCLIB');
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _fetchJioSaavn(String title, String artist) async {
    try {
      final query = '$title $artist'.trim();
      final searchUri = Uri.parse(_jioBase).replace(queryParameters: {
        '__call': 'autocomplete.get',
        '_format': 'json',
        '_marker': '0',
        'cc': 'in',
        'includeMetaTags': '1',
        'query': query,
      });
      final searchResponse = await http.get(searchUri, headers: _headers).timeout(
            const Duration(seconds: 7),
          );
      if (searchResponse.statusCode != 200) return null;
      final decoded = jsonDecode(searchResponse.body);
      final data = decoded is Map && decoded['songs'] is Map
          ? (decoded['songs']['data'] as List?)
          : null;
      if (data == null || data.isEmpty) return null;

      Map<String, dynamic>? bestSong;
      var bestScore = double.negativeInfinity;
      for (final item in data.take(8)) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final candidateTitle = (map['title'] ?? map['song'] ?? '').toString();
        final candidateArtist = (map['singers'] ?? map['artist'] ?? '').toString();
        final score = _textMatchScore(title, artist, candidateTitle, candidateArtist);
        if (score > bestScore) {
          bestScore = score;
          bestSong = map;
        }
      }
      if (bestSong == null) return null;

      var lyricsId = _findString(bestSong, const {
        'lyrics_id',
        'lyricsId',
      });
      final songId = _findString(bestSong, const {'id', 'songid'});

      if (lyricsId == null && songId != null) {
        final detailsUri = Uri.parse(_jioBase).replace(queryParameters: {
          '__call': 'song.getDetails',
          'cc': 'in',
          '_marker': '0?_marker=0',
          '_format': 'json',
          'pids': songId,
        });
        final detailsResponse = await http.get(detailsUri, headers: _headers).timeout(
              const Duration(seconds: 7),
            );
        if (detailsResponse.statusCode == 200) {
          final details = jsonDecode(detailsResponse.body);
          if (details is Map) {
            final record = details[songId] is Map ? details[songId] : details;
            if (record is Map) lyricsId = _findString(record, const {'lyrics_id', 'lyricsId'});
          }
        }
      }

      if (lyricsId == null || lyricsId.isEmpty) return null;
      final lyricsUri = Uri.parse(_jioBase).replace(queryParameters: {
        '__call': 'lyrics.getLyrics',
        'ctx': 'web6dot0',
        'api_version': '4',
        '_format': 'json',
        '_marker': '0?_marker=0',
        'lyrics_id': lyricsId,
      });
      final lyricsResponse = await http.get(lyricsUri, headers: _headers).timeout(
            const Duration(seconds: 7),
          );
      if (lyricsResponse.statusCode != 200) return null;
      final body = jsonDecode(lyricsResponse.body);
      if (body is! Map) return null;
      final rawLyrics = body['lyrics']?.toString();
      final clean = _cleanHtmlLyrics(rawLyrics);
      if (clean == null || clean.isEmpty) return null;
      return LyricsResult(plain: clean, source: 'JioSaavn');
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _fetchLyricsOvh(String title, String artist) async {
    try {
      final uri = Uri.parse('$_ovhBase/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}');
      final response = await http.get(uri, headers: _headers).timeout(
            const Duration(seconds: 6),
          );
      if (response.statusCode != 200) return null;
      final map = jsonDecode(response.body);
      if (map is! Map) return null;
      final lyrics = map['lyrics']?.toString().trim();
      if (lyrics == null || lyrics.isEmpty) return null;
      return LyricsResult(plain: lyrics, source: 'lyrics.ovh');
    } catch (_) {
      return null;
    }
  }

  Map<String, String> get _headers => const {
        'User-Agent': _userAgent,
        'Accept': 'application/json,text/plain,*/*',
      };

  static double _matchScore(
    String title,
    String artist,
    int duration,
    String candidateTitle,
    String candidateArtist,
    double candidateDuration,
  ) {
    var score = _textMatchScore(title, artist, candidateTitle, candidateArtist);
    if (duration > 0 && candidateDuration > 0) {
      final delta = (duration - candidateDuration).abs();
      score += math.max(0, 1.0 - delta / 20.0).toDouble() * 3;
    }
    return score;
  }

  static double _textMatchScore(String title, String artist, String ct, String ca) {
    final t = _normalize(title);
    final a = _normalize(artist);
    final candidateT = _normalize(ct);
    final candidateA = _normalize(ca);
    var score = 0.0;
    if (candidateT == t) score += 5;
    if (candidateA.contains(a) || a.contains(candidateA)) score += 4;
    if (candidateT.contains(t) || t.contains(candidateT)) score += 2;
    return score;
  }

  static String _normalize(String value) => value
      .toLowerCase()
      // Keep Devanagari/Gurmukhi/Haryanvi letters intact; only strip common
      // title punctuation so Indian-language matching remains useful.
      .replaceAll(RegExp(r'[\[\](){},.!?;:\'\"|/\\_+*=]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String? _findString(Map map, Set<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) return value.toString();
    }
    for (final value in map.values) {
      if (value is Map) {
        final nested = _findString(value, keys);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  static String? _cleanHtmlLyrics(String? raw) {
    if (raw == null) return null;
    var text = raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return text.isEmpty ? null : text;
  }

  LyricsResult? _fromJsonBody(String body, {required String source}) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      return _fromJsonMap(map, source: source);
    } catch (_) {
      return null;
    }
  }

  LyricsResult _fromJsonMap(Map<String, dynamic> map, {required String source}) {
    final syncedRaw = map['syncedLyrics'] as String?;
    final plain = map['plainLyrics'] as String?;
    final synced = (syncedRaw != null && syncedRaw.trim().isNotEmpty)
        ? _parseLrc(syncedRaw)
        : null;
    return LyricsResult(synced: synced, plain: plain, source: source);
  }

  static final _lrcTag = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]');

  List<LyricLine> _parseLrc(String lrc) {
    final lines = <LyricLine>[];
    var offsetMs = 0;
    for (final rawLine in lrc.split(RegExp(r'\r?\n'))) {
      final offsetMatch = RegExp(r'^\[offset:([+-]?\d+)\]', caseSensitive: false).firstMatch(rawLine.trim());
      if (offsetMatch != null) {
        offsetMs = int.tryParse(offsetMatch.group(1)!) ?? 0;
        continue;
      }
      final matches = _lrcTag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final text = rawLine.replaceAll(_lrcTag, '').trim();
      if (text.isEmpty) continue;
      for (final match in matches) {
        final min = int.tryParse(match.group(1)!) ?? 0;
        final sec = int.tryParse(match.group(2)!) ?? 0;
        final fraction = (match.group(3) ?? '0').padRight(3, '0').substring(0, 3);
        final ms = int.tryParse(fraction) ?? 0;
        final corrected = math.max(0, Duration(minutes: min, seconds: sec, milliseconds: ms).inMilliseconds + offsetMs).toInt();
        lines.add(LyricLine(Duration(milliseconds: corrected), text));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  String _encode(LyricsResult r) => jsonEncode({
        'source': r.source,
        'plain': r.plain,
        'synced': r.synced?.map((l) => {'ms': l.time.inMilliseconds, 't': l.text}).toList(),
      });

  LyricsResult? _decode(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final syncedList = map['synced'] as List?;
      final synced = syncedList
          ?.whereType<Map>()
          .map((e) => LyricLine(
                Duration(milliseconds: (e['ms'] as num).toInt()),
                e['t'].toString(),
              ))
          .toList();
      return LyricsResult(
        synced: (synced != null && synced.isNotEmpty) ? synced : null,
        plain: map['plain'] as String?,
        source: map['source']?.toString() ?? 'cache',
      );
    } catch (_) {
      return null;
    }
  }
}
