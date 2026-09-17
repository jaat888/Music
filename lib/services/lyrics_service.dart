// lib/services/lyrics_service.dart
// Synced (karaoke-style) lyrics — pehle lyrics_screen.dart me sirf ek
// SharedPreferences cache read hota tha, kahin se fetch hi nahi hota tha
// (isliye "Lyrics abhi available nahi" hamesha dikhta tha). Ab lrclib.net
// (free, no API key, khaas gaano ke time-synced LRC lyrics ke liye
// bana hai — OpenTune/OuterTune jaise apps bhi yehi use karte hain) se
// fetch karte hain.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class LyricsResult {
  final List<LyricLine>? synced; // time-stamped, live sync ke liye
  final String? plain; // sirf plain text (koi timing nahi)
  const LyricsResult({this.synced, this.plain});

  bool get hasSynced => synced != null && synced!.isNotEmpty;
  bool get hasAny => hasSynced || (plain != null && plain!.trim().isNotEmpty);
}

class LyricsService {
  LyricsService._internal();
  static final LyricsService instance = LyricsService._internal();

  static const _base = 'https://lrclib.net/api';

  String _cacheKey(String songId) => 'lyrics_v2_$songId';

  // Cache-first: pehle local SharedPreferences dekho, warna network call.
  Future<LyricsResult?> getForSong({
    required String songId,
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_cacheKey(songId));
    if (cached != null) {
      return _decode(cached);
    }
    final result = await _fetch(
      title: title,
      artist: artist,
      durationSeconds: durationSeconds,
    );
    // Result null ho ya khaali — dono cache karo taaki har baar dobara
    // network call na ho (khaali result ka matlab "iske lyrics milte hi
    // nahi", wo bhi ek valid/stable jawab hai).
    await prefs.setString(
      _cacheKey(songId),
      _encode(result ?? const LyricsResult()),
    );
    return result;
  }

  Future<LyricsResult?> _fetch({
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    try {
      // Step 1: exact `/get` — duration match hone par best result deta hai.
      final getUri = Uri.parse('$_base/get').replace(queryParameters: {
        'track_name': title,
        'artist_name': artist,
        if (durationSeconds > 0) 'duration': '$durationSeconds',
      });
      final res = await http.get(getUri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final parsed = _fromJsonBody(res.body);
        if (parsed != null && parsed.hasAny) return parsed;
      }

      // Step 2: `/get` na mile (404, ya duration mismatch) to `/search` try
      // karo aur pehla result le lo.
      final searchUri = Uri.parse('$_base/search').replace(queryParameters: {
        'track_name': title,
        'artist_name': artist,
      });
      final searchRes =
          await http.get(searchUri).timeout(const Duration(seconds: 8));
      if (searchRes.statusCode == 200) {
        final list = jsonDecode(searchRes.body) as List;
        if (list.isNotEmpty) {
          final parsed = _fromJsonMap(list.first as Map<String, dynamic>);
          if (parsed.hasAny) return parsed;
        }
      }
    } catch (e) {
      print('Lyrics fetch failed: $e');
    }
    return null;
  }

  LyricsResult? _fromJsonBody(String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      return _fromJsonMap(map);
    } catch (_) {
      return null;
    }
  }

  LyricsResult _fromJsonMap(Map<String, dynamic> map) {
    final syncedRaw = map['syncedLyrics'] as String?;
    final plain = map['plainLyrics'] as String?;
    final synced = (syncedRaw != null && syncedRaw.trim().isNotEmpty)
        ? _parseLrc(syncedRaw)
        : null;
    return LyricsResult(synced: synced, plain: plain);
  }

  // "[01:02.34]Kuch line yahan" jaisi LRC lines parse karta hai. Ek line
  // me multiple timestamps bhi ho sakte hain ("[00:01.00][00:05.00]text").
  static final _lrcTag = RegExp(r'\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]');

  List<LyricLine> _parseLrc(String lrc) {
    final lines = <LyricLine>[];
    for (final rawLine in lrc.split('\n')) {
      final matches = _lrcTag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;
      final text = rawLine.replaceAll(_lrcTag, '').trim();
      if (text.isEmpty) continue;
      for (final m in matches) {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final fracStr = (m.group(3) ?? '0').padRight(3, '0').substring(0, 3);
        final ms = int.parse(fracStr);
        lines.add(LyricLine(
          Duration(minutes: min, seconds: sec, milliseconds: ms),
          text,
        ));
      }
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }

  String _encode(LyricsResult r) => jsonEncode({
        'plain': r.plain,
        'synced': r.synced
            ?.map((l) => {'ms': l.time.inMilliseconds, 't': l.text})
            .toList(),
      });

  LyricsResult _decode(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final syncedList = map['synced'] as List?;
      final synced = syncedList
          ?.map((e) => LyricLine(
                Duration(milliseconds: e['ms'] as int),
                e['t'] as String,
              ))
          .toList();
      return LyricsResult(
        synced: (synced != null && synced.isNotEmpty) ? synced : null,
        plain: map['plain'] as String?,
      );
    } catch (_) {
      return const LyricsResult();
    }
  }
}
