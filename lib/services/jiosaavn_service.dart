// lib/services/jiosaavn_service.dart
//
// JioSaavn se SIRF public playlist metadata (title + singer/artist) —
// koi login/API key nahi. Audio yahan se kabhi nahi liya jaata; gaana hamesha
// YouTube pe match hokar chalta hai (dekho curated_playlist_screen.dart).
//
// V120 FIX (user report: "JioSaavn ki playlists dikhti hi nahi"):
// Pehle sirf ek undocumented endpoint (jiosaavn.com/api.php, purana shape)
// try hota tha. Wo bina `api_version=4` ke purane shape me answer deta hai
// (playlist ka naam `listname` me aata hai, `title` me nahi) — purana parser
// har item ko "title nahi mila" maan ke skip kar deta tha, aur Home ka section
// chup-chaap gayab ho jata tha. Ab:
//   1) jiosaavn.com  api_version=4   (naya shape)
//   2) jiosaavn.com  legacy          (purana shape, listname/listid support)
//   3) saavn.dev     (public wrapper API — fallback agar jiosaavn.com block/
//                     shape-change ho)
// teeno sources ek ke baad ek try hote hain, browser jaise headers ke saath,
// aur parser har jaane-pehchane shape (title/name/listname, image string ya
// list, artists string ya list) ko samajhta hai. Har failure AppLogger me
// likha jata hai (`JIOSAAVN ...`) taaki agar phir bhi kuch na aaye to
// exact wajah log me mil sake. Home list 12 ghante cache hoti hai aur network
// fail hone par purani list dikhti rehti hai.
//
// Kabhi bhi throw nahi karta — fail par khaali list (Home crash nahi hota).

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class JioSaavnPlaylistPreview {
  final String id;
  final String title;
  final String subtitle;
  final String thumb;
  JioSaavnPlaylistPreview({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.thumb,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subtitle': subtitle,
        'thumb': thumb,
      };
}

class JioSaavnTrackMeta {
  final String title;
  final String artist;
  JioSaavnTrackMeta({required this.title, required this.artist});
}

class JioSaavnHomeCache {
  final List<JioSaavnPlaylistPreview> items;
  final int savedAtMs;
  const JioSaavnHomeCache(this.items, this.savedAtMs);
}

class JioSaavnService {
  JioSaavnService._internal();
  static final JioSaavnService instance = JioSaavnService._internal();

  static const String _base = 'https://www.jiosaavn.com/api.php';
  static const String _devBase = 'https://saavn.dev/api';

  /// saavn.dev se aayi playlist ID ke aage ye prefix lagta hai, taaki
  /// `getPlaylistTracks` ko pata rahe kaunsa source use karna hai.
  static const String _devPrefix = 'sd:';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Accept': 'application/json, text/plain, */*',
    'Accept-Language': 'en-IN,en;q=0.9,hi;q=0.8',
  };

  static const String _homeCacheKey = 'jiosaavn_home_previews_v1';

  // Ek source baar-baar fail ho raha ho to thodi der ke liye skip karte hain,
  // taaki 10 categories x timeout se Home der tak atka na rahe.
  final Map<String, int> _fails = {};
  final Map<String, int> _deadUntilMs = {};

  bool _isDead(String src) =>
      (_deadUntilMs[src] ?? 0) > DateTime.now().millisecondsSinceEpoch;

  void _markOk(String src) {
    _fails[src] = 0;
  }

  void _markFail(String src) {
    final n = (_fails[src] ?? 0) + 1;
    _fails[src] = n;
    if (n >= 3) {
      _deadUntilMs[src] =
          DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch;
      _fails[src] = 0;
    }
  }

  // ---------------------------------------------------------------- helpers

  String? _asStr(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  /// JioSaavn/wrapper text me HTML entities aati hain (&quot; &amp; &#039;).
  String _clean(String s) {
    var out = s
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
    out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    return out.trim();
  }

  String _hiRes(String? image) {
    if (image == null || image.isEmpty) return '';
    return image
        .replaceAll('150x150', '500x500')
        .replaceAll('50x50', '500x500')
        .replaceAll('http://', 'https://');
  }

  /// image: String ya [{quality,url}, ...] dono.
  String _imageOf(dynamic image) {
    if (image is String) return _hiRes(image);
    if (image is List && image.isNotEmpty) {
      String? best;
      for (final e in image) {
        if (e is Map) {
          final url = _asStr(e['url'] ?? e['link']);
          if (url != null) best = url; // aakhri usually sabse badi quality
        } else if (e is String && e.isNotEmpty) {
          best = e;
        }
      }
      return _hiRes(best);
    }
    return '';
  }

  Future<dynamic> _getJson(String src, Uri uri) async {
    try {
      final res = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        print('JIOSAAVN [$src] HTTP ${res.statusCode} for ${uri.path}');
        _markFail(src);
        return null;
      }
      try {
        final decoded = jsonDecode(res.body);
        _markOk(src);
        return decoded;
      } catch (_) {
        final head = res.body.length > 80 ? res.body.substring(0, 80) : res.body;
        print('JIOSAAVN [$src] non-JSON response: ${head.replaceAll('\n', ' ')}');
        _markFail(src);
        return null;
      }
    } catch (e) {
      print('JIOSAAVN [$src] request failed: $e');
      _markFail(src);
      return null;
    }
  }

  // -------------------------------------------------------- playlist search

  /// Query (jaise "Bollywood hits") se milte-julte playlists.
  Future<List<JioSaavnPlaylistPreview>> searchPlaylists(
    String query, {
    int max = 6,
  }) async {
    try {
      // 1) jiosaavn.com, naya shape
      if (!_isDead('jio4')) {
        final r = await _searchDirect(query, max, apiV4: true, src: 'jio4');
        if (r.isNotEmpty) return r;
      }
      // 2) jiosaavn.com, purana shape
      if (!_isDead('jio3')) {
        final r = await _searchDirect(query, max, apiV4: false, src: 'jio3');
        if (r.isNotEmpty) return r;
      }
      // 3) saavn.dev fallback
      if (!_isDead('dev')) {
        final r = await _searchDev(query, max);
        if (r.isNotEmpty) return r;
      }
    } catch (e) {
      print('JIOSAAVN searchPlaylists("$query") error: $e');
    }
    print('JIOSAAVN no playlists for "$query" from any source');
    return [];
  }

  Future<List<JioSaavnPlaylistPreview>> _searchDirect(
    String query,
    int max, {
    required bool apiV4,
    required String src,
  }) async {
    final params = <String, String>{
      '__call': 'search.getPlaylistResults',
      'q': query,
      'p': '1',
      'n': '$max',
      '_format': 'json',
      '_marker': '0',
      'ctx': 'web6dot0',
      if (apiV4) 'api_version': '4',
    };
    final decoded = await _getJson(src, Uri.parse(_base).replace(queryParameters: params));
    if (decoded == null) return [];
    final items = _itemsOf(decoded);
    final out = <JioSaavnPlaylistPreview>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final p = _previewFrom(raw);
      if (p != null) out.add(p);
      if (out.length >= max) break;
    }
    if (out.isEmpty) {
      print('JIOSAAVN [$src] parsed 0 playlists (items=${items.length}) for "$query"');
    }
    return out;
  }

  Future<List<JioSaavnPlaylistPreview>> _searchDev(String query, int max) async {
    final uri = Uri.parse('$_devBase/search/playlists').replace(
      queryParameters: {'query': query, 'page': '0', 'limit': '$max'},
    );
    final decoded = await _getJson('dev', uri);
    if (decoded == null) return [];
    final items = _itemsOf(decoded);
    final out = <JioSaavnPlaylistPreview>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final p = _previewFrom(raw, idPrefix: _devPrefix);
      if (p != null) out.add(p);
      if (out.length >= max) break;
    }
    if (out.isEmpty) {
      print('JIOSAAVN [dev] parsed 0 playlists (items=${items.length}) for "$query"');
    }
    return out;
  }

  /// Alag-alag response wrappers se items ki list nikaalta hai.
  List<dynamic> _itemsOf(dynamic decoded) {
    if (decoded is List) return decoded;
    if (decoded is Map) {
      for (final key in const ['results', 'data', 'playlists']) {
        final v = decoded[key];
        if (v is List) return v;
        if (v is Map) {
          final inner = _itemsOf(v);
          if (inner.isNotEmpty) return inner;
        }
      }
    }
    return const [];
  }

  JioSaavnPlaylistPreview? _previewFrom(Map raw, {String idPrefix = ''}) {
    final id = _asStr(raw['id'] ?? raw['listid'] ?? raw['perma_token'] ?? raw['token']);
    final titleRaw =
        _asStr(raw['title'] ?? raw['listname'] ?? raw['name'] ?? raw['list_name']);
    if (id == null || titleRaw == null) return null;
    final songCount = _asStr(
      raw['songCount'] ?? raw['song_count'] ??
          (raw['more_info'] is Map ? raw['more_info']['song_count'] : null),
    );
    final subtitle = _asStr(raw['subtitle']) ??
        (songCount != null ? '$songCount songs' : 'JioSaavn');
    return JioSaavnPlaylistPreview(
      id: '$idPrefix$id',
      title: _clean(titleRaw),
      subtitle: _clean(subtitle),
      thumb: _imageOf(raw['image']),
    );
  }

  // ------------------------------------------------------- playlist tracks

  /// Playlist ID se gaano ka title+singer (audio kabhi nahi).
  Future<List<JioSaavnTrackMeta>> getPlaylistTracks(
    String playlistId, {
    int max = 40,
  }) async {
    try {
      final isDev = playlistId.startsWith(_devPrefix);
      final realId = isDev ? playlistId.substring(_devPrefix.length) : playlistId;

      // Jis source se preview aaya, pehle wahi; phir baaki.
      final order = isDev ? ['dev', 'jio4', 'jio3'] : ['jio4', 'jio3', 'dev'];
      for (final src in order) {
        if (_isDead(src)) continue;
        final r = await _tracksFrom(src, realId, max);
        if (r.isNotEmpty) return r;
      }
    } catch (e) {
      print('JIOSAAVN getPlaylistTracks($playlistId) error: $e');
    }
    return [];
  }

  Future<List<JioSaavnTrackMeta>> _tracksFrom(String src, String id, int max) async {
    Uri uri;
    if (src == 'dev') {
      uri = Uri.parse('$_devBase/playlists').replace(
        queryParameters: {'id': id, 'page': '0', 'limit': '$max'},
      );
    } else {
      uri = Uri.parse(_base).replace(queryParameters: {
        '__call': 'playlist.getDetails',
        'listid': id,
        '_format': 'json',
        '_marker': '0',
        'ctx': 'web6dot0',
        if (src == 'jio4') 'api_version': '4',
      });
    }
    final decoded = await _getJson(src, uri);
    if (decoded == null || decoded is! Map) return [];
    final out = _parseTracks(decoded, max);
    if (out.isEmpty) {
      print('JIOSAAVN [$src] parsed 0 tracks for playlist $id');
    }
    return out;
  }

  List<JioSaavnTrackMeta> _parseTracks(Map decoded, int max) {
    final out = <JioSaavnTrackMeta>[];
    for (final raw in _trackItems(decoded)) {
      if (raw is! Map) continue;
      final titleRaw = _asStr(raw['title'] ?? raw['song'] ?? raw['name']);
      if (titleRaw == null) continue;
      out.add(JioSaavnTrackMeta(
        title: _clean(titleRaw),
        artist: _clean(_artistOf(raw)),
      ));
      if (out.length >= max) break;
    }
    return out;
  }

  // Sirf tests ke liye — response-shape parsing ko network ke bina check karne ko.
  @visibleForTesting
  JioSaavnPlaylistPreview? debugPreviewFrom(Map raw, {String idPrefix = ''}) =>
      _previewFrom(raw, idPrefix: idPrefix);

  @visibleForTesting
  List<JioSaavnTrackMeta> debugTracksFrom(Map decoded, {int max = 40}) =>
      _parseTracks(decoded, max);

  List<dynamic> _trackItems(Map decoded) {
    for (final key in const ['list', 'songs']) {
      final v = decoded[key];
      if (v is List) return v;
    }
    final data = decoded['data'];
    if (data is Map) return _trackItems(data);
    return const [];
  }

  String _namesOf(dynamic v) {
    if (v is String) return v;
    if (v is List) {
      return v
          .map((e) => e is Map ? _asStr(e['name']) : _asStr(e))
          .whereType<String>()
          .join(', ');
    }
    return '';
  }

  String _artistOf(Map raw) {
    // purana shape: singers / primary_artists (String)
    final singers = _asStr(raw['singers']);
    if (singers != null) return singers;
    final primary = _asStr(raw['primary_artists']);
    if (primary != null) return primary;

    // v4 shape: more_info.artistMap.primary_artists [{name}]
    final more = raw['more_info'];
    if (more is Map) {
      final map = more['artistMap'];
      if (map is Map) {
        final n = _namesOf(map['primary_artists']);
        if (n.isNotEmpty) return n;
      }
    }
    // saavn.dev shape: artists.primary [{name}]
    final artists = raw['artists'];
    if (artists is Map) {
      final n = _namesOf(artists['primary']);
      if (n.isNotEmpty) return n;
      final all = _namesOf(artists['all']);
      if (all.isNotEmpty) return all;
    }
    final music = _asStr(raw['music']);
    if (music != null) return music;

    // v4 subtitle: "Artist1, Artist2 - Album" -> " - " se pehle ka hissa.
    final sub = _asStr(raw['subtitle']);
    if (sub != null) {
      final i = sub.indexOf(' - ');
      return i > 0 ? sub.substring(0, i) : sub;
    }
    return '';
  }

  // ------------------------------------------------------------- Home cache

  Future<JioSaavnHomeCache> readHomeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_homeCacheKey);
      if (raw == null || raw.isEmpty) return const JioSaavnHomeCache([], 0);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const JioSaavnHomeCache([], 0);
      final items = <JioSaavnPlaylistPreview>[];
      final list = decoded['items'];
      if (list is List) {
        for (final e in list) {
          if (e is! Map) continue;
          final id = _asStr(e['id']);
          final title = _asStr(e['title']);
          if (id == null || title == null) continue;
          items.add(JioSaavnPlaylistPreview(
            id: id,
            title: title,
            subtitle: _asStr(e['subtitle']) ?? 'JioSaavn',
            thumb: _asStr(e['thumb']) ?? '',
          ));
        }
      }
      final at = decoded['at'];
      return JioSaavnHomeCache(items, at is num ? at.toInt() : 0);
    } catch (_) {
      return const JioSaavnHomeCache([], 0);
    }
  }

  Future<void> writeHomeCache(List<JioSaavnPlaylistPreview> items) async {
    if (items.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _homeCacheKey,
        jsonEncode({
          'at': DateTime.now().millisecondsSinceEpoch,
          'items': items.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {}
  }
}
