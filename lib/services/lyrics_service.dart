// lib/services/lyrics_service.dart
// Multi-source Radio lyrics. Synced LRC is preferred; Indian-language/plain
// lyrics fall back through JioSaavn and lyrics.ovh so Radio never depends on
// a single lyrics provider.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song.dart';
import 'innertube_client.dart';
import 'app_logger.dart';

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
  // v96: BetterLyrics (TTML, word-by-word) aur Kugou (per-line synced,
  // Chinese source — Hindi/regional ke liye kam useful lekin decent
  // fallback) naye add kiye.
  static const _betterLyricsBase = 'https://lyrics-api.boidu.dev/getLyrics';
  static const _kugouSearchBase = 'https://mobileservice.kugou.com/api/v3/lyric/search';
  static const _kugouDownloadBase = 'https://lyrics.kugou.com/download';
  static const _userAgent = 'SurSathi/55 RadioLyrics';

  // v115: Radio ab best-timed-source selection karta hai, isliye cache key
  // bump ki gayi hai taaki purana first-source result is naye scan ko bypass
  // na kare.
  // Normal LyricsScreen cache and Radio's strict best-synced cache must stay
  // physically separate. Otherwise a normal-screen first-source result can
  // short-circuit Radio's all-provider quality scan for the same song.
  String _cacheKey(String songId) => 'lyrics_v5_$songId';
  String _syncedCacheKey(String songId) => 'lyrics_v5_synced_$songId';

  // BUG FIX (Radio "subtitle" stuck-loading — v58): Radio was calling
  // getForSong() for the SAME current song from more than one place at
  // once — the screen's own direct lyrics load, plus prefetchForSongs()
  // (which always lists the current song first, and gets triggered twice
  // per song transition) — each one firing its own independent
  // LRCLIB -> LRCLIB-search -> JioSaavn -> lyrics.ovh chain. On a slow/
  // mobile connection those duplicate chains compete for the same
  // bandwidth, so the one result the screen is actually waiting on could
  // take far longer than a single request would (this is exactly why the
  // same song's lyrics loaded fine from the plain LyricsScreen, which only
  // ever makes one request, but not from Radio). This in-flight map makes
  // every concurrent call for the same songId share one underlying fetch
  // instead of starting a new one.
  final Map<String, Future<LyricsResult?>> _inFlight = {};

  // Radio needs a stricter contract than the full lyrics screen: it must
  // show ONLY genuinely time-synced lyrics. A plain-only cached result must
  // never make Radio stop searching for a timed version. This second map
  // also prevents a normal plain-lyrics request from racing a Radio timed
  // request and deciding the wrong result.
  final Map<String, Future<LyricsResult?>> _syncedInFlight = {};

  /// Radio-specific lyrics lookup.
  ///
  /// All providers that can return timing are scanned before a winner is
  /// chosen. The source with the strongest timing coverage is selected, not
  /// simply the first provider that replies. If none of the timed providers
  /// returns usable synchronized lyrics, this returns null so Radio can show
  /// "Lyrics not available" rather than pretending plain text is synced.
  Future<LyricsResult?> getSyncedForSong({
    required String songId,
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_syncedCacheKey(songId));
    if (cached != null) {
      final decoded = _decode(cached);
      if (decoded != null && decoded.hasSynced) return decoded;
    }

    final existing = _syncedInFlight[songId];
    if (existing != null) return existing;

    final future = _fetchBestSyncedSource(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
    _syncedInFlight[songId] = future;
    try {
      final result = await future;
      if (result != null && result.hasSynced) {
        await prefs.setString(_syncedCacheKey(songId), _encode(result));
      }
      return result;
    } finally {
      _syncedInFlight.remove(songId);
    }
  }

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

    final existing = _inFlight[songId];
    if (existing != null) return existing;

    final future = _fetchMultiSource(
      songId: songId,
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
    _inFlight[songId] = future;
    try {
      final result = await future;
      // Cache only a real result. A temporary provider/network failure
      // should not permanently turn a song into "no lyrics".
      if (result != null && result.hasAny) {
        await prefs.setString(_cacheKey(songId), _encode(result));
      }
      return result;
    } finally {
      _inFlight.remove(songId);
    }
  }

  // BUG FIX (Radio "subtitle" stuck-loading — v58): prefetching upcoming
  // Radio songs' lyrics must never be able to outlive the songs it was
  // started for. `isCancelled` lets the caller stop this loop as soon as
  // the listener has skipped past that batch, instead of it quietly
  // continuing to fire requests (and eat bandwidth) for songs nobody is
  // listening to anymore across a long Radio session.
  Future<void> prefetchForSongs(
    Iterable<Song> songs, {
    int maxSongs = 10,
    bool Function()? isCancelled,
  }) async {
    // Keep requests serial and bounded. LRCLIB explicitly asks clients to
    // avoid bursts and to identify themselves with a User-Agent.
    for (final song in songs.take(maxSongs)) {
      if (isCancelled?.call() ?? false) return;
      await getForSong(
        songId: song.id,
        title: song.title,
        artist: song.artist,
        durationSeconds: song.duration,
      );
      if (isCancelled?.call() ?? false) return;
      await Future.delayed(const Duration(milliseconds: 220));
    }
  }

  /// Radio look-ahead must use the same strict synchronized contract as the
  /// current-song lookup. Plain-only lyrics are intentionally not prefetched
  /// for Radio because they cannot be time-mapped onto the audio timeline.
  Future<void> prefetchSyncedForSongs(
    Iterable<Song> songs, {
    int maxSongs = 10,
    bool Function()? isCancelled,
  }) async {
    for (final song in songs.take(maxSongs)) {
      if (isCancelled?.call() ?? false) return;
      await getSyncedForSong(
        songId: song.id,
        title: song.title,
        artist: song.artist,
        durationSeconds: song.duration,
      );
      if (isCancelled?.call() ?? false) return;
      await Future.delayed(const Duration(milliseconds: 220));
    }
  }

  // Normal LyricsScreen keeps the v96 fallback order (YT Music internal ->
  // BetterLyrics -> LRCLIB -> Kugou -> JioSaavn -> lyrics.ovh). Radio uses
  // the strict method above, which scans all timing-capable sources first.
  // A source that only has PLAIN text is kept as a fallback candidate but
  // does not stop the search — we keep trying lower sources in case one of
  // them has synced timing. Among plain-only results, the FIRST one found
  // in priority order is kept (matches the user's requested ordering for
  // the plain case too).
  Future<LyricsResult?> _fetchBestSyncedSource({
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    // Do the timing-capable providers together so a slow provider cannot
    // block the whole Radio lyric decision. We still inspect EVERY returned
    // timed result before picking one.
    final results = await Future.wait<LyricsResult?>([
      _fetchBetterLyrics(title, artist, durationSeconds),
      _fetchLrclibExact(title, artist, durationSeconds),
      _fetchLrclibSearch(title, artist, durationSeconds),
      _fetchKugou(title, artist, durationSeconds),
    ], eagerError: false);

    LyricsResult? best;
    var bestScore = double.negativeInfinity;
    for (final result in results) {
      if (result == null || !result.hasSynced) continue;
      final score = _syncedQualityScore(result.synced!, durationSeconds);
      if (score > bestScore) {
        best = result;
        bestScore = score;
      }
    }

    if (best != null) {
      AppLogger.instance.log(
        '[LYRICS] Radio timed scan selected ${best.source} — '
        '${best.synced!.length} timed lines, quality=${bestScore.toStringAsFixed(3)}',
      );
    } else {
      AppLogger.instance.log('[LYRICS] Radio timed scan found no usable synced lyrics');
    }
    return best;
  }

  static double _syncedQualityScore(List<LyricLine> lines, int durationSeconds) {
    if (lines.length < 2) return double.negativeInfinity;

    final sorted = [...lines]..sort((a, b) => a.time.compareTo(b.time));
    final durationMs = durationSeconds > 0 ? durationSeconds * 1000 : 0;
    final valid = durationMs > 0
        ? sorted.where((line) => line.time.inMilliseconds <= durationMs + 15000).toList()
        : sorted;
    if (valid.length < 2) return double.negativeInfinity;

    final lastMs = valid.last.time.inMilliseconds;
    final coverage = durationMs > 0
        ? (lastMs / durationMs).clamp(0.0, 1.0).toDouble()
        : (valid.length / 40.0).clamp(0.0, 1.0).toDouble();
    final lineDensity = (valid.length / 60.0).clamp(0.0, 1.0).toDouble();

    // Prefer lyrics that actually cover the song timeline. A tiny timed
    // snippet should not beat a nearly complete source just because it
    // happens to respond first. Line count is a secondary completeness
    // signal; source priority is deliberately NOT used as a winner rule.
    return coverage * 0.78 + lineDensity * 0.22;
  }

  Future<LyricsResult?> _fetchMultiSource({
    required String songId,
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    LyricsResult? plain;

    // 1) YouTube Music's own "Lyrics" tab (InnerTube, same source the
    // official app shows). Plain-text only (see innertube_client.dart's
    // getLyrics() comment) but usually the most accurate match since it's
    // tied to this exact videoId rather than a title/artist guess.
    final ytMusic = await _fetchYouTubeMusicLyrics(songId);
    if (ytMusic?.hasPlain == true) plain ??= ytMusic;

    // 2) BetterLyrics — Apple-Music-style TTML, word-by-word timing. We
    // flatten it to line-level LyricLines (our model doesn't carry
    // per-word timing yet) but it's still real synced data.
    final better = await _fetchBetterLyrics(title, artist, durationSeconds);
    if (better?.hasSynced == true) return better;
    if (better?.hasPlain == true) plain ??= better;

    // 3) LRCLIB exact signature -> best/most reliable source for
    // synchronized LRC.
    final exact = await _fetchLrclibExact(title, artist, durationSeconds);
    if (exact?.hasSynced == true) return exact;

    // 4) LRCLIB title/artist search -> catches remasters, regional
    // releases, duration mismatches and Indian catalogue variants.
    final searched = await _fetchLrclibSearch(title, artist, durationSeconds);
    if (searched?.hasSynced == true) return searched;
    if (exact?.hasPlain == true) plain ??= exact;
    if (searched?.hasPlain == true) plain ??= searched;

    // 5) Kugou — Chinese source, per-line synced lyrics. Less useful for
    // Hindi/Haryanvi/Punjabi catalogue but a decent extra synced fallback
    // before we drop to plain-only sources.
    final kugou = await _fetchKugou(title, artist, durationSeconds);
    if (kugou?.hasSynced == true) return kugou;
    if (kugou?.hasPlain == true) plain ??= kugou;

    // 6) JioSaavn's public web API. Particularly useful for Hindi, Punjabi,
    // Haryanvi and other Indian catalogue songs. Plain-text only, so never
    // invent timestamps.
    final jio = await _fetchJioSaavn(title, artist);
    if (jio?.hasPlain == true) plain ??= jio;

    // 7) Generic plain-lyrics fallback.
    final ovh = await _fetchLyricsOvh(title, artist);
    if (ovh?.hasPlain == true) plain ??= ovh;

    return plain;
  }

  Future<LyricsResult?> _fetchYouTubeMusicLyrics(String songId) async {
    if (songId.isEmpty) return null;
    try {
      final result = await InnertubeClient.instance
          .getLyrics(songId)
          .timeout(const Duration(seconds: 10));
      if (result == null) return null;
      return LyricsResult(
        plain: result.text,
        source: result.source != null
            ? 'YouTube Music (${result.source})'
            : 'YouTube Music',
      );
    } catch (_) {
      return null;
    }
  }

  Future<LyricsResult?> _fetchBetterLyrics(
    String title,
    String artist,
    int durationSeconds,
  ) async {
    try {
      final uri = Uri.parse(_betterLyricsBase).replace(queryParameters: {
        's': title,
        'a': artist,
        if (durationSeconds > 0) 'd': '$durationSeconds',
      });
      final response = await http.get(uri, headers: _headers).timeout(
            const Duration(seconds: 8),
          );
      if (response.statusCode != 200) return null;
      final map = jsonDecode(response.body);
      if (map is! Map) return null;
      final ttml = map['ttml']?.toString();
      if (ttml == null || ttml.isEmpty) return null;
      final synced = _parseTtml(ttml);
      final plainText = _normalizeMultiLineText(
        synced.map((l) => l.text).where((t) => t.trim().isNotEmpty).join('\n'),
      );
      return LyricsResult(
        synced: synced.isNotEmpty ? synced : null,
        plain: plainText.isNotEmpty ? plainText : null,
        source: 'BetterLyrics',
      );
    } catch (_) {
      return null;
    }
  }

  // TTML -> line-level LyricLines. Each <p begin="..."> is one line; the
  // line's own text is every <span> inside it joined together (spans carry
  // per-word timing which we don't have a model for yet, but joining their
  // text back together reconstructs the full line correctly).
  static final _ttmlP = RegExp(
    r'<p\b[^>]*\bbegin="([^"]+)"[^>]*>(.*?)</p>',
    dotAll: true,
  );
  static final _ttmlSpanText = RegExp(r'<span\b[^>]*>([^<]*)</span>', dotAll: true);

  List<LyricLine> _parseTtml(String ttml) {
    final lines = <LyricLine>[];
    for (final match in _ttmlP.allMatches(ttml)) {
      final beginMs = _parseTtmlTime(match.group(1) ?? '');
      if (beginMs == null) continue;
      final inner = match.group(2) ?? '';
      final segments = <String>[];
      for (final span in _ttmlSpanText.allMatches(inner)) {
        final segment = _normalizeSingleLineText(
          _decodeXmlEntities(span.group(1) ?? ''),
        );
        if (segment.isNotEmpty) segments.add(segment);
      }
      var text = _joinTimedSegments(segments);
      if (text.isEmpty) {
        // Some lines have no nested <span> (rare) — fall back to the raw
        // inner text with tags stripped.
        text = _normalizeSingleLineText(
          _decodeXmlEntities(inner.replaceAll(RegExp(r'<[^>]+>'), '')),
        );
      }
      if (text.isEmpty) continue;
      lines.add(LyricLine(Duration(milliseconds: beginMs), text));
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  // Handles both "HH:MM:SS.mmm" and "M:SS.mmm" per the BetterLyrics docs.
  static int? _parseTtmlTime(String raw) {
    final parts = raw.trim().split(':');
    try {
      double seconds;
      if (parts.length == 3) {
        seconds = int.parse(parts[0]) * 3600 +
            int.parse(parts[1]) * 60 +
            double.parse(parts[2]);
      } else if (parts.length == 2) {
        seconds = int.parse(parts[0]) * 60 + double.parse(parts[1]);
      } else {
        seconds = double.parse(parts[0]);
      }
      return (seconds * 1000).round();
    } catch (_) {
      return null;
    }
  }

  static String _decodeXmlEntities(String text) => text
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  Future<LyricsResult?> _fetchKugou(
    String title,
    String artist,
    int durationSeconds,
  ) async {
    try {
      final keyword = artist.trim().isNotEmpty ? '$artist - $title' : title;
      final searchUri =
          Uri.parse(_kugouSearchBase).replace(queryParameters: {
        'ver': '1',
        'man': 'yes',
        'client': 'mobi',
        'keyword': keyword,
        if (durationSeconds > 0) 'duration': '${durationSeconds * 1000}',
        'hash': '',
      });
      final searchResponse = await http.get(searchUri, headers: _headers).timeout(
            const Duration(seconds: 8),
          );
      if (searchResponse.statusCode != 200) return null;
      final searchMap = jsonDecode(searchResponse.body);
      if (searchMap is! Map) return null;
      final candidates = searchMap['candidates'];
      if (candidates is! List || candidates.isEmpty) return null;

      // Pick the candidate whose own duration is closest to ours (Kugou
      // returns several song/lyric versions — covers, remixes etc.).
      Map? best;
      var bestDelta = double.infinity;
      for (final c in candidates) {
        if (c is! Map) continue;
        final candDuration = (c['duration'] as num?)?.toDouble() ?? 0;
        final delta = durationSeconds > 0 && candDuration > 0
            ? (durationSeconds * 1000 - candDuration).abs()
            : 0.0;
        if (delta < bestDelta) {
          bestDelta = delta;
          best = c;
        }
      }
      best ??= candidates.first as Map?;
      if (best == null) return null;
      final id = best['id']?.toString();
      final accesskey = best['accesskey']?.toString();
      if (id == null || accesskey == null || id.isEmpty || accesskey.isEmpty) {
        return null;
      }

      final downloadUri =
          Uri.parse(_kugouDownloadBase).replace(queryParameters: {
        'ver': '1',
        'client': 'pc',
        'id': id,
        'accesskey': accesskey,
        'fmt': 'lrc',
        'charset': 'utf8',
      });
      final downloadResponse =
          await http.get(downloadUri, headers: _headers).timeout(
                const Duration(seconds: 8),
              );
      if (downloadResponse.statusCode != 200) return null;
      final downloadMap = jsonDecode(downloadResponse.body);
      if (downloadMap is! Map) return null;
      final contentB64 = downloadMap['content']?.toString();
      if (contentB64 == null || contentB64.isEmpty) return null;
      final lrcText = utf8.decode(base64.decode(contentB64), allowMalformed: true);
      final synced = _parseLrc(lrcText);
      if (synced.isEmpty) return null;
      return LyricsResult(synced: synced, source: 'Kugou');
    } catch (_) {
      return null;
    }
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
      // BUG FIX (v56 — user report: "lyrics load ho jaaye to bhi sync
      // achha nahi hota"): pehle yahan hamesha "best" candidate use ho
      // jaata tha, chahe wo kitna bhi kharab match kyun na ho (koi
      // minimum score threshold nahi tha) — matlab agar LRCLIB pe is
      // gaane ka koi decent match nahi tha, to bhi ek bilkul alag
      // title/duration wale gaane ki LRC timing yahan use ho jaati thi.
      // Us doosre gaane ki timing is gaane ke audio se kabhi match nahi
      // karti — isi liye "lyrics dikh rahi hain lekin sync galat hai"
      // jaisa symptom hota tha. Ab ek minimum score chahiye (kam se kam
      // decent title overlap + duration proximity) — nahi to yahan se
      // `null` return hota hai aur pipeline JioSaavn/plain lyrics
      // fallback pe chala jaata hai, jo galat-sync LRC se behtar hai.
      // BUG FIX (v57 — user report: "radio me subtitle aata hi nahi, wahi
      // gaana normal player me chalao to dikh jaata hai"): v56 me diya
      // gaya `minAcceptableScore = 5.0` real-world data ke liye zyada
      // strict nikla — LRCLIB ke community-contributed results me artist
      // ka naam aksar thoda alag format me hota hai (ya bilkul missing),
      // aur duration bhi 2-5 second idhar-udhar hota hai (intro/outro
      // trim ka farak) — chahe title theek match ho raha ho. Isse ek
      // GENUINELY sahi match bhi (title-contains + halka duration
      // mismatch) score ~4 pe reh jaata tha, 5.0 ke threshold se neeche,
      // aur reject ho jaata — result: us gaane ka koi bhi lyrics (na
      // synced, na plain) nahi dikhta tha. Threshold ab 3.0 hai — pure
      // coincidental ek-shabd title overlap (score sirf 2) ab bhi reject
      // hota hai, lekin title-match + koi bhi corroborating signal
      // (artist ya duration) accept ho jaata hai.
      const minAcceptableScore = 3.0;
      if (best == null || bestScore < minAcceptableScore) return null;
      return _fromJsonMap(best, source: 'LRCLIB');
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
      return LyricsResult(plain: _normalizeMultiLineText(clean), source: 'JioSaavn');
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
      return LyricsResult(plain: _normalizeMultiLineText(lyrics), source: 'lyrics.ovh');
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
      .replaceAll(RegExp(r'''[\[\](){},.!?;:'\"|/\\_+*=]+'''), ' ')
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
    final rawPlain = map['plainLyrics'] as String?;
    final plain = rawPlain == null ? null : _normalizeMultiLineText(rawPlain);
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
        lines.add(
          LyricLine(
            Duration(milliseconds: corrected),
            _normalizeSingleLineText(text),
          ),
        );
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  static String _normalizeSingleLineText(String text) {
    return text
        .replaceAll('\u00A0', ' ')
        .replaceAll(RegExp(r'[\t\f\v]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _normalizeMultiLineText(String text) {
    final lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map(_normalizeSingleLineText)
        .where((line) => line.isNotEmpty)
        .toList();
    return lines.join('\n').trim();
  }

  @visibleForTesting
  static String joinTimedSegmentsForTest(List<String> segments) =>
      _joinTimedSegments(segments);

  @visibleForTesting
  static double syncedQualityScoreForTest(List<LyricLine> lines, int durationSeconds) =>
      _syncedQualityScore(lines, durationSeconds);

  static String _joinTimedSegments(List<String> segments) {
    final buffer = StringBuffer();
    for (final segment in segments) {
      final cleaned = _normalizeSingleLineText(segment);
      if (cleaned.isEmpty) continue;
      if (buffer.isNotEmpty) {
        // Also treat the ASCII apostrophe as punctuation. Some TTML
        // providers split a contraction into spans like `don` + `'t`; that
        // must become `don't`, not `don 't`.
        final rightStartsPunctuation = RegExp(r"^[,.;:!?%\)\]\}'\u2019\u201d]")
            .hasMatch(cleaned);
        if (!rightStartsPunctuation) buffer.write(' ');
      }
      buffer.write(cleaned);
    }
    return _normalizeSingleLineText(buffer.toString());
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
                _normalizeSingleLineText(e['t'].toString()),
              ))
          .toList();
      return LyricsResult(
        synced: (synced != null && synced.isNotEmpty) ? synced : null,
        plain: (map['plain'] as String?) == null
            ? null
            : _normalizeMultiLineText(map['plain'] as String),
        source: map['source']?.toString() ?? 'cache',
      );
    } catch (_) {
      return null;
    }
  }
}
