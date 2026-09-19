// lib/services/jiosaavn_service.dart
//
// NEW (2026-09-19, v95) — JioSaavn se SIRF public playlist metadata (title +
// singer/artist) nikalne ke liye — koi login, koi API key nahi chahiye.
// JioSaavn ka koi official public API nahi hai; ye wahi undocumented,
// website-khud-use-karti-hai wala endpoint hai jo saari open-source JioSaavn
// wrapper libraries (jiosaavn-api, saavn_play, wagera) use karte hain —
// sirf metadata ke liye, koi audio yahan se kabhi nahi liya jaata. Audio
// hamesha YouTube se hi aata hai (dekho curated_playlist_screen.dart —
// title+artist YouTube pe match karke play-able Song banta hai), bilkul
// wahi pattern jo Spotify import (spotify_service.dart) ke liye already
// established hai.
//
// RELIABILITY NOTE: ye endpoint reverse-engineered/undocumented hai —
// koi bhi field kabhi bhi missing ho sakta hai ya shape badal sakta hai.
// Isliye poore is file mein defensive parsing hai: koi bhi cheez samajh na
// aaye to us item/us poori category ko sirf skip karo (khaali list return
// karo), kabhi bhi throw karke poore Home screen ko crash mat karo — same
// convention jo innertube_client.dart aur youtube_service.dart follow
// karte hain.

import 'dart:convert';
import 'package:http/http.dart' as http;

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
}

class JioSaavnTrackMeta {
  final String title;
  final String artist;
  JioSaavnTrackMeta({required this.title, required this.artist});
}

class JioSaavnService {
  JioSaavnService._internal();
  static final JioSaavnService instance = JioSaavnService._internal();

  static const String _base = 'https://www.jiosaavn.com/api.php';

  // Image URLs "150x150"/"50x50" me aate hain — behtar resolution ke liye
  // "500x500" se replace kar dete hain (jaisa saari community wrappers
  // karte hain). Fail-safe: pattern na mile to jo mila wahi wapas.
  String _hiRes(String? image) {
    if (image == null || image.isEmpty) return '';
    return image.replaceAll('150x150', '500x500').replaceAll('50x50', '500x500');
  }

  String? _asStr(dynamic v) {
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  // Query (jaise "Bollywood hits", "Punjabi hits") se milte-julte
  // curated/editorial playlists dhoondta hai.
  Future<List<JioSaavnPlaylistPreview>> searchPlaylists(
    String query, {
    int max = 6,
  }) async {
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        '__call': 'search.getPlaylistResults',
        'q': query,
        'p': '1',
        'n': '$max',
        '_format': 'json',
        '_marker': '0',
        'ctx': 'web6dot0',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];

      dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        return []; // response JSON nahi tha (HTML error page wagera) — skip
      }

      // Kabhi seedha List aata hai, kabhi {"results": [...]} ya
      // {"data": [...]} wale shape mein — teeno handle karo.
      List<dynamic> items;
      if (decoded is List) {
        items = decoded;
      } else if (decoded is Map && decoded['results'] is List) {
        items = decoded['results'] as List;
      } else if (decoded is Map && decoded['data'] is List) {
        items = decoded['data'] as List;
      } else {
        return [];
      }

      final out = <JioSaavnPlaylistPreview>[];
      for (final raw in items) {
        if (raw is! Map) continue;
        final id = _asStr(raw['id'] ?? raw['listid'] ?? raw['token']);
        final title = _asStr(raw['title'] ?? raw['name']);
        if (id == null || title == null) continue; // shape samajh nahi aaya — skip
        out.add(JioSaavnPlaylistPreview(
          id: id,
          title: title,
          subtitle: _asStr(raw['subtitle']) ?? 'JioSaavn',
          thumb: _hiRes(_asStr(raw['image'])),
        ));
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      // Network/parsing fail — is category ke liye bas khaali list, poora
      // Home screen crash nahi hoga (dekho home_screen.dart ke try/catch).
      return [];
    }
  }

  // Playlist ID se uske gaano ka title+singer nikalta hai — audio URL
  // yahan se KABHI nahi (wo hamesha YouTube se hi resolve hota hai).
  Future<List<JioSaavnTrackMeta>> getPlaylistTracks(
    String playlistId, {
    int max = 40,
  }) async {
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        '__call': 'playlist.getDetails',
        'listid': playlistId,
        '_format': 'json',
        '_marker': '0',
        'ctx': 'web6dot0',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return [];

      dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        return [];
      }
      if (decoded is! Map) return [];
      final list = decoded['list'] ?? decoded['songs'];
      if (list is! List) return [];

      final out = <JioSaavnTrackMeta>[];
      for (final raw in list) {
        if (raw is! Map) continue;
        final title = _asStr(raw['title'] ?? raw['song']);
        if (title == null) continue;
        final artist = _asStr(raw['singers']) ??
            _asStr(raw['primary_artists']) ??
            _asStr(raw['subtitle']) ??
            '';
        out.add(JioSaavnTrackMeta(title: title, artist: artist ?? ''));
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
